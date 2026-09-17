import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var showDiagnostics = false
    @State private var showNetwork = false
    @State private var showForgetConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(Typo.sans(30, .semibold))
                    .tracking(-0.9)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, Metrics.headerTop)

                cameraCard

                if !state.connection.isConnected {
                    notConnectedNote
                }

                generalGroup

                ForEach(SettingGroup.allCases) { group in
                    let rows = SettingsRegistry.settings(in: group)
                    if !rows.isEmpty && group != .general {
                        settingsGroup(group, rows: rows)
                    }
                }

                if let error = state.settings.lastError {
                    Text(error)
                        .font(Typo.mono(11))
                        .foregroundStyle(Palette.destructiveText)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                                .fill(Palette.destructiveBg)
                        )
                        .onTapGesture { state.settings.clearError() }
                }

                destructiveGroup
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.scrollBottom)
        }
        .background(Palette.bg)
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
        .sheet(isPresented: $showNetwork) { NetworkView() }
        .task(id: state.connection.camera?.host) {
            if state.connection.isConnected {
                await state.settings.loadAll()
            }
        }
    }

    // MARK: - Camera card

    private var cameraCard: some View {
        Button {
            state.isConnectSheetPresented = true
        } label: {
            HStack(spacing: 12) {
                CameraPlaceholder()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(state.connection.camera?.model ?? state.remembered.name)
                        .font(Typo.sans(15, .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(metaLine)
                        .font(Typo.mono(11))
                        .foregroundStyle(Palette.inkQuaternary)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.inkQuaternary)
            }
            .padding(14)
            .cardSurface()
        }
        .buttonStyle(.plain)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let firmware = state.connection.camera?.firmware { parts.append("FW \(firmware)") }
        if let sd = state.sdCardPercentUsed { parts.append("SD \(sd)%") }
        if let battery = state.batteryPercent { parts.append("\(battery)%") }
        if let host = state.connection.camera?.host { parts.append(host) }
        return parts.isEmpty ? "Not connected" : parts.joined(separator: " - ")
    }

    private var notConnectedNote: some View {
        Text("Camera settings appear once the app is connected. The rows below cannot be read or changed from here.")
            .font(Typo.sans(13))
            .foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }

    // MARK: - Groups

    private var generalGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "General")
            VStack(spacing: 0) {
                plainRow("Camera connection",
                         value: state.connection.isConnected ? "Connected" : "Not connected") {
                    state.isConnectSheetPresented = true
                }
                divider
                plainRow("Network", value: state.networkMode.label) {
                    showNetwork = true
                }
                divider
                plainRow("Wi-Fi name", value: state.remembered.lastSSID ?? "Unknown", action: nil)
                divider
                plainRow("SSID prefix", value: state.remembered.ssidPrefix, action: nil)
                divider
                plainRow("Diagnostics", value: "\(state.diagnostics.entries.count) entries") {
                    showDiagnostics = true
                }
            }
            .cardSurface()
        }
    }

    private func settingsGroup(_ group: SettingGroup, rows: [CameraSetting]) -> some View {
        let editable = rows.filter { setting in
            if case .destructiveAction = setting.kind { return false }
            return true
        }

        return Group {
            if !editable.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: group.rawValue)
                    if let note = group.note {
                        Text(note)
                            .font(Typo.sans(11.5))
                            .foregroundStyle(Palette.inkQuaternary)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(editable.enumerated()), id: \.element.id) { index, setting in
                            if index > 0 { divider }
                            row(setting)
                        }
                    }
                    .cardSurface()
                }
            }
        }
    }

    private var destructiveGroup: some View {
        let rows = SettingsRegistry.settings(in: .general).filter { setting in
            if case .destructiveAction = setting.kind { return true }
            return false
        }

        return VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Danger zone")
            VStack(spacing: 0) {
                forgetRow
                ForEach(Array(rows.enumerated()), id: \.element.id) { _, setting in
                    divider
                    row(setting)
                }
            }
            .cardSurface()
        }
    }

    /// Forgetting is a local action: it clears the remembered address and
    /// stops the app reconnecting. Nothing on the camera changes.
    private var forgetRow: some View {
        Button {
            showForgetConfirm = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Forget this camera")
                        .font(Typo.sans(14.5, .medium))
                        .foregroundStyle(Palette.destructiveText)
                    Text("Clears the remembered address and stops reconnecting. The camera itself is not changed.")
                        .font(Typo.sans(11.5))
                        .foregroundStyle(Palette.inkQuaternary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.destructiveText)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            "Forget this camera?",
            isPresented: $showForgetConfirm,
            titleVisibility: .visible
        ) {
            Button("Forget this camera", role: .destructive) {
                state.forgetCamera()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app stops looking for it and forgets its address. Search again at any time from the camera card.")
        }
    }

    private func row(_ setting: CameraSetting) -> some View {
        SettingRow(
            setting: setting,
            value: state.connection.isConnected ? state.settings.value(for: setting) : .unavailable("not connected"),
            isPending: state.settings.pending.contains(setting.id),
            onApply: { par in
                Task { await state.settings.apply(setting, par: par) }
            },
            onRunAction: {
                Task { await state.runDestructive(setting) }
            }
        )
    }

    // MARK: - Plumbing

    private var divider: some View {
        Rectangle().fill(Palette.divider).frame(height: 1)
    }

    private func plainRow(
        _ label: String,
        value: String,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            action?()
        } label: {
            HStack {
                Text(label)
                    .font(Typo.sans(14.5, .medium))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(value)
                    .font(Typo.sans(13.5))
                    .foregroundStyle(Palette.inkQuaternary)
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.inkQuaternary)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}
