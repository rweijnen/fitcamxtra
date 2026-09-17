import Foundation
import Network

/// Watches the phone's network path so the app can reconnect by itself.
///
/// This matters more here than in a normal app: the usual sequence is to open
/// the app, find nothing, then join the camera's access point in Settings. A
/// one-shot search at launch would miss that entirely.
public final class NetworkPathMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "nl.remkoweijnen.fitcamxtra.path")
    private var lastToken: String?
    private var started = false

    public init() {}

    /// Calls `onChange` when the usable path changes, with a short description
    /// of what it changed to. Repeats of the same path are swallowed, because
    /// NWPathMonitor reports the same state more than once.
    public func start(onChange: @escaping @Sendable (String) -> Void) {
        guard !started else { return }
        started = true

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            let interfaces = path.availableInterfaces
                .map { "\($0.name):\($0.type)" }
                .joined(separator: ",")
            let token = "\(path.status)|\(interfaces)|\(path.isExpensive)"

            guard token != self.lastToken else { return }
            self.lastToken = token

            guard path.status == .satisfied else {
                onChange("no usable network")
                return
            }
            let wifi = path.usesInterfaceType(.wifi)
            onChange(wifi ? "wifi" : "a network that is not wifi")
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }
}
