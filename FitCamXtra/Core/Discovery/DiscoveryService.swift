import Foundation

/// A camera the app has positively identified by its HTTP fingerprint.
public struct DiscoveredCamera: Sendable, Equatable {
    public let host: String
    public let model: String?
    public let firmware: String?
    public let foundBy: Source
    /// The raw cmd=3012 document. This unit reports neither model nor
    /// firmware, so the diagnostics carry what it does send.
    public var versionReply: String = ""

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

/// What a finished search found, and what is still worth trying.
public struct DiscoveryOutcome: Sendable, Equatable {
    /// Why a search found nothing, when the app can actually tell. Anything
    /// it cannot diagnose stays nil rather than guessing.
    public enum Obstacle: Sendable, Equatable {
        /// No local IPv4 network at all: the phone is not on wifi.
        case phoneNotOnWiFi
        /// The network was swept and nothing answered even a ping, which is
        /// what a refused local-network permission looks like from here.
        case networkUnreachable
    }

    public let camera: DiscoveredCamera?
    public var obstacle: Obstacle?
    /// Set when the phone's network is wider than the range swept without
    /// asking, so the caller can offer the full sweep instead of the app
    /// quietly deciding the camera is not there.
    public let widerScan: WiderScan?

    public init(camera: DiscoveredCamera?, widerScan: WiderScan?, obstacle: Obstacle? = nil) {
        self.camera = camera
        self.widerScan = widerScan
        self.obstacle = obstacle
    }

    public struct WiderScan: Sendable, Equatable {
        public let prefixLength: Int
        public let network: String
        public let addressCount: Int
        /// Rough seconds, from the probe timeout and how many run at once.
        public let estimatedSeconds: Int
    }
}

/// Supplies the phone's own IPv4 networks. Implemented per platform, because
/// this is the one piece of discovery that is not portable.
///
/// Plural on purpose: a phone in a car holds more than one local network at
/// once, and which of them the camera is on cannot be told from the interface
/// name.
public protocol NetworkInterfaceProviding: Sendable {
    /// Every local IPv4 network the phone is on, most likely first.
    func currentIPv4Subnets() -> [IPv4Subnet]
}

extension NetworkInterfaceProviding {
    /// The first of them. Kept for callers that only need somewhere to start.
    public func currentWiFiSubnet() -> IPv4Subnet? {
        currentIPv4Subnets().first
    }
}

/// What an ICMP echo sweep found.
public struct ReachabilitySweep: Sendable, Equatable {
    /// Addresses that replied.
    public let answered: [String]
    /// Set when the sweep could not be performed at all, which is itself a
    /// result and must not read as "nothing is there".
    public let failure: String?

    public init(answered: [String], failure: String?) {
        self.answered = answered
        self.failure = failure
    }
}

/// Pings addresses. Platform-supplied, because ICMP is not portable; the
/// decision about when to ping is not, and stays here.
public protocol HostReachabilityProbing: Sendable {
    func ping(hosts: [String], timeout: TimeInterval) async -> ReachabilitySweep
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
    /// Optional: when present, a network that answered nothing over HTTP is
    /// pinged, so silence can be told from absence.
    private let reachability: HostReachabilityProbing?
    private let sink: LogSink?

    /// Per-probe timeout during the sweep. Long enough for a busy embedded
    /// HTTP server on the same wifi, short enough to keep the sweep quick.
    public var probeTimeout: TimeInterval = 0.45
    /// Probes in flight at once. The sweep is latency-bound, not CPU-bound.
    public var maxConcurrentProbes: Int = 48
    /// The cached address gets longer, because a hit here ends discovery.
    public var cachedAddressTimeout: TimeInterval = 1.5
    /// Second pass, for a camera that is present but slow to answer.
    public var slowProbeTimeout: TimeInterval = 1.5

    /// Ceiling for the echo sweep of one network. It usually ends well inside
    /// this, as soon as the replies stop arriving.
    public var pingTimeout: TimeInterval = 1.5

    public init(
        transport: CameraTransport,
        interfaces: NetworkInterfaceProviding,
        reachability: HostReachabilityProbing? = nil,
        sink: LogSink? = nil
    ) {
        self.transport = transport
        self.interfaces = interfaces
        self.reachability = reachability
        self.sink = sink
    }

