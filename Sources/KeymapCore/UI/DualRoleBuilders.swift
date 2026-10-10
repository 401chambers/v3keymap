import SwiftUI
import ViaKit

/// Builds keys made from parts: a modifier held with a key, Mod-Tap, Layer-Tap, and one-shot modifiers.
struct DualRoleBuilder: View {
    let model: AppModel
    let onPick: (Keycode) -> Void

    private func toggle(_ flag: ModifierSet, _ title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.builderMods.contains(flag) },
            set: { on in if on { model.builderMods.insert(flag) } else { model.builderMods.remove(flag) } }))
            .toggleStyle(.button)
    }

    private var needsKey: Bool { model.builderKind != .oneShot }
    private var needsModifiers: Bool { model.builderKind != .layerTap }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Kind", selection: Binding(get: { model.builderKind }, set: { model.builderKind = $0 })) {
                ForEach(AppModel.BuilderKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            Text(explanation).font(.callout).foregroundStyle(.secondary)

            if needsModifiers {
                HStack(spacing: 6) {
                    toggle(.ctrl, "⌃ Control")
                    toggle(.shift, "⇧ Shift")
                    toggle(.alt, "⌥ Option")
                    toggle(.gui, "⌘ Command")
                    Divider().frame(height: 18)
                    toggle(.right, "Right-hand")
                }
            }
            if model.builderKind == .layerTap {
                Picker("Layer", selection: Binding(get: { model.builderLayer }, set: { model.builderLayer = $0 })) {
                    ForEach(0..<AppModel.layerNames.count, id: \.self) { Text("\($0): \(AppModel.layerNames[$0])").tag($0) }
                }
            }
            if needsKey {
                HStack {
                    Text(model.builderKind == .layerTap || model.builderKind == .modTap ? "Key when tapped" : "Key").foregroundStyle(.secondary)
                    Button {
                        model.builderChoosingKey.toggle()
                    } label: {
                        if let key = model.builderKey {
                            Text(KeyLabels.label(for: Keycode(raw: UInt16(key))).long)
                        } else {
                            Text("Choose a key…")
                        }
                    }
                    .popover(isPresented: Binding(get: { model.builderChoosingKey }, set: { model.builderChoosingKey = $0 })) {
                        BasicKeyChooser { key in
                            model.builderKey = UInt8(key.raw)
                            model.builderChoosingKey = false
                        }
                    }
                }
            }
            HStack {
                if let built = model.builtKeycode {
                    let label = KeyLabels.label(for: built)
                    Keycap(label: label, width: 56, height: 46)
                    Text(label.long).font(.callout)
                } else {
                    Text("Choose \(missing) to continue.").font(.callout).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Button("Use this key") { if let built = model.builtKeycode { onPick(built) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.builtKeycode == nil)
            }
            Spacer(minLength: 0)
        }
    }

    private var explanation: String {
        switch model.builderKind {
        case .combo: return "Sends a key with modifiers held, such as Shift + A or Command + C, from a single key."
        case .modTap: return "Acts as a modifier while held and as a normal key when tapped, such as Shift when held and A when tapped."
        case .layerTap: return "Switches to a layer while held and acts as a normal key when tapped."
        case .oneShot: return "A modifier that applies to the next key you press, then lets go."
        }
    }

    private var missing: String {
        switch model.builderKind {
        case .combo, .modTap: return model.builderMods.hasBase ? "a key" : "a modifier and a key"
        case .layerTap: return "a key"
        case .oneShot: return "a modifier"
        }
    }
}

/// A small grid of ordinary keys to pick the "tap" key from.
struct BasicKeyChooser: View {
    let onPick: (Keycode) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 50, maximum: 60), spacing: 6)], spacing: 6) {
                ForEach(Keycode.all.filter { $0.category == .basic && $0.raw >= 0x04 && $0.raw <= 0xFF }, id: \.raw) { code in
                    Button { onPick(code) } label: { Keycap(label: KeyLabels.label(for: code), width: 50, height: 42) }
                        .buttonStyle(KeycapButtonStyle())
                        .help(KeyLabels.label(for: code).long)
                }
            }
            .padding(10)
        }
        .frame(width: 380, height: 280)
    }
}
