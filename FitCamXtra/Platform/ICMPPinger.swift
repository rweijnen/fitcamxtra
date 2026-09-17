import Foundation
import Darwin

/// An ICMP echo sweep: who is alive on this range.
///
/// Discovery runs this before it probes anything for the camera, because an
/// echo request costs a fraction of a TCP connection attempt and the camera is
/// confirmed to answer one. It also answers the question that a silent HTTP
/// sweep cannot — *is anything there at all* — since a host replies to an echo
/// whether or not it runs a web server.
///
/// iOS allows this without any entitlement: `SOCK_DGRAM` with `IPPROTO_ICMP`
/// is the unprivileged ping socket, the same one Apple's own SimplePing uses.
/// It is still local network traffic, so it is subject to the same local
/// network permission as the HTTP probes.
///
/// One socket serves the whole sweep. Each address gets its own sequence
/// number, all the requests go out, and replies are collected until the
/// deadline. That is one file descriptor and one read loop for 254 hosts
/// rather than 254 of each.
public final class ICMPPinger: HostReachabilityProbing, @unchecked Sendable {
    /// How long to keep listening after the last reply before calling the
    /// sweep done. Everything on the subnet is one hop away.
    private let quietPeriod: TimeInterval

    public init(quietPeriod: TimeInterval = 0.4) {
        self.quietPeriod = quietPeriod
    }

    public func ping(
        hosts: [String],
        timeout: TimeInterval
    ) async -> ReachabilitySweep {
        guard !hosts.isEmpty else { return ReachabilitySweep(answered: [], failure: nil) }

        return await withCheckedContinuation { continuation in
            // Raw sockets and poll() are blocking work; keep them off the
            // cooperative pool.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.run(hosts: hosts, timeout: timeout))
            }
        }
    }

    private func run(hosts: [String], timeout: TimeInterval) -> ReachabilitySweep {
        let handle = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard handle >= 0 else {
            // EACCES here is the platform refusing the ping socket outright,
            // which is worth saying plainly rather than reporting as silence.
            return ReachabilitySweep(
                answered: [],
                failure: "The system would not open a ping socket: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(handle) }

        var sequenceToHost: [UInt16: String] = [:]
        var sent = 0

        for (index, host) in hosts.enumerated() {
            // Replies are matched on the sequence number, so the sweep cannot
            // be larger than the number space. A /16 fits; anything wider is
            // already past what this app sweeps.
            guard index <= Int(UInt16.max) else { break }
            let sequence = UInt16(index)
            guard var destination = Self.sockaddrIn(for: host) else { continue }
            let packet = Self.echoRequest(sequence: sequence)

            let written = packet.withUnsafeBytes { body -> Int in
                withUnsafePointer(to: &destination) { address in
                    address.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                        sendto(handle, body.baseAddress, body.count, 0,
                               generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if written > 0 {
                sequenceToHost[sequence] = host
                sent += 1
            }
        }

        guard sent > 0 else {
            return ReachabilitySweep(answered: [], failure: "No echo request could be sent.")
        }

        var answered: [String] = []
        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(timeout)
        var lastReply: Date?
        var buffer = [UInt8](repeating: 0, count: 1500)

        while Date() < deadline, answered.count < sequenceToHost.count {
            // Everything here is one hop away, so replies arrive in a burst.
            // Once they stop coming the rest are not coming, and waiting out
            // the full deadline would only delay the HTTP probes that follow.
            let quietDeadline = lastReply.map { min($0.addingTimeInterval(quietPeriod), deadline) } ?? deadline
            let remaining = quietDeadline.timeIntervalSinceNow
            guard remaining > 0 else { break }

            var descriptor = pollfd(fd: handle, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000))
            guard ready > 0 else { break }

            let read = recv(handle, &buffer, buffer.count, 0)
            guard read > 0 else { continue }

            guard let sequence = Self.echoReplySequence(in: buffer, length: read),
                  let host = sequenceToHost[sequence],
                  seen.insert(host).inserted else { continue }
            answered.append(host)
            lastReply = Date()
        }

        return ReachabilitySweep(answered: answered, failure: nil)
    }

    // MARK: - Packets

    private static func echoRequest(sequence: UInt16) -> [UInt8] {
        // Type 8, code 0, checksum, identifier, sequence. The kernel rewrites
        // the identifier on a SOCK_DGRAM socket, so replies are matched on the
        // sequence number alone.
        var packet: [UInt8] = [8, 0, 0, 0, 0, 0,
                               UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        packet.append(contentsOf: Array("FitCamXtra".utf8))

        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    /// The sequence number of an echo reply, or nil for anything else.
    private static func echoReplySequence(in buffer: [UInt8], length: Int) -> UInt16? {
        var offset = 0

        // Darwin hands IPv4 replies over with their IP header attached.
        if length > 0, buffer[0] >> 4 == 4 {
            offset = Int(buffer[0] & 0x0F) * 4
        }
        guard length >= offset + 8 else { return nil }
        guard buffer[offset] == 0 else { return nil }  // 0 is echo reply.

        return UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
    }

    /// Internet checksum: one's complement sum of 16-bit words.
    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(truncatingIfNeeded: ~sum)
    }

    private static func sockaddrIn(for host: String) -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        return address
    }
}
