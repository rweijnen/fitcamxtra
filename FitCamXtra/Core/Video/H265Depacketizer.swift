import Foundation

/// Turns RTP payloads into whole H.265 NAL units, per RFC 7798.
///
/// H.265 is not H.264 with different numbers. The NAL header is two bytes
/// rather than one, the type sits in bits 1 to 6 of the first byte, and the
/// aggregation and fragmentation packets have their own types, so the two
/// formats need separate code.
///
///  0               1
/// |F|   Type    |  LayerId  | TID |
public struct H265Depacketizer {
    private var fragment: [UInt8] = []
    private var fragmentTimestamp: UInt32 = 0
    private var droppedFragment = false
    private var lastSequence: UInt16?

    public private(set) var lostPackets = 0

    public init() {}

    public mutating func handle(_ packet: RTPPacket) -> [VideoNALUnit] {
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

        guard packet.payload.count >= 2 else { return [] }
        let base = packet.payload.startIndex
        let header0 = packet.payload[base]
        let header1 = packet.payload[base + 1]
        let type = (header0 >> 1) & 0x3F

        switch type {
        case 0...47:
            return [VideoNALUnit(bytes: Array(packet.payload), timestamp: packet.timestamp, codec: .h265)]

        case 48:
            return aggregation(packet)

        case 49:
            return fragmentation(packet, header0: header0, header1: header1)

        default:
            // 50 is PACI, which carries its own extension header. This camera
            // does not send it, and guessing at it would be worse than
            // ignoring it.
            return []
        }
    }

    /// Aggregation packet: a two-byte header, then repeated 16-bit size and
    /// NAL unit.
    private func aggregation(_ packet: RTPPacket) -> [VideoNALUnit] {
        var units: [VideoNALUnit] = []
        var index = packet.payload.startIndex + 2
        let end = packet.payload.endIndex

        while index + 2 <= end {
            let length = Int(packet.payload[index]) << 8 | Int(packet.payload[index + 1])
            index += 2
            guard length > 0, index + length <= end else { break }
            units.append(VideoNALUnit(
                bytes: Array(packet.payload[index..<(index + length)]),
                timestamp: packet.timestamp,
                codec: .h265
            ))
            index += length
        }
        return units
    }

    /// Fragmentation unit: the two-byte payload header, then one byte carrying
    /// start and end flags plus the real NAL type, then the fragment.
    private mutating func fragmentation(
        _ packet: RTPPacket,
        header0: UInt8,
        header1: UInt8
    ) -> [VideoNALUnit] {
        guard packet.payload.count >= 3 else { return [] }
        let base = packet.payload.startIndex
        let fuHeader = packet.payload[base + 2]
        let start = (fuHeader & 0x80) != 0
        let end = (fuHeader & 0x40) != 0
        let nalType = fuHeader & 0x3F
        let body = packet.payload[(base + 3)...]

        if start {
            fragment.removeAll(keepingCapacity: true)
            droppedFragment = false
            fragmentTimestamp = packet.timestamp
            // Rebuild the two-byte header: keep F, LayerId and TID from the
            // payload header, and take the type from the fragmentation header.
            fragment.append((header0 & 0x81) | (nalType << 1))
            fragment.append(header1)
            fragment.append(contentsOf: body)
            return []
        }

        guard !fragment.isEmpty, !droppedFragment else {
            droppedFragment = true
            return []
        }

        fragment.append(contentsOf: body)

        if end {
            let unit = VideoNALUnit(bytes: fragment, timestamp: fragmentTimestamp, codec: .h265)
            fragment.removeAll(keepingCapacity: true)
            return [unit]
        }
        return []
    }
}