    /// Full discovery run. `onProgress` is called as work advances.
    /// Sweeps the phone's own /24, or `prefixLength` when one is given.
    public func discover(
        cachedHost: String?,
        prefixLength: Int? = nil,
        onProgress: (@Sendable (DiscoveryProgress) -> Void)? = nil
    ) async -> DiscoveryOutcome {
        let started = Date()
        sink?.log(.info, .discovery, "Discovery started")

        // 1. The remembered address.
        if let cachedHost, !cachedHost.isEmpty {
            onProgress?(.tryingCachedAddress(cachedHost))
            sink?.log(.info, .discovery, "Trying remembered address \(cachedHost)")
            if let camera = await probe(host: cachedHost, timeout: cachedAddressTimeout, source: .cachedAddress) {
                sink?.log(.info, .discovery, "Camera answered at \(cachedHost)", detail: describe(camera))
                onProgress?(.found(camera))
                return DiscoveryOutcome(camera: camera, widerScan: nil)
            }
            sink?.log(.info, .discovery, "Remembered address did not answer; sweeping")
        } else {
            sink?.log(.info, .discovery, "No remembered address")
        }

        // 2. The phone's own networks, so we never guess a range. All of them:
        //    in a car the phone holds the head unit's CarPlay link and the
        //    wifi network the camera joined at the same time, and no interface
        //    name says which is which.
        let subnets = interfaces.currentIPv4Subnets()
        guard !subnets.isEmpty else {
            sink?.log(.error, .discovery,
                      "No local IPv4 network found. The phone is probably not on wifi.")
            onProgress?(.finishedWithoutResult)
            return DiscoveryOutcome(camera: nil, widerScan: nil, obstacle: .phoneNotOnWiFi)
        }

        sink?.log(.info, .discovery,
                  subnets.count == 1
                      ? "The phone is on one local network"
                      : "The phone is on \(subnets.count) local networks; sweeping each in turn",
                  detail: subnets
                      .map { "\($0.interfaceName ?? "?")  \($0.address)/\($0.prefixLength)" }
                      .joined(separator: "\n"))

        // 3. Sweep each of them until one answers.
        var wider: DiscoveryOutcome.WiderScan?
        // Nothing answering a ping anywhere is the signature of a phone that
        // cannot reach its own network, rather than of a camera that is absent.
        var sawAnythingAlive = false
        for subnet in subnets {
            // A wider sweep is asked for by network, so the requested width
            // applies only to a network that is actually that wide.
            let width: Int
            if let prefixLength, subnet.prefixLength <= prefixLength {
                width = prefixLength
            } else {
                width = subnet.automaticPrefixLength
            }

            switch await sweepOne(subnet, width: width, cachedHost: cachedHost, onProgress: onProgress) {
            case .found(let camera):
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                sink?.log(.info, .discovery,
                          "Found the camera at \(camera.host) after \(elapsed)s",
                          detail: describe(camera))
                onProgress?(.found(camera))
                return DiscoveryOutcome(camera: camera, widerScan: nil)
            case .cancelled:
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                sink?.log(.info, .discovery, "Search stopped after \(elapsed)s before it finished")
                onProgress?(.finishedWithoutResult)
                return DiscoveryOutcome(camera: nil, widerScan: nil)
            case .nothing(let offer, let anythingAlive):
                wider = wider ?? offer
                sawAnythingAlive = sawAnythingAlive || anythingAlive
            }
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        if wider == nil {
            sink?.log(.warning, .discovery,
                      "No camera answered on any of the phone's networks after \(elapsed)s. "
                      + "Check the phone is on the same network as the camera and that the "
                      + "local network permission was allowed.")
        }
        onProgress?(.finishedWithoutResult)
        return DiscoveryOutcome(camera: nil,
                                widerScan: wider,
                                obstacle: sawAnythingAlive ? nil : .networkUnreachable)
    }

    private enum SubnetSweepResult {
        case found(DiscoveredCamera)
        case cancelled
        case nothing(wider: DiscoveryOutcome.WiderScan?, anythingAlive: Bool)
    }

    /// One network, fast pass then slow pass.
    private func sweepOne(
        _ subnet: IPv4Subnet,
        width: Int,
        cachedHost: String?,
        onProgress: (@Sendable (DiscoveryProgress) -> Void)?
    ) async -> SubnetSweepResult {
        let started = Date()
        let label = subnet.rangeDescription(forPrefix: width)

        // Report the network, not the phone's own address: they differ, and
        // printing the host address made the sweep look wrong.
        sink?.log(.info, .discovery,
                  "Sweeping \(label)",
                  detail: """
                  interface  \(subnet.interfaceName ?? "not known")
                  phone      \(subnet.address)
                  netmask    \(subnet.netmask) (/\(subnet.prefixLength))
                  network    \(subnet.networkAddress)
                  broadcast  \(subnet.broadcastAddress)
                  scanning   \(label), \(subnet.hostCount(forPrefix: width)) addresses
                  gateway    \(subnet.gateway.map(String.init(describing:)) ?? "not known")
                  """)

        let targets = subnet.scanTargets(prefixLength: width).filter { $0.description != cachedHost }
        guard !targets.isEmpty else {
            sink?.log(.warning, .discovery, "Nothing to scan on \(label)")
            return .nothing(wider: nil, anythingAlive: false)
        }

        onProgress?(.sweeping(subnet: label, probed: 0, total: targets.count))

        // 1. Ping first. One echo request per address costs a fraction of a
        //    TCP connection attempt, and the whole /24 answers inside the time
        //    a single HTTP pass needs, so asking who is alive before asking
        //    who is a camera turns 253 connection attempts into a handful.
        //
        //    The camera is confirmed to answer echo requests, so this is the
        //    path that normally finds it. It still does not get to decide the
        //    answer: an access point can filter echo between its clients and a
        //    single reply can be lost, so the full HTTP sweep below runs
        //    whenever this does not produce the camera.
        let living = await pingSweep(targets: targets, label: label)

        if let living, !living.isEmpty {
            let addresses = living.compactMap(IPv4Address.init)
            sink?.log(.info, .discovery,
                      "Asking the \(addresses.count) live addresses for the camera first")

            // These are known to be up, so they get the generous deadline
            // rather than the sweep's short one.
            if let camera = await sweep(targets: addresses, timeout: cachedAddressTimeout, onProbed: { _ in }) {
                return .found(camera)
            }
            sink?.log(.info, .discovery,
                      "None of the live addresses served the camera's CGI; sweeping the rest")
        }

        if Task.isCancelled { return .cancelled }

        // 2. Every address, in case the camera is one that does not answer a
        //    ping at all.
        sink?.log(.info, .discovery,
                  "\(targets.count) addresses, \(maxConcurrentProbes) at a time, "
                  + "\(Int(probeTimeout * 1000)) ms each")

        var found = await sweep(targets: targets, timeout: probeTimeout) { probed in
            onProgress?(.sweeping(subnet: label, probed: probed, total: targets.count))
        }

        if found == nil, Task.isCancelled {
            return .cancelled
        }

        // A busy embedded HTTP server can miss a short deadline, so a second,
        // slower pass over the whole range is worth its seconds — but only
        // where the fast pass is the only thing that has looked. The camera
        // answers ICMP, so when the ping sweep worked, anything alive has
        // already been probed at the long deadline by name. Repeating the
        // whole range at 1500 ms then costs eight seconds to re-ask 250
        // addresses that are not there. Where ping found nothing at all, that
        // evidence is missing and the slow pass still runs.
        let pingProvedTheRange = (living?.isEmpty == false)

        if found == nil, pingProvedTheRange {
            sink?.log(.info, .discovery,
                      "Not repeating the range at \(Int(slowProbeTimeout * 1000)) ms: "
                      + "the ping sweep already found everything that is alive here")
        }

        if found == nil, !pingProvedTheRange {
            sink?.log(.info, .discovery,
                      "Nothing answered in \(Int(probeTimeout * 1000)) ms; trying again at "
                      + "\(Int(slowProbeTimeout * 1000)) ms")
            found = await sweep(targets: targets, timeout: slowProbeTimeout) { probed in
                onProgress?(.sweeping(subnet: label, probed: probed, total: targets.count))
            }
        }

        if found == nil, Task.isCancelled {
            return .cancelled
        }

        if let found {
            return .found(found)
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        explainSilence(living: living, targets: targets, label: label)

        // Only offer the wider sweep when the phone's real network is bigger
        // than what was just swept.
        var wider: DiscoveryOutcome.WiderScan?
        if subnet.isWiderThanAutomatic && width > subnet.prefixLength {
            let count = subnet.hostCount(forPrefix: subnet.prefixLength)
            let seconds = Int((Double(count) / Double(max(maxConcurrentProbes, 1))) * probeTimeout)
            wider = DiscoveryOutcome.WiderScan(
                prefixLength: subnet.prefixLength,
                network: subnet.rangeDescription(forPrefix: subnet.prefixLength),
                addressCount: count,
                estimatedSeconds: max(seconds, 1)
            )
            sink?.log(.warning, .discovery,
                      "No camera on \(label) after \(elapsed)s. The phone's network is actually "
                      + "/\(subnet.prefixLength), which is \(count) addresses; that is not swept "
                      + "without asking.")
        } else {
            sink?.log(.info, .discovery, "No camera answered on \(label) after \(elapsed)s")
        }

        return .nothing(wider: wider, anythingAlive: !(living?.isEmpty ?? true))
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
                foundBy: source,
                versionReply: String(response.raw.prefix(600))
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
        reply     \(camera.versionReply)
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
        timeout: TimeInterval,
        onProbed: @Sendable @escaping (Int) -> Void
    ) async -> DiscoveredCamera? {
        let transport = self.transport
        let window = min(maxConcurrentProbes, targets.count)

        let outcome = await withTaskGroup(of: ProbeOutcome.self) { group -> (DiscoveredCamera?, SweepTally) in
            var index = 0
            var completed = 0
            var tally = SweepTally()
            tally.size = targets.count

            guard !Task.isCancelled else { return (nil, tally) }

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

                switch result {
                case .camera(let camera):
                    group.cancelAll()
                    return (camera, tally)
                case .answeredButNotCamera(let host, let reply):
                    tally.answeredButNotCamera += 1
                    tally.note("\(host)  answered, not the camera: \(reply)")
                case .refused(let host):
                    tally.refused += 1
                    tally.note("\(host)  refused the connection")
                case .timedOut(let host):
                    tally.timedOut += 1
                    tally.noteTimeout(host)
                case .otherFailure(let host, let reason):
                    tally.otherFailure += 1
                    tally.note("\(host)  \(reason)")
                }

                // The app cancels a sweep when the network changes or it goes
                // to the background. Stop feeding the group rather than
                // probing an address range the phone has left.
                if Task.isCancelled {
                    group.cancelAll()
                    return (nil, tally)
                }

                if index < targets.count {
                    let host = targets[index].description
                    index += 1
                    group.addTask {
                        await Self.probeStatic(host: host, timeout: timeout, transport: transport)
                    }
                }
            }
            return (nil, tally)
        }

        if outcome.0 == nil {
            let tally = outcome.1
            let detail = [tally.detail, reachabilityNote(tally)]
                .compactMap { $0 }
                .joined(separator: "\n\n")
            sink?.log(.info, .discovery,
                      "HTTP pass at \(Int(timeout * 1000)) ms: \(tally.summary)",
                      detail: detail.isEmpty ? nil : detail)
        }
        return outcome.0
    }

    /// Asks the whole range who is alive. Returns the addresses that answered,
    /// or nil when no ping sweep could be run at all — which is not the same
    /// as nobody answering, and callers must not treat it as such.
    private func pingSweep(targets: [IPv4Address], label: String) async -> [String]? {
        guard let reachability, !Task.isCancelled else { return nil }

        let started = Date()
        sink?.log(.info, .discovery, "Pinging \(targets.count) addresses on \(label)")

        let sweep = await reachability.ping(hosts: targets.map(\.description), timeout: pingTimeout)
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))

