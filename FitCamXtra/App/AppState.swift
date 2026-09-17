import Foundation
import Observation

/// Everything the app remembers about the camera between launches.
/// No credentials are ever stored: the SSID prefix is a matching hint only.
struct RememberedCamera: Codable, Equatable {
    var name: String
    var lastHost: String?
    var lastSSID: String?
    var ssidPrefix: String
    var lastSeenEventID: String?
    var autoSaveNewEvents: Bool

    static let `default` = RememberedCamera(
        name: "car-cam-cx7053DW",
        lastHost: nil,
        lastSSID: nil,
        ssidPrefix: "CAR-WA7053",
        lastSeenEventID: nil,
        autoSaveNewEvents: false
    )
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

    // Live
    var isRecording = false
    var elapsedSeconds = 0
    var isImmersive = false
    var snapshotToastVisible = false

    // Events
    var events: [CameraEvent] = []
    var unreadEventIDs: Set<String> = []

    // Card
    var files: [MediaFile] = []

    // Chrome
    var tab: AppTab = .live
    var isConnectSheetPresented = false

    // Device chips
    var sdCardPercentUsed: Int?
    var batteryPercent: Int?

    /// The in-app record of what actually happened. Nothing is sent anywhere.
    let diagnostics: DiagnosticsLog

    private let transport: CameraTransport
    private let discovery: DiscoveryService
    private let pathMonitor = NetworkPathMonitor()
    private let sink: LogSink
    private var client: CameraClient?
    private var tickTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?

    var isSearching: Bool { discoveryTask != nil }

    init(transport: CameraTransport = URLSessionTransport(),
         interfaces: NetworkInterfaceProviding = NetworkInterfaceProvider()) {
        let log = DiagnosticsLog()
        let sink = DiagnosticsSink(log)
        self.diagnostics = log
        self.sink = sink
        self.transport = transport
        self.discovery = DiscoveryService(transport: transport, interfaces: interfaces, sink: sink)
        self.remembered = RememberedStore.load() ?? .default
    }

    // MARK: - Automatic connection

    /// Called once at launch. From then on the app reconnects by itself when
    /// the network changes or it returns to the foreground.
    func startAutoConnect() {
        sink.log(.info, .app, "App started, watching for network changes")
        pathMonitor.start { [weak self] description in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sink.log(.info, .network, "Network changed to \(description)")
                self.connectIfNeeded(reason: "the network changed")
            }
        }
        connectIfNeeded(reason: "the app launched")
    }

    func onForeground() {
        connectIfNeeded(reason: "the app came to the foreground")
    }

    /// Starts a search unless one is already running. When already connected it
    /// first checks the current camera is still answering, which is one request
    /// rather than a whole sweep.
    func connectIfNeeded(reason: String) {
        guard discoveryTask == nil else {
            sink.log(.debug, .app, "Already searching, ignoring: \(reason)")
            return
        }

        discoveryTask = Task { @MainActor [weak self] in
            defer { self?.discoveryTask = nil }
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
            await self.runDiscovery()
        }
    }

    var unreadCount: Int { unreadEventIDs.count }

    /// Launch lands on Events when something is new, otherwise Live.
    func landingTab() -> AppTab {
        unreadCount > 0 ? .events : .live
    }

    // MARK: - Discovery

    /// Manual "Scan again". Forces a search even when one looks unnecessary.
    func rescan() {
        discoveryTask?.cancel()
        discoveryTask = nil
        connection = .disconnected
        connectIfNeeded(reason: "you asked for a rescan")
    }

    private func runDiscovery() async {
        connection = .searching("Looking for the camera")
        discoveryStatus = nil

        let cached = remembered.lastHost
        let found = await discovery.discover(cachedHost: cached) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.apply(progress)
            }
        }

        if let found {
            await connect(to: found)
        } else {
            connection = .disconnected
            discoveryStatus = "No camera found on this network."
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
        let client = CameraClient(host: camera.host, transport: transport, sink: sink)
        self.client = client
        connection = .connected(camera)
        discoveryStatus = nil

        remembered.lastHost = camera.host
        if let model = camera.model, !model.isEmpty {
            remembered.name = model
        }
        RememberedStore.save(remembered)

        sink.log(.info, .app, "Connected to \(camera.host) via \(camera.foundBy.label)")
        await refreshStatus()
    }

    func forgetCamera() {
        sink.log(.info, .app, "Forgetting the camera")
        discoveryTask?.cancel()
        discoveryTask = nil
        client = nil
        connection = .disconnected
        stopTicking()
        isRecording = false
        elapsedSeconds = 0
        remembered.lastHost = nil
        RememberedStore.save(remembered)
    }

    // MARK: - Status

    func refreshStatus() async {
        guard let client else { return }

        if let response = try? await client.send(.sdCardStatus) {
            sdCardPercentUsed = response.int("percent") ?? response.int("used")
        }
        if let response = try? await client.send(.batteryStatus) {
            batteryPercent = response.int("percent") ?? response.int("battery") ?? response.int("value")
        }
        if let response = try? await client.send(.recordStatus) {
            let recording = (response.int("status") ?? 0) == 1
            setRecording(recording, elapsed: response.int("duration") ?? 0)
        }
        if let response = try? await client.send(.wifiInfo) {
            if let mode = response.int("mode"), let parsed = NetworkMode(rawValue: mode) {
                networkMode = parsed
            }
        }
    }

    // MARK: - Live

    func toggleRecording() async {
        guard let client else { return }
        let wanted = !isRecording
        do {
            try await client.send(.setRecordStatus, par: wanted ? 1 : 0)
            setRecording(wanted, elapsed: 0)
        } catch {
            await refreshStatus()
        }
    }

    func takeSnapshot() async {
        guard let client else { return }
        _ = try? await client.send(.takePhoto)
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
