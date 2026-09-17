import Foundation
import Observation

/// Reads and writes the camera's settings.
///
/// Values are applied optimistically so a toggle feels instant, then rolled
/// back if the camera refuses. A row whose value could not be read is left
/// unknown and cannot be edited, so the UI never claims a state the camera
/// did not report.
@Observable
@MainActor
final class SettingsStore {
    private(set) var values: [String: SettingValue] = [:]
    private(set) var isLoading = false
    private(set) var lastError: String?
    /// Rows currently waiting on the camera.
    private(set) var pending: Set<String> = []

    private var client: CameraClient?
    private let sink: LogSink

    init(sink: LogSink) {
        self.sink = sink
    }

    func attach(client: CameraClient?) {
        self.client = client
        if client == nil {
            values.removeAll()
        }
    }

    func value(for setting: CameraSetting) -> SettingValue {
        values[setting.id] ?? .unknown
    }

    // MARK: - Reading

    /// Reads every row. Rows are read in parallel but the camera is a small
    /// embedded server, so the width is kept modest.
    func loadAll() async {
        guard let client else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        sink.log(.info, .app, "Reading camera settings")
        await readCapabilities(client: client)

        let readable = SettingsRegistry.all.filter { setting in
            switch setting.kind {
            case .destructiveAction, .readOnly: return false
            default: return true
            }
        }

        // The camera is a small embedded server, so keep the width modest and
        // work through the rows in batches rather than all at once.
        var fresh: [String: SettingValue] = [:]
        for batch in stride(from: 0, to: readable.count, by: 4).map({
            Array(readable[$0..<min($0 + 4, readable.count)])
        }) {
            await withTaskGroup(of: (String, SettingValue).self) { group in
                for setting in batch {
                    group.addTask {
                        let value = await Self.read(setting, client: client)
                        return (setting.id, value)
                    }
                }
                for await (id, value) in group {
                    fresh[id] = value
                }
            }
        }
        values = fresh

        let answered = fresh.values.filter { $0.isEditable }.count
        sink.log(answered == fresh.count ? .info : .warning, .app,
                 "Settings read: \(answered) of \(fresh.count) rows returned a value")
    }

    /// The firmware reports what it supports. We do not parse it into the UI
    /// yet, but recording it means the provisional option lists can be
    /// replaced with the camera's real ones rather than more guesses.
    private func readCapabilities(client: CameraClient) async {
        for command in [CameraCommand.allCapability, .resolutionCapability, .allConfigValues] {
            do {
                let response = try await client.send(command)
                sink.log(.info, .app, "Capability report cmd=\(command.rawValue)",
                         detail: String(response.raw.prefix(2000)))
            } catch {
                sink.log(.debug, .app, "cmd=\(command.rawValue) not readable: \(error.localizedDescription)")
            }
        }
    }

    private static func read(_ setting: CameraSetting, client: CameraClient) async -> SettingValue {
        do {
            // No `par` means "report the current value" in this CGI.
            let response = try await client.send(setting.command)
            if let value = numericValue(in: response) {
                return .number(value)
            }
            return .unavailable("no value in the reply")
        } catch CameraError.commandUnsupported {
            return .unavailable("not supported by this camera")
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// The reply element differs per command, so try the names the firmware's
    /// templates actually use before giving up.
    private static func numericValue(in response: CameraResponse) -> Int? {
        for key in ["value", "val", "status", "cur", "current", "string"] {
            if let value = response.int(key) { return value }
        }
        return nil
    }

    // MARK: - Writing

    func apply(_ setting: CameraSetting, par: Int) async {
        guard let client else { return }

        let previous = values[setting.id] ?? .unknown
        values[setting.id] = .number(par)
        pending.insert(setting.id)
        defer { pending.remove(setting.id) }

        do {
            try await client.send(setting.command, par: par)
            sink.log(.info, .app, "\(setting.label) set to \(par)")

            // Re-read so the camera, not the app, has the last word.
            let confirmed = await Self.read(setting, client: client)
            if case .number(let actual) = confirmed {
                values[setting.id] = .number(actual)
                if actual != par {
                    sink.log(.warning, .app,
                             "\(setting.label) was set to \(par) but reads back as \(actual)")
                }
            }
        } catch {
            values[setting.id] = previous
            lastError = "\(setting.label) could not be changed: \(error.localizedDescription)"
            sink.log(.error, .app, "\(setting.label) failed: \(error.localizedDescription)")
        }
    }

    /// Destructive commands are never optimistic and never re-read.
    func runAction(_ setting: CameraSetting, par: Int?) async -> Bool {
        guard let client else { return false }
        pending.insert(setting.id)
        defer { pending.remove(setting.id) }

        do {
            try await client.send(setting.command, par: par)
            sink.log(.warning, .app, "\(setting.label) was run")
            return true
        } catch {
            lastError = "\(setting.label) failed: \(error.localizedDescription)"
            sink.log(.error, .app, "\(setting.label) failed: \(error.localizedDescription)")
            return false
        }
    }

    func clearError() {
        lastError = nil
    }
}