        if let failure = sweep.failure {
            sink?.log(.warning, .discovery,
                      "The ping sweep could not run: \(failure)",
                      detail: "Falling back to probing every address over HTTP.")
            return nil
        }

        // Who answered is the single most useful line in a failed export, so
        // it is recorded whether or not the camera turns up afterwards.
        sink?.log(.info, .discovery,
                  "\(sweep.answered.count) of \(targets.count) answered a ping in \(elapsed)s",
                  detail: sweep.answered.isEmpty
                      ? nil
                      : sweep.answered.prefix(SweepTally.maxNotes).joined(separator: "\n")
                        + (sweep.answered.count > SweepTally.maxNotes
                           ? "\nand \(sweep.answered.count - SweepTally.maxNotes) more" : ""))
        return sweep.answered
    }

    /// Says what a network that produced no camera actually told us. The three
    /// cases mean different things and "no camera found" hides all of them.
    private func explainSilence(living: [String]?, targets: [IPv4Address], label: String) {
        guard let living else { return }

        if living.isEmpty {
            sink?.log(.warning, .discovery,
                      "Nothing on \(label) answered a ping either",
                      detail: """
                      Not one of \(targets.count) addresses replied to an echo request, so \
                      this is not about port 80: the phone is not exchanging packets with \
                      anything on this network. That points at the network rather than at \
                      the camera.
                      """)
            return
        }

        sink?.log(.warning, .discovery,
                  "\(living.count) addresses on \(label) are alive but none is the camera",
                  detail: """
                  \(living.prefix(30).joined(separator: "\n"))

                  The phone can reach this network. If the camera is one of these it did \
                  not answer cmd=\(CameraCommand.version.rawValue) on port 80, and its \
                  address can be entered by hand on the Connect screen.
                  """)
    }

