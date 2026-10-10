import SwiftUI
import ViaKit

public struct MainView: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Group {
            if let working = model.working, let original = model.onDevice, let layout = model.layout {
                workspace(working: working, original: original, layout: layout)
            } else {
                connectionScreen
            }
        }
        .frame(minWidth: 1060, idealWidth: 1280, minHeight: 600, idealHeight: 800)
    }

    // MARK: Main window

    private func workspace(working: KeyboardConfig, original: KeyboardConfig, layout: LayoutDefinition) -> some View {
        NavigationSplitView {
            List(selection: Binding<AppModel.Panel?>(get: { model.selectedPanel }, set: { if let p = $0 { model.selectedPanel = p } })) {
                ForEach(AppModel.Panel.allCases, id: \.self) { panel in
                    Label(panel.title, systemImage: panel.icon)
                        .badge(panel == .changes ? model.pending.count : 0)
                        .tag(panel)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    appearanceButton
                    // The version only, so it can be compared by eye with Keychron's website.
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Firmware").font(.caption2).foregroundStyle(.tertiary)
                        Text(AppModel.firmwareVersion(from: working.firmware)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail(working: working, original: original, layout: layout)
                .background { GlassBackdrop() }
                .navigationTitle(model.selectedPanel.title)
                .navigationSubtitle(model.state == .connected ? "Keychron V3 · Connected" : "Keychron V3 · Disconnected")
                .toolbar { toolbar(layerCount: working.keymap.count) }
        }
        .confirmationDialog("Discard \(model.pending.count) unapplied changes?", isPresented: Binding(get: { model.confirmingRevert }, set: { model.confirmingRevert = $0 }), titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { model.discardPending() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The keys, macros, lighting and settings you changed go back to what the keyboard has. Nothing is written to the keyboard.")
        }
        .confirmationDialog("Reset the keymap to factory settings?", isPresented: Binding(get: { model.confirmingKeymapReset }, set: { model.confirmingKeymapReset = $0 }), titleVisibility: .visible) {
            Button("Reset Keymap", role: .destructive) { Task { await model.resetKeymapToFactory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every key on all four layers and the knob go back to the keyboard's factory settings. Macros and lighting are not changed, and edits you haven't applied are lost. A backup of your current setup is saved first.")
        }
        .alert("Something needs your attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })) {
            Button("OK") { model.dismissError() }
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder
    private func detail(working: KeyboardConfig, original: KeyboardConfig, layout: LayoutDefinition) -> some View {
        switch model.selectedPanel {
        case .macros: MacrosView(model: model, working: working)
        case .backup: BackupView(model: model)
        case .typing: TypingPanel(model: model)
        default:
            GeometryReader { geo in
                // One container: the board, tab strips, panes and glass buttons share a sampling region (glass cannot sample glass).
                GlassEffectContainer(spacing: 0) {
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        let editingLighting = model.selectedPanel == .lighting && model.lightingMode != .standard && (model.lightingTab == .perKey || model.lightingTab == .mixed)
                        KeyboardBoard(layout: layout, keymap: working.keymap[model.selectedLayer], original: original.keymap[model.selectedLayer],
                                      pressed: model.pressedKeys, selected: model.selectedPanel == .keys ? model.selectedKey : nil,
                                      knobHighlighted: model.selectedPanel == .knob,
                                      knobTurns: knobTurns(working), knobChanged: working.encoders[model.selectedLayer] != original.encoders[model.selectedLayer],
                                      selection: editingLighting ? model.selectedKeys : [],
                                      ledColour: model.selectedPanel == .lighting && model.lightingMode == .perKey ? { model.ledColour(at: $0)?.color } : nil,
                                      zoneOf: model.selectedPanel == .lighting && model.lightingMode == .mixed ? { model.zone(of: $0) } : nil,
                                      pressCount: model.selectedPanel == .keyTest ? { model.pressCount(at: $0) } : nil,
                                      knobFlashLeft: model.knobFlashLeft, knobFlashRight: model.knobFlashRight) {
                            if editingLighting {
                                model.toggleSelection($0)
                            } else if $0 == KnobLayout.press && model.selectedPanel == .knob {
                                model.knobTarget = .press
                            } else {
                                model.selectedKey = $0
                                if model.selectedPanel != .keys && model.selectedPanel != .keyTest { model.selectedPanel = .keys }
                            }
                        }
                        .frame(maxHeight: min(max(geo.size.height * 0.44, 220), 430))
                        legendRow
                    }
                    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
                    inspector(working: working, original: original)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                }
            }
        }
    }

    private func knobTurns(_ working: KeyboardConfig) -> KnobTurns? {
        guard working.encoders.indices.contains(model.selectedLayer), let a = working.encoders[model.selectedLayer].first else { return nil }
        return KnobTurns(left: KeyLabels.label(for: a.counterClockwise), right: KeyLabels.label(for: a.clockwise))
    }

    @ViewBuilder
    private func inspector(working: KeyboardConfig, original: KeyboardConfig) -> some View {
        switch model.selectedPanel {
        case .knob: KnobInspector(model: model, working: working)
        case .lighting: LightingInspector(model: model, working: working)
        case .keyTest: KeyTestInspector(model: model, working: working)
        case .changes: ChangesInspector(model: model)
        default: KeysInspector(model: model, working: working, original: original)
        }
    }

    /// Buttons that act on the whole keyboard, on the right of the colour key under the picture. All the same size.
    @ViewBuilder private var boardActions: some View {
        switch model.selectedPanel {
        case .keys:
            actionButton("Reset Keymap", help: "Put all keys and the knob back to the keyboard's factory settings") { model.confirmingKeymapReset = true }
                .disabled(model.isApplying)
        case .keyTest:
            actionButton("Reset Count", help: "Set every key's count back to zero") { model.resetKeyCounts() }
        default: EmptyView()
        }
    }

    private func actionButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).lineLimit(1).frame(width: 118) }
            .buttonStyle(.glass).controlSize(.regular).help(help)
    }

    /// The colour key with the board buttons at its right end. The key stays centred when there is room for that, and
    /// moves left to make room for the buttons when the window is narrow.
    private var legendRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { boardActions.hidden(); Spacer(minLength: 0); legend; Spacer(minLength: 0); boardActions }
            HStack(spacing: 14) { legend; Spacer(minLength: 0); boardActions }
        }
        .frame(maxWidth: .infinity)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([("Keys", KeyStyle.standard), ("Modifiers", .modifier), ("Media", .media), ("Layers", .layer), ("Macros", .macro), ("Backlight", .lighting)], id: \.0) { item in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.capBase(scheme))
                        .overlay(RoundedRectangle(cornerRadius: 3).fill(scheme == .dark ? (item.1.darkFill ?? item.1.tint?.opacity(0.40) ?? .clear) : (item.1.tint ?? .clear).opacity(0.25)))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(nsColor: .separatorColor)))
                        .frame(width: 13, height: 13)
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 5) { Circle().fill(Theme.changed).frame(width: 8, height: 8); Text("Changed").font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(layerCount: Int) -> some ToolbarContent {
        if model.selectedPanel.showsKeyboard {
            ToolbarItem(placement: .principal) {
                Picker("Layer", selection: Binding(get: { model.selectedLayer }, set: { model.selectedLayer = $0 })) {
                    ForEach(0..<layerCount, id: \.self) { l in
                        Text(AppModel.layerNames.indices.contains(l) ? AppModel.layerNames[l] : "Layer \(l)").tag(l)
                    }
                }
                .pickerStyle(.segmented)
                .help("Fn layers apply while you hold Fn")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            applyRevert
        }
        .sharedBackgroundVisibility(.hidden)       // the control draws its own single glass capsule
    }

    /// One tap steps through Match System (half black, half white), Light (sun) and Dark (moon).
    private var appearanceButton: some View {
        Button { model.cycleAppearance() } label: {
            Image(systemName: model.appearance.icon)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Appearance: \(model.appearance.title)")   // otherwise VoiceOver reads the symbol's name
        .help("Appearance: \(model.appearance.title). Click to change.")
    }

    /// Revert and Apply: two glass capsules of the same size. Apply is washed blue when there is something to apply.
    private var applyRevert: some View {
        let hasChanges = !model.pending.isEmpty
        let canApply = hasChanges && model.state == .connected && !model.isApplying
        return HStack(spacing: 8) {
            GlassCapsuleButton(enabled: hasChanges, action: { model.revertPending() }) { Text("Revert") }
                .accessibilityLabel("Revert")
                .help("Discard the changes that have not been applied")
            GlassCapsuleButton(tint: canApply ? ApplyGlassStyle.blue : nil, enabled: canApply, action: { Task { await model.applyPending() } }) {
                if model.isApplying { ProgressView().controlSize(.small) } else { Text("Apply") }
            }
            .keyboardShortcut(.return, modifiers: .command)   // not plain Return: that would also fire from text fields
            .accessibilityLabel(model.isApplying ? "Applying" : "Apply")
            .help("Write the changes to the keyboard (⌘↩)")
        }
    }

    // MARK: Not connected

    /// The keyboard picture with blank keys and a status line. The app keeps looking and connects by itself.
    @ViewBuilder
    private var connectionScreen: some View {
        VStack(spacing: 18) {
            if let layout = model.offlineLayout {
                let blank = Array(repeating: Array(repeating: Keycode(raw: 0), count: 16), count: 6)
                KeyboardBoard(layout: layout, keymap: blank, original: blank, glass: false) { _ in }
                    .disabled(true)
                    .frame(maxHeight: 400)
            }
            HStack(spacing: 10) {
                if model.state == .connecting || model.state == .notFound || model.state == .disconnected { ProgressView().controlSize(.small) }
                Label(connectionTitle, systemImage: connectionIcon).font(.headline)
            }
            Text(connectionText).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            if let message = model.errorMessage { Text(message).font(.caption).foregroundStyle(.tertiary).frame(maxWidth: 520) }
            if model.state == .permissionDenied || { if case .wrongDevice = model.state { return true } else { return false } }() {
                HStack(spacing: 10) {
                    if model.state == .permissionDenied {
                        Button("Open System Settings") { model.openInputMonitoringSettings() }.buttonStyle(.bordered)
                    }
                    Button("Try again") { Task { await model.connect() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { GlassBackdrop() }
    }

    private var connectionTitle: String {
        switch model.state {
        case .permissionDenied: return "macOS blocked access"
        case .wrongDevice: return "This keyboard isn't supported"
        case .connecting: return "Connecting to your keyboard…"
        default: return "Keyboard not connected"
        }
    }

    private var connectionIcon: String {
        switch model.state {
        case .permissionDenied: return "lock.shield"
        case .wrongDevice: return "exclamationmark.triangle"
        default: return "cable.connector"
        }
    }

    private var connectionText: String {
        switch model.state {
        case .permissionDenied: return "Open System Settings › Privacy & Security › Input Monitoring, switch on Keymap, then press Try again."
        case .wrongDevice(let why): return why
        default: return "Plug in your Keychron V3 with the USB cable (wireless mode isn't supported). It connects by itself."
        }
    }
}


/// The blue wash on Apply's half of the Revert/Apply control. "Sky". Alternatives tried: Aqua blue (0.30, 0.75, 0.95) and
/// Steel blue (0.42, 0.58, 0.80), both at 0.65-0.70.
enum ApplyGlassStyle {
    static let blue = Color(red: 0.40, green: 0.70, blue: 1.00).opacity(0.70)
}

/// A fixed-size glass capsule button, optionally washed with a colour.
struct GlassCapsuleButton<Label: View>: View {
    var tint: Color?
    var enabled = true
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        let glass: Glass = tint.map { .regular.tint($0).interactive() } ?? .regular.interactive()
        Button(action: action) {
            label
                .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))   // no opacity on glass: it collapses the material
                .frame(width: 84, height: 30)
                .glassEffect(glass, in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
