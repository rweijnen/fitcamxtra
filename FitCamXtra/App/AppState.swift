import Foundation
import Observation
import UIKit

/// Everything the app remembers about the camera between launches.
/// No credentials are ever stored: the SSID prefix is a matching hint only.
struct RememberedCamera: Codable, Equatable {
    /// Set from what the camera reports. Empty until one has been connected,
    /// so nothing invents a device that is not there.
    var name: String
    var lastHost: String?
    var lastSSID: String?
    var ssidPrefix: String
    var lastSeenEventID: String?
    /// When the newest event we have shown was recorded. Identity alone is
    /// not enough on a camera that loop-overwrites: the remembered clip is
    /// routinely gone, and then every locked clip counts as new.
    var lastSeenEventAt: Date?
    var autoSaveNewEvents: Bool
    /// The camera's own access point, as the camera reported it (cmd=3029).
    /// Empty until one has said so: the name cannot be derived from the model,
    /// and Connect used to send people looking for an invented one.
    /// The home network the camera was last told to join. The passphrase is
    /// deliberately not kept: it goes to the camera and nowhere else.
    var homeSSID: String?
    /// Cleared by Forget. Without this the sweep finds the camera again within
    /// seconds and forgetting looks like it did nothing.
    var autoConnectEnabled: Bool

    static let `default` = RememberedCamera(
        name: "",
        lastHost: nil,
        lastSSID: nil,
        ssidPrefix: "",
        lastSeenEventID: nil,
        autoSaveNewEvents: false,
        homeSSID: nil,
        autoConnectEnabled: true
    )

    init(
        name: String,
        lastHost: String?,
        lastSSID: String?,
        ssidPrefix: String,
        lastSeenEventID: String?,
        lastSeenEventAt: Date? = nil,
        autoSaveNewEvents: Bool,
        homeSSID: String?,
        autoConnectEnabled: Bool
    ) {
        self.name = name
        self.lastHost = lastHost
        self.lastSSID = lastSSID
        self.ssidPrefix = ssidPrefix
        self.lastSeenEventID = lastSeenEventID
        self.lastSeenEventAt = lastSeenEventAt
        self.autoSaveNewEvents = autoSaveNewEvents
        self.homeSSID = homeSSID
        self.autoConnectEnabled = autoConnectEnabled
    }

    /// Decoded field by field with defaults. The synthesised decoder fails
    /// outright on a key added in a later build, which would silently discard
    /// everything the app had remembered.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        lastHost = try container.decodeIfPresent(String.self, forKey: .lastHost)
        lastSSID = try container.decodeIfPresent(String.self, forKey: .lastSSID)
        // A build before this one stored the invented default. Drop it, so
        // the camera's own answer replaces it rather than sitting behind it.
        let storedPrefix = try container.decodeIfPresent(String.self, forKey: .ssidPrefix) ?? ""
        ssidPrefix = storedPrefix == "CAR-WA7053" ? "" : storedPrefix
        lastSeenEventID = try container.decodeIfPresent(String.self, forKey: .lastSeenEventID)
        lastSeenEventAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenEventAt)
        autoSaveNewEvents = try container.decodeIfPresent(Bool.self, forKey: .autoSaveNewEvents) ?? false
        homeSSID = try container.decodeIfPresent(String.self, forKey: .homeSSID)
        autoConnectEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoConnectEnabled) ?? true
    }
}

enum AppTab: Hashable {
    case live
    case events
    case files
    case settings
}

enum ConnectionState: Equatable {
    case disconnected
    case searching(String)
    case connected(DiscoveredCamera)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var camera: DiscoveredCamera? {
        if case .connected(let camera) = self { return camera }
        return nil
    }
}

@Observable
@MainActor
final class AppState {
    // Connection
    var connection: ConnectionState = .disconnected
    var remembered: RememberedCamera = .default
    var networkMode: NetworkMode = .accessPoint
    var discoveryStatus: String?
    /// What stood in the way of the last search, when the app could tell.
    /// Drives the offer to open iOS Settings, because the two things that
    /// produce it are both fixed there and nowhere else.
    var searchObstacle: DiscoveryOutcome.Obstacle?
    /// Set when the phone's network is wider than the range swept without
    /// asking, so the UI can offer the full sweep rather than the app quietly
    /// concluding the camera is absent.
    var widerScanOffer: DiscoveryOutcome.WiderScan?

