import AppKit
import Foundation
import ISDTCore
import SwiftUI

// Dev-only tooling, driven by launch flags:
//   --demo                         simulated chargers (A8, A4, C4), no Bluetooth
//   --demo --render <dir>          render the main views to PNGs (ImageRenderer)
//   --check-windows <path>         report windows, titles, sizes and breathing bolts
//   --probe <path> [--probe-write <slot>]   read-only hardware probe (+ guarded write test on an empty slot)

// MARK: - Demo data

extension ChargerHub {
    func startDemo() {
        isDemo = true
        radio = .poweredOn
        // Demo mode shows only the simulated chargers and never touches the saved list.
        chargers.forEach { $0.shutdown() }
        chargers.removeAll()
        for kind in [ChargerKind.a8Air, .a4Air, .c4Air] {
            let charger = Charger(id: UUID(), kind: kind, central: central)
            charger.loadDemo()
            adopt(charger, persist: false)
            windowRequests.append(charger.id)
        }
        scheduleRenderIfRequested()
        scheduleWindowCheckIfRequested()
    }
}

extension Charger {
    func loadDemo() {
        isDemo = true
        link = .connected
        hardware = HardwareInfo(hardwareVersion: "1.0", firmwareVersion: "1.2", serialNumber: nil)
        inputMillivolts = 5_020
        inputMilliamps = 2_140

        func slot(_ i: Int, _ phase: ChargePhase, _ pct: Int, mV: Int, mA: Int, mAh: Int, minutes: Int, type: BatteryType) -> SlotStatus {
            SlotStatus(slot: i, phase: phase, capacityPercent: pct, chargedMAh: mAh, energyMWh: mAh * 37 / 10,
                       elapsed: TimeInterval(minutes * 60), rawBatteryType: type.rawValue, currentMA: mA, voltageMV: mV)
        }
        let li = SlotConfig(batteryType: .liIon, currentMA: 500, cutoffMV: 4_200, capacityLimitMAh: 0)
        let nimh = SlotConfig(batteryType: .niMHCd, currentMA: 700, cutoffMV: 4, capacityLimitMAh: 3_000)
        let auto = SlotConfig.defaults(for: .auto)
        var finishing = 2

        switch kind {
        case .a8Air:
            slots = [
                slot(0, .constantCurrent, 42, mV: 3_790, mA: 500, mAh: 1_040, minutes: 63, type: .liIon),
                slot(1, .constantVoltage, 91, mV: 4_170, mA: 180, mAh: 2_310, minutes: 168, type: .liIon),
                slot(2, .constantVoltage, 97, mV: 4_190, mA: 120, mAh: 2_480, minutes: 191, type: .liIon),
                slot(3, .done, 100, mV: 4_200, mA: 0, mAh: 3_020, minutes: 214, type: .liIon),
                slot(4, .charging, 58, mV: 1_380, mA: 700, mAh: 1_450, minutes: 124, type: .niMHCd),
                slot(5, .idle, 0, mV: 3_620, mA: 0, mAh: 0, minutes: 0, type: .auto),
                SlotStatus(slot: 6),
                slot(7, .error, 0, mV: 4_410, mA: 0, mAh: 0, minutes: 0, type: .liIon),
            ]
            deviceConfigs = [0: li, 1: li, 2: li, 3: li, 4: nimh, 5: auto, 6: auto, 7: li]
        case .a4Air:
            slots = [
                slot(0, .charging, 35, mV: 1_310, mA: 500, mAh: 820, minutes: 95, type: .niMHCd),
                slot(1, .constantVoltage, 88, mV: 4_150, mA: 220, mAh: 2_050, minutes: 150, type: .liIon),
                slot(2, .done, 100, mV: 1_450, mA: 0, mAh: 2_300, minutes: 270, type: .niMHCd),
                SlotStatus(slot: 3),
            ]
            deviceConfigs = [0: nimh, 1: li, 2: nimh, 3: auto]
            finishing = 1
        case .c4Air:
            // Large-cell bays (5/6) in use: only two columns show.
            slots = (0..<4).map { SlotStatus(slot: $0) } + [
                slot(4, .constantCurrent, 64, mV: 3_950, mA: 1_500, mAh: 3_100, minutes: 120, type: .liIon),
                slot(5, .constantVoltage, 94, mV: 4_180, mA: 400, mAh: 4_300, minutes: 200, type: .liIon),
            ]
            deviceConfigs = Dictionary(uniqueKeysWithValues: (0..<6).map { ($0, SlotConfig(batteryType: .liIon, currentMA: 1_500, cutoffMV: 4_200, capacityLimitMAh: 0)) })
            finishing = 5
        }
        visibleSlots = kind.visibleSlots(in: slots, c4UsesLargeBaysForDemo: kind == .c4Air)
        drafts = deviceConfigs
        _ = detector.ingest(visibleStatuses)

        let insertedLater: Int? = (kind == .a8Air) ? 6 : (kind == .a4Air ? 3 : nil)
        demoTask = Task { [weak self] in
            // Early on, a battery is put into an empty slot: its bolt appears long after the others.
            try? await Task.sleep(for: .seconds(3.5))
            if let insertedLater, let self, !Task.isCancelled {
                slots[insertedLater] = slot(insertedLater, .charging, 6, mV: 1_250, mA: 500, mAh: 40, minutes: 2, type: .niMHCd)
            }
            // A few seconds in one slot tops off: exactly what the real poll loop would see.
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled else { return }
            slots[finishing].phase = .done
            slots[finishing].capacityPercent = 100
            slots[finishing].currentMA = 0
            slots[finishing].voltageMV = 4_200
            handle(events: detector.ingest(visibleStatuses))
        }
    }

