import Foundation

/// Portable IPv4 maths. No platform types: the Android port reuses this as is.
public struct IPv4Address: Sendable, Hashable, CustomStringConvertible {
    public let raw: UInt32

    public init(raw: UInt32) {
        self.raw = raw
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        self.raw = value
    }

    public var description: String {
        let a = (raw >> 24) & 0xFF
        let b = (raw >> 16) & 0xFF
        let c = (raw >> 8) & 0xFF
        let d = raw & 0xFF
        return "\(a).\(b).\(c).\(d)"
    }

    public var isPrivate: Bool {
        let a = (raw >> 24) & 0xFF
        let b = (raw >> 16) & 0xFF
        if a == 10 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        return false
    }
}

/// The subnet the phone itself is on, which is where the camera must be.
public struct IPv4Subnet: Sendable, Equatable {
    public let address: IPv4Address
    public let prefixLength: Int
    public let gateway: IPv4Address?

    public init(address: IPv4Address, prefixLength: Int, gateway: IPv4Address? = nil) {
        self.address = address
        self.prefixLength = min(max(prefixLength, 0), 32)
        self.gateway = gateway
    }

    public init?(address: String, netmask: String, gateway: String? = nil) {
        guard let parsed = IPv4Address(address), let mask = IPv4Address(netmask) else { return nil }
        self.address = parsed
        self.prefixLength = IPv4Subnet.prefixLength(fromMask: mask.raw)
        self.gateway = gateway.flatMap(IPv4Address.init)
    }

    public static func prefixLength(fromMask mask: UInt32) -> Int {
        var count = 0
        var value = mask
        while value & 0x8000_0000 != 0 {
            count += 1
            value <<= 1
        }
        return count
    }

    /// Scan width is clamped to a /24 around the phone. A wider netmask would
    /// mean tens of thousands of probes for no practical gain: consumer
    /// networks and head units put the camera on the phone's own /24.
    public var scanPrefixLength: Int {
        max(prefixLength, 24)
    }

    public var scanNetwork: UInt32 {
        let bits = scanPrefixLength
        guard bits < 32 else { return address.raw }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        return address.raw & mask
    }

    public var scanHostCount: Int {
        let bits = 32 - scanPrefixLength
        guard bits > 1 else { return 0 }
        return (1 << bits) - 2
    }

    /// Every host worth probing: the subnet minus network, broadcast, the
    /// phone itself and the gateway.
    public func scanTargets() -> [IPv4Address] {
        let bits = 32 - scanPrefixLength
        guard bits > 1, bits <= 8 else { return [] }
        let network = scanNetwork
        let total = UInt32(1) << UInt32(bits)

        var targets: [IPv4Address] = []
        targets.reserveCapacity(Int(total))
        for offset in 1..<(total - 1) {
            let candidate = network | offset
            if candidate == address.raw { continue }
            if let gateway, candidate == gateway.raw { continue }
            targets.append(IPv4Address(raw: candidate))
        }
        return targets
    }
}
