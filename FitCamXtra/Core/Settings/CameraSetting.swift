import Foundation

// The Novatek CGI convention: a command sent without `par` reports the current
// value, and the same command with `par` sets it. That means every row here is
// both a getter and a setter, and no separate read command is needed.
//
// Some mappings below are marked provisional. The firmware's own capability
// report (cmd 3031 and 3030) is fetched on connect and written to the
// diagnostics log, so the real option lists can replace the guesses rather
// than being invented here.

public enum SettingGroup: String, Sendable, CaseIterable, Identifiable {
    case video = "VIDEO"
    case advanced = "ADVANCED"
    case parking = "PARKING MODE"
    case general = "GENERAL"

    public var id: String { rawValue }

    public var note: String? {
        switch self {
        case .parking: return "Not all units have this. Check your model."
        default: return nil
        }
    }
}

public enum SettingKind: Sendable {
    case toggle
    /// Discrete choices as (par value, label).
    case options([SettingOption])
    /// Continuous value. `step` is in the command's own units.
    case slider(range: ClosedRange<Double>, step: Double, unit: String, scale: Double)
    /// Read-only text, such as a firmware version.
    case readOnly
    /// A command with consequences, confirmed before sending.
    case destructiveAction(confirmTitle: String, confirmBody: String, par: Int?)
}

public struct SettingOption: Sendable, Equatable, Identifiable {
    public let par: Int
    public let label: String
    public var id: Int { par }

    public init(_ par: Int, _ label: String) {
        self.par = par
        self.label = label
    }
}

public struct CameraSetting: Sendable, Identifiable {
    public let id: String
    public let group: SettingGroup
    public let label: String
    public let hint: String?
    public let command: CameraCommand
    public let kind: SettingKind
    /// True when the command number is confirmed from the firmware table but
    /// the meaning of `par` is not yet verified on a real unit.
    public let provisional: Bool

    public init(
        id: String,
        group: SettingGroup,
        label: String,
        hint: String? = nil,
        command: CameraCommand,
        kind: SettingKind,
        provisional: Bool = false
    ) {
        self.id = id
        self.group = group
        self.label = label
        self.hint = hint
        self.command = command
        self.kind = kind
        self.provisional = provisional
    }
}

public enum SettingsRegistry {
    public static let all: [CameraSetting] = [
        // MARK: Video
        CameraSetting(
            id: "microphone",
            group: .video,
            label: "Sound Recording",
            hint: "Records to the clip; live view stays muted",
            command: .microphone,
            kind: .toggle
        ),
        // Options are replaced at runtime by what cmd=3030 reports, because
        // the indices are not contiguous: a CAR-WA7053 uses 1, 7 and 10.
        CameraSetting(
            id: "resolution",
            group: .video,
            label: "Video Resolution",
            hint: "4K is upscaled from a 2K sensor, so it means bigger files and no extra detail",
            command: .recordResolution,
            kind: .options([])
        ),
        CameraSetting(
            id: "bitrate",
            group: .video,
            label: "Record Bitrate",
            hint: "Higher is clearer and bigger, and fills the card faster.",
            command: .recordBitrate,
            // Default 8000, and Validate_UI_configuration rejects above 32000.
            // Confirmed on hardware: cmd=3014 reports 2022 as 8000.
            kind: .slider(range: 8000...32000, step: 1000, unit: "Mbps", scale: 0.001)
        ),
        CameraSetting(
            id: "loop",
            group: .video,
            label: "Loop Record",
            hint: "The oldest clip is overwritten when the card is full",
            command: .fileDuration,
            kind: .options([
                SettingOption(1, "1 min"),
                SettingOption(2, "2 min"),
                SettingOption(3, "3 min"),
            ]),
            provisional: true
        ),
        CameraSetting(
            id: "exposure",
            group: .video,
            label: "Exposure Compensation",
            command: .exposure,
            kind: .options([
                SettingOption(0, "-2.0"), SettingOption(1, "-1.5"), SettingOption(2, "-1.0"),
                SettingOption(3, "-0.5"), SettingOption(4, "0.0"), SettingOption(5, "+0.5"),
                SettingOption(6, "+1.0"), SettingOption(7, "+1.5"), SettingOption(8, "+2.0"),
            ]),
            provisional: true
        ),
        CameraSetting(
            id: "wdr",
            group: .video,
            label: "WDR / HDR",
            command: .wideDynamic,
            kind: .toggle
        ),
        CameraSetting(
            id: "watermark",
            group: .video,
            label: "Watermark",
            hint: "The brand mark burned into the frame",
            command: .watermark,
            kind: .toggle
        ),
        CameraSetting(
            id: "flip",
            group: .video,
            label: "Image Flip",
            hint: "For upside-down mounting",
            command: .verticalFlip,
            kind: .toggle
        ),
        CameraSetting(
            id: "autorecord",
            group: .video,
            label: "Auto Record",
            hint: "Start recording when the camera gets power",
            command: .autoRecord,
            kind: .toggle
        ),

        // MARK: Advanced
        // 2011 is not shown. The firmware's own command table calls it
        // Config_Snapshot_SensorLevel, against config field 0x4f, so the
        // driving G-sensor it was shipped as is somebody else's setting.
        // Telling a dashcam owner their collision sensing is off, when the
        // row may control something about stills, is worse than not offering
        // the row at all. It comes back when hardware says what it does.
        CameraSetting(
            id: "language",
            group: .advanced,
            label: "Camera Language",
            command: .language,
            kind: .options([
                SettingOption(0, "English"),
                SettingOption(1, "Chinese"),
                SettingOption(2, "Japanese"),
                SettingOption(3, "Russian"),
            ]),
            provisional: true
        ),

        // MARK: Parking
        CameraSetting(
            id: "parking",
            group: .parking,
            label: "Parking Collision Detection",
            hint: "Impact sensing after the car is off",
            command: .parkingSensor,
            kind: .options([
                SettingOption(0, "Off"),
                SettingOption(1, "Least"),
                SettingOption(2, "Medium"),
                SettingOption(3, "Most"),
            ]),
            provisional: true
        ),
        // MARK: General
        CameraSetting(
            id: "format",
            group: .general,
            label: "Format SD Card",
            command: .formatSDCard,
            kind: .destructiveAction(
                confirmTitle: "Format the SD card?",
                confirmBody: "Every clip and photo on the card is erased, including locked ones. This cannot be undone.",
                par: 1
            )
        ),
        CameraSetting(
            id: "reset",
            group: .general,
            label: "Factory Reset",
            hint: "Also restores AP mode, which makes this a way back if station mode goes wrong",
            command: .factoryReset,
            kind: .destructiveAction(
                confirmTitle: "Reset the camera?",
                confirmBody: "Every camera setting returns to its default and the camera goes back to running its own access point. Recordings on the card are kept.",
                par: 1
            )
        ),
    ]

    public static func settings(in group: SettingGroup) -> [CameraSetting] {
        all.filter { $0.group == group }
    }
}

/// What the app currently knows about one row. A value that could not be read
/// stays `unknown` rather than showing a default the camera never reported.
public enum SettingValue: Sendable, Equatable {
    case unknown
    case unavailable(String)
    case number(Int)

    public var intValue: Int? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var isEditable: Bool {
        if case .number = self { return true }
        return false
    }
}
