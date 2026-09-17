import Foundation

/// Turns RTP payloads into whole H.264 NAL units, per RFC 6184.
///
/// Three packet shapes matter for this camera:
///   - types 1 to 23, a single NAL unit carried whole
///   - type 24, STAP-A, several small NAL units in one packet
///   - type 28, FU-A, one NAL unit split across packets
///
/// Portable by design: it consumes bytes and produces bytes, so the Android
/// port reuses it unchanged.
public struct H264Depacketizer {
    private var fragment: [UInt8] = []
    private var fragmentTimestamp: UInt32 = 0
    private var droppedFragment = false
    private var lastSequence: UInt16?

    public private(set) var lostPackets = 0

    public init() {}

    public mutating func handle(_ packet: RTPPacket) -> [VideoNALUnit] {
        // A gap means the current fragment can never be completed.
        if let last = lastSequence {
            let expected = last &+ 1
            if packet.sequenceNumber != expected {
                let gap = Int(packet.sequenceNumber &- expected)
                if gap > 0 && gap < 0x8000 {
                    lostPackets += gap
                    if !fragment.isEmpty {
                        fragment.removeAll(keepingCapacity: true)
                        droppedFragment = true
                    }
                }
            }
        }
        lastSequence = packet.sequenceNumber

        guard let first = packet.payload.first else { return [] }
        let type = first & 0x1F

        switch type {
        case 1...23:
            return [VideoNALUnit(bytes: Array(packet.payload), timestamp: packet.timestamp, codec: .h264)]

        case 24:
            return stapA(packet)

        case 28:
            return fuA(packet, indicator: first)

        default:
            // 25 to 27 and 29 are multi-time aggregation and FU-B, which this
            // camera does not send. Ignoring them is better than guessing.
            return []
        }
    }

    /// STAP-A: one byte of header, then repeated 2-byte length and NAL unit.
    private func stapA(_ packet: RTPPacket) -> [VideoNALUnit] {
        var units: [VideoNALUnit] = []
        var index = packet.payload.startIndex + 1
        let end = packet.payload.endIndex

        while index + 2 <= end {
            let length = Int(packet.payload[index]) << 8 | Int(packet.payload[index + 1])
            index += 2
            guard length > 0, index + length <= end else { break }
            units.append(VideoNALUnit(
                bytes: Array(packet.payload[index..<(index + length)]),
                timestamp: packet.timestamp,
                codec: .h264
            ))
            index += length
        }
        return units
    }

    /// FU-A: indicator byte, then a header carrying start and end flags plus
    /// the real NAL type. The original header is rebuilt on the start packet.
    private mutating func fuA(_ packet: RTPPacket, indicator: UInt8) -> [VideoNALUnit] {
        guard packet.payload.count >= 2 else { return [] }
        let base = packet.payload.startIndex
        let header = packet.payload[base + 1]
        let start = (header & 0x80) != 0
        let end = (header & 0x40) != 0
        let nalType = header & 0x1F
        let body = packet.payload[(base + 2)...]

        if start {
            fragment.removeAll(keepingCapacity: true)
            droppedFragment = false
            fragmentTimestamp = packet.timestamp
            // Reconstruct the NAL header: F and NRI from the indicator, type
            // from the fragmentation header.
            fragment.append((indicator & 0xE0) | nalType)
            fragment.append(contentsOf: body)
            return []
        }

        // A continuation with no start, or after a gap, cannot be trusted.
        guard !fragment.isEmpty, !droppedFragment else {
            droppedFragment = true
            return []
        }

        fragment.append(contentsOf: body)

        if end {
            let unit = VideoNALUnit(bytes: fragment, timestamp: fragmentTimestamp, codec: .h264)
            fragment.removeAll(keepingCapacity: true)
            return [unit]
        }
        return []
    }
}
