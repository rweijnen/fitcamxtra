import Foundation

// Portable: no Apple-only types. The command surface recovered from the
// CAR-WA7053 firmware command table. Transport is
// GET http://<host>/?custom=1&cmd=<N>[&par=<int>][&str=<string>] -> XML.

public enum CameraCommand: Int, Sendable, CaseIterable {
    // Snapshot
    case takePhoto = 1001
    case snapshotImageSize = 1002

    // Video
    case setRecordStatus = 2001
    case recordResolution = 2002
    case fileDuration = 2003
    case wideDynamic = 2004
    case exposure = 2005
    case microphone = 2007
    case watermark = 2008
    case sensorLevel = 2011
    case autoRecord = 2012
    /// 2013 is named SetRecordBitrate in the dispatch table but reports
        /// nothing and does not hold the value. The bitrate the firmware
        /// validates against its 8000 default and 32000 ceiling is config index
        /// 0x34, which is command 2022. Confirmed on a CAR-WA7053: cmd=3014
        /// reports 2022 as 8000.
    case unusedRecordBitrate = 2013
    case liveviewBitrate = 2014
    case startLive = 2015
    case recordStatus = 2016
    case takePhotoSimple = 2017
    case streamURL = 2019
    /// Named Config_Video_AntiProtect in the table, but it carries the
    /// record bitrate in kbps. See the note on 2013.
    case recordBitrate = 2022
    case verticalFlip = 2023

    // Device and management
    case setWorkMode = 3001
    case supportedCommands = 3002
    case wifiName = 3003
    case wifiPassword = 3004
    case setDate = 3005
    case setTime = 3006
    case language = 3008
    case displayMode = 3009
    case formatSDCard = 3010
    case factoryReset = 3011
    case version = 3012
    case applyFirmware = 3013
    case allConfigValues = 3014
    case eventFileList = 3015
    case baseInfo = 3017
    case rebootWifi = 3018
    case batteryStatus = 3019
    case saveConfig = 3021
    case sdCardStatus = 3024
    case switchCamera = 3028
    case wifiInfo = 3029
    case resolutionCapability = 3030
    case allCapability = 3031
    case setStationCredentials = 3032
    case setNetworkMode = 3033
    case parkingSensor = 3038

    // Files
    case thumbnail = 4001
    case deleteFile = 4003
    case movieFileInfo = 4005

    // Parking
    case batteryValue = 8005

    /// Listed as Config_Parking_DurationLimit, but it answers with a scan of
    /// the wifi networks the camera can see. Useful: the phone cannot
    /// enumerate networks, so this is how station mode offers a list.
    case scanWifiNetworks = 8050
}

/// One camera request. Deliberately value-typed and transport-free so the
/// same model can back an Android client later.
public struct CameraRequest: Sendable, Equatable {
    public let command: CameraCommand
    public var par: Int?
    public var str: String?

    public init(_ command: CameraCommand, par: Int? = nil, str: String? = nil) {
        self.command = command
        self.par = par
        self.str = str
    }

    /// Query string in the order the firmware's dispatcher expects.
    public func query() -> String {
        var items = ["custom=1", "cmd=\(command.rawValue)"]
        if let par {
            items.append("par=\(par)")
        }
        if let str {
            items.append("str=\(Self.escape(str))")
        }
        return items.joined(separator: "&")
    }

    public func path() -> String {
        "/?" + query()
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        for byte in Array(value.utf8) {
            let scalar = UnicodeScalar(byte)
            let isUnreserved =
                (byte >= 0x41 && byte <= 0x5A) ||
                (byte >= 0x61 && byte <= 0x7A) ||
                (byte >= 0x30 && byte <= 0x39) ||
                scalar == "-" || scalar == "_" || scalar == "." || scalar == "~" ||
                // The station-mode credentials were confirmed on hardware with
                // a literal colon between the name and the password. Percent
                // encoding it assumes the firmware decodes, which is not
                // something this CGI has been shown to do.
                scalar == ":"
            if isUnreserved {
                out.unicodeScalars.append(scalar)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}

public enum NetworkMode: Int, Sendable, CaseIterable {
    case accessPoint = 0
    case station = 1

    public var label: String {
        switch self {
        case .accessPoint: return "AP"
        case .station: return "STATION"
        }
    }
}
