import AppKit
import SwiftUI
import ViaKit

extension HSVColor {
    var color: Color { Color(hue: Double(h) / 255, saturation: Double(s) / 255, brightness: 1) }

    init(color: Color) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(color).usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        self.init(h: UInt8(min(max(h * 255, 0), 255)), s: UInt8(min(max(s * 255, 0), 255)), v: 255)
    }
}

/// Lighting: tabs for Backlight, Per-key RGB, Mix RGB and the Caps Lock light. Per-key and Mix RGB each have a card with a switch.
struct LightingInspector: View {
    let model: AppModel
    let working: KeyboardConfig

    private var tabs: [AppModel.LightingTab] {
        AppModel.LightingTab.allCases.filter {
            switch $0 {
            case .standard: return true
            case .perKey: return model.supportsPerKeyRGB
            case .mixed: return model.supportsMixedRGB
            case .indicator: return model.supportsIndicator
            }
        }
    }

    private func modeCard(title: String, icon: String, text: String, mode: AppModel.LightingMode) -> some View {
        Pane(title) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
                    Spacer()
                    Toggle(title, isOn: Binding(get: { model.lightingMode == mode }, set: { on in model.lightingTab = mode == .perKey ? .perKey : .mixed; Task { await model.setLightingMode(on ? mode : .standard) } }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 220, idealWidth: 250, maxWidth: 280)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if tabs.count > 1 {
                TabStrip(items: tabs, selection: Binding(get: { model.lightingTab }, set: { model.lightingTab = $0 })) { $0.rawValue }
                    .frame(maxWidth: 520)
            }
            switch model.lightingTab {
            case .standard:
                if model.lightingMode == .standard {
                    StandardLightingInspector(model: model, working: working)
                } else {
                    Pane("Backlight effects are off") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(model.lightingMode == .perKey ? "Per-key RGB" : "Mix RGB") is on, so the keyboard is not using a backlight effect.").foregroundStyle(.secondary)
                            Button("Use backlight effects") { Task { await model.setLightingMode(.standard) } }.buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: 420)
                }
            case .perKey:
                HStack(alignment: .top, spacing: Theme.paneGap) {
                    modeCard(title: "Per-key RGB", icon: "paintpalette", text: "Give every key its own colour. Select keys on the picture, pick a colour and paint them. Switching this on replaces the backlight effect.", mode: .perKey)
                    if model.lightingMode == .perKey { PerKeyPanes(model: model) }
                }
            case .mixed:
                HStack(alignment: .top, spacing: Theme.paneGap) {
                    modeCard(title: "Mix RGB", icon: "square.grid.2x2", text: "Split the keys into two zones and give each zone its own effects, played in turn for the times you set. Switching this on replaces the backlight effect.", mode: .mixed)
                    if model.lightingMode == .mixed { MixedPanes(model: model) }
                }
            case .indicator:
                if let indicator = working.settings?.indicator { IndicatorPanes(model: model, indicator: indicator) }
            }
        }
    }
}

/// The Caps Lock light: on or off, and its colour.
private struct IndicatorPanes: View {
    let model: AppModel
    let indicator: LEDIndicator

    var body: some View {
        HStack(alignment: .top, spacing: Theme.paneGap) {
            Pane("Caps Lock Light") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Light the Caps Lock key when Caps Lock is on", isOn: Binding(get: { indicator.capsLockEnabled }, set: { on in
                        var v = indicator; v.capsLockEnabled = on; model.setIndicator(v)
                    }))
                    ColorPicker("Colour", selection: Binding(get: { indicator.colour.color }, set: { picked in
                        let c = HSVColor(color: picked)
                        var v = indicator; v.hue = c.h; v.saturation = c.s; model.setIndicator(v)
                    }), supportsOpacity: false)
                    .disabled(!indicator.capsLockEnabled)
                    Text("Shown on the keyboard as you change it; kept when you press Apply.").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 420)
            Spacer(minLength: 0)
        }
    }
}

private struct PerKeyPanes: View {
    let model: AppModel

    private let swatches: [HSVColor] = [HSVColor(h: 0, s: 255, v: 255), HSVColor(h: 20, s: 255, v: 255), HSVColor(h: 43, s: 255, v: 255), HSVColor(h: 85, s: 255, v: 255),
                                        HSVColor(h: 128, s: 255, v: 255), HSVColor(h: 170, s: 255, v: 255), HSVColor(h: 200, s: 255, v: 255), HSVColor(h: 0, s: 0, v: 255)]

