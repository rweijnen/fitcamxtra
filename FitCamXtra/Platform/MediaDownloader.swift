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

    private func url(for path: String) -> URL? {
        guard let host else { return nil }
        if path.lowercased().hasPrefix("http") { return URL(string: path) }
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "http://\(host)\(escaped)")
    }

    // MARK: - Thumbnails

    func thumbnail(for file: MediaFile) async -> UIImage? {
        if let cached = thumbnailCache[file.path] { return cached }

        // Stills can be fetched whole; a clip cannot, so ask the camera for its
        // own thumbnail rather than pulling down a minute of 1440p.
        let request: URLRequest?
        if file.kind == .photo, let url = url(for: file.path) {
            request = URLRequest(url: url)
        } else if let host {
            let escaped = file.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? file.path
            request = URL(string: "http://\(host)/?custom=1&cmd=4001&str=\(escaped)").map { URLRequest(url: $0) }
        } else {
            request = nil
        }

        guard let request else { return nil }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let image = UIImage(data: data) else { return nil }
            thumbnailCache[file.path] = image
            return image
        } catch {
            return nil
        }
    }

    // MARK: - Saving

    /// Downloads one file and adds it to the photo library.
    func saveToPhotos(_ file: MediaFile, progress: (@MainActor (Double) -> Void)? = nil) async throws {
        guard let url = url(for: file.path) else { throw DownloadError.notConnected }
        guard await requestPhotosPermission() else { throw DownloadError.photosDenied }

        sink.log(.info, .http, "Downloading \(file.displayName) (\(file.sizeLabel))")
        let (temporaryURL, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
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
        guard size > 0 else { throw DownloadError.empty }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            options.originalFilename = file.displayName
            request.addResource(with: file.kind == .photo ? .photo : .video, fileURL: named, options: options)
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
                try await client.send(.deleteFile, str: file.path)
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
