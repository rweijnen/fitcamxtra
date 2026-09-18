import Foundation
import Network

/// Drives an RTSP session over TCP and hands whole H.264 NAL units to a
/// callback. RTP is interleaved on the same connection, which avoids UDP
/// entirely: no second socket, no NAT guessing, and it works the same on the
/// camera's own access point as on a home LAN.
public actor RTSPClient {
    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case describing
        case playing
        case failed(String)
        case stopped
    }

    public private(set) var state: State = .idle

    private let host: String
    private let port: UInt16
    private let path: String
    private let sink: LogSink?

    private var connection: NWConnection?
    private var reader = InterleavedFrameReader()
    private var depacketizer: VideoDepacketizer?

    private var cseq = 1
    private var session: String?
    private var contentBase: String?
    private var track: SDPMedia?
    private var pendingCSeq: Int?
    private var pendingContinuation: CheckedContinuation<RTSPResponse, Error>?
    private var readLoop: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?

    private var onParameterSets: (@Sendable (VideoCodec, ParameterSets) -> Void)?
    private var onNAL: (@Sendable (VideoNALUnit) -> Void)?
    private var onStateChange: (@Sendable (State) -> Void)?

    public init(host: String, port: UInt16 = 554, path: String = "xxx.mov", sink: LogSink? = nil) {
        self.host = host
        self.port = port
        self.path = path
        self.sink = sink
    }

    /// Built from the URL the camera itself reported. The host is still taken
    /// from the address we are connected on, because the camera reports the
    /// address it believes it has, which is not always the one that answered.
    public init(url: String, fallbackHost: String? = nil, sink: LogSink? = nil) {
        let parsed = URL(string: url)
        self.host = fallbackHost ?? parsed?.host ?? url
        self.port = UInt16(parsed?.port ?? 554)
        let reportedPath = parsed?.path ?? ""
        self.path = reportedPath.isEmpty || reportedPath == "/"
            ? "xxx.mov"
            : String(reportedPath.drop(while: { $0 == "/" }))
        self.sink = sink
    }

    private var baseURL: String {
        "rtsp://\(host):\(port)/\(path)"
    }

    /// What PLAY and TEARDOWN address. RFC 2326 puts aggregate control at the
    /// Content-Base the server gave us; LIVE555 answers 404 for a URL that is
    /// not exactly one it knows, so its own answer is used in preference to
    /// the one we assembled.
    private var aggregateURL: String {
        guard let base = contentBase, !base.isEmpty else { return baseURL }
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    // MARK: - Lifecycle

    public func start(
        onParameterSets: @escaping @Sendable (VideoCodec, ParameterSets) -> Void,
        onNAL: @escaping @Sendable (VideoNALUnit) -> Void,
        onStateChange: @escaping @Sendable (State) -> Void
    ) async {
        self.onParameterSets = onParameterSets
        self.onNAL = onNAL
        self.onStateChange = onStateChange

        set(.connecting)
        sink?.log(.info, .app, "RTSP connecting to \(baseURL)")

        do {
            try await openConnection()
            try await handshake()
        } catch {
            let message = (error as? RTSPError)?.description ?? error.localizedDescription
            sink?.log(.error, .app, "RTSP failed: \(message)")
            set(.failed(message))
            await stop()
        }
    }

    public func stop() async {
        keepAlive?.cancel(); keepAlive = nil
        readLoop?.cancel(); readLoop = nil

        if let session, connection != nil {
            let request = RTSPRequest(method: "TEARDOWN", url: aggregateURL)
            send(request.encoded(cseq: nextCSeq(), session: session))
        }
        self.session = nil

        connection?.cancel()
        connection = nil

        if case .failed = state {} else { set(.stopped) }
        failPending(with: RTSPError.cancelled)
    }

    private func set(_ new: State) {
        state = new
        onStateChange?(new)
    }

    // MARK: - Connection

    private func openConnection() async throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 554
        )
        let parameters = NWParameters.tcp
        parameters.prohibitExpensivePaths = false
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resumeOnce(.success(()))
                case .failed(let error):
                    box.resumeOnce(.failure(error))
                case .cancelled:
                    box.resumeOnce(.failure(RTSPError.cancelled))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        startReading()
    }

    private func startReading() {
        readLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let connection = await self.connection else { return }
                do {
                    let data = try await Self.receive(on: connection)
                    if data.isEmpty { continue }
                    await self.ingest([UInt8](data))
                } catch {
                    await self.handleReadFailure(error)
                    return
                }
            }
        }
    }

    private static func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    box.resumeOnce(.failure(error))
                } else if isComplete {
                    box.resumeOnce(.failure(RTSPError.closed))
                } else {
                    box.resumeOnce(.success(data ?? Data()))
                }
            }
        }
    }

    private func handleReadFailure(_ error: Error) {
        // Whatever was waiting on a reply is never going to get one.
        failPending(with: error)

        guard case .playing = state else {
            if case .failed = state {} else {
                set(.failed(error.localizedDescription))
            }
            return
        }
        sink?.log(.warning, .app, "RTSP stream ended: \(error.localizedDescription)")
        set(.failed(error.localizedDescription))
    }

    private func ingest(_ bytes: [UInt8]) {
        reader.append(bytes)
        for chunk in reader.drain() {
            switch chunk {
            case .text(let text):
                if let response = RTSPResponse.parse(text) {
                    let answered = response.header("cseq").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if let answered, let expected = pendingCSeq, answered != expected {
                        sink?.log(.debug, .app,
                                  "Ignoring a reply to CSeq \(answered) while waiting for \(expected)")
                        continue
                    }
                    let waiting = pendingContinuation
                    pendingContinuation = nil
                    pendingCSeq = nil
                    waiting?.resume(returning: response)
                }
            case .rtp(let channel, let payload):
                // Channel 0 is RTP for the first track; 1 is its RTCP.
                guard channel == 0, let packet = RTPPacket(payload) else { continue }
                guard var depacketizer else { continue }
                let units = depacketizer.handle(packet)
                self.depacketizer = depacketizer
                for unit in units {
                    onNAL?(unit)
                }
            }
        }
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func nextCSeq() -> Int {
        defer { cseq += 1 }
        return cseq
    }

    private func perform(_ request: RTSPRequest, timeout: TimeInterval = 8) async throws -> RTSPResponse {
        guard connection != nil else { throw RTSPError.closed }

        // The deadline has to end the waiting task, not just win the race.
        // A task group awaits its children on the way out, so a timeout whose
        // sibling is parked in a continuation nobody resumes never returns at
        // all: the 8 seconds elapsed, the error was thrown, and the Live
        // screen sat on "Starting the live stream" until the tab was left.
        do {
            return try await withThrowingTaskGroup(of: RTSPResponse.self) { group in
                group.addTask { [weak self] in
                    guard let self else { throw RTSPError.cancelled }
                    return try await self.awaitResponse(for: request)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw RTSPError.timedOut(request.method)
                }
                guard let result = try await group.next() else { throw RTSPError.closed }
                group.cancelAll()
                return result
            }
        } catch {
            failPending(with: error)
            throw error
        }
    }

    private func awaitResponse(for request: RTSPRequest) async throws -> RTSPResponse {
        let cseq = nextCSeq()
        return try await withCheckedThrowingContinuation { continuation in
            // A reply that arrives after its request gave up would otherwise
            // be handed to whatever asked next: the late answer to OPTIONS
            // resolving DESCRIBE is how a camera with a video track reports
            // that it has none.
            pendingCSeq = cseq
            pendingContinuation = continuation
            send(request.encoded(cseq: cseq, session: session))
        }
    }

    /// Ends whatever is waiting, once. Safe to call when nothing is.
    private func failPending(with error: Error) {
        guard let waiting = pendingContinuation else { return }
        pendingContinuation = nil
        pendingCSeq = nil
        waiting.resume(throwing: error)
    }

    // MARK: - Handshake

    private func handshake() async throws {
        set(.describing)

        _ = try? await perform(RTSPRequest(method: "OPTIONS", url: baseURL))

        let describe = try await perform(RTSPRequest(
            method: "DESCRIBE",
            url: baseURL,
            headers: ["Accept": "application/sdp"]
        ))
        guard describe.statusCode == 200 else {
            throw RTSPError.status("DESCRIBE", describe.statusCode, describe.reason)
        }
        contentBase = describe.header("content-base") ?? describe.header("content-location")

        guard let media = SDPParser.videoTrack(in: describe.body) else {
            sink?.log(.error, .app, "No video track in the camera's SDP", detail: describe.body)
            throw RTSPError.noVideoTrack
        }
        track = media
        sink?.log(.info, .app,
                  "RTSP video track: \(media.encoding ?? "unknown codec"), payload type \(media.payloadType.map(String.init) ?? "?")",
                  detail: describe.body)

        guard let codec = media.codec else {
            throw RTSPError.unsupportedCodec(media.encoding ?? "unknown")
        }
        depacketizer = VideoDepacketizer(codec: codec)

        // The camera usually sends its parameter sets in the SDP, and repeats
        // them in the stream. Either source is fine.
        if media.parameterSets.isComplete(for: codec) {
            onParameterSets?(codec, media.parameterSets)
        }

        let setup = try await perform(RTSPRequest(
            method: "SETUP",
            url: controlURL(for: media),
            headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"]
        ))
        guard setup.statusCode == 200 else {
            throw RTSPError.status("SETUP", setup.statusCode, setup.reason)
        }
        session = setup.header("session")?
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let play = try await perform(RTSPRequest(
            method: "PLAY",
            url: aggregateURL,
            headers: ["Range": "npt=0.000-"]
        ))
        guard play.statusCode == 200 else {
            sink?.log(.error, .app,
                      "PLAY \(aggregateURL) was refused: \(play.statusCode) \(play.reason)",
                      detail: """
                      A 404 here usually means no stream is running: the SDP is
                      static, so DESCRIBE answers either way. The start-live
                      command is what creates it.
                      """)
            throw RTSPError.status("PLAY", play.statusCode, play.reason)
        }

        sink?.log(.info, .app, "RTSP playing")
        set(.playing)
        startKeepAlive()
    }

    /// The control attribute may be absolute, relative, or the placeholder `*`.
    private func controlURL(for media: SDPMedia) -> String {
        guard let control = media.control, control != "*" else { return baseURL }
        if control.lowercased().hasPrefix("rtsp://") { return control }
        let base = contentBase ?? (baseURL + "/")
        if base.hasSuffix("/") { return base + control }
        return base + "/" + control
    }

    /// Some Novatek builds drop an idle session, so keep it warm.
    private func startKeepAlive() {
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self else { return }
                await self.sendKeepAlive()
            }
        }
    }

    private func sendKeepAlive() {
        guard case .playing = state, let session else { return }
        let request = RTSPRequest(method: "OPTIONS", url: baseURL)
        send(request.encoded(cseq: nextCSeq(), session: session))
    }
}

public enum RTSPError: Error, CustomStringConvertible {
    case closed
    case cancelled
    case timedOut(String)
    case status(String, Int, String)
    case noVideoTrack
    case unsupportedCodec(String)

    public var description: String {
        switch self {
        case .closed:
            return "the camera closed the stream"
        case .cancelled:
            return "the stream was stopped"
        case .timedOut(let method):
            return "the camera did not answer \(method)"
        case .status(let method, let code, let reason):
            return "\(method) returned \(code) \(reason)"
        case .noVideoTrack:
            return "the camera offered no video track"
        case .unsupportedCodec(let codec):
            return "the camera is streaming \(codec), which this build cannot decode yet"
        }
    }
}

/// NWConnection handlers can fire more than once, and resuming a continuation
/// twice is fatal, so guard it.
private final class ContinuationBox<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resumeOnce(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        pending.resume(with: result)
    }
}
