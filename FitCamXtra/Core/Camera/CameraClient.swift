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
    private let sink: LogSink?

    public init(
        host: String,
        transport: CameraTransport,
        defaultTimeout: TimeInterval = 6.0,
        sink: LogSink? = nil
    ) {
        self.host = host
        self.transport = transport
        self.defaultTimeout = defaultTimeout
        self.sink = sink
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
        let name = "cmd=\(request.command.rawValue) (\(request.command))"
        let started = Date()

        do {
            let data = try await transport.get(url: url, timeout: timeout ?? defaultTimeout)
            let response = try CameraResponseParser.parse(data)
            let ms = Int(Date().timeIntervalSince(started) * 1000)

            if response.isCommandUnsupported {
                sink?.log(.warning, .http, "\(name) not supported by this camera",
                          detail: String(response.raw.prefix(600)))
                throw CameraError.commandUnsupported(command: request.command.rawValue)
            }
            if let status = response.status, status != 0 {
                sink?.log(.warning, .http, "\(name) returned status \(status)",
                          detail: String(response.raw.prefix(600)))
                throw CameraError.commandFailed(command: request.command.rawValue, status: status)
            }

            sink?.log(.debug, .http, "\(name) ok in \(ms) ms",
                      detail: String(response.raw.prefix(600)))
            return response
        } catch let error as CameraError {
            throw error
        } catch {
            sink?.log(.error, .http, "\(name) failed: \(error.localizedDescription)")
            throw error
        }
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

    /// 2015 starts the stream, 2019 reports its URL.
    ///
    /// Skipping this is what a LIVE555 `404 Stream Not Found` on PLAY looks
    /// like: DESCRIBE answers from a static SDP whether or not a stream is
    /// running, so the failure only shows up two requests later.
    ///
    /// Returns whatever the camera says its stream URL is, or nil when it
    /// reports none — the caller then keeps the path it already had rather
    /// than this inventing one.
    public func startLiveStream() async throws -> String? {
        try await send(.startLive, par: 1)

        let response = try await send(.streamURL)
        let reported = response.string("url")
            ?? response.string("string")
            ?? response.string("value")
        guard let reported, reported.lowercased().hasPrefix("rtsp://") else {
            sink?.log(.info, .app,
                      "The camera reported no stream URL; keeping the known path",
                      detail: String(response.raw.prefix(400)))
            return nil
        }
        sink?.log(.info, .app, "The camera reports its stream at \(reported)")
        return reported
    }

    public func setNetworkMode(_ mode: NetworkMode) async throws {
        try await send(.setNetworkMode, par: mode.rawValue)
    }

    /// Credentials, then the mode flip, then the save that makes it survive a
    /// reboot on patched firmware, then a wifi restart.
    ///
    /// Confirmed against the camera: 3032 takes `str=<ssid>:<passphrase>`,
    /// separated by a colon, followed by 3033, 3021 and 3018 in that order.
    /// The app previously sent a tab, which nothing supported.
    ///
    /// An SSID containing a colon cannot be expressed this way, and the
    /// camera has no other form we know of, so it is refused rather than sent
    /// as something the camera would split in the wrong place — the failure
    /// this avoids is the camera leaving its own network holding credentials
    /// it cannot use, which takes a physical reset to undo.
    public func applyStationMode(ssid: String, passphrase: String) async throws {
        guard !ssid.contains(":") else {
            throw CameraError.malformedResponse(
                "This network's name contains a colon, which the camera uses to "
                + "separate the name from the password. It cannot be set from here."
            )
        }
        try await send(.setStationCredentials, str: ssid + ":" + passphrase)
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
        // Confirmed on hardware: this unit answers cmd=3012 with
        // <String>CAR-WA7053-230114</String> and no model element at all, so
        // the app called a camera it was talking to "No camera yet".
        model = response.string("model")
            ?? response.string("product")
            ?? response.string("brand")
            ?? response.string("string")
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
