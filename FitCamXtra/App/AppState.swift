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

    private let transport: CameraTransport
    private let discovery: DiscoveryService
    private var client: CameraClient?
    private var tickTask: Task<Void, Never>?

    init(transport: CameraTransport = URLSessionTransport(),
         interfaces: NetworkInterfaceProviding = NetworkInterfaceProvider()) {
        self.transport = transport
        self.discovery = DiscoveryService(transport: transport, interfaces: interfaces)
        self.remembered = RememberedStore.load() ?? .default
    }

    var unreadCount: Int { unreadEventIDs.count }

    /// Launch lands on Events when something is new, otherwise Live.
    func landingTab() -> AppTab {
        unreadCount > 0 ? .events : .live
    }

    // MARK: - Discovery

    func discover() async {
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
        let client = CameraClient(host: camera.host, transport: transport)
        self.client = client
        connection = .connected(camera)
        discoveryStatus = nil

        remembered.lastHost = camera.host
        RememberedStore.save(remembered)

        await refreshStatus()
    }

    func forgetCamera() {
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
