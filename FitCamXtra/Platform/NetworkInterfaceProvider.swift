import Foundation
import Darwin

/// Reads the phone's own IPv4 addresses and netmasks, so a sweep targets a
/// real subnet instead of a guessed one.
///
/// iOS gives an app its own interface addresses but not the ARP table and not
/// the default route, so the gateway is inferred rather than read. It is only
/// used to probe one address early, never to exclude one, so a wrong guess
/// costs nothing but ordering.
///
/// **Every local IPv4 network is returned, not just the one that looks most
/// like wifi.** A phone in a car is on more than one at once: the head unit's
/// wireless CarPlay link and the wifi network the camera joined are different
/// networks on different interfaces, and picking a single interface by name
/// meant the app could sweep the one the camera was not on and report the
/// camera as absent. Interface names are not a reliable guide to which is
/// which, so all of them are swept in turn.
public struct NetworkInterfaceProvider: NetworkInterfaceProviding {
    /// Interfaces that cannot carry a camera on the local network: cellular,
    /// VPN tunnels, and Apple's peer-to-peer link-local radios.
    private static let excludedPrefixes = ["pdp_ip", "utun", "ipsec", "awdl", "llw", "lo"]

    /// Swept first when present. This is preference only: everything local is
    /// swept either way.
    private let preferredOrder: [String]

    public init(preferredOrder: [String] = ["en0", "en1", "en2", "bridge100"]) {
        self.preferredOrder = preferredOrder
    }

    public func currentIPv4Subnets() -> [IPv4Subnet] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [(name: String, address: IPv4Address, mask: IPv4Address)] = []

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }

            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addrPointer = entry.pointee.ifa_addr,
                  addrPointer.pointee.sa_family == UInt8(AF_INET),
                  let maskPointer = entry.pointee.ifa_netmask else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            guard !Self.excludedPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }

            guard let address = Self.ipv4(from: addrPointer),
                  let mask = Self.ipv4(from: maskPointer),
                  address.isPrivate else { continue }

            // The same network can appear twice under different interface
            // names. Sweeping it twice would only waste seconds.
            let network = address.raw & mask.raw
            let alreadyHave = found.contains { ($0.address.raw & $0.mask.raw) == network }
            guard !alreadyHave else { continue }

            found.append((name, address, mask))
        }

        return found
            .sorted { rank(of: $0.name) < rank(of: $1.name) }
            .map { entry in
                IPv4Subnet(
                    address: entry.address,
                    prefixLength: IPv4Subnet.prefixLength(fromMask: entry.mask.raw),
                    gateway: Self.likelyGateway(address: entry.address, mask: entry.mask),
                    interfaceName: entry.name
                )
            }
    }

    private func rank(of name: String) -> Int {
        preferredOrder.firstIndex(of: name) ?? preferredOrder.count
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
