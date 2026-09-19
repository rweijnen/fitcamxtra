import Foundation
import Photos
import UIKit

/// How much of a download is on disk. Shared between the transfer queue, which
/// writes it, and the retry loop, which reads it after a failure.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64 = 0

    var value: Int64 {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Downloads clips and stills from the camera's own HTTP file server and puts
/// them in the photo library. Apple-specific: the Android port replaces this
/// whole file and keeps everything above it.
@MainActor
final class MediaDownloader {
    var host: String? {
        didSet {
            guard host != oldValue else { return }
            // A different camera, or the same one on a different address, gets
            // a fresh judgement. One timeout used to disable every thumbnail
            // for the rest of the process.
            thumbnailsUnavailable = false
            hasLoggedThumbnailFailure = false
            useAlternateThumbnailCommand = false
        }
    }
    private let sink: LogSink
    private let session: URLSession
    private let thumbnails = ThumbnailCache()
    private var hasLoggedThumbnailFailure = false
    /// True once the camera has answered a thumbnail request with something
    /// that is not an image. Read by the card screen, which owes the user an
    /// explanation for a grid of placeholders.
    private(set) var thumbnailsUnavailable = false
    /// Set once 4001 has refused, so the next tile tries 4002 — the firmware's
    /// command table gives both the same handler — before previews are written
    /// off entirely.
    private var useAlternateThumbnailCommand = false
    /// Work the app started by itself waits behind anything a person is
    /// waiting on. The camera serves one thing at a time well.
    let gate: CameraActivityGate

    init(sink: LogSink, gate: CameraActivityGate) {
        self.sink = sink
        self.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        // Two at a time. A grid of tiles will ask for as many as it can draw,
        // and this camera serves one thing at a time well.
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    enum DownloadError: LocalizedError {
        case notConnected
        case badResponse(Int)
        case photosDenied
        case empty

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to the camera."
            case .badResponse(let code): return "The camera answered with \(code)."
            case .photosDenied: return "Permission to add to Photos was refused."
            case .empty: return "The camera returned an empty file."
            }
        }
    }

    /// Retries of a dropped download before giving up and saying so.
    private let maxDownloadAttempts = 4

    private func url(for path: String) -> URL? {
        guard let host else { return nil }
        if path.lowercased().hasPrefix("http") { return URL(string: path) }
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "http://\(host)\(escaped)")
    }

    // MARK: - Thumbnails

    /// Throws away every cached thumbnail. Used when a camera is forgotten:
    /// these are pictures of the user's own driving, and Forget should mean it.
    func clearThumbnails() {
        thumbnails.clear()
        thumbnailsUnavailable = false
        hasLoggedThumbnailFailure = false
    }

    /// A thumbnail already on disk, without asking the camera for anything.
    func cachedThumbnail(for file: MediaFile) -> UIImage? {
        thumbnails.image(for: file.cameraPath)
    }

    func hasThumbnail(for file: MediaFile) -> Bool {
        thumbnails.contains(file.cameraPath)
    }

    /// - Parameter background: true when the app asked for this on its own
    ///   initiative. Background requests wait for anything a person is
    ///   waiting on; foreground ones announce themselves so the prefetch
    ///   stands down instead of competing.
    ///
    ///   Without this, scrolling the card during a save reproduced exactly
    ///   the failure the gate was added to prevent: tiles firing requests at
    ///   the camera while it was trying to serve an 80 MB download.
    func thumbnail(for file: MediaFile, background: Bool = false) async -> UIImage? {
        if let cached = thumbnails.image(for: file.cameraPath) { return cached }
        // Failures are remembered too. Without this every redraw of a card of
        // 83 clips asked again, which is a flood of requests at an embedded
        // server that is also trying to serve a download.
        if thumbnailsUnavailable { return nil }

        // Stills can be fetched whole; a clip cannot, so ask the camera for its
        // own thumbnail rather than pulling down a minute of 1440p.
        let request: URLRequest?
        if file.kind == .photo, let url = url(for: file.path) {
            request = URLRequest(url: url)
        } else if let host {
            // The camera's own path, sent literally. The percent-encoded form
            // was answered with Status -21, and this CGI has never been shown
            // to decode percent escapes — the station credentials had to go
            // out raw for the same reason.
            request = thumbnailRequest(host: host, command: thumbnailCommand, path: file.cameraPath)
        } else {
            request = nil
        }

        guard let request else { return nil }
        if background {
            await gate.waitUntilIdle()
        } else {
            await gate.beginInteractive()
        }
        defer {
            if !background { Task { await gate.endInteractive() } }
        }

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse

            guard let http, (200...299).contains(http.statusCode) else {
                noteThumbnailFailure(file,
                                     "the camera answered \(http?.statusCode ?? -1)",
                                     url: request.url,
                                     data: data,
                                     latching: true)
                return nil
            }
            guard let image = UIImage(data: data) else {
                noteThumbnailFailure(file,
                                     "the \(data.count) bytes it sent are not an image",
                                     url: request.url,
                                     data: data,
                                     latching: true)
                return nil
            }
            thumbnails.store(data, image: image, for: file.cameraPath)
            return image
        } catch {
            noteThumbnailFailure(file, error.localizedDescription,
                                 url: request.url, data: nil, latching: false)
            return nil
        }
    }

    /// A blank tile told nobody anything: this path swallowed every failure.
    /// cmd=4001 is one of the commands whose parameter form was never
    /// confirmed on hardware, so what the camera sends back instead of an
    /// image is worth recording. Logged once per connection rather than once
    /// per tile, because a full card would otherwise flood the log with the
    /// same line.
    /// 4001 and 4002 share a handler in the firmware's command table, so if
    /// one refuses, the other costs a single request to find out.
    private var thumbnailCommand: Int {
        useAlternateThumbnailCommand ? 4002 : 4001
    }

    private func thumbnailRequest(host: String, command: Int, path: String) -> URLRequest? {
        // Only what would end the query string is encoded. A colon and a
        // backslash are legal in a query, and this camera wants them as they
        // are.
        let encoded = path
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: "#", with: "%23")
            .replacingOccurrences(of: " ", with: "%20")
        return URL(string: "http://\(host)/?custom=1&cmd=\(command)&str=\(encoded)")
            .map { URLRequest(url: $0) }
    }

    private func noteThumbnailFailure(
        _ file: MediaFile,
        _ reason: String,
        url: URL?,
        data: Data?,
        latching: Bool
    ) {
        // One refusal moves to the other command; a second gives up.
        if latching, !useAlternateThumbnailCommand {
            useAlternateThumbnailCommand = true
            sink.log(.info, .http,
                     "cmd=4001 refused a thumbnail; trying cmd=4002 for the next one",
                     detail: "\(file.displayName): \(reason)")
            return
        }

        // Only a camera that answered and refused is worth giving up on. A
        // timeout says the link was busy, which it often is while a clip is
        // downloading, and the next tile deserves its own try.
        thumbnailsUnavailable = latching
        guard !hasLoggedThumbnailFailure else { return }
        hasLoggedThumbnailFailure = true

        var detail = "asked  \(url?.absoluteString ?? "no usable URL")"
        if let data, !data.isEmpty {
            let text = String(decoding: data.prefix(300), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { detail += "\nsent   \(text)" }
        }
        sink.log(.warning, .http,
                 "No thumbnail for \(file.displayName): \(reason)",
                 detail: detail)
    }

    // MARK: - Saving

    /// Downloads one file and adds it to the photo library.
    func saveToPhotos(_ file: MediaFile,
                      progress: (@MainActor (TransferProgress) -> Void)? = nil) async throws {
        guard let url = url(for: file.path) else { throw DownloadError.notConnected }
        guard await requestPhotosPermission() else { throw DownloadError.photosDenied }

        await gate.beginInteractive()
        defer { Task { await gate.endInteractive() } }

        sink.log(.info, .http, "Downloading \(file.displayName) (\(file.sizeLabel)) from \(url)")

        let temporaryURL: URL
        let response: URLResponse
        do {
            // Streamed rather than handed to `session.download`, which reports
            // nothing until it finishes: a clip is tens of megabytes over the
            // camera's own wifi, and a progress bar that sits at zero for a
            // minute cannot be told from a hang.
            (temporaryURL, response) = try await downloadStreaming(from: url,
                                                                   expected: file.byteCount,
                                                                   progress: progress)
        } catch {
            sink.log(.error, .http,
                     "Download of \(file.displayName) failed: \(error.localizedDescription)",
                     detail: "url  \(url)")
            throw error
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            sink.log(.error, .http,
                     "The camera answered \(http.statusCode) for \(file.displayName)",
                     detail: "url  \(url)")
            throw DownloadError.badResponse(http.statusCode)
        }

        // The download lands under a random name, and Photos infers the type
        // from the extension, so move it next door with the real one.
        let named = temporaryURL
            .deletingLastPathComponent()
            .appendingPathComponent(file.displayName)
        try? FileManager.default.removeItem(at: named)
        try FileManager.default.moveItem(at: temporaryURL, to: named)
        defer { try? FileManager.default.removeItem(at: named) }

        let attributes = try? FileManager.default.attributesOfItem(atPath: named.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            sink.log(.error, .http, "\(file.displayName) downloaded as an empty file")
            throw DownloadError.empty
        }
        sink.log(.info, .http, "Downloaded \(file.displayName): \(size) bytes")

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.originalFilename = file.displayName
                request.addResource(with: file.kind == .photo ? .photo : .video,
                                    fileURL: named,
                                    options: options)
            }
        } catch {
            // Photos rejects a file it cannot read as the type claimed, and
            // its own error is the only thing that says which.
            sink.log(.error, .app,
                     "Photos refused \(file.displayName): \(error.localizedDescription)",
                     detail: "\(size) bytes, offered as \(file.kind == .photo ? "a photo" : "a video")")
            throw error
        }

        // A final report at the real size, so the last thing the screen shows
        // is the whole file rather than the last chunk before it finished.
        progress?(TransferProgress(bytesReceived: size, totalBytes: size, bytesPerSecond: 0))
        sink.log(.info, .app, "Saved \(file.displayName) to Photos")
    }

    /// Downloads a clip to a temporary file and hands back its URL, for the
    /// share sheet. The file keeps the camera's own name so it arrives
    /// recognisable, and lives in the caches directory, which the system
    /// reclaims on its own.
    func exportForSharing(
        _ file: MediaFile,
        progress: (@MainActor (TransferProgress) -> Void)? = nil
    ) async throws -> URL {
        guard let url = url(for: file.path) else { throw DownloadError.notConnected }

        await gate.beginInteractive()
        defer { Task { await gate.endInteractive() } }

        sink.log(.info, .http, "Downloading \(file.displayName) to share")
        let (temporaryURL, response) = try await downloadStreaming(from: url,
                                                                   expected: file.byteCount,
                                                                   progress: progress)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DownloadError.badResponse(http.statusCode)
        }

        let named = FileManager.default.temporaryDirectory
            .appendingPathComponent(file.displayName)
        try? FileManager.default.removeItem(at: named)
        try FileManager.default.moveItem(at: temporaryURL, to: named)
        return named
    }

    /// Saves a whole incident: the locked clip and the neighbours chosen.
    func saveIncident(
        _ bundle: IncidentBundle,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws {
        // Per file, because the clips are fetched one after another.
        let files = bundle.segments.compactMap(\.file)
        guard !files.isEmpty else { throw DownloadError.empty }

        for (index, file) in files.enumerated() {
            try await saveToPhotos(file)
            progress?(Double(index + 1) / Double(files.count))
        }
        sink.log(.info, .app, "Saved an incident of \(files.count) clips to Photos")
    }

    /// Downloads to a temporary file while saying how far it has got, and
    /// picks up where it left off when the camera drops the connection.
    ///
    /// A clip is tens of megabytes from an embedded server over its own wifi,
    /// and "The network connection was lost" part-way through is a normal
    /// event there rather than an exceptional one. Starting again from zero
    /// would make a large clip unsaveable on a link that drops once a minute,
    /// so each attempt asks for the bytes that are missing.
    private func downloadStreaming(
        from url: URL,
        expected: Int64,
        progress: (@MainActor (TransferProgress) -> Void)?
    ) async throws -> (URL, URLResponse) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        // Bytes on disk, updated as they land rather than on return: an
        // attempt that throws still wrote what it wrote, and the retry has to
        // know how much that was. Reading it only from the return value meant
        // a dropped download resumed from zero, which made the retry path
        // dead code.
        let counter = ByteCounter()
        var written: Int64 = 0
        var lastResponse: URLResponse?
        var attempt = 0

        while true {
            attempt += 1
            do {
                let (response, bytesWritten) = try await appendDownload(
                    from: url,
                    to: destination,
                    startingAt: written,
                    expected: expected,
                    progress: progress,
                    landed: counter
                )
                lastResponse = response
                written = bytesWritten
                break
            } catch {
                written = counter.value
                let resumable = written > 0 && attempt <= maxDownloadAttempts
                guard resumable else {
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
                sink.log(.warning, .http,
                         "The download stopped after \(written) bytes: "
                         + "\(error.localizedDescription). Asking for the rest.",
                         detail: "attempt \(attempt) of \(maxDownloadAttempts)")
            }
        }

        guard let lastResponse else { throw DownloadError.empty }
        return (destination, lastResponse)
    }

    /// One attempt, appending to what is already on disk.
    ///
    /// The transfer itself runs on `FileTransfer`'s own queue: this type is
    /// main-actor bound, and a clip is large enough that neither the byte
    /// loop nor the file writes belong on the thread the UI runs on.
    private func appendDownload(
        from url: URL,
        to destination: URL,
        startingAt offset: Int64,
        expected: Int64,
        progress: (@MainActor (TransferProgress) -> Void)?,
        landed: ByteCounter
    ) async throws -> (URLResponse, Int64) {
        let transfer = FileTransfer()

        let result = try await transfer.run(
            url: url,
            destination: destination,
            offset: offset,
            expected: expected,
            // Set straight from the transfer queue rather than hopped to the
            // main actor: a hop that has not run yet when the connection
            // drops would tell the retry that nothing was written.
            landed: { bytes in landed.value = bytes },
            progress: progress.map { report in
                // The transfer calls this from its own queue, so the hop to
                // the main actor is explicit and the closure is declared
                // Sendable rather than being promoted on the way through.
                { @Sendable update in
                    Task { @MainActor in report(update) }
                }
            }
        )

        if offset > 0 && !result.resumed {
            sink.log(.info, .http, "The camera ignored the range request; starting again")
        }
        landed.value = result.bytesOnDisk
        return (result.response, result.bytesOnDisk)
    }

    private func requestPhotosPermission() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .authorized || current == .limited { return true }
        if current == .denied || current == .restricted { return false }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status == .authorized || status == .limited)
            }
        }
    }

    // MARK: - Deleting

    /// The camera's file server deletes with a query flag; the CGI command is
    /// tried first because it also clears the protect bit.
    func delete(_ file: MediaFile, client: CameraClient?) async throws {
        await gate.beginInteractive()
        defer { Task { await gate.endInteractive() } }

        if let client {
            do {
                try await client.send(.deleteFile, str: file.cameraPath)
                sink.log(.info, .app, "Deleted \(file.displayName)")
                return
            } catch {
                // Raised from debug: this is the path a locked clip takes,
                // because the CGI is tried first for clearing the protect
                // bit, and a refusal here is the reason the fallback runs.
                sink.log(.warning, .app,
                         "The delete command refused \(file.displayName): "
                         + "\(error.localizedDescription). Trying the file server.")
            }
        }

        guard let host else { throw DownloadError.notConnected }
        let escaped = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        guard let url = URL(string: "http://\(host)\(escaped)?del=1") else {
            throw DownloadError.notConnected
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DownloadError.badResponse(http.statusCode)
        }

        // A 200 is not a deletion. This server answers with the same XML the
        // CGI uses, and a negative Status inside a 200 read as success — so
        // the app reported clips erased that were still on the card, and the
        // next listing quietly brought them back.
        if let parsed = try? CameraResponseParser.parse(data),
           let status = parsed.status, status != 0 {
            sink.log(.error, .app,
                     "The file server refused to delete \(file.displayName): status \(status)",
                     detail: String(parsed.raw.prefix(400)))
            throw CameraError.commandFailed(command: CameraCommand.deleteFile.rawValue, status: status)
        }

        sink.log(.info, .app, "Deleted \(file.displayName) via the file server")
    }
}
