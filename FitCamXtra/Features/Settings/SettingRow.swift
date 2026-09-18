import SwiftUI

/// One settings row. The control depends on the setting's kind, and a row the
/// camera never reported a value for is shown as unavailable rather than
/// pretending to a default.
struct SettingRow: View {
    let setting: CameraSetting
    let value: SettingValue
    /// Supplied by the store, because the resolution list comes from the
    /// camera's own capability report rather than anything declared here.
    let options: [SettingOption]
    let isPending: Bool
    let onApply: (Int) -> Void
    let onRunAction: () -> Void

    @State private var showOptions = false
    @State private var sliderValue: Double = 0
    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(setting.label)
                        .font(Typo.sans(.cardTitle, .medium))
                        .foregroundStyle(isDestructive ? Palette.destructiveText : Palette.ink)

                    if let hint = setting.hint {
                        Text(hint)
                            .font(Typo.sans(.detail))
                            .foregroundStyle(Palette.inkQuaternary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if case .unavailable(let reason) = value {
                        Text(reason)
                            .font(Typo.mono(.micro))
                            .foregroundStyle(Palette.accentText)
                    } else if case .unknown = value, !isPending {
                        Text("not read yet")
                            .font(Typo.mono(.micro))
                            .foregroundStyle(Palette.inkFaint)
                    }
                }

                Spacer(minLength: 8)
                control
            }

            if case .slider = setting.kind, value.isEditable {
                sliderControl
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .confirmationDialog(
            confirmTitle,
            isPresented: $showOptions,
            titleVisibility: optionsAreConfirmation ? .visible : .hidden
        ) {
            dialogButtons
        } message: {
            if case .destructiveAction(_, let body, _) = setting.kind {
                Text(body)
            }
        }
    }

    private var isDestructive: Bool {
        if case .destructiveAction = setting.kind { return true }
        return false
    }

    private var optionsAreConfirmation: Bool { isDestructive }

    private var confirmTitle: String {
        if case .destructiveAction(let title, _, _) = setting.kind { return title }
        return setting.label
    }

    // MARK: - Controls

    @ViewBuilder
    private var control: some View {
        if isPending {
            ProgressView()
                .controlSize(.small)
                .tint(Palette.accent)
        } else {
            switch setting.kind {
            case .toggle:
                Toggle("", isOn: Binding(
                    get: { (value.intValue ?? 0) != 0 },
                    set: { onApply($0 ? 1 : 0) }
                ))
                .labelsHidden()
                .tint(Palette.accent)
                .disabled(!value.isEditable)

            case .options:
                Button {
                    showOptions = true
                } label: {
                    HStack(spacing: 5) {
                        Text(currentLabel(options))
                            .font(Typo.sans(.body))
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(Palette.inkQuaternary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.inkQuaternary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!value.isEditable || options.isEmpty)

            case .slider(_, _, let unit, let scale):
                if let current = value.intValue {
                    Text(format(Double(current) * scale) + " " + unit)
                        .font(Typo.mono(.label, .semibold))
                        .foregroundStyle(Palette.accent)
                } else {
                    Text("--")
                        .font(Typo.mono(.label))
                        .foregroundStyle(Palette.inkFaint)
                }

            case .readOnly:
                Text(value.intValue.map(String.init) ?? "--")
                    .font(Typo.sans(.body))
                    .foregroundStyle(Palette.inkQuaternary)

            case .destructiveAction:
                Button {
                    showOptions = true
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.destructiveText)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sliderControl: some View {
        Group {
            if case .slider(let range, let step, _, _) = setting.kind {
                Slider(
                    value: Binding(
                        get: { isDragging ? sliderValue : Double(value.intValue ?? Int(range.lowerBound)) },
                        set: { sliderValue = $0 }
                    ),
                    in: range,
                    step: step,
                    onEditingChanged: { editing in
                        isDragging = editing
                        if !editing {
                            onApply(Int(sliderValue.rounded()))
                        }
                    }
                )
                .tint(Palette.accent)
            }
        }
    }

    @ViewBuilder
    private var dialogButtons: some View {
        switch setting.kind {
        case .options:
            ForEach(options) { option in
                Button(option.label) { onApply(option.par) }
            }
            Button("Cancel", role: .cancel) {}

        case .destructiveAction:
            Button(setting.label, role: .destructive) { onRunAction() }
            Button("Cancel", role: .cancel) {}

        default:
            EmptyView()
        }
    }

    private func currentLabel(_ options: [SettingOption]) -> String {
        guard let current = value.intValue else { return "--" }
        return options.first { $0.par == current }?.label ?? "value \(current)"
    }

    private func format(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}
