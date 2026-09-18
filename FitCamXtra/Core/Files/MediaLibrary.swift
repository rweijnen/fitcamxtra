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
    /// Why the last read failed, if it did, and shown on the screen that
    /// failed. An unread error here is how a timeout came to be rendered as
    /// "Nothing on the card yet", which tells someone who has just had a
    /// crash that their camera locked nothing.
    private(set) var lastError: String?
    /// Events whose ids were not in the list the last time we connected.
    private(set) var unreadEventIDs: Set<String> = []
    /// True while what is on screen came from the last visit rather than from
    /// the camera. The screen says so rather than presenting it as current.
    private(set) var isShowingCachedListing = false
    private(set) var listingFetchedAt: Date?

    private var client: CameraClient?
    private let sink: LogSink
    private let downloads: MediaDownloader
    private var cache: LibraryCache?
    private var prefetch: Task<Void, Never>?

    init(sink: LogSink, downloads: MediaDownloader) {
        self.sink = sink
        self.downloads = downloads
    }

    func attach(client: CameraClient?, host: String?) {
        self.client = client
        downloads.host = host
        prefetch?.cancel()
        prefetch = nil

        guard let host else {
            cache = nil
            events = []
            files = []
            unreadEventIDs = []
            isShowingCachedListing = false
            listingFetchedAt = nil
            return
        }

        // Paint what was on the card last time straight away. The camera takes
        // most of a second to describe a card and several times that for a
        // full one, and a stale listing that says it is stale beats an empty
        // screen.
        let cache = LibraryCache(cameraID: host)
        self.cache = cache
        if files.isEmpty, let stored = cache.load() {
            files = stored.files.sorted(by: MediaLibrary.newestFirst)
            events = MediaLibrary.lockedEvents(in: files)
            isShowingCachedListing = true
            listingFetchedAt = stored.fetchedAt
            sink.log(.info, .app,
                     "Showing \(files.count) files remembered from \(stored.fetchedAt.formatted())")
        }
    }

    // MARK: - Events

    /// Locked clips, which is what Events shows. cmd=3015 returns the whole
    /// card either way, so this is a filter rather than a second request.
    static func lockedEvents(in files: [MediaFile]) -> [CameraEvent] {
        files
            .filter { $0.kind == .video && $0.isLocked }
            .sorted(by: MediaLibrary.newestFirst)
            .map { file in
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
    }

    func loadEvents(lastSeenID: String?) async {
        guard let client else { return }
        // The listing this needs is the listing the card screen needs. Pulling
        // it twice cost a second of an already slow camera for nothing.
        if files.isEmpty || isShowingCachedListing {
            await loadFiles()
        }
        isLoadingEvents = true
        defer { isLoadingEvents = false }

        events = MediaLibrary.lockedEvents(in: files)
        sink.log(.info, .app,
                 "\(files.count) files listed, \(events.count) carry the lock attribute")

        let undated = events.filter { $0.recordedAt == nil }.count
        if undated > 0 {
            sink.log(.warning, .app,
                     "\(undated) of \(events.count) locked clips carried no readable timestamp, "
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
            // Somebody is waiting for this, so it goes ahead of the prefetch.
            let response = try await downloads.gate.interactive {
                try await client.send(.eventFileList, par: 0)
            }
            lastError = nil
            sink.log(.info, .app, "File list fetched", detail: String(response.raw.prefix(2000)))
            let parsed = FileListParser.parse(Data(response.raw.utf8))
                .sorted(by: MediaLibrary.newestFirst)
            if !parsed.isEmpty {
                files = parsed
                events = MediaLibrary.lockedEvents(in: parsed)
                isShowingCachedListing = false
                listingFetchedAt = Date()
                cache?.save(parsed)
                sink.log(.info, .app, "\(files.count) files on the card")
                startPrefetch()
                return
            }
            sink.log(.warning, .app, "The file list came back empty or in an unrecognised shape")
            files = []
            isShowingCachedListing = false
        } catch {
            lastError = error.localizedDescription
            sink.log(.error, .app, "File list failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Filling the cache

    /// Pulls thumbnails the app does not have yet, newest first, one at a
    /// time, and only while nobody is waiting on the camera for anything else.
    ///
    /// Only thumbnails and the listing are ever fetched this way. A clip is
    /// tens of megabytes and stays on the card until someone asks for it.
    func startPrefetch() {
        prefetch?.cancel()
        let targets = files
        guard !targets.isEmpty else { return }

        prefetch = Task { [weak self] in
            guard let self else { return }
            var fetched = 0
            var missing = 0

            for file in targets {
                if Task.isCancelled { break }
                if self.downloads.hasThumbnail(for: file) { continue }
                missing += 1

                // Yield to anything a person started, then leave a gap so a
                // burst of these cannot crowd out a request that arrives next.
                await self.downloads.gate.waitUntilIdle()
                if Task.isCancelled { break }

                if await self.downloads.thumbnail(for: file) != nil {
                    fetched += 1
                } else {
                    // The camera has said it will not serve these. Asking 80
                    // more times is noise.
                    break
                }
                try? await Task.sleep(for: .milliseconds(120))
            }

            if fetched > 0 {
                self.sink.log(.info, .app,
                              "Cached \(fetched) of \(missing) missing thumbnails in the background")
            }
        }
    }

    func stopPrefetch() {
        prefetch?.cancel()
        prefetch = nil
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