    // Live
    var isRecording = false
    /// Why the last start or stop did not happen. Shown on Live.
    var recordingProblem: String?
    var elapsedSeconds = 0
    var isImmersive = false
    var snapshotToastVisible = false
    var snapshotMessage = ""

    // Chrome
    var tab: AppTab = .live
    var isConnectSheetPresented = false

    // Device chips. These are raw codes, not percentages: cmd=3024 answers 1
    // and cmd=3019 answers 5 on a healthy unit, and neither scale is known, so
    // nothing here is rendered as a percentage.
    var sdCardStatusCode: Int?
    var batteryLevelCode: Int?

    /// True when the card query answers anything other than its healthy value.
    var sdCardLooksUnhealthy: Bool {
        guard let sdCardStatusCode else { return false }
        return sdCardStatusCode != 1
    }

    /// The in-app record of what actually happened. Nothing is sent anywhere.
    let diagnostics: DiagnosticsLog
    /// Camera settings, read from and written to the device.
    let settings: SettingsStore
    /// The live RTSP view.
    let liveStream: LiveStream
    /// What is on the card: locked events and the full listing.
    let library: MediaLibrary
    /// Downloads, thumbnails and saving to Photos.
    let downloader: MediaDownloader

    private let transport: CameraTransport
    private let discovery: DiscoveryService
    private let pathMonitor = NetworkPathMonitor()
    private let sink: LogSink
    private var client: CameraClient?
    private var tickTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    /// Identifies a search so a task that is cancelled, or that finishes late
    /// after iOS suspended the app, cannot clear the handle of the search that
    /// replaced it. Without this, a stale run left the app looking busy and
    /// every later attempt was dropped as "already searching".
    private var discoveryGeneration = 0
    /// True once the path monitor has reported where the phone is.
    private var hasSeenNetwork = false
    /// Fruitless searches in a row. Sweeping a network the camera is not on
    /// costs seconds of radio every time, and repeating it on every return to
    /// the foreground neither finds the camera nor tells the user anything
    /// new, so the app stops and hands the decision back.
    private var searchAttempts = 0
    /// How many of those to run before waiting to be asked.
    private let maxAutomaticSearches = 3

    var isSearching: Bool { discoveryTask != nil }

    init(transport: CameraTransport = URLSessionTransport(),
         interfaces: NetworkInterfaceProviding = NetworkInterfaceProvider()) {
        let log = DiagnosticsLog()
        let sink = DiagnosticsSink(log)
        let gate = CameraActivityGate()
        self.diagnostics = log
        self.sink = sink
        self.settings = SettingsStore(sink: sink)
        self.liveStream = LiveStream(sink: sink, gate: gate)
        let downloader = MediaDownloader(sink: sink, gate: gate)
        self.downloader = downloader
        self.library = MediaLibrary(sink: sink, downloads: downloader)
        self.transport = transport
        self.discovery = DiscoveryService(
            transport: transport,
            interfaces: interfaces,
            reachability: ICMPPinger(),
            sink: sink
        )
        self.remembered = RememberedStore.load() ?? .default
    }

    // MARK: - Automatic connection