    func applyDemo(targets: [Int], config: SlotConfig) async {
        isApplying = true
        defer { isApplying = false }
        lastApplyTargets = targets
        applyResults.removeAll()
        for slot in targets { applyResults[slot] = .pending }
        try? await Task.sleep(for: .milliseconds(700))
        for slot in targets {
            deviceConfigs[slot] = config
            drafts[slot] = config
            dirty.remove(slot)
            applyResults[slot] = .verified
        }
    }
}

private extension ChargerKind {
    /// Demo helper: the C4 starts in the large-bay layout.
    func visibleSlots(in slots: [SlotStatus], c4UsesLargeBaysForDemo large: Bool) -> [Int] {
        var flag = large
        return visibleSlots(in: slots, c4UsesLargeBays: &flag)
    }
}

// MARK: - Window / bolt check

extension ChargerHub {
    func scheduleWindowCheckIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--check-windows"), i + 1 < args.count else { return }
        let path = args[i + 1]
        Task {
            try? await Task.sleep(for: .seconds(7))
            var out = "chargers: \(chargers.map { "\($0.name) visible=\($0.visibleSlots)" })\n"
            for menu in NSApp.mainMenu?.items ?? [] {
                out += "menu [\(menu.title)|\(menu.submenu?.title ?? "-")]: " + (menu.submenu?.items.map { $0.isSeparatorItem ? "|" : $0.title }.joined(separator: ", ") ?? "") + "\n"
            }
            let windows = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
            out += "windows: \(windows.count)\n"
            for window in windows {
                var bolts: [BoltView] = []
                @MainActor func walk(_ view: NSView) {
                    if let bolt = view as? BoltView { bolts.append(bolt) }
                    view.subviews.forEach(walk)
                }
                if let content = window.contentView { walk(content) }
                let animated = bolts.filter { $0.layer?.animation(forKey: "breath") != nil }.count
                out += "  \"\(window.title)\" size=\(window.frame.size) content=\(window.contentLayoutRect.size) bolts=\(bolts.count) animated=\(animated)\n"
            }
            // In sync means identical opacity at the same instant, whenever each bolt appeared.
            var all: [BoltView] = []
            @MainActor func collect(_ view: NSView) {
                if let bolt = view as? BoltView { all.append(bolt) }
                view.subviews.forEach(collect)
            }
            windows.forEach { if let c = $0.contentView { collect(c) } }
            let samples = all.compactMap { $0.layer?.presentation()?.opacity }.map { Double($0) }
            if let lo = samples.min(), let hi = samples.max() {
                let list = samples.map { String(format: "%.3f", $0) }.joined(separator: " ")
                out += "bolt opacities: " + list + "\n"
                out += String(format: "spread=%.4f over %d bolts\n", hi - lo, samples.count)
            }
            try? out.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Off-screen rendering

extension ChargerHub {
    /// ImageRenderer needs no Screen Recording permission. Platform-backed pieces (ScrollView, TextField,
    /// Button, the bolt) and the glass material don't draw off-screen, so this is a layout/content check.
    func scheduleRenderIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return }
        let dir = args[i + 1]
        Task {
            try? await Task.sleep(for: .seconds(1))
            renderImages(to: dir)
            NSApp.terminate(nil)
        }
    }

