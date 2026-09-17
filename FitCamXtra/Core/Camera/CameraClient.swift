import Foundation

/// The single seam between portable camera logic and platform networking.
/// An Android port supplies its own conformer and reuses everything above it.
public protocol CameraTransport: Sendable {
    func get(url: URL, timeout: TimeInterval) async throws -> Data
}

/// Talks to one camera. Portable: it only knows a host and a transport.
public actor CameraClient {
    public private(set) var host: String
    private let transport: CameraTransport
    private let defaultTimeout: TimeInterval

    public init(host: String, transport: CameraTransport, defaultTimeout: TimeInterval = 6.0) {
        self.host = host
        self.transport = transport
        self.defaultTimeout = defaultTimeout
    }

    public func retarget(host newHost: String) {
        host = newHost
    }

    public func url(for request: CameraRequest) -> URL? {
        URL(string: "http://\(host)\(request.path())")
    }

    @discardableResult
    public func send(_ request: CameraRequest, timeout: TimeInterval? = nil) async throws -> CameraResponse {
        guard let url = url(for: request) else { throw CameraError.notReachable }
        let data = try await transport.get(url: url, timeout: timeout ?? defaultTimeout)
        let response = try CameraResponseParser.parse(data)

        if response.isCommandUnsupported {
            throw CameraError.commandUnsupported(command: request.command.rawValue)
        }
        if let status = response.status, status != 0 {
            throw CameraError.commandFailed(command: request.command.rawValue, status: status)
        }
        return response
    }

    @discardableResult
    public func send(
        _ command: CameraCommand,
        par: Int? = nil,
        str: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> CameraResponse {
        try await send(CameraRequest(command, par: par, str: str), timeout: timeout)
    }

    // MARK: - Convenience

    public func version() async throws -> CameraVersion {
        CameraVersion(response: try await send(.version))
    }

    /// 2015 starts the stream, 2019 returns its URL.
    public func startLiveStream() async throws -> String {
        try await send(.startLive, par: 1)
        let response = try await send(.streamURL)
        if let url = response.string("url") ?? response.string("string") {
            return url
        }
        return "rtsp://\(host)/xxx.mov"
    }

    public func setNetworkMode(_ mode: NetworkMode) async throws {
        try await send(.setNetworkMode, par: mode.rawValue)
    }

    /// Credentials, then the mode flip, then the save that makes it survive a
    /// reboot on patched firmware, then a wifi restart.
    public func applyStationMode(ssid: String, passphrase: String) async throws {
        try await send(.setStationCredentials, str: ssid + "\t" + passphrase)
        try await send(.setNetworkMode, par: NetworkMode.station.rawValue)
        try await send(.saveConfig)
        try await send(.rebootWifi)
    }
}

public struct CameraVersion: Sendable, Equatable {
    public let model: String?
    public let firmware: String?
    public let raw: String

    public init(response: CameraResponse) {
        model = response.string("model") ?? response.string("product") ?? response.string("brand")
        firmware = response.string("firmware") ?? response.string("version") ?? response.string("fw")
        raw = response.raw
    }

    /// The camera is the only host on a subnet that answers cmd=3012 with a
    /// Novatek version document, so a parsed reply is identity enough.
    public var looksLikeFitCamX: Bool {
        if model != nil || firmware != nil { return true }
        let haystack = raw.lowercased()
        return haystack.contains("nt966") || haystack.contains("car-wa") || haystack.contains("fitcam")
    }
}
