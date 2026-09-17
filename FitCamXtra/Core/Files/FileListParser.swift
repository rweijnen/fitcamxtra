import Foundation

/// Reads the camera's file and event lists.
///
/// The firmware's list template is not documented, so this recognises the
/// shapes Novatek builds actually use and falls back to any repeated element
/// that carries a name and a size. The raw XML is logged on every fetch, so a
/// shape this misses can be added rather than guessed at.
public enum FileListParser {
    /// Element names seen across Novatek builds for one record.
    private static let recordNames = ["file", "item", "movie", "photo", "event"]

    public static func parse(_ data: Data, now: Date = Date()) -> [MediaFile] {
        guard let root = XMLTreeParser.parse(data) else { return [] }

        var records: [XMLNode] = []
        for name in recordNames {
            let found = root.descendants(named: name).filter { !$0.children.isEmpty }
            if !found.isEmpty {
                records = found
                break
            }
        }
        if records.isEmpty {
            // Fall back to the largest group of repeated sibling elements.
            records = root.repeatedGroups().max(by: { $0.count < $1.count }) ?? []
        }

        return records.compactMap { record(from: $0) }
    }

    private static func record(from node: XMLNode) -> MediaFile? {
        guard let rawPath = node.value("fpath", "path", "filepath", "url")
                ?? node.value("name", "filename")
        else { return nil }

        let name = node.value("name", "filename") ?? lastComponent(of: rawPath)
        guard !name.isEmpty else { return nil }

        let size = node.value("size", "fsize", "length").flatMap { Int64($0.filter(\.isNumber)) } ?? 0
        let date = node.value("time", "date", "timecode", "ctime").flatMap(parseDate) ?? Date()
        let duration = node.value("duration", "playtime", "time_len").flatMap(parseDuration)

        // The attribute field carries the protect bit on these builds. Treat
        // any of the usual spellings as authoritative and otherwise fall back
        // to the folder convention.
        let locked: Bool
        if let attribute = node.value("attr", "lock", "protect", "locked") {
            locked = attribute != "0" && attribute.lowercased() != "false"
        } else {
            locked = rawPath.uppercased().contains("EVENT") || rawPath.uppercased().contains("RO")
        }

        let kind: MediaFile.Kind = isPhoto(name) ? .photo : .video

        return MediaFile(
            id: httpPath(from: rawPath),
            path: httpPath(from: rawPath),
            recordedAt: date,
            byteCount: size,
            kind: kind,
            duration: duration,
            isLocked: locked
        )
    }

    private static func isPhoto(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png")
    }

    private static func lastComponent(of path: String) -> String {
        let normalised = path.replacingOccurrences(of: "\\", with: "/")
        return normalised.split(separator: "/").last.map(String.init) ?? path
    }

    /// The camera reports a DOS-style path such as `A:\DCIM\100MEDIA\FILE.MOV`,
    /// while its own HTTP file server serves `/DCIM/100MEDIA/FILE.MOV`.
    public static func httpPath(from cameraPath: String) -> String {
        var path = cameraPath.replacingOccurrences(of: "\\", with: "/")
        if let colon = path.firstIndex(of: ":") {
            path = String(path[path.index(after: colon)...])
        }
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
            return path
        }
        if !path.hasPrefix("/") { path = "/" + path }
        return path
    }

    /// Accepts the formats these builds emit, newest convention first.
    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let formats = [
            "yyyy/MM/dd HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy/MM/dd_HH:mm:ss",
            "yyyyMMddHHmmss",
            "yyyy/MM/dd",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        // Some builds embed the stamp in the file name: 20260430203630_014965
        if let match = trimmed.range(of: "[0-9]{14}", options: .regularExpression) {
            formatter.dateFormat = "yyyyMMddHHmmss"
            return formatter.date(from: String(trimmed[match]))
        }
        return nil
    }

    static func parseDuration(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) { return seconds }
        // hh:mm:ss or mm:ss
        let parts = trimmed.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Derives the recording time from a file name when the list omits it.
    public static func dateFromName(_ name: String) -> Date? {
        parseDate(name)
    }
}

extension MediaFile {
    /// The event view groups by the minute the clip started.
    public var displayName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    public var sizeLabel: String {
        let megabytes = Double(byteCount) / 1_048_576
        if megabytes >= 1024 {
            return String(format: "%.1f GB", megabytes / 1024)
        }
        return String(format: "%.0f MB", megabytes)
    }

    public var durationLabel: String? {
        guard let duration, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
