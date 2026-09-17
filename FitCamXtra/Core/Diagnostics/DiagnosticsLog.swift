import Foundation
import Observation

// For a local-network app the interesting failures are silent: a probe that
// timed out, a reply that would not parse, a permission that was refused.
// None of that reaches a crash report, so the app keeps its own record.

public enum LogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}

public enum LogCategory: String, Sendable {
    case discovery = "DISCOVERY"
    case http = "HTTP"
    case app = "APP"
    case network = "NETWORK"
}

public struct LogEntry: Sendable, Identifiable {
    public let id = UUID()
    public let at: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    /// Raw payload, such as the camera's XML, kept out of the summary line.
    public let detail: String?

    public init(
        at: Date = Date(),
        level: LogLevel,
        category: LogCategory,
        message: String,
        detail: String? = nil
    ) {
        self.at = at
        self.level = level
        self.category = category
        self.message = message
        self.detail = detail
    }
}

/// Portable logging seam. Core code logs through this and never knows whether
/// anything is listening.
public protocol LogSink: Sendable {
    func record(_ entry: LogEntry)
}

extension LogSink {
    public func log(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: String,
        detail: String? = nil
    ) {
        record(LogEntry(level: level, category: category, message: message, detail: detail))
    }
}

/// The in-app log. Bounded, so a long sweep cannot grow without limit.
@Observable
@MainActor
public final class DiagnosticsLog {
    public private(set) var entries: [LogEntry] = []
    private let limit: Int

    public init(limit: Int = 500) {
        self.limit = limit
    }

    public func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    public func clear() {
        entries.removeAll()
    }

    /// Plain text for the share sheet.
    /// Context about the app and device, so a log sent on its own still says
    /// what produced it. Set when the app starts and on every connection.
    public var context: [String: String] = [:]

    public func setContext(_ key: String, _ value: String?) {
        if let value, !value.isEmpty {
            context[key] = value
        } else {
            context.removeValue(forKey: key)
        }
    }

    public func exportText() -> String {
        let stamp = Date().formatted(date: .abbreviated, time: .standard)
        var out = "FitCamXtra diagnostics\nExported \(stamp)\n"
        for key in context.keys.sorted() {
            out += "\(key.padding(toLength: 12, withPad: " ", startingAt: 0)) \(context[key] ?? "")\n"
        }
        out += "\(entries.count) entries\n\n"

        for entry in entries {
            out += Self.line(for: entry)
            if let detail = entry.detail, !detail.isEmpty {
                let indented = detail
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "    " + $0 }
                    .joined(separator: "\n")
                out += "\n" + indented
            }
            out += "\n"
        }
        return out
    }

    /// Writes the log to a real file so the share sheet offers Mail, Files and
    /// AirDrop properly. Sharing a long string instead lands it inline in a
    /// message body, which is unusable at a few hundred entries.
    public func exportFile() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "FitCamXtra-diagnostics-\(formatter.string(from: Date())).txt"

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try exportText().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func line(for entry: LogEntry) -> String {
        let time = entry.at.formatted(.dateTime.hour().minute().second())
        return "\(time)  \(entry.level.label.padding(toLength: 5, withPad: " ", startingAt: 0))  \(entry.category.rawValue)  \(entry.message)"
    }
}

/// Sendable adapter, so portable code can log into the UI-bound store without
/// depending on it.
public struct DiagnosticsSink: LogSink {
    private let log: DiagnosticsLog

    public init(_ log: DiagnosticsLog) {
        self.log = log
    }

    public func record(_ entry: LogEntry) {
        Task { @MainActor in
            log.append(entry)
        }
    }
}
