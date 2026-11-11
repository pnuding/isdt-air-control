import ISDTCore
import SwiftUI

/// Popover content: settings for the slot that was clicked, with a way to send them to every slot.
struct SlotEditorView: View {
    @Environment(Charger.self) private var model
    @State private var confirmingAll = false

    var body: some View {
        if let slot = model.editingSlot {
            let config = model.editorConfig
            let limits = config.batteryType.limits

            VStack(alignment: .leading, spacing: 16) {
                titleBlock(slot)
                batterySection(config)

                if config.batteryType == .auto {
                    Label("The charger detects the chemistry and picks current and cut-off itself.", systemImage: "wand.and.stars")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    currentSection(config)
                    if let range = limits.cutoff {
                        ValueEditor(
                            title: limits.cutoffIsDelta ? "Delta-peak (−ΔV)" : "Cut-off voltage", unit: "mV",
                            value: intBinding(\.cutoffMV),
                            range: Double(range.lowerBound)...Double(range.upperBound),
                            step: limits.cutoffIsDelta ? 1 : 10,
                            note: limits.cutoffIsDelta ? "Charging ends when the cell voltage falls by this much." : nil)
                    }
                    if let range = limits.capacity {
                        capacitySection(config, range: range)
                    }
                }

                issues(config)
                results
                actions
            }
            .padding(20)
            .frame(width: 330)
        }
    }

    // MARK: Header

    private func titleBlock(_ slot: Int) -> some View {
        let status = model.slots[slot]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Slot \(slot + 1)").font(.title2.bold())
                Spacer()
                Label(status.phase.label, systemImage: status.phase.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status.phase.color)
            }
            if status.hasBattery {
                Text("\(Format.voltage(status.voltageMV)) · \(Format.milliampHours(status.chargedMAh))" + (status.elapsed > 0 ? " · \(Format.elapsed(status.elapsed))" : ""))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let stored = model.deviceConfigs[slot] {
                Text("In the charger: \(Format.summary(stored))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Fields

    private func batterySection(_ config: SlotConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Battery type").font(.subheadline.weight(.medium))
            Picker("Battery type", selection: Binding(
                get: { model.editorConfig.batteryType },
                set: { model.editorConfig = model.editorConfig.switching(to: $0, currentRange: model.kind.currentRange) }
            )) {
                ForEach(BatteryType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Text(config.batteryType.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func currentSection(_ config: SlotConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Charger default current").font(.subheadline.weight(.medium))
                Spacer()
                Toggle("Charger default current", isOn: Binding(
                    get: { model.editorConfig.usesDefaultCurrent },
                    set: { model.editorConfig.currentMA = $0 ? 0 : 300 }
                ))
                .labelsHidden()
                .toggleStyle(ColoredSwitchToggleStyle(tint: .accentColor))
            }
            if config.usesDefaultCurrent {
                Text("The charger picks the current itself (about 500 mA per slot).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ValueEditor(
                    title: "Charge current", unit: "mA",
                    value: intBinding(\.currentMA),
                    range: Double(model.kind.currentRange.lowerBound)...Double(model.kind.currentRange.upperBound),
                    step: Double(ISDT.currentStep))
            }
        }
    }

    private func capacitySection(_ config: SlotConfig, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stop at capacity").font(.subheadline.weight(.medium))
                Spacer()
                Toggle("Stop at capacity", isOn: Binding(
                    get: { model.editorConfig.capacityLimitMAh > 0 },
                    set: { on in
                        model.editorConfig.capacityLimitMAh = on ? min(max(3000, range.lowerBound), range.upperBound) : 0
                    }
                ))
                .labelsHidden()
                .toggleStyle(ColoredSwitchToggleStyle(tint: .accentColor))
            }
            if config.capacityLimitMAh > 0 {
                ValueEditor(
                    title: "Capacity limit", unit: "mAh",
                    value: intBinding(\.capacityLimitMAh),
                    range: Double(range.lowerBound)...Double(range.upperBound),
                    step: 250,
                    note: "A safety cut-off: charging stops once this much has gone in.")
            } else {
                Text("Off — the cut-off above ends the charge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func issues(_ config: SlotConfig) -> some View {
        let problems = config.issues(currentRange: model.kind.currentRange)
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        let targets = model.lastApplyTargets
        if targets.count == 1, let slot = targets.first, let result = model.applyResults[slot] {
            resultRow(slot: slot, result: result)
        } else if targets.count > 1 {
            let entries = targets.compactMap { slot in model.applyResults[slot].map { (slot, $0) } }
            let confirmed = entries.filter { $0.1 == .verified }.count
            VStack(alignment: .leading, spacing: 4) {
                if entries.contains(where: { $0.1 == .pending }) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Sending to \(targets.count) slots…")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else if confirmed == targets.count {
                    Label("All \(targets.count) slots confirmed by the charger", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Text("\(confirmed) of \(targets.count) slots confirmed")
                        .font(.caption.weight(.semibold))
                    ForEach(entries.filter { $0.1 != .verified }, id: \.0) { slot, result in
                        resultRow(slot: slot, result: result)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(slot: Int, result: ApplyResult) -> some View {
        switch result {
        case .pending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Slot \(slot + 1): sending…")
            }
            .font(.caption).foregroundStyle(.secondary)
        case .verified:
            Label("Slot \(slot + 1): confirmed by the charger", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .adjusted(let stored):
            Label("Slot \(slot + 1): the charger kept \(Format.summary(stored))", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .unconfirmed:
            Label("Slot \(slot + 1): sent, but the charger didn't confirm", systemImage: "questionmark.circle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.link != .connected {
                Label("Connect to the charger to apply settings.", systemImage: "bolt.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if confirmingAll {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Send these settings to all \(model.visibleSlots.count) slots?")
                        .font(.subheadline.weight(.semibold))
                    Text("Slots with a battery restart charging.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel") { confirmingAll = false }
                            .buttonStyle(.glass)
                        Spacer()
                        Button("Apply to All Slots") {
                            confirmingAll = false
                            Task { await model.applyEditor(toAll: true) }
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            } else {
                HStack {
                    Button("Revert") { model.revertEditor() }
                        .buttonStyle(.glass)
                        .disabled(!model.editorIsDirty || model.isApplying)
                    Spacer()
                    Button("Apply") { Task { await model.applyEditor() } }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canApply)
                }
                Button {
                    confirmingAll = true
                } label: {
                    Label("Apply to All Slots…", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.link)
                .font(.callout)
                .disabled(!model.canApply)
            }

            Text("Applying restarts charging on slots that have a battery in them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Bindings

    private func intBinding(_ keyPath: WritableKeyPath<SlotConfig, Int>) -> Binding<Double> {
        Binding(
            get: { Double(model.editorConfig[keyPath: keyPath]) },
            set: { model.editorConfig[keyPath: keyPath] = Int($0.rounded()) }
        )
    }
}

/// A label, a typed value with unit, and a slider over the same range.
private struct ValueEditor: View {
    let title: LocalizedStringKey
    let unit: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var note: LocalizedStringKey? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                DecimalField(value: $value, decimals: 0, range: range, width: 64, accessibilityLabel: title)
                Text(unit).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