    private func renderImages(to dir: String) {
        func render<V: View>(_ view: V, charger: Charger?, width: CGFloat, name: String, dark: Bool = false) {
            var content = AnyView(view)
            if let charger { content = AnyView(content.environment(charger)) }
            let framed = content
                .environment(self)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.glassEnabled, false)
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .background(dark ? Color(white: 0.12) : Color(white: 0.97))
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                print("render failed: \(name)")
                return
            }
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            print("rendered \(name)")
        }

        for charger in chargers {
            let key = charger.kind.rawValue
            func row() -> some View {
                VStack(alignment: .leading, spacing: 16) {
                    DeviceHeader()
                    HStack(spacing: 10) {
                        ForEach(charger.visibleSlots, id: \.self) { slot in
                            SlotColumnView(status: charger.slots[slot], config: charger.deviceConfigs[slot],
                                           isEditing: false, hasUnappliedEdits: false, isLive: true)
                                .frame(maxWidth: 120)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            render(row(), charger: charger, width: 760, name: "main_\(key)")
            render(row(), charger: charger, width: 760, name: "main_\(key)_dark", dark: true)
        }

        if let a8 = chargers.first(where: { $0.kind == .a8Air }) {
            a8.editingSlot = 4
            render(SlotEditorView(), charger: a8, width: 330, name: "editor_nimh")
            a8.editingSlot = 1
            a8.lastApplyTargets = Array(0..<8)
            a8.applyResults = Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, $0 == 5 ? ApplyResult.unconfirmed : .verified) })
            render(SlotEditorView(), charger: a8, width: 330, name: "editor_apply_all")
            a8.applyResults = [:]
            a8.lastApplyTargets = []
            a8.editingSlot = nil
        }

        let saved = (chargers, discovered)
        radio = .poweredOn
        render(ChargersView(), charger: nil, width: 520, name: "chargers")
        _ = saved
    }
}

// MARK: - Hardware probe (read-only)

extension ChargerHub {
    private static func probeLine(_ s: SlotStatus) -> String {
        var line = "slot \(s.slot + 1): \(s.phase) raw=\(s.rawState) \(s.capacityPercent)%"
        line += " \(s.voltageMV) mV \(s.currentMA) mA \(s.chargedMAh) mAh"
        line += " type=\(s.rawBatteryType) err=\(s.errorCode)\n"
        return line
    }

    func startProbesIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--probe"), i + 1 < args.count else { return }
        let path = args[i + 1]
        for charger in chargers { charger.probePath = path }
        scheduleWindowCheckIfRequested()

        var writeSlot: Int?
        if let w = args.firstIndex(of: "--probe-write"), w + 1 < args.count, let slot = Int(args[w + 1]) { writeSlot = slot - 1 }
        if let writeSlot, let first = chargers.first { Task { await first.runProbeWrite(slot: writeSlot) } }

        Task { [weak self] in
            while let self, !Task.isCancelled {
                try? probeReport().write(toFile: path, atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func probeReport() -> String {
        var out = "radio: \(radio)\n"
        out += "discovered:"
        for device in discovered {
            let rssi: String = String(device.rssi)
            out += " " + device.name + " [" + device.modelName + "] rssi " + rssi + ";"
        }
        out += "\n"
        for c in chargers {
            out += "== " + c.name + " (" + c.kind.rawValue + ") link: " + String(describing: c.link) + "\n"
            out += "hardware: " + String(describing: c.hardware) + "\n"
            out += "input: " + String(describing: c.inputMillivolts) + " mV, " + String(describing: c.inputMilliamps) + " mA\n"
            for s in c.slots { out += Self.probeLine(s) }
            out += "visible: " + String(describing: c.visibleSlots) + "\n"
            let configs = c.deviceConfigs.sorted { $0.key < $1.key }
            out += "configs:"
            for (slot, config) in configs {
                let number: String = String(slot + 1)
                out += " " + number + ": " + Format.summary(config) + ";"
            }
            out += "\n"
            out += "--- write test\n" + c.probeNotes.joined(separator: "\n") + "\n"
            out += "--- traffic\n" + c.trafficLog.suffix(40).joined(separator: "\n") + "\n"
        }
        return out
    }
}

extension Charger {
    /// Writes a test config to one slot that must be empty, reads it back, then restores the original.
    func runProbeWrite(slot: Int) async {
        func note(_ text: String) { probeNotes.append("\(Date().formatted(.dateTime.hour().minute().second())) \(text)") }
        while link != .connected || deviceConfigs[slot] == nil { try? await Task.sleep(for: .seconds(1)) }
        try? await Task.sleep(for: .seconds(4))
        guard slots[slot].phase == .empty, let original = deviceConfigs[slot], let session else {
            note("ABORT: slot \(slot + 1) is \(slots[slot].phase), not empty. Nothing written.")
            return
        }
        note("slot \(slot + 1) empty (\(slots[slot].voltageMV) mV). original: \(original)")

        let test = SlotConfig(batteryType: .niMHCd, currentMA: 400, cutoffMV: 5, capacityLimitMAh: 0)
        editingSlot = slot
        editorConfig = test
        await applyEditor()
        note("applied \(test)")
        note("result: \(String(describing: applyResults[slot]))")
        note("stored now: \(String(describing: deviceConfigs[slot]))")
        try? await Task.sleep(for: .seconds(6))

        // Restore exactly what was there, bypassing validation (the original may hold out-of-range leftovers).
        do {
            let outcome = try await session.writeSlot(slot, config: original)
            try? await Task.sleep(for: .seconds(1))
            let readback = try await session.readSlotConfigs(slots: [slot])
            note("restore write: \(outcome); stored now: \(String(describing: readback[slot])); matches original: \(readback[slot] == original)")
        } catch {
            note("restore FAILED: \(error.localizedDescription)")
        }
        note("DONE")
    }
}