    /// Called once at launch. From then on the app reconnects by itself when
    /// the network changes or it returns to the foreground.
    func startAutoConnect() {
        recordEnvironment()
        sink.log(.info, .app, "App started, watching for network changes")
        pathMonitor.start { [weak self] description in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // The monitor reports the current path as soon as it starts.
                // That is the network the launch search is already using, not
                // a change, and cancelling for it threw away a search that had
                // just begun.
                guard self.hasSeenNetwork else {
                    self.hasSeenNetwork = true
                    self.sink.log(.info, .network, "On \(description)")
                    self.connectIfNeeded(reason: "the app launched")
                    return
                }

                self.sink.log(.info, .network, "Network changed to \(description)")
                // A different network is new information: it earns a fresh
                // search even after the app has given up on the old one, and
                // the sweep already running is walking a subnet the phone has
                // left.
                self.searchAttempts = 0
                self.cancelDiscovery(reason: "the network changed")
                self.connectIfNeeded(reason: "the network changed")
            }
        }
        connectIfNeeded(reason: "the app launched")
    }

    /// Stamps the export header, so a log sent on its own still says which
    /// build and which device produced it.
    private func recordEnvironment() {
        let bundle = Bundle.main.infoDictionary
        let version = bundle?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        diagnostics.setContext("app", "FitCamXtra \(version) (\(build))")
        diagnostics.setContext("ios", "\(device.systemName) \(device.systemVersion)")
        diagnostics.setContext("device", device.model)
    }

    func onForeground() {
        connectIfNeeded(reason: "the app came to the foreground")
    }

    /// iOS suspends the app within seconds of it leaving the screen, which is
    /// exactly when someone goes to Settings to join the camera's access
    /// point. A sweep caught by that suspension neither progresses nor ends:
    /// one was seen to sit there for 2 hours 45 minutes, and every return to
    /// the foreground in between was dropped as "already searching". Ending it
    /// here means the app comes back ready to look on the new network.
    func onBackground() {
        cancelDiscovery(reason: "the app went to the background")
        // iOS is about to suspend us anyway, and a prefetch that resumes
        // mid-request on a camera that has moved on is worse than starting it
        // again on the way back.
        library.stopPrefetch()
    }

    /// Ends the running search, if there is one, and makes sure its late
    /// completion cannot clear the handle of whatever replaces it.
    func cancelDiscovery(reason: String) {
        guard let task = discoveryTask else { return }
        sink.log(.info, .app, "Stopping the search because \(reason)")
        discoveryGeneration &+= 1
        discoveryTask = nil
        task.cancel()
        if case .searching = connection {
            connection = .disconnected
        }
        discoveryStatus = nil
    }

    /// Starts a search unless one is already running. When already connected it
    /// first checks the current camera is still answering, which is one request
    /// rather than a whole sweep.
    func connectIfNeeded(reason: String) {
        guard remembered.autoConnectEnabled else {
            sink.log(.info, .app,
                     "Not searching (\(reason)): this camera was forgotten. Use Scan again.")
            return
        }
        guard searchAttempts < maxAutomaticSearches || connection.isConnected else {
            sink.log(.info, .app,
                     "Not searching (\(reason)): \(searchAttempts) searches found nothing on "
                     + "this network. Waiting for Scan again, or for the network to change.")
            discoveryStatus = "No camera found after \(searchAttempts) attempts. "
                + "Join the camera's wifi, then tap Scan again."
            return
        }
        guard discoveryTask == nil else {
            sink.log(.debug, .app, "Already searching, ignoring: \(reason)")
            return
        }

        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        discoveryTask = Task { @MainActor [weak self] in
            defer { self?.finishDiscovery(generation: generation) }
            guard let self else { return }

            if let camera = self.connection.camera {
                if await self.discovery.probe(host: camera.host, timeout: 1.5, source: .cachedAddress) != nil {
                    self.sink.log(.debug, .app, "Still connected to \(camera.host)")
                    return
                }
                self.sink.log(.warning, .app, "Lost \(camera.host), searching again")
                self.connection = .disconnected
            }

            self.sink.log(.info, .app, "Searching because \(reason)")
            self.searchAttempts += 1
            await self.runDiscovery(generation: generation)
        }
    }

    /// The discovery sheet is only ever opened by a tap, so opening it is a
    /// request to look now. It overrides both the attempt cap and Forget:
    /// those exist to stop the app searching on its own, not to stop the
    /// person asking. Without this the app sat inert on every launch after a
    /// Forget, with the reason visible only in the log.
    func searchBecauseConnectOpened() {
        guard !connection.isConnected, discoveryTask == nil else { return }

        if !remembered.autoConnectEnabled {
            remembered.autoConnectEnabled = true
            RememberedStore.save(remembered)
            sink.log(.info, .app, "Opening Connect undoes Forget: looking again")
        }
        searchAttempts = 0
        connectIfNeeded(reason: "you opened Connect")
    }

    var unreadCount: Int { library.unreadEventIDs.count }

    /// True once a camera has actually been connected. Drives whether the app
    /// offers to forget one.
    var hasRememberedCamera: Bool {
        remembered.lastHost != nil || !remembered.name.isEmpty
    }

    /// What to call the camera, or nil when none is known.
    var cameraName: String? {
        if let model = connection.camera?.model, !model.isEmpty { return model }
        return remembered.name.isEmpty ? nil : remembered.name
    }

    /// Called when the Events tab is opened, so the badge clears.
    func markEventsSeen() {
        guard let newest = library.markEventsSeen() else { return }
        remembered.lastSeenEventID = newest.id
        remembered.lastSeenEventAt = newest.recordedAt ?? remembered.lastSeenEventAt
        RememberedStore.save(remembered)
    }

    func cameraClient() -> CameraClient? { client }

    /// Launch lands on Events when something is new, otherwise Live.
    func landingTab() -> AppTab {
        unreadCount > 0 ? .events : .live
    }

    // MARK: - Discovery

    /// Manual "Scan again". Forces a search even when one looks unnecessary.
    func rescan() {
        cancelDiscovery(reason: "you asked for a rescan")
        connection = .disconnected
        // Asking again is the user overriding the app's decision to stop.
        searchAttempts = 0
        // Scanning again is an explicit request, so it undoes Forget.
        remembered.autoConnectEnabled = true
        RememberedStore.save(remembered)
        connectIfNeeded(reason: "you asked for a rescan")
    }

    private func runDiscovery(prefixLength: Int? = nil, generation: Int? = nil) async {
        connection = .searching("Looking for the camera")
        discoveryStatus = nil
        widerScanOffer = nil

        let cached = remembered.lastHost
        let outcome = await discovery.discover(
            cachedHost: cached,
            prefixLength: prefixLength
        ) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A superseded run keeps reporting while it winds down, and
                // its "No camera answered" would land on the screen someone
                // is reading while the current sweep is still going.
                guard generation == nil || generation == self.discoveryGeneration else { return }
                self.apply(progress)
            }
        }

        // A search that was cancelled, by backgrounding or by a network
        // change, must not write its verdict over the one that replaced it.
        if let generation, generation != discoveryGeneration {
            sink.log(.debug, .app, "Discarding the result of a search that was superseded")
            return
        }

        searchObstacle = outcome.obstacle

        if let camera = outcome.camera {
            await connect(to: camera)
        } else {
            connection = .disconnected
            widerScanOffer = outcome.widerScan
            discoveryStatus = Self.status(for: outcome)
        }
    }

    /// Sweeps the phone's whole network, which the app never does unaided
    /// because it can run to tens of thousands of probes.
    func scanWiderNetwork() {
        guard let offer = widerScanOffer, discoveryTask == nil else { return }
        widerScanOffer = nil
        remembered.autoConnectEnabled = true
        RememberedStore.save(remembered)

        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        discoveryTask = Task { @MainActor [weak self] in
            defer { self?.finishDiscovery(generation: generation) }
            guard let self else { return }
            self.sink.log(.info, .app,
                          "Sweeping the whole /\(offer.prefixLength) because you asked")
            await self.runDiscovery(prefixLength: offer.prefixLength, generation: generation)
        }
    }

    /// Clears the handle only when the search that is ending is still the
    /// current one.
    private func finishDiscovery(generation: Int) {
        guard generation == discoveryGeneration else { return }
        discoveryTask = nil
    }

    /// What to say about a search that found nothing. The app knows more
    /// than "no camera found" in two cases, and saying the general thing when
    /// the specific one is known is how someone ends up searching for a
    /// camera that was never the problem.
    private static func status(for outcome: DiscoveryOutcome) -> String {
        switch outcome.obstacle {
        case .phoneNotOnWiFi:
            return "This phone is not on a wifi network, so there is nowhere to look."
        case .networkUnreachable:
            return "Nothing on this network answered at all, not even a ping."
        case nil:
            return outcome.widerScan == nil
                ? "No camera found on this network."
                : "No camera on this part of the network."
        }
    }

    private func apply(_ progress: DiscoveryProgress) {
        switch progress {
        case .tryingCachedAddress(let host):
            discoveryStatus = "Trying \(host)"
        case .sweeping(let subnet, let probed, let total):
            discoveryStatus = probed == 0
                ? "Scanning \(subnet)"
                : "Scanning \(subnet) - \(probed) of \(total)"
        case .found(let camera):
            discoveryStatus = "Found \(camera.host)"
        case .finishedWithoutResult:
            discoveryStatus = "No camera answered."
        }
    }

    func probeManual(host: String) async -> Bool {
        guard let found = await discovery.probe(host: host, timeout: 2.0, source: .manual) else {
            return false
        }
        await connect(to: found)
        return true
    }

    func connect(to camera: DiscoveredCamera) async {
        searchObstacle = nil
        let client = CameraClient(host: camera.host, transport: transport, sink: sink)
        self.client = client
        connection = .connected(camera)
        discoveryStatus = nil

        remembered.lastHost = camera.host
        remembered.autoConnectEnabled = true
        searchAttempts = 0
        if let model = camera.model, !model.isEmpty {
            remembered.name = model
        }
        RememberedStore.save(remembered)

        // Ask the camera what its own access point is called, so Connect can
        // name it instead of guessing.
        if remembered.lastSSID == nil || remembered.ssidPrefix.isEmpty,
           let response = try? await client.send(.wifiInfo) {
            let reported = CameraAccessPoint.parse(Data(response.raw.utf8))
            if let ssid = reported.ssid, !ssid.isEmpty {
                remembered.lastSSID = ssid
                remembered.ssidPrefix = ssid
                RememberedStore.save(remembered)
                sink.log(.info, .app, "The camera calls its own access point \(ssid)")
            }
        }

        diagnostics.setContext("camera", camera.model ?? "unreported")
        diagnostics.setContext("firmware", camera.firmware ?? "unreported")
        diagnostics.setContext("address", camera.host)
        sink.log(.info, .app, "Connected to \(camera.host) via \(camera.foundBy.label)")
        settings.attach(client: client)
        library.attach(client: client, host: camera.host)
        await refreshStatus()
        await library.loadEvents(lastSeenID: remembered.lastSeenEventID,
                                 lastSeenAt: remembered.lastSeenEventAt)
    }

    // MARK: - Network mode

    /// Applies the AP or station switch, then starts looking for the camera
    /// again, because changing mode drops it off the current network.
    func applyNetworkMode(
        _ mode: NetworkMode,
        ssid: String,
        passphrase: String
    ) async -> Result<Void, Error> {
        guard let client else { return .failure(CameraError.notConnected) }

        do {
            switch mode {
            case .station:
                sink.log(.info, .network, "Switching the camera to station mode on \(ssid)")
                try await client.applyStationMode(ssid: ssid, passphrase: passphrase)
                remembered.homeSSID = ssid
            case .accessPoint:
                sink.log(.info, .network, "Switching the camera back to its own access point")
                try await client.applyAccessPointMode()
            }

            networkMode = mode
            remembered.lastHost = nil        // the address changes with the mode
            RememberedStore.save(remembered)

            // The camera restarts its wifi, so give it a moment before looking.
            connection = .disconnected
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))
                self?.connectIfNeeded(reason: "the camera changed wifi mode")
            }
            return .success(())
        } catch {
            sink.log(.error, .network, "Mode switch failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    /// Runs a destructive settings action and refreshes what it affected.
    func runDestructive(_ setting: CameraSetting) async {
        guard case .destructiveAction(_, _, let par) = setting.kind else { return }
        let ok = await settings.runAction(setting, par: par)
        guard ok else { return }

        if setting.command == .formatSDCard {
            // The card is empty now. Without this the app kept listing every
            // clip that had just been erased, from its own cache.
            library.forgetCache()
            await library.loadFiles()
            await refreshStatus()
            return
        }

        if setting.command == .factoryReset {
            // A factory reset puts the camera back on its own access point.
            networkMode = .accessPoint
            remembered.lastHost = nil
            RememberedStore.save(remembered)
            connection = .disconnected
            connectIfNeeded(reason: "the camera was factory reset")
        } else {
            await refreshStatus()
        }
    }

    func forgetCamera() {
        sink.log(.info, .app, "Forgetting the camera")
        library.forgetCache()
        // Through cancelDiscovery, so the generation moves on: cancellation is
        // cooperative, and a search that had already found the camera would
        // otherwise finish, reconnect, and switch auto-connect back on.
        cancelDiscovery(reason: "the camera was forgotten")
        client = nil
        settings.attach(client: nil)
        library.attach(client: nil, host: nil)
        liveStream.stop()
        connection = .disconnected
        stopTicking()
        isRecording = false
        elapsedSeconds = 0
        remembered.lastHost = nil
        remembered.lastSSID = nil
        // The name and the access point came from the camera being forgotten,
        // so they go too. Leaving them behind kept a forgotten camera's name
        // on the Settings screen with nothing to connect it to.
        remembered.name = ""
        remembered.ssidPrefix = ""
        remembered.autoConnectEnabled = false
        RememberedStore.save(remembered)
        sink.log(.info, .app, "Camera forgotten. Auto-connect is off until you scan again.")
    }

    // MARK: - Status

    func refreshStatus() async {
        guard let client else { return }

        if let response = try? await client.send(.sdCardStatus) {
            sdCardStatusCode = response.int("value")
            if sdCardLooksUnhealthy {
                sink.log(.warning, .app, "SD card status is \(sdCardStatusCode ?? -1)")
            }
        }
        if let response = try? await client.send(.batteryStatus) {
            batteryLevelCode = response.int("value")
        }

        // cmd=3014 reports whether it is recording; a direct cmd=2016 answers
        // the elapsed seconds.
        if let response = try? await client.send(.allConfigValues) {
            let config = CameraConfigSnapshot.parse(Data(response.raw.utf8))
            if let mode = config.value(for: .setNetworkMode),
               let parsed = NetworkMode(rawValue: mode) {
                networkMode = parsed
            }
            let recording = (config.value(for: .recordStatus) ?? 0) == 1
            var elapsed = 0
            if let status = try? await client.send(.recordStatus) {
                elapsed = status.int("value") ?? 0
            }
            setRecording(recording, elapsed: elapsed)
        }
        // cmd=3003 answers nothing useful; cmd=3029 carries the real SSID.
        if let response = try? await client.send(.wifiInfo) {
            let ap = CameraAccessPoint.parse(Data(response.raw.utf8))
            if let ssid = ap.ssid, !ssid.isEmpty {
                remembered.lastSSID = ssid
                RememberedStore.save(remembered)
            }
        }
    }

    // MARK: - Live

    /// Starts or stops **the camera's** recording to its card. Nothing is
    /// recorded to the phone; this is cmd=2001, the dashcam's own switch.
    func toggleRecording() async {
        guard let client else { return }
        let wanted = !isRecording
        do {
            try await client.send(.setRecordStatus, par: wanted ? 1 : 0)
            setRecording(wanted, elapsed: 0)
            recordingProblem = nil

            // Status 0 means the command was accepted, not that it was
            // applied — the same distinction that made a resolution change
            // look like it had worked. Ask the camera what it is doing.
            await refreshStatus()
            if isRecording != wanted {
                recordingProblem = wanted
                    ? "The camera did not start recording."
                    : "The camera is still recording."
                sink.log(.warning, .app, recordingProblem ?? "")
            } else {
                sink.log(.info, .app, wanted ? "Camera recording started" : "Camera recording stopped")
            }
        } catch {
            // This used to re-read the status and say nothing, so a camera
            // that refused left the button springing back with no
            // explanation — on the one control whose whole job is making
            // sure the car is being recorded.
            recordingProblem = wanted
                ? "The camera would not start recording: \(error.localizedDescription)"
                : "The camera would not stop recording: \(error.localizedDescription)"
            sink.log(.error, .app, recordingProblem ?? "")
            await refreshStatus()
        }
    }

    func takeSnapshot() async {
        guard let client else { return }
        do {
            try await client.send(.takePhoto)
            snapshotMessage = "Snapshot saved to the camera's card"
        } catch {
            snapshotMessage = "The camera refused the snapshot"
        }
        snapshotToastVisible = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            snapshotToastVisible = false
        }
    }

    private func setRecording(_ recording: Bool, elapsed: Int) {
        isRecording = recording
        elapsedSeconds = elapsed
        recording ? startTicking() : stopTicking()
    }

    /// The timer only advances while recording and connected, so a dropped
    /// camera freezes it rather than inventing time.
    private func startTicking() {
        stopTicking()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRecording, self.connection.isConnected else { return }
                self.elapsedSeconds += 1
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    var elapsedLabel: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }
}

/// Small UserDefaults-backed store. Nothing sensitive lives here.
enum RememberedStore {
    private static let key = "fitcamxtra.remembered.camera"

    static func load() -> RememberedCamera? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RememberedCamera.self, from: data)
    }

    static func save(_ camera: RememberedCamera) {
        guard let data = try? JSONEncoder().encode(camera) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