    /// Says what the tally means, because "no camera found" reads the same
    /// whether the network was empty or the phone was never let onto it.
    private func reachabilityNote(_ tally: SweepTally) -> String? {
        guard tally.reachable == 0, tally.timedOut > 0 else { return nil }
        return """
        Nothing on this network answered in any way, not even a refusal. That \
        is what it looks like when the local network permission is off \
        (Settings > FitCamXtra > Local Network), or when the access point \
        keeps its clients apart, as car head units often do. It is not proof \
        that the camera is absent.
        """
    }

    private static func probeStatic(
        host: String,
        timeout: TimeInterval,
        transport: CameraTransport
    ) async -> ProbeOutcome {
        let request = CameraRequest(.version)
        guard let url = URL(string: "http://\(host)\(request.path())") else {
            return .otherFailure(host: host, reason: "not a usable address")
        }
        do {
            let data = try await transport.get(url: url, timeout: timeout)
            let response = try CameraResponseParser.parse(data)
            let version = CameraVersion(response: response)
            guard version.looksLikeFitCamX else {
                return .answeredButNotCamera(
                    host: host,
                    reply: response.raw
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .prefix(160)
                        .description
                )
            }
            return .camera(DiscoveredCamera(
                host: host,
                model: version.model,
                firmware: version.firmware,
                foundBy: .subnetSweep,
                versionReply: String(response.raw.prefix(600))
            ))
        } catch CameraError.timedOut {
            return .timedOut(host: host)
        } catch CameraError.connectionRefused {
            return .refused(host: host)
        } catch let error as CameraError {
            return .otherFailure(host: host, reason: error.errorDescription ?? "\(error)")
        } catch {
            // Bytes came back that the parser could not read. Whatever is
            // there is reachable, which is what the tally counts.
            return .answeredButNotCamera(host: host, reply: error.localizedDescription)
        }
    }

