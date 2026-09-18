import Foundation
import Photos
import UIKit

/// Downloads clips and stills from the camera's own HTTP file server and puts
/// them in the photo library. Apple-specific: the Android port replaces this
/// whole file and keeps everything above it.
@MainActor
final class MediaDownloader {
    var host: String?
    private let sink: LogSink
    private let session: URLSession
    private var thumbnailCache: [String: UIImage] = [:]
    private var hasLoggedThumbnailFailure = false
    private var thumbnailsUnavailable = false

    init(sink: LogSink) {
        self.sink = sink
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
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

    /// Written out in blocks rather than byte by byte, and small enough that
    /// progress still moves on a slow link.
    private let chunkSize = 64 * 1024
    /// Retries of a dropped download before giving up and saying so.
    private let maxDownloadAttempts = 4

    private func url(for path: String) -> URL? {
        guard let host else { return nil }
        if path.lowercased().hasPrefix("http") { return URL(string: path) }
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "http://\(host)\(escaped)")
    }

    // MARK: - Thumbnails

    func thumbnail(for file: MediaFile) async -> UIImage? {
        if let cached = thumbnailCache[file.path] { return cached }
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
            // The camera's own path, backslashes and drive letter included.
            // The file server's path is a different thing, and the CGI answers
            // a request for it with something that is not an image.
            let escaped = file.cameraPath
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~")))
                ?? file.cameraPath
            request = URL(string: "http://\(host)/?custom=1&cmd=4001&str=\(escaped)").map { URLRequest(url: $0) }
        } else {
            request = nil
        }

        guard let request else { return nil }
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse

            guard let http, (200...299).contains(http.statusCode) else {
                noteThumbnailFailure(file,
                                     "the camera answered \(http?.statusCode ?? -1)",
                                     url: request.url,
                                     data: data)
                return nil
            }
            guard let image = UIImage(data: data) else {
                noteThumbnailFailure(file,
                                     "the \(data.count) bytes it sent are not an image",
                                     url: request.url,
                                     data: data)
                return nil
            }
            thumbnailCache[file.path] = image
            return image
        } catch {
            noteThumbnailFailure(file, error.localizedDescription, url: request.url, data: nil)
            return nil
        }
    }

    /// A blank tile told nobody anything: this path swallowed every failure.
    /// cmd=4001 is one of the commands whose parameter form was never
    /// confirmed on hardware, so what the camera sends back instead of an
    /// image is worth recording. Logged once per connection rather than once
    /// per tile, because a full card would otherwise flood the log with the
    /// same line.
    private func noteThumbnailFailure(_ file: MediaFile, _ reason: String, url: URL?, data: Data?) {
        thumbnailsUnavailable = true
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
    func saveToPhotos(_ file: MediaFile, progress: (@MainActor (Double) -> Void)? = nil) async throws {
        guard let url = url(for: file.path) else { throw DownloadError.notConnected }
        guard await requestPhotosPermission() else { throw DownloadError.photosDenied }

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

        progress?(1)
        sink.log(.info, .app, "Saved \(file.displayName) to Photos")
    }

    /// Saves a whole incident: the locked clip and the neighbours chosen.
    func saveIncident(
        _ bundle: IncidentBundle,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws {
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
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> (URL, URLResponse) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: destination.path, contents: nil)

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
                    progress: progress
                )
                lastResponse = response
                written = bytesWritten
                break
            } catch {
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
    private func appendDownload(
        from url: URL,
        to destination: URL,
        startingAt offset: Int64,
        expected: Int64,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> (URLResponse, Int64) {
        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let (stream, response) = try await session.bytes(for: request)

        // A server that ignores Range answers 200 and starts from the top, so
        // what is already on disk has to go.
        let honoursRange = (response as? HTTPURLResponse)?.statusCode == 206
        var written = offset
        if offset > 0 && !honoursRange {
            sink.log(.info, .http, "The camera ignored the range request; starting again")
            written = 0
        }

        let handle = try FileHandle(forWritingTo: destination)
        do {
            try handle.truncate(atOffset: UInt64(written))
            try handle.seekToEnd()
        } catch {
            try? handle.close()
            throw error
        }

        let reported = response.expectedContentLength > 0 ? response.expectedContentLength : 0
        let total = reported > 0 ? reported + (honoursRange ? offset : 0) : expected
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var lastReported = 0.0

        do {
            for try await byte in stream {
                buffer.append(byte)
                guard buffer.count >= chunkSize else { continue }

                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                guard total > 0 else { continue }
                let fraction = min(Double(written) / Double(total), 1)
                // Only on visible movement: this drives a view.
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    progress?(fraction)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
            }
            try handle.close()
        } catch {
            try? handle.write(contentsOf: buffer)
            try? handle.close()
            throw error
        }

        return (response, written)
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
        if let client {
            do {
                try await client.send(.deleteFile, str: file.cameraPath)
                sink.log(.info, .app, "Deleted \(file.displayName)")
                return
            } catch {
                sink.log(.debug, .app, "Delete command refused, trying the file server")
            }
        }

        guard let host else { throw DownloadError.notConnected }
        let escaped = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        guard let url = URL(string: "http://\(host)\(escaped)?del=1") else {
            throw DownloadError.notConnected
        }
        let (_, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DownloadError.badResponse(http.statusCode)
        }
        sink.log(.info, .app, "Deleted \(file.displayName) via the file server")
    }
}