    var body: some View {
        let count = model.selectedKeys.count
        HStack(alignment: .top, spacing: Theme.paneGap) {
            Pane("Colour") {
                VStack(alignment: .leading, spacing: 12) {
                    ColorPicker("Colour", selection: Binding(get: { model.paintColour.color }, set: { model.paintColour = HSVColor(color: $0) }), supportsOpacity: false)
                    HStack(spacing: 6) {
                        ForEach(Array(swatches.enumerated()), id: \.offset) { _, c in
                            Button { model.paintColour = c } label: {
                                Circle().fill(c.color).frame(width: 22, height: 22).overlay(Circle().strokeBorder(Color(nsColor: .separatorColor)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button("Paint \(count) selected \(count == 1 ? "key" : "keys")") { model.paintSelected(model.paintColour) }
                        .buttonStyle(.borderedProminent).disabled(count == 0)
                }
            }
            Pane("Keys") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(count == 0 ? "Click keys on the picture above to select them, then paint." : "\(plural(count, "key")) selected.").foregroundStyle(.secondary)
                    HStack {
                        Button("Select all") { model.selectAllKeys() }.buttonStyle(.bordered)
                        Button("Clear selection") { model.clearSelection() }.buttonStyle(.bordered).disabled(count == 0)
                    }
                    if let perKey = model.working?.settings?.perKey {
                        Picker("Behaviour", selection: Binding(get: { perKey.type }, set: { model.setPerKeyType($0) })) {
                            ForEach(PerKeyType.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                    Text("Brightness comes from the slider on the Backlight tab. The knob has no light.").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct MixedPanes: View {
    let model: AppModel

    private var effectIDs: [UInt8] { (1..<Int(model.customEffects?.perKey ?? 23)).map { UInt8($0) } }

    var body: some View {
        let count = model.selectedKeys.count
        let zones = model.working?.settings?.mixed?.zones ?? []
        HStack(alignment: .top, spacing: Theme.paneGap) {
            Pane("Zones") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(count == 0 ? "Click keys on the picture above to select them, then move them to a zone." : "\(plural(count, "key")) selected.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)   // wraps in the narrow pane
                    ForEach(zones.indices, id: \.self) { z in
                        Button("Move to zone \(z + 1)") { model.assignSelected(toZone: z) }.buttonStyle(.bordered).disabled(count == 0)
                    }
                    Button("Select all") { model.selectAllKeys() }.buttonStyle(.bordered)
                    Button("Clear selection") { model.clearSelection() }.buttonStyle(.bordered).disabled(count == 0)
                    Text("On the picture, zone 1 is shown blue and zone 2 orange.").font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 260)
            ForEach(zones.indices, id: \.self) { z in
                Pane("Zone \(z + 1)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(zones[z].enumerated()).filter { $0.element.isUsed }, id: \.offset) { slot, effect in
                                row(zone: z, slot: slot, effect: effect)
                                Divider()
                            }
                            if let free = zones[z].firstIndex(where: { !$0.isUsed }) {
                                Button("Add an effect", systemImage: "plus") {
                                    model.setMixedEffect(zone: z, slot: free, MixedEffect(effect: 2, hue: 0, sat: 255, speed: 127, durationMs: 5000))
                                }
                                .buttonStyle(.bordered)
                            }
                            Text("The zone plays its effects in turn, each for the time shown.").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func row(zone: Int, slot: Int, effect: MixedEffect) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Effect", selection: Binding(get: { effect.effect }, set: { var e = effect; e.effect = $0; model.setMixedEffect(zone: zone, slot: slot, e) })) {
                    ForEach(effectIDs, id: \.self) { Text(RGBMatrixEffect.name(for: $0)).tag($0) }
                }
                .labelsHidden()
                Button { model.removeMixedEffect(zone: zone, slot: slot) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove this effect")
            }
            HStack {
                if RGBMatrixEffect.usesColour.contains(effect.effect) {
                ColorPicker("Colour", selection: Binding(get: { HSVColor(h: effect.hue, s: effect.sat, v: 255).color },
                                                         set: { let c = HSVColor(color: $0); var e = effect; e.hue = c.h; e.sat = c.s; model.setMixedEffect(zone: zone, slot: slot, e) }),
                            supportsOpacity: false).labelsHidden()
                }
                Slider(value: Binding(get: { Double(effect.speed) }, set: { var e = effect; e.speed = UInt8($0); model.setMixedEffect(zone: zone, slot: slot, e) }), in: 0...255)
                    .help("Speed")
                Stepper(value: Binding(get: { Double(effect.durationMs) / 1000 }, set: { var e = effect; e.durationMs = UInt32($0 * 1000); model.setMixedEffect(zone: zone, slot: slot, e) }), in: 1...600, step: 1) {
                    Text("\(effect.durationMs / 1000) s").monospacedDigit()
                }
            }
        }
    }
}
