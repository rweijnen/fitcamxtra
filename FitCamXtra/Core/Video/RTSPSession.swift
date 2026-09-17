import Foundation

/// RTSP request and response handling, and the small piece of SDP we need.
/// Pure text and bytes, so the Android port keeps all of it.

public struct RTSPResponse: Sendable {
    public let statusCode: Int
    public let reason: String
    public let headers: [String: String]
    public let body: String

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Parses a full response. Returns nil when the buffer is incomplete.
    public static func parse(_ text: String) -> RTSPResponse? {
        guard let separator = text.range(of: "\r\n\r\n") else { return nil }
        let head = String(text[text.startIndex..<separator.lowerBound])
        var lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }

        let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, parts[0].hasPrefix("RTSP/"), let code = Int(parts[1]) else {
            return nil
        }
        lines.removeFirst()

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }

        let bodyStart = separator.upperBound
        var body = String(text[bodyStart...])
        if let length = headers["content-length"].flatMap(Int.init) {
            guard body.utf8.count >= length else { return nil }
            body = String(body.prefix(length))
        }

        return RTSPResponse(
            statusCode: code,
            reason: parts.count > 2 ? parts[2] : "",
            headers: headers,
            body: body
        )
    }
}

public struct RTSPRequest {
    public let method: String
    public let url: String
    public var headers: [String: String]

    public init(method: String, url: String, headers: [String: String] = [:]) {
        self.method = method
        self.url = url
        self.headers = headers
    }

    public func encoded(cseq: Int, session: String?) -> Data {
        var text = "\(method) \(url) RTSP/1.0\r\n"
        text += "CSeq: \(cseq)\r\n"
        text += "User-Agent: FitCamXtra\r\n"
        if let session {
            text += "Session: \(session)\r\n"
        }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }
}

/// Just enough SDP to find the video track and its parameter sets.
public struct SDPMedia: Sendable {
    public let control: String?
    public let payloadType: UInt8?
    public let encoding: String?
    public let clockRate: Int?
    public let parameterSets: ParameterSets

    public var codec: VideoCodec? {
        encoding.flatMap(VideoCodec.init(rtpEncoding:))
    }
}

public enum SDPParser {
    /// Returns the first video media section.
    public static func videoTrack(in sdp: String) -> SDPMedia? {
        var inVideo = false
        var control: String?
        var payloadType: UInt8?
        var encoding: String?
        var clockRate: Int?
        var sets = ParameterSets()

        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count > 2, line.dropFirst().first == "=" else { continue }
            let kind = line.first!
            let value = String(line.dropFirst(2))

            if kind == "m" {
                if inVideo { break }              // a second section; we have ours
                inVideo = value.hasPrefix("video")
                if inVideo {
                    let fields = value.split(separator: " ")
                    if fields.count >= 4 { payloadType = UInt8(fields[3]) }
                }
                continue
            }

            guard inVideo, kind == "a" else { continue }

            if value.hasPrefix("control:") {
                control = String(value.dropFirst("control:".count))
            } else if value.hasPrefix("rtpmap:") {
                // rtpmap:96 H264/90000
                let body = value.dropFirst("rtpmap:".count)
                let fields = body.split(separator: " ")
                if fields.count >= 2 {
                    payloadType = UInt8(fields[0]) ?? payloadType
                    let codec = fields[1].split(separator: "/")
                    encoding = codec.first.map(String.init)
                    if codec.count > 1 { clockRate = Int(codec[1]) }
                }
            } else if value.hasPrefix("fmtp:") {
                sets = parameterSets(in: value)
            }
        }

        guard inVideo || control != nil || encoding != nil else { return nil }
        return SDPMedia(
            control: control,
            payloadType: payloadType,
            encoding: encoding,
            clockRate: clockRate,
            parameterSets: sets
        )
    }

    /// H.264 packs both sets into one comma-separated attribute:
    ///   `sprop-parameter-sets=<base64 SPS>,<base64 PPS>`
    /// H.265 uses three separate ones, and needs the VPS as well:
    ///   `sprop-vps=<b64>;sprop-sps=<b64>;sprop-pps=<b64>`
    private static func parameterSets(in fmtp: String) -> ParameterSets {
        var sets = ParameterSets()

        if let range = fmtp.range(of: "sprop-parameter-sets=") {
            let value = fmtp[range.upperBound...].prefix { $0 != ";" && !$0.isWhitespace }
            let parts = value.split(separator: ",")
            if parts.count >= 2 {
                sets.sps = decode(String(parts[0]))
                sets.pps = decode(String(parts[1]))
            }
        }

        for (name, keyPath) in [
            ("sprop-vps=", \ParameterSets.vps),
            ("sprop-sps=", \ParameterSets.sps),
            ("sprop-pps=", \ParameterSets.pps),
        ] {
            guard let range = fmtp.range(of: name) else { continue }
            let value = fmtp[range.upperBound...].prefix { $0 != ";" && !$0.isWhitespace }
            if let decoded = decode(String(value)) {
                sets[keyPath: keyPath] = decoded
            }
        }
        return sets
    }

    private static func decode(_ base64: String) -> [UInt8]? {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return nil }
        return [UInt8](data)
    }
}

/// Splits the interleaved byte stream RTSP uses when RTP rides the same TCP
/// connection: `$`, one channel byte, a 16-bit length, then that many bytes.
/// Control responses arrive in the same stream as plain text.
public struct InterleavedFrameReader {
    public enum Chunk: Sendable {
        case rtp(channel: UInt8, payload: ArraySlice<UInt8>)
        case text(String)
    }

    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ data: [UInt8]) {
        buffer.append(contentsOf: data)
    }

    /// Pulls off whatever is complete. Anything partial stays buffered.
    public mutating func drain() -> [Chunk] {
        var chunks: [Chunk] = []

        while !buffer.isEmpty {
            if buffer[0] == 0x24 {                       // '$'
                guard buffer.count >= 4 else { break }
                let length = Int(buffer[2]) << 8 | Int(buffer[3])
                guard buffer.count >= 4 + length else { break }
                let channel = buffer[1]
                chunks.append(.rtp(channel: channel, payload: buffer[4..<(4 + length)]))
                buffer.removeFirst(4 + length)
                continue
            }

            // Plain-text control response. It ends at the blank line, plus any
            // body the Content-Length announces.
            guard let headerEnd = findHeaderEnd() else { break }
            let headText = String(decoding: buffer[0..<headerEnd], as: UTF8.self)
            var total = headerEnd
            if let length = contentLength(in: headText) {
                guard buffer.count >= headerEnd + length else { break }
                total = headerEnd + length
            }
            chunks.append(.text(String(decoding: buffer[0..<total], as: UTF8.self)))
            buffer.removeFirst(total)
        }
        return chunks
    }

    private func findHeaderEnd() -> Int? {
        guard buffer.count >= 4 else { return nil }
        for index in 0...(buffer.count - 4) {
            if buffer[index] == 0x0D, buffer[index + 1] == 0x0A,
               buffer[index + 2] == 0x0D, buffer[index + 3] == 0x0A {
                return index + 4
            }
        }
        return nil
    }

    private func contentLength(in head: String) -> Int? {
        for line in head.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
