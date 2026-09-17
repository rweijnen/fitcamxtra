import Foundation
import Darwin

/// Reads the phone's own IPv4 address and netmask on the wifi interface, so a
/// sweep targets the real subnet instead of a guessed one.
///
/// iOS gives an app its own interface addresses but not the ARP table and not
/// the default route, so the gateway is inferred rather than read. It is only
/// used to probe one address early, never to exclude one, so a wrong guess
/// costs nothing but ordering.
public struct NetworkInterfaceProvider: NetworkInterfaceProviding {
    /// en0 is wifi on iPhone. Others are listed for the simulator and for
    /// hotspot or wired adapters.
    private let candidateInterfaces: [String]

    public init(candidateInterfaces: [String] = ["en0", "en1", "en2", "bridge100"]) {
        self.candidateInterfaces = candidateInterfaces
    }

    public func currentWiFiSubnet() -> IPv4Subnet? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var best: (name: String, address: IPv4Address, mask: IPv4Address)?

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }

            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addrPointer = entry.pointee.ifa_addr,
                  addrPointer.pointee.sa_family == UInt8(AF_INET),
                  let maskPointer = entry.pointee.ifa_netmask else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            guard candidateInterfaces.contains(name) else { continue }

            guard let address = Self.ipv4(from: addrPointer),
                  let mask = Self.ipv4(from: maskPointer),
                  address.isPrivate else { continue }

            // Prefer the earliest candidate in the list, which is wifi.
            if let current = best,
               let currentRank = candidateInterfaces.firstIndex(of: current.name),
               let newRank = candidateInterfaces.firstIndex(of: name),
               newRank >= currentRank {
                continue
            }
            best = (name, address, mask)
        }

        guard let best else { return nil }
        return IPv4Subnet(
            address: best.address,
            prefixLength: IPv4Subnet.prefixLength(fromMask: best.mask.raw),
            gateway: Self.likelyGateway(address: best.address, mask: best.mask)
        )
    }

    private static func ipv4(from pointer: UnsafeMutablePointer<sockaddr>) -> IPv4Address? {
        guard pointer.pointee.sa_family == UInt8(AF_INET) else { return nil }
        let value = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee.sin_addr.s_addr
        }
        return IPv4Address(raw: UInt32(bigEndian: value))
    }

    /// Router convention, not a fact: the first host address on the subnet.
    /// Only ever used to order probes.
    private static func likelyGateway(address: IPv4Address, mask: IPv4Address) -> IPv4Address? {
        let network = address.raw & mask.raw
        let candidate = network | 1
        guard candidate != address.raw else { return nil }
        return IPv4Address(raw: candidate)
    }
}
