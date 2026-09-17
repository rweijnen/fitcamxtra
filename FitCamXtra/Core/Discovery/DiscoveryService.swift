import Foundation

/// A camera the app has positively identified by its HTTP fingerprint.
public struct DiscoveredCamera: Sendable, Equatable {
    public let host: String
    public let model: String?
    public let firmware: String?
    public let foundBy: Source

    public enum Source: Sendable, Equatable {
        /// The remembered address answered straight away.
        case cachedAddress
        /// Found during the subnet sweep.
        case subnetSweep
        /// The user typed the address.
        case manual

        public var label: String {
            switch self {
            case .cachedAddress: return "remembered address"
            case .subnetSweep: return "subnet sweep"
            case .manual: return "manual entry"
            }
        }
    }
}

public enum DiscoveryProgress: Sendable, Equatable {
    case tryingCachedAddress(String)
    case sweeping(subnet: String, probed: Int, total: Int)
    case found(DiscoveredCamera)
    case finishedWithoutResult
}

/// Supplies the phone's own IPv4 subnet. Implemented per platform, because
/// this is the one piece of discovery that is not portable.
public protocol NetworkInterfaceProviding: Sendable {
    func currentWiFiSubnet() -> IPv4Subnet?
}

/// Finds the camera. The camera announces itself on nothing: the firmware has
/// no mDNS responder, no SSDP and no UDP beacon, so the phone must look.
///
/// Order, cheapest first:
///   1. Probe the remembered address. DHCP servers, car head units included,
///      usually hand the same MAC the same lease, so this resolves the large
///      majority of reconnects in a single request.
///   2. Derive the range from the phone's own interface, never a guess.
///   3. Sweep that range concurrently. All probes are in flight at once, so a
///      /24 resolves in a second or two.
///
/// MAC matching is not available: iOS sandboxing blocks the ARP table, so the
/// cmd=3012 version document is the identity check.
public actor DiscoveryService {
    private let transport: CameraTransport
    private let interfaces: NetworkInterfaceProviding
    private let sink: LogSink?

    /// Per-probe timeout during the sweep. Long enough for a busy embedded
    /// HTTP server on the same wifi, short enough to keep the sweep quick.
    public var probeTimeout: TimeInterval = 0.45
    /// Probes in flight at once. The sweep is latency-bound, not CPU-bound.
    public var maxConcurrentProbes: Int = 48
    /// The cached address gets longer, because a hit here ends discovery.
    public var cachedAddressTimeout: TimeInterval = 1.5

    public init(
        transport: CameraTransport,
        interfaces: NetworkInterfaceProviding,
        sink: LogSink? = nil
    ) {
        self.transport = transport
        self.interfaces = interfaces
        self.sink = sink
    }

    /// Full discovery run. `onProgress` is called as work advances.
    public func discover(
        cachedHost: String?,
        onProgress: (@Sendable (DiscoveryProgress) -> Void)? = nil
    ) async -> DiscoveredCamera? {
        let started = Date()
        sink?.log(.info, .discovery, "Discovery started")

        // 1. The remembered address.
        if let cachedHost, !cachedHost.isEmpty {
            onProgress?(.tryingCachedAddress(cachedHost))
            sink?.log(.info, .discovery, "Trying remembered address \(cachedHost)")
            if let camera = await probe(host: cachedHost, timeout: cachedAddressTimeout, source: .cachedAddress) {
                sink?.log(.info, .discovery, "Camera answered at \(cachedHost)", detail: describe(camera))
                onProgress?(.found(camera))
                return camera
            }
            sink?.log(.info, .discovery, "Remembered address did not answer; sweeping")
        } else {
            sink?.log(.info, .discovery, "No remembered address")
        }

        // 2. The phone's own subnet, so we never guess a range.
        guard let subnet = interfaces.currentWiFiSubnet() else {
            sink?.log(.error, .discovery,
                      "No IPv4 wifi interface found. The phone is probably not on wifi.")
            onProgress?(.finishedWithoutResult)
            return nil
        }

        let label = "\(subnet.address)/\(subnet.scanPrefixLength)"
        sink?.log(.info, .discovery,
                  "Phone is \(subnet.address), scanning \(label)",
                  detail: "netmask prefix \(subnet.prefixLength), gateway guess "
                        + (subnet.gateway.map(String.init(describing:)) ?? "none"))

        // 3. Concurrent sweep.
        let targets = subnet.scanTargets().filter { $0.description != cachedHost }
        guard !targets.isEmpty else {
            sink?.log(.warning, .discovery, "Nothing to scan on \(label)")
            onProgress?(.finishedWithoutResult)
            return nil
        }

        onProgress?(.sweeping(subnet: label, probed: 0, total: targets.count))
        sink?.log(.info, .discovery,
                  "Sweeping \(targets.count) addresses, \(maxConcurrentProbes) at a time, "
                  + "\(Int(probeTimeout * 1000)) ms each")

        let found = await sweep(targets: targets) { probed in
            onProgress?(.sweeping(subnet: label, probed: probed, total: targets.count))
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        if let found {
            sink?.log(.info, .discovery,
                      "Found the camera at \(found.host) after \(elapsed)s",
                      detail: describe(found))
            onProgress?(.found(found))
        } else {
            sink?.log(.warning, .discovery,
                      "No camera answered on \(label) after \(elapsed)s. "
                      + "Check the phone is on the camera's wifi and that the "
                      + "local network permission was allowed.")
            onProgress?(.finishedWithoutResult)
        }
        return found
    }

    /// Probe one address. Used by discovery and by the manual-entry field.
    public func probe(
        host: String,
        timeout: TimeInterval? = nil,
        source: DiscoveredCamera.Source = .manual
    ) async -> DiscoveredCamera? {
        let request = CameraRequest(.version)
        guard let url = URL(string: "http://\(host)\(request.path())") else {
            sink?.log(.error, .discovery, "\(host) is not a usable address")
            return nil
        }

        do {
            let data = try await transport.get(url: url, timeout: timeout ?? probeTimeout)
            let response = try CameraResponseParser.parse(data)
            let version = CameraVersion(response: response)
            guard version.looksLikeFitCamX else {
                sink?.log(.debug, .discovery,
                          "\(host) answered but is not the camera",
                          detail: String(response.raw.prefix(400)))
                return nil
            }
            return DiscoveredCamera(
                host: host,
                model: version.model,
                firmware: version.firmware,
                foundBy: source
            )
        } catch {
            if source != .subnetSweep {
                sink?.log(.info, .discovery, "\(host) did not answer: \(describe(error))")
            }
            return nil
        }
    }

    private func describe(_ camera: DiscoveredCamera) -> String {
        """
        host      \(camera.host)
        model     \(camera.model ?? "unreported")
        firmware  \(camera.firmware ?? "unreported")
        found by  \(camera.foundBy.label)
        """
    }

    private nonisolated func describe(_ error: Error) -> String {
        if let cameraError = error as? CameraError {
            return cameraError.errorDescription ?? "\(cameraError)"
        }
        return error.localizedDescription
    }

    /// Runs every probe concurrently, capped by `maxConcurrentProbes`, and
    /// stops the moment one answers.
    private func sweep(
        targets: [IPv4Address],
        onProbed: @Sendable @escaping (Int) -> Void
    ) async -> DiscoveredCamera? {
        let transport = self.transport
        let timeout = self.probeTimeout
        let window = min(maxConcurrentProbes, targets.count)

        return await withTaskGroup(of: DiscoveredCamera?.self) { group in
            var index = 0
            var completed = 0

            for _ in 0..<window {
                let host = targets[index].description
                index += 1
                group.addTask {
                    await Self.probeStatic(host: host, timeout: timeout, transport: transport)
                }
            }

            while let result = await group.next() {
                completed += 1
                onProbed(completed)

                if let result {
                    group.cancelAll()
                    return result
                }

                if index < targets.count {
                    let host = targets[index].description
                    index += 1
                    group.addTask {
                        await Self.probeStatic(host: host, timeout: timeout, transport: transport)
                    }
                }
            }
            return nil
        }
    }

    private static func probeStatic(
        host: String,
        timeout: TimeInterval,
        transport: CameraTransport
    ) async -> DiscoveredCamera? {
        let request = CameraRequest(.version)
        guard let url = URL(string: "http://\(host)\(request.path())") else { return nil }
        do {
            let data = try await transport.get(url: url, timeout: timeout)
            let response = try CameraResponseParser.parse(data)
            let version = CameraVersion(response: response)
            guard version.looksLikeFitCamX else { return nil }
            return DiscoveredCamera(
                host: host,
                model: version.model,
                firmware: version.firmware,
                foundBy: .subnetSweep
            )
        } catch {
            return nil
        }
    }
}
