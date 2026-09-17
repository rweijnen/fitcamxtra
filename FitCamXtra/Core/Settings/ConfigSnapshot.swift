import Foundation

/// All current settings in one request.
///
/// Confirmed on a CAR-WA7053 unit: sending a config command **without** `par`
/// does not report its value. It answers `<Status>0</Status>` meaning "command
/// accepted" and nothing else, so reading rows one at a time returns a wall of
/// zeroes that looks like every setting is off.
///
/// `cmd=3014` is the real getter. It returns alternating `Cmd` and `Status`
/// elements, where `Status` carries that command's current value:
///
/// ```xml
/// <Function>
///   <Cmd>2002</Cmd><Status>10</Status>   <!-- resolution index 10 -->
///   <Cmd>2022</Cmd><Status>8000</Status> <!-- record bitrate, kbps -->
/// </Function>
/// ```
public struct CameraConfigSnapshot: Sendable, Equatable {
    public private(set) var values: [Int: Int] = [:]

    public init(values: [Int: Int] = [:]) {
        self.values = values
    }

    public func value(for command: CameraCommand) -> Int? {
        values[command.rawValue]
    }

    public var isEmpty: Bool { values.isEmpty }

    /// Walks the reply pairwise. Anything that is not a Cmd followed by a
    /// Status is skipped rather than guessed at.
    public static func parse(_ data: Data) -> CameraConfigSnapshot {
        guard let root = XMLTreeParser.parse(data) else { return CameraConfigSnapshot() }

        var values: [Int: Int] = [:]
        var pendingCommand: Int?

        for node in root.children {
            switch node.name {
            case "cmd":
                pendingCommand = Int(node.text)
            case "status":
                if let command = pendingCommand, let value = Int(node.text) {
                    values[command] = value
                }
                pendingCommand = nil
            default:
                pendingCommand = nil
            }
        }
        return CameraConfigSnapshot(values: values)
    }
}

/// The resolutions this unit actually offers, from `cmd=3030`.
///
/// The indices are not contiguous, so they cannot be guessed. A CAR-WA7053
/// reports 1 for 2160p30, 7 for 1440p30 and 10 for 1080p60.
public struct ResolutionOption: Sendable, Equatable, Identifiable {
    public let index: Int
    public let name: String
    public let width: Int?
    public let height: Int?
    public let frameRate: Int?

    public var id: Int { index }

    /// "2560x1440 30fps", falling back to the camera's own label.
    public var label: String {
        guard let width, let height else { return name }
        let size = "\(width)x\(height)"
        guard let frameRate else { return size }
        return "\(size) \(frameRate)fps"
    }

    /// The sensor is 4 megapixels, so anything above 1440 lines is upscaled.
    public var isUpscaled: Bool {
        (height ?? 0) > 1440
    }

    public static func parse(_ data: Data) -> [ResolutionOption] {
        guard let root = XMLTreeParser.parse(data) else { return [] }

        return root.descendants(named: "item").compactMap { item -> ResolutionOption? in
            guard let index = item.value("index").flatMap(Int.init) else { return nil }
            let size = item.value("size") ?? ""
            let parts = size.split(whereSeparator: { $0 == "*" || $0 == "x" || $0 == "X" })
            return ResolutionOption(
                index: index,
                name: item.value("name") ?? size,
                width: parts.count == 2 ? Int(parts[0]) : nil,
                height: parts.count == 2 ? Int(parts[1]) : nil,
                frameRate: item.value("framerate").flatMap(Int.init)
            )
        }
        .sorted { ($0.height ?? 0, $0.frameRate ?? 0) > ($1.height ?? 0, $1.frameRate ?? 0) }
    }
}

/// One wifi network the camera can see, from the camera's own scan.
///
/// The camera scans for access points and reports them. That is worth having:
/// the phone cannot enumerate networks, but the camera can, so station mode
/// can offer a list instead of asking someone to type an SSID exactly.
public struct CameraVisibleNetwork: Sendable, Equatable, Identifiable {
    public let ssid: String
    public let authType: Int?
    /// As reported. The firmware labels it dBm but sends a positive number,
    /// so it is treated as a relative strength only.
    public let signal: Int?

    public var id: String { ssid }

    public static func parse(_ data: Data) -> [CameraVisibleNetwork] {
        guard let root = XMLTreeParser.parse(data) else { return [] }

        var seen = Set<String>()
        return root.descendants(named: "ap_index").compactMap { node -> CameraVisibleNetwork? in
            guard let ssid = node.value("ssid"), !ssid.isEmpty, seen.insert(ssid).inserted else {
                return nil
            }
            let signal = node.value("rssi")?
                .split(separator: " ")
                .first
                .flatMap { Int($0) }
            return CameraVisibleNetwork(
                ssid: ssid,
                authType: node.value("auth_type").flatMap(Int.init),
                signal: signal
            )
        }
    }
}

/// The camera's own access point details, from `cmd=3029`.
public struct CameraAccessPoint: Sendable, Equatable {
    public let ssid: String?
    public let passphrase: String?

    public static func parse(_ data: Data) -> CameraAccessPoint {
        guard let root = XMLTreeParser.parse(data) else {
            return CameraAccessPoint(ssid: nil, passphrase: nil)
        }
        return CameraAccessPoint(
            ssid: root.descendants(named: "ssid").first?.text,
            passphrase: root.descendants(named: "passphrase").first?.text
        )
    }
}
