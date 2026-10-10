import AppKit
import SwiftUI
import ViaKit

extension AppModel.Panel {
    var icon: String {
        switch self {
        case .keys: return "keyboard"
        case .knob: return "dial.medium"
        case .macros: return "bolt"
        case .lighting: return "lightbulb"
        case .typing: return "slider.horizontal.3"
        case .changes: return "checklist"
        case .keyTest: return "hand.tap"
        case .backup: return "externaldrive"
        }
    }
    var title: String { self == .changes ? "Changes" : rawValue }
    /// Panels that show the keyboard picture with a control area beneath it.
    var showsKeyboard: Bool { self != .macros && self != .backup && self != .typing }
}

@MainActor private func searchBinding(_ model: AppModel) -> Binding<String> { Binding(get: { model.keycodeSearch }, set: { model.keycodeSearch = $0 }) }
@MainActor private func categoryBinding(_ model: AppModel) -> Binding<PickerCategory> { Binding(get: { model.pickerCategory }, set: { model.pickerCategory = $0 }) }

/// A titled panel in the control area under the keyboard.
struct Pane<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder _ content: () -> Content) { self.title = title.titleCased; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .paneCard()
    }
}

/// A soft colour wash behind the content. Liquid Glass needs something to refract; a flat window would make it look like grey plastic.
struct GlassBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if scheme == .dark {
                // Deep midnight blue with a cool blue glow top left and an indigo one top right.
                Color(red: 0.06, green: 0.08, blue: 0.14)
                RadialGradient(colors: [Color(red: 0.20, green: 0.42, blue: 0.85).opacity(0.38), .clear], center: .topLeading, startRadius: 0, endRadius: 640)
                RadialGradient(colors: [Color(red: 0.40, green: 0.32, blue: 0.85).opacity(0.30), .clear], center: .topTrailing, startRadius: 0, endRadius: 620)
                RadialGradient(colors: [Color(red: 0.10, green: 0.50, blue: 0.62).opacity(0.24), .clear], center: .bottomLeading, startRadius: 0, endRadius: 600)
            } else {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(colors: [Color.accentColor.opacity(0.30), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
                RadialGradient(colors: [Color.purple.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: 560)
                RadialGradient(colors: [Color.teal.opacity(0.22), .clear], center: .bottomLeading, startRadius: 0, endRadius: 560)
                RadialGradient(colors: [Color.pink.opacity(0.16), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 480)
            }
        }
        .ignoresSafeArea()
    }
}

/// Keys: the picker for the selected key (the key itself is outlined on the keyboard above).
struct KeysInspector: View {
    let model: AppModel
    let working: KeyboardConfig
    let original: KeyboardConfig

    var body: some View {
        if let s = model.selectedKey {
            let layer = model.selectedLayer
            let code = working.keymap[layer][s.row][s.col]
            let before = original.keymap[layer][s.row][s.col]
            Pane("Change “\(KeyLabels.label(for: code).long)” to") {
                VStack(alignment: .leading, spacing: 10) {
                    if code != before {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.changed).frame(width: 8, height: 8)
                            Text("Was \(KeyLabels.label(for: before).long)").foregroundStyle(.secondary)
                            Button("Undo this change") { model.setKey(layer: layer, row: s.row, col: s.col, before) }.buttonStyle(.borderless)
                        }
                    }
                    KeycodePickerGrid(search: searchBinding(model), category: categoryBinding(model), current: code, model: model) {
                        model.setKey(layer: layer, row: s.row, col: s.col, $0)
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a Key", systemImage: "cursorarrow.click.2",
                                   description: Text("Click any key above to see what it does and change it. Changes wait until you press Apply."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Knob: tabs for turn left, turn right and press on top of the same picker the keys use.
struct KnobInspector: View {
    let model: AppModel
    let working: KeyboardConfig

    var body: some View {
        let layer = model.selectedLayer
        if working.encoders.indices.contains(layer), let actions = working.encoders[layer].first, working.keymap.indices.contains(layer) {
            content(layer: layer, actions: actions)
        } else {
            ContentUnavailableView("No Knob on This Layer", systemImage: "dial.medium")
        }
    }

    private func content(layer: Int, actions: EncoderActions) -> some View {
        let press = KnobLayout.press
        let pressCode = working.keymap[layer][press.row][press.col]
        let target = model.knobTarget
        let current: Keycode = target == .left ? actions.counterClockwise : target == .right ? actions.clockwise : pressCode
        let layerName = AppModel.layerNames.indices.contains(layer) ? AppModel.layerNames[layer] : "Layer \(layer)"
        return VStack(alignment: .leading, spacing: 10) {
            TabStrip(items: AppModel.KnobTarget.allCases, selection: Binding(get: { model.knobTarget }, set: { model.knobTarget = $0 })) { $0.rawValue }
                .frame(maxWidth: 360)
            Pane("Knob · \(layerName) · \(target.rawValue): \(KeyLabels.label(for: current).long)") {
                KeycodePickerGrid(search: searchBinding(model), category: categoryBinding(model), current: current, model: model) { code in
                    switch target {
                    case .left: model.setEncoder(layer: layer, index: 0, clockwise: false, code)
                    case .right: model.setEncoder(layer: layer, index: 0, clockwise: true, code)
                    case .press: model.setKey(layer: layer, row: press.row, col: press.col, code)
                    }
                }
            }
        }
    }
}

/// Standard lighting: effect and colour beside brightness and speed.
struct StandardLightingInspector: View {
    let model: AppModel
    let working: KeyboardConfig

    private func update(_ change: (inout LightingState) -> Void) {
        var l = working.lighting
        change(&l)
        model.setLighting(l)
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<LightingState, UInt8>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { Double(working.lighting[keyPath: keyPath]) }, set: { v in update { $0[keyPath: keyPath] = UInt8(v) } }), in: 0...255)
                Text("\(working.lighting[keyPath: keyPath])").monospacedDigit().foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
            }
        }
    }

    private var colourBinding: Binding<Color> {
        Binding(
            get: { Color(hue: Double(working.lighting.hue) / 255, saturation: Double(working.lighting.saturation) / 255, brightness: 1) },
            set: { picked in
                guard let ns = NSColor(picked).usingColorSpace(.sRGB) else { return }
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                update { $0.hue = UInt8(min(max(h * 255, 0), 255)); $0.saturation = UInt8(min(max(s * 255, 0), 255)) }
            })
    }

    /// The V3 has 23 built-in effects (0-22); the two Keychron ones after them have their own modes.
    private var effectIDs: [UInt8] {
        let count = Int(model.customEffects?.perKey ?? 23)
        return Array(0..<UInt8(count)) + (working.lighting.effect >= UInt8(count) ? [working.lighting.effect] : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: Theme.paneGap) {
                Pane("Effect and Colour") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Effect", selection: Binding(get: { working.lighting.effect }, set: { v in update { $0.effect = v } })) {
                            ForEach(effectIDs, id: \.self) { Text(RGBMatrixEffect.name(for: $0)).tag($0) }
                        }
                        ColorPicker("Colour", selection: colourBinding, supportsOpacity: false)
                            .disabled(!RGBMatrixEffect.usesColour.contains(working.lighting.effect))
                    }
                }
                Pane("Brightness and Speed") {
                    VStack(alignment: .leading, spacing: 14) {
                        slider("Brightness", \.brightness).disabled(working.lighting.effect == 0)
                        if working.lighting.effect == 0 { Text("Pick an effect to change brightness. The keyboard ignores it while the effect is None.").font(.caption).foregroundStyle(.tertiary) }
                        slider("Speed", \.speed)
                    }
                }
            }
            .frame(maxHeight: 150)
            Text("Changes show on the keyboard as you make them and are kept when you press Apply. Revert puts the saved lighting back.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

/// Key Test: a notice strip while macOS has not granted Accessibility access (it goes away once it has, and comes back if
/// the access is taken away); below it the sound on the left and, on the right, the text the keys would type.
struct KeyTestInspector: View {
    let model: AppModel
    let working: KeyboardConfig

    var body: some View {
        VStack(spacing: Theme.paneGap) {
            if !model.captureAllowed {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "lock").foregroundStyle(.secondary)
                    Text("Key repeats and shortcut blocking need Accessibility access.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)   // wraps in a narrow window instead of truncating
                    Spacer(minLength: 12)
                    Button("Allow Access") { model.requestKeyCaptureAccess() }.buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background { RoundedRectangle(cornerRadius: Theme.insetRadius).fill(Theme.insetWash) }
            }
            panes
        }
    }

    private var panes: some View {
        HStack(alignment: .top, spacing: Theme.paneGap) {
            Pane("Sound") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Play a sound on each key press", isOn: Binding(get: { model.keySoundOn }, set: { model.keySoundOn = $0 }))
                    Picker("Sound", selection: Binding(get: { model.keySound }, set: { model.keySound = $0 })) {
                        ForEach(AppModel.keySounds, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(!model.keySoundOn)
                }
            }
            .frame(width: 280)
            Pane("Typed") {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        Text(model.typedText.isEmpty ? "Press keys on the keyboard and they appear here as text, so you can see which ones did not register." : model.typedText)
                            .font(.system(.title3, design: .monospaced))
                            .foregroundStyle(model.typedText.isEmpty ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: .infinity)
                    HStack {
                        Spacer()
                        Button("Clear") { model.clearTypedText() }.buttonStyle(.bordered).controlSize(.small).disabled(model.typedText.isEmpty)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Changes: everything Apply would write, in words.
struct ChangesInspector: View {
    let model: AppModel

    private func icon(_ t: ConfigChange.Target) -> String {
        switch t {
        case .key: return "keyboard"
        case .encoder: return "dial.medium"
        case .macros: return "bolt"
        case .lighting: return "lightbulb"
        case .debounce: return "timer"
        case .snapClick: return "arrow.left.arrow.right"
        case .perKeyRGB: return "paintpalette"
        case .mixedRGB: return "square.grid.2x2"
        case .indicator: return "capslock"
        }
    }

    var body: some View {
        if model.pending.isEmpty {
            ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                   description: Text("The keyboard already matches what you see. Edits you make are listed here before you apply them."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Pane("\(plural(model.pending.count, "change")) waiting") {
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(model.pending.enumerated()), id: \.offset) { _, change in
                                Label(model.describe(change), systemImage: icon(change.target))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Revert all changes", role: .destructive) { model.revertPending() }
                }
            }
        }
    }
}
