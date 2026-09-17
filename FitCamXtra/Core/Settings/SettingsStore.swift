import Foundation
import Observation

/// Reads and writes the camera's settings.
///
/// Reading is a single `cmd=3014`, not one request per row. Sending a config
/// command without `par` does **not** report its value on this firmware: it
/// answers `<Status>0</Status>` meaning the command was accepted, which read
/// back as the value zero and made every row look switched off.
///
/// Writes are applied optimistically so a toggle feels instant, then the whole
/// snapshot is re-read so the camera has the last word. A row the snapshot does
/// not mention stays unknown and cannot be edited.
@Observable
@MainActor
final class SettingsStore {
    private(set) var snapshot = CameraConfigSnapshot()
    private(set) var resolutions: [ResolutionOption] = []
    private(set) var accessPoint: CameraAccessPoint?
    private(set) var visibleNetworks: [CameraVisibleNetwork] = []
    private(set) var isLoading = false
    private(set) var isScanningNetworks = false
    private(set) var lastError: String?
    private(set) var pending: Set<String> = []

    /// Optimistic values, shown until the next snapshot confirms or corrects.
    private var overrides: [Int: Int] = [:]

    private var client: CameraClient?
    private let sink: LogSink

    init(sink: LogSink) {
        self.sink = sink
    }

    func attach(client: CameraClient?) {
        self.client = client
        if client == nil {
            snapshot = CameraConfigSnapshot()
            resolutions = []
            accessPoint = nil
            visibleNetworks = []
            overrides = [:]
        }
    }

    // MARK: - Reading

    func value(for setting: CameraSetting) -> SettingValue {
        if case .destructiveAction = setting.kind { return .unknown }
        if let optimistic = overrides[setting.command.rawValue] {
            return .number(optimistic)
        }
        guard !snapshot.isEmpty else { return .unknown }
        guard let value = snapshot.value(for: setting.command) else {
            return .unavailable("not reported by this camera")
        }
        return .number(value)
    }

    /// The options a row should show. Resolution comes from the camera's own
    /// capability report; everything else uses the declared list.
    func options(for setting: CameraSetting) -> [SettingOption] {
        if setting.command == .recordResolution, !resolutions.isEmpty {
            return resolutions.map { option in
                SettingOption(option.index, option.isUpscaled ? option.label + " (upscaled)" : option.label)
            }
        }
        if case .options(let declared) = setting.kind { return declared }
        return []
    }

    func loadAll() async {
        guard let client else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        // What the unit can do, then what it is currently set to.
        if resolutions.isEmpty {
            if let response = try? await client.send(.resolutionCapability) {
                resolutions = ResolutionOption.parse(Data(response.raw.utf8))
                sink.log(.info, .app, "\(resolutions.count) resolutions offered",
                         detail: resolutions.map { "index \($0.index)  \($0.label)" }.joined(separator: "\n"))
            }
        }

        if let response = try? await client.send(.wifiInfo) {
            accessPoint = CameraAccessPoint.parse(Data(response.raw.utf8))
        }

        await refreshSnapshot()
    }

    private func refreshSnapshot() async {
        guard let client else { return }
        do {
            let response = try await client.send(.allConfigValues)
            let parsed = CameraConfigSnapshot.parse(Data(response.raw.utf8))
            guard !parsed.isEmpty else {
                lastError = "The camera returned no settings."
                sink.log(.warning, .app, "cmd=3014 parsed to nothing", detail: String(response.raw.prefix(1200)))
                return
            }
            snapshot = parsed
            overrides = [:]

            let known = SettingsRegistry.all.compactMap { parsed.value(for: $0.command) }.count
            sink.log(.info, .app, "Settings read: \(known) of \(SettingsRegistry.all.count) rows reported",
                     detail: parsed.values
                        .sorted { $0.key < $1.key }
                        .map { "cmd \($0.key) = \($0.value)" }
                        .joined(separator: "\n"))
        } catch {
            lastError = error.localizedDescription
            sink.log(.error, .app, "Reading settings failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Writing

    func apply(_ setting: CameraSetting, par: Int) async {
        guard let client else { return }

        overrides[setting.command.rawValue] = par
        pending.insert(setting.id)
        defer { pending.remove(setting.id) }

        do {
            try await client.send(setting.command, par: par)
            sink.log(.info, .app, "\(setting.label) set to \(par)")
            await refreshSnapshot()

            if let actual = snapshot.value(for: setting.command), actual != par {
                sink.log(.warning, .app,
                         "\(setting.label) was set to \(par) but reads back as \(actual)")
            }
        } catch {
            overrides.removeValue(forKey: setting.command.rawValue)
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

    // MARK: - Wifi scan

    /// Asks the camera which networks it can see. The phone cannot enumerate
    /// wifi, but the camera can, so station mode offers a list rather than
    /// asking someone to type an SSID exactly right.
    func scanNetworks() async {
        guard let client, !isScanningNetworks else { return }
        isScanningNetworks = true
        defer { isScanningNetworks = false }

        do {
            // The scan takes a couple of seconds on the camera itself.
            let response = try await client.send(.scanWifiNetworks, timeout: 15)
            visibleNetworks = CameraVisibleNetwork.parse(Data(response.raw.utf8))
            sink.log(.info, .app, "Camera sees \(visibleNetworks.count) networks",
                     detail: visibleNetworks.map(\.ssid).joined(separator: "\n"))
        } catch {
            lastError = "Scanning for networks failed: \(error.localizedDescription)"
            sink.log(.error, .app, "Wifi scan failed: \(error.localizedDescription)")
        }
    }

    func clearError() {
        lastError = nil
    }
}
