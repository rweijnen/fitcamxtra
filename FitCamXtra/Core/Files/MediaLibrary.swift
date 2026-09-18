import Foundation
import Observation

/// Fetches what is on the card: the locked-clip list that backs Events, and
/// the full listing that backs the card browser.
@Observable
@MainActor
final class MediaLibrary {
    private(set) var events: [CameraEvent] = []
    private(set) var files: [MediaFile] = []
    private(set) var isLoadingEvents = false
    private(set) var isLoadingFiles = false
    private(set) var lastError: String?
    /// Events whose ids were not in the list the last time we connected.
    private(set) var unreadEventIDs: Set<String> = []

    private var client: CameraClient?
    private let sink: LogSink
    private let downloads: MediaDownloader

    init(sink: LogSink, downloads: MediaDownloader) {
        self.sink = sink
        self.downloads = downloads
    }

    func attach(client: CameraClient?, host: String?) {
        self.client = client
        downloads.host = host
        if client == nil {
            events = []
            files = []
            unreadEventIDs = []
        }
    }

    // MARK: - Events

    func loadEvents(lastSeenID: String?) async {
        guard let client else { return }
        isLoadingEvents = true
        defer { isLoadingEvents = false }

        do {
            let response = try await client.send(.eventFileList)
            sink.log(.info, .app, "Event list fetched", detail: String(response.raw.prefix(2000)))

            // cmd=3015 returns the whole card, not an event list, so the
            // locked clips are the ones carrying the read-only attribute.
            let all = FileListParser.parse(Data(response.raw.utf8))
            let parsed = all
                .filter { $0.kind == .video && $0.isLocked }
                .sorted(by: MediaLibrary.newestFirst)
            sink.log(.info, .app,
                     "\(all.count) files listed, \(parsed.count) carry the lock attribute")

            // The listing says a clip is locked, never what locked it, so the
            // trigger stays unknown rather than claiming a button press.
            events = parsed.map { file in
                CameraEvent(
                    id: file.id,
                    recordedAt: file.recordedAt,
                    duration: file.duration,
                    trigger: .unknown,
                    path: file.path,
                    cameraPath: file.cameraPath,
                    isLocked: true
                )
            }

            let undated = parsed.filter { $0.recordedAt == nil }.count
            if undated > 0 {
                sink.log(.warning, .app,
                         "\(undated) of \(parsed.count) locked clips carried no readable timestamp, "
                         + "so their neighbouring clips cannot be matched")
            }

            // Anything newer than the last event we showed counts as new.
            if let lastSeenID, let index = events.firstIndex(where: { $0.id == lastSeenID }) {
                unreadEventIDs = Set(events.prefix(index).map(\.id))
            } else if lastSeenID == nil {
                unreadEventIDs = []
            } else {
                unreadEventIDs = Set(events.map(\.id))
            }

            sink.log(.info, .app, "\(events.count) locked clips, \(unreadEventIDs.count) new")
        } catch {
            lastError = error.localizedDescription
            sink.log(.error, .app, "Event list failed: \(error.localizedDescription)")
        }
    }

    func markEventsSeen() -> String? {
        unreadEventIDs = []
        return events.first?.id
    }

    // MARK: - Files

    func loadFiles() async {
        guard let client else { return }
        isLoadingFiles = true
        defer { isLoadingFiles = false }

        do {
            let response = try await client.send(.eventFileList, par: 0)
            sink.log(.info, .app, "File list fetched", detail: String(response.raw.prefix(2000)))
            let parsed = FileListParser.parse(Data(response.raw.utf8))
                .sorted(by: MediaLibrary.newestFirst)
            if !parsed.isEmpty {
                files = parsed
                sink.log(.info, .app, "\(files.count) files on the card")
                return
            }
            sink.log(.warning, .app, "The file list came back empty or in an unrecognised shape")
            files = []
        } catch {
            lastError = error.localizedDescription
            sink.log(.error, .app, "File list failed: \(error.localizedDescription)")
        }
    }

    /// Newest first, with anything the camera gave no timestamp for sorted
    /// last rather than being treated as brand new.
    static func newestFirst(_ a: MediaFile, _ b: MediaFile) -> Bool {
        switch (a.recordedAt, b.recordedAt) {
        case let (x?, y?): return x > y
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return a.path > b.path
        }
    }

    /// Files grouped by day, newest day first. A day of nil holds the files
    /// whose timestamp could not be read.
    func filesByDay(filter: FileFilter) -> [(day: Date?, files: [MediaFile])] {
        let calendar = Calendar.current
        let filtered = files.filter(filter.matches)
        let grouped = Dictionary(grouping: filtered) { file in
            file.recordedAt.map { calendar.startOfDay(for: $0) }
        }
        return grouped
            .map { (day: $0.key, files: $0.value.sorted(by: MediaLibrary.newestFirst)) }
            .sorted { lhs, rhs in
                switch (lhs.day, rhs.day) {
                case let (x?, y?): return x > y
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return false
                }
            }
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    var lockedBytes: Int64 { files.filter(\.isLocked).reduce(0) { $0 + $1.byteCount } }

    // MARK: - Incident bundles

    /// The clips around a locked one. Loop recording writes roughly one-minute
    /// chunks and the button only locks the chunk it landed in, so the start or
    /// the aftermath often sits in a neighbour.
    func bundle(for event: CameraEvent, range: IncidentBundle.Range) -> IncidentBundle {
        IncidentBundle.build(event: event, range: range, files: files)
    }
}

public enum FileFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case video = "Video"
    case photos = "Photos"
    case locked = "Locked"

    public var id: String { rawValue }

    func matches(_ file: MediaFile) -> Bool {
        switch self {
        case .all: return true
        case .video: return file.kind == .video
        case .photos: return file.kind == .photo
        case .locked: return file.isLocked
        }
    }
}
