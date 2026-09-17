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
    /// The interface this came from, for the diagnostics. A sweep of the wrong
    /// network looks identical to a camera that is not there unless the log
    /// says which interface the range was taken from.
    public let interfaceName: String?

    public init(address: IPv4Address, prefixLength: Int, gateway: IPv4Address? = nil,
                interfaceName: String? = nil) {
        self.address = address
        self.prefixLength = min(max(prefixLength, 0), 32)
        self.gateway = gateway
        self.interfaceName = interfaceName
    }

    public init?(address: String, netmask: String, gateway: String? = nil,
                 interfaceName: String? = nil) {
        guard let parsed = IPv4Address(address), let mask = IPv4Address(netmask) else { return nil }
        self.address = parsed
        self.prefixLength = IPv4Subnet.prefixLength(fromMask: mask.raw)
        self.gateway = gateway.flatMap(IPv4Address.init)
        self.interfaceName = interfaceName
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

    /// The network this address sits on, at its real netmask.
    public var networkAddress: IPv4Address {
        IPv4Address(raw: address.raw & maskBits(prefixLength))
    }

    public var broadcastAddress: IPv4Address {
        IPv4Address(raw: address.raw | ~maskBits(prefixLength))
    }

    public var netmask: IPv4Address {
        IPv4Address(raw: maskBits(prefixLength))
    }

    /// Addresses in the real network, excluding network and broadcast.
    public var hostCount: Int {
        hostCount(forPrefix: prefixLength)
    }

    public func hostCount(forPrefix prefix: Int) -> Int {
        let bits = 32 - min(max(prefix, 0), 32)
        guard bits > 1 else { return 0 }
        guard bits < 31 else { return Int(UInt32.max) }
        return (1 << bits) - 2
    }

    /// A network wider than this is not swept without being asked. A /16 is
    /// 65,534 probes, which is minutes of scanning, so the user decides.
    public static let automaticPrefixFloor = 24

    public var isWiderThanAutomatic: Bool {
        prefixLength < Self.automaticPrefixFloor
    }

    /// The width swept without asking: the real netmask, or the /24 around the
    /// phone when the network is wider than that.
    public var automaticPrefixLength: Int {
        max(prefixLength, Self.automaticPrefixFloor)
    }

    private func maskBits(_ prefix: Int) -> UInt32 {
        let bits = min(max(prefix, 0), 32)
        return bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
    }

    public func network(forPrefix prefix: Int) -> IPv4Address {
        IPv4Address(raw: address.raw & maskBits(prefix))
    }

    /// Every host worth probing at the given width: the range minus its
    /// network address, its broadcast address and the phone itself.
    ///
    /// The gateway is deliberately **not** excluded. On the camera's own access
    /// point the camera *is* the gateway, so skipping it would skip the very
    /// device we are looking for. Likely addresses are ordered first instead,
    /// which costs nothing and usually ends the sweep on the first result.
    public func scanTargets(prefixLength prefix: Int? = nil) -> [IPv4Address] {
        let width = min(max(prefix ?? automaticPrefixLength, 8), 32)
        let bits = 32 - width
        guard bits > 1, bits <= 24 else { return [] }

        let base = address.raw & maskBits(width)
        let total = UInt32(1) << UInt32(bits)
        let last = total - 1

        // Ordered by how often a camera or router sits there: the gateway we
        // inferred, then the high address this model uses on its own access
        // point, then the usual router address.
        var preferred: [UInt32] = []
        if let gateway, gateway.raw & maskBits(width) == base {
            preferred.append(gateway.raw)
        }
        let localBase = address.raw & maskBits(24)
        preferred.append(localBase | 254)
        preferred.append(localBase | 1)

        var seen = Set<UInt32>([base, base | last, address.raw])
        var targets: [IPv4Address] = []
        targets.reserveCapacity(Int(min(total, 65_536)))

        for candidate in preferred where !seen.contains(candidate) {
            guard candidate > base, candidate < base | last else { continue }
            seen.insert(candidate)
            targets.append(IPv4Address(raw: candidate))
        }

        for offset in 1..<last {
            let candidate = base | offset
            if seen.contains(candidate) { continue }
            targets.append(IPv4Address(raw: candidate))
        }
        return targets
    }

    /// A human description of what will be swept, using the network address
    /// rather than the phone's own address.
    public func rangeDescription(forPrefix prefix: Int? = nil) -> String {
        let width = prefix ?? automaticPrefixLength
        return "\(network(forPrefix: width))/\(width)"
    }
}
