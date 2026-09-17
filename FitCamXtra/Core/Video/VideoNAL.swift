import Foundation

public enum VideoCodec: String, Sendable, Equatable {
    case h264 = "H264"
    case h265 = "H265"

    public init?(rtpEncoding: String) {
        switch rtpEncoding.uppercased() {
        case "H264": self = .h264
        case "H265", "HEVC": self = .h265
        default: return nil
        }
    }

    public var label: String {
        self == .h264 ? "H.264" : "H.265"
    }
}

/// One complete NAL unit, without a start code or length prefix.
public struct VideoNALUnit: Sendable, Equatable {
    public let bytes: [UInt8]
    public let timestamp: UInt32
    public let codec: VideoCodec

    public init(bytes: [UInt8], timestamp: UInt32, codec: VideoCodec) {
        self.bytes = bytes
        self.timestamp = timestamp
        self.codec = codec
    }

    /// H.264 puts the type in the low 5 bits of one header byte. H.265 uses a
    /// two-byte header with the type in bits 1 to 6 of the first.
    public var type: UInt8 {
        guard let first = bytes.first else { return 0xFF }
        switch codec {
        case .h264: return first & 0x1F
        case .h265: return (first >> 1) & 0x3F
        }
    }

    public var isVPS: Bool { codec == .h265 && type == 32 }

    public var isSPS: Bool {
        codec == .h264 ? type == 7 : type == 33
    }

    public var isPPS: Bool {
        codec == .h264 ? type == 8 : type == 34
    }

    public var isParameterSet: Bool { isVPS || isSPS || isPPS }

    /// A slice the decoder should be handed, as opposed to a parameter set or
    /// a delimiter.
    public var isVideoFrame: Bool {
        switch codec {
        case .h264:
            return type == 1 || type == 5
        case .h265:
            // 0 to 31 are the video coding layer types; 32 and above are
            // parameter sets, delimiters and suffixes.
            return type <= 31
        }
    }

    public var isKeyframe: Bool {
        switch codec {
        case .h264:
            return type == 5
        case .h265:
            // 16 to 23 are the random-access picture types.
            return (16...23).contains(type)
        }
    }
}

/// The sets a decoder needs before it can make sense of any frame. H.264 needs
/// SPS and PPS; H.265 also needs the VPS.
public struct ParameterSets: Sendable, Equatable {
    public var vps: [UInt8]?
    public var sps: [UInt8]?
    public var pps: [UInt8]?

    public init(vps: [UInt8]? = nil, sps: [UInt8]? = nil, pps: [UInt8]? = nil) {
        self.vps = vps
        self.sps = sps
        self.pps = pps
    }

    public func isComplete(for codec: VideoCodec) -> Bool {
        switch codec {
        case .h264:
            return sps?.isEmpty == false && pps?.isEmpty == false
        case .h265:
            return vps?.isEmpty == false && sps?.isEmpty == false && pps?.isEmpty == false
        }
    }

    public mutating func absorb(_ unit: VideoNALUnit) {
        if unit.isVPS { vps = unit.bytes }
        if unit.isSPS { sps = unit.bytes }
        if unit.isPPS { pps = unit.bytes }
    }
}

/// Routes RTP payloads to the right depacketiser.
public struct VideoDepacketizer {
    public let codec: VideoCodec
    private var h264 = H264Depacketizer()
    private var h265 = H265Depacketizer()

    public init(codec: VideoCodec) {
        self.codec = codec
    }

    public mutating func handle(_ packet: RTPPacket) -> [VideoNALUnit] {
        switch codec {
        case .h264: return h264.handle(packet)
        case .h265: return h265.handle(packet)
        }
    }

    public var lostPackets: Int {
        codec == .h264 ? h264.lostPackets : h265.lostPackets
    }
}
