import Foundation

/// Minimal RTP parsing, per RFC 3550. Portable: pure bytes, no platform types.
///
///  0                   1                   2                   3
/// |V=2|P|X|  CC   |M|     PT      |       sequence number         |
/// |                           timestamp                           |
/// |           synchronisation source (SSRC) identifier            |
/// |             contributing source identifiers, CC of them       |
public struct RTPPacket: Sendable {
    public let payloadType: UInt8
    public let sequenceNumber: UInt16
    public let timestamp: UInt32
    public let marker: Bool
    public let payload: ArraySlice<UInt8>

    public init?(_ bytes: ArraySlice<UInt8>) {
        guard bytes.count >= 12 else { return nil }
        let base = bytes.startIndex

        let first = bytes[base]
        guard (first >> 6) == 2 else { return nil }          // version must be 2
        let hasPadding = (first & 0x20) != 0
        let hasExtension = (first & 0x10) != 0
        let csrcCount = Int(first & 0x0F)

        let second = bytes[base + 1]
        marker = (second & 0x80) != 0
        payloadType = second & 0x7F

        sequenceNumber = UInt16(bytes[base + 2]) << 8 | UInt16(bytes[base + 3])
        timestamp = UInt32(bytes[base + 4]) << 24
            | UInt32(bytes[base + 5]) << 16
            | UInt32(bytes[base + 6]) << 8
            | UInt32(bytes[base + 7])

        var offset = 12 + csrcCount * 4
        guard bytes.count >= offset else { return nil }

        if hasExtension {
            guard bytes.count >= offset + 4 else { return nil }
            let words = Int(bytes[base + offset + 2]) << 8 | Int(bytes[base + offset + 3])
            offset += 4 + words * 4
            guard bytes.count >= offset else { return nil }
        }

        var end = bytes.endIndex
        if hasPadding, let padding = bytes.last, padding > 0 {
            guard bytes.count >= offset + Int(padding) else { return nil }
            end -= Int(padding)
        }

        guard base + offset <= end else { return nil }
        payload = bytes[(base + offset)..<end]
    }
}