    /// What one probe came back as. A sweep that finds nothing is not one
    /// story but several, and the log has to tell them apart.
    ///
    /// Everything except a plain timeout carries the address and what it said,
    /// because that is the material for reading a failed sweep afterwards. The
    /// timeouts are only counted: there are usually 250 of them and they all
    /// say the same nothing.
    private enum ProbeOutcome: Sendable {
        case camera(DiscoveredCamera)
        case answeredButNotCamera(host: String, reply: String)
        case refused(host: String)
        case timedOut(host: String)
        case otherFailure(host: String, reason: String)
    }

    /// The tally of one pass, logged whether or not it found anything.
    private struct SweepTally: Sendable {
        /// Per-address lines for everything that was not a plain timeout. The
        /// log is bounded, so this is one entry per pass rather than one per
        /// address, and it is capped in case a network is full of web servers.
        static let maxNotes = 40
        /// Up to this many addresses, every one is named, timeouts included.
        /// Above it a timeout is only counted: a swept /24 produces 250 of
        /// them and they all say the same nothing.
        static let namesEveryAddressUpTo = 16

        /// How many addresses this pass covered.
        var size = 0
        var answeredButNotCamera = 0
        var refused = 0
        var timedOut = 0
        var otherFailure = 0
        private(set) var notes: [String] = []
        private var droppedNotes = 0

        mutating func note(_ line: String) {
            if notes.count < Self.maxNotes {
                notes.append(line)
            } else {
                droppedNotes += 1
            }
        }

        mutating func noteTimeout(_ host: String) {
            guard size <= Self.namesEveryAddressUpTo else { return }
            note("\(host)  no answer")
        }

        /// Addresses that proved the phone can reach this network at all.
        var reachable: Int { answeredButNotCamera + refused }

        var summary: String {
            "\(answeredButNotCamera) answered, \(refused) refused, "
            + "\(timedOut) timed out, \(otherFailure) failed otherwise"
        }

        /// Every address worth naming, or nil when they all timed out.
        var detail: String? {
            guard !notes.isEmpty else { return nil }
            var lines = notes
            if droppedNotes > 0 {
                lines.append("and \(droppedNotes) more")
            }
            return lines.joined(separator: "\n")
        }
    }
}
