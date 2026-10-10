import AppKit
import Foundation
import Observation
import ViaKit

public enum ConnectionState: Equatable, Sendable {
    case notFound, permissionDenied, connecting, connected, disconnected
    case wrongDevice(String)
}

/// App state. Edits live in `working`; nothing reaches the keyboard until `applyPending()`.
@MainActor
@Observable
public final class AppModel {
    /// Layer roles on the V3, as read from the keyboard's own keymap.
    nonisolated public static let layerNames = ["Mac Base", "Mac Fn", "Windows Base", "Windows Fn"]

    public private(set) var state: ConnectionState = .notFound
    /// The config being edited.
    public private(set) var working: KeyboardConfig? { didSet { refreshPending(); schedulePreview() } }
    /// The config as last read from, or written to, the keyboard.
    public private(set) var onDevice: KeyboardConfig? { didSet { refreshPending() } }
    public private(set) var layout: LayoutDefinition?
    public private(set) var lastBackupURL: URL?
    public private(set) var errorMessage: String?
    public private(set) var isApplying = false

    // UI selection state lives here (not in @State: SwiftUI's @State macro plugin is not in the Command Line Tools).
    public var selectedLayer = 0
    public var selectedKey: MatrixPosition?
    public var keycodeSearch = ""
    /// What is typed in the picker's "Any keycode" box.
    public var anyKeycodeText = ""
    public enum KnobTarget: String, CaseIterable, Sendable { case left = "Turn Left", right = "Turn Right", press = "Press" }
    public var knobTarget: KnobTarget = .left
    /// The colour the Paint button applies in per-key lighting.
    public var paintColour = HSVColor(h: 170, s: 255, v: 255)

    // Device settings
    public private(set) var ledMap: LEDMap?
    public private(set) var customEffects: CustomEffectIDs?
    /// Keys chosen on the picture for painting (per-key RGB) or assigning to a zone (Mix RGB).
    public private(set) var selectedKeys: Set<MatrixPosition> = []
    /// Snap Click rows that are not complete yet (a type but a missing key); they are never written.
    public private(set) var snapClickDrafts: [Int: SnapClickSlot] = [:]
    @ObservationIgnored private var standardEffect: UInt8 = 1

    public enum LightingMode: String, CaseIterable, Sendable { case standard = "Standard", perKey = "Per-key", mixed = "Mixed" }

    public var supportsDebounce: Bool { working?.settings?.debounce != nil }
    public var supportsSnapClick: Bool { working?.settings?.snapClick != nil }
    public var supportsPerKeyRGB: Bool { working?.settings?.perKey != nil }
    public var supportsMixedRGB: Bool { working?.settings?.mixed != nil }
    public var supportsIndicator: Bool { working?.settings?.indicator != nil }

    public func setIndicator(_ value: LEDIndicator) {
        guard working?.settings?.indicator != nil else { return }
        working?.settings?.indicator = value
    }

    /// Which kind of lighting the current effect selects. Standard until the custom effect ids are known.
    public var lightingMode: LightingMode {
        guard let ids = customEffects, let effect = working?.lighting.effect else { return .standard }
        return effect == ids.perKey ? .perKey : effect == ids.mixed ? .mixed : .standard
    }
    public var pickerCategory: PickerCategory = .keys
    /// Lighting panel: showing the Caps Lock light instead of the effect modes.
    public enum LightingTab: String, CaseIterable, Sendable { case standard = "Backlight", perKey = "Per-key RGB", mixed = "Mix RGB", indicator = "Indicator Light" }
    /// The tab the user picked in the Lighting panel; until then the tab follows the keyboard's current lighting mode.
    public var lightingTabOverride: LightingTab?
    public var lightingTab: LightingTab {
        get { lightingTabOverride ?? (lightingMode == .perKey ? .perKey : lightingMode == .mixed ? .mixed : .standard) }
        set { lightingTabOverride = newValue }
    }
    /// Asking whether to put the keymap back to factory settings.
    public var confirmingKeymapReset = false
    public var showingLayerHelp = false

    // Builder for keys made from parts (modifier + key, Mod-Tap, Layer-Tap, one-shot modifier)
    public enum BuilderKind: String, CaseIterable, Sendable {
        case combo = "Modifier + key", modTap = "Mod-Tap", layerTap = "Layer-Tap", oneShot = "One-shot modifier"
    }
    public var builderKind: BuilderKind = .combo
    public var builderMods: ModifierSet = []
    public var builderLayer = 1
    public var builderKey: UInt8?
    public var builderChoosingKey = false

    /// The key the builder would make right now; nil until everything it needs has been chosen.
    public var builtKeycode: Keycode? {
        switch builderKind {
        case .combo:
            guard builderMods.hasBase, let key = builderKey else { return nil }
            return .combo(mods: builderMods, key: key)
        case .modTap:
            guard builderMods.hasBase, let key = builderKey else { return nil }
            return .modTap(mods: builderMods, key: key)
        case .layerTap:
            guard let key = builderKey else { return nil }
            return .layerTap(layer: builderLayer, key: key)
        case .oneShot:
            return builderMods.hasBase ? .oneShotMod(builderMods) : nil
        }
    }

    public enum Panel: String, CaseIterable, Sendable {
        case keys = "Keys", knob = "Knob", macros = "Macros", lighting = "Lighting", typing = "Typing", changes = "Pending changes", keyTest = "Key Test", backup = "Backup"
    }
    public enum MacroAddKind: String, CaseIterable, Sendable { case text = "Text", tap = "Tap", down = "Hold", up = "Release", delay = "Delay" }
    public var macroSlot = 0 { didSet { macroCodeError = nil } }
    public enum MacroTab: String, CaseIterable, Sendable { case configuration = "Configuration", code = "Code Input" }
    public var macroTab: MacroTab = .configuration
    /// Text typed on the Code Input tab and not yet turned into steps; nil shows the macro as it is. Kept per slot, so
    /// looking at another macro and coming back does not lose what was typed.
    public var macroCodeDraft: String? {
        get { macroCodeDrafts[macroSlot] }
        set { macroCodeDrafts[macroSlot] = newValue }
    }
    private var macroCodeDrafts: [Int: String] = [:]
    /// Set when Revert would discard more than one change, so the view can ask first.
    public var confirmingRevert = false
    /// The macro slot the trash button was pressed for, while the view asks whether to empty it.
    public var confirmingMacroClear: Int?
    public var macroCodeError: String?
    /// Macro recording: how pauses are handled, and what has been recorded so far.
    public var macroDelay: MacroDelayChoice = .none
    public var macroFixedDelayMs = 50
    public private(set) var isRecordingMacro = false
    public private(set) var recordedKeyCount = 0
    /// Names for macro slots, kept on this Mac only (the keyboard has no place for them).
    public private(set) var macroTitles: [Int: String] = {
        let saved = UserDefaults.standard.dictionary(forKey: "macroTitles") as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in Int(k).map { ($0, v) } })
    }()
    public enum MacroDelayChoice: String, CaseIterable, Sendable { case none = "No waits", dynamic = "Recorded waits", fixed = "Fixed wait" }
    @ObservationIgnored private var macroMonitor: Any?
    @ObservationIgnored private var recordedEvents: [MacroRecorder.Event] = []
    public var macroAddKind: MacroAddKind = .text
    public var macroDraft = ""
    public struct RestorePreview: Sendable { public let url: URL; public let changes: [ConfigChange] }
    public var restorePreview: RestorePreview?
    /// Bytes available for macros on this keyboard (read at connect).
    public private(set) var macroCapacity = 1750
    /// Opening Key Test starts polling the keyboard's switch matrix; leaving it stops.
    public var selectedPanel: Panel = .keys {
        didSet {
            if selectedPanel != .macros { stopMacroRecording() }
            if selectedPanel != .lighting { lightingTabOverride = nil }
            if selectedPanel == .keyTest { startKeyTest() } else { stopKeyTest() }
            if selectedPanel == .lighting, supportsPerKeyRGB, customEffects == nil { Task { await ensureCustomEffects(silently: true) } }
        }
    }
    /// Keys currently held down (only filled while Key Test is running).
    public private(set) var pressedKeys: Set<MatrixPosition> = []
    /// Key Test: how many times each key was pressed (by normalised QMK keycode) since the counts were last reset.
    public private(set) var keyCounts: [UInt16: Int] = [:]
    /// Key Test: presses seen in the keyboard's matrix, used when macOS has not allowed the event-based count.
    public private(set) var matrixCounts: [MatrixPosition: Int] = [:]
    /// Key Test: the text the pressed keys would type, so a sentence can be checked for missing letters.
    public private(set) var typedText = ""
    @ObservationIgnored private var capsOn = false
    /// Key Test: knob turns seen, and which way it last turned (for the green flash on its arrows).
    public private(set) var knobLeftTurns = 0
    public private(set) var knobRightTurns = 0
    public private(set) var knobFlashLeft = false
    public private(set) var knobFlashRight = false
    /// Whether macOS has allowed this app to see and hold back key presses (Accessibility).
    public private(set) var captureAllowed = KeyCapture.isTrusted
    /// How the model asks whether macOS has granted Accessibility access, and how it asks for it; tests swap both.
    @ObservationIgnored var trustProbe: () -> Bool = { KeyCapture.isTrusted }
    @ObservationIgnored var trustPrompter: () -> Void = { KeyCapture.requestTrust() }

    /// What Apply would write: the difference between `onDevice` and `working`, kept up to date as either changes so
    /// the views can read it as often as they like.
    public private(set) var pending: [ConfigChange] = []
    private func refreshPending() {
        guard let onDevice, let working else { pending = []; return }
        pending = ConfigStore.diff(from: onDevice, to: working)
    }

    @ObservationIgnored private let transportFactory: @Sendable () throws -> HIDTransport
    @ObservationIgnored private let backupDirectory: URL
    @ObservationIgnored private var engine: ApplyEngine?
    @ObservationIgnored private var device: ViaDevice?
    @ObservationIgnored private var keyTestTask: Task<Void, Never>?
    @ObservationIgnored private let capture = KeyCapture()
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored private var lastHeld: [MatrixPosition: Date] = [:]
    @ObservationIgnored private var trustWatch: Task<Void, Never>?
    @ObservationIgnored private var knobFlashTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var lightWatchTask: Task<Void, Never>?
    @ObservationIgnored private var autoConnectTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryTask: Task<Bool, Never>?

    public static var defaultBackupDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keymap/Backups")
    }

    public init(transportFactory: @escaping @Sendable () throws -> HIDTransport, backupDirectory: URL) {
        self.transportFactory = transportFactory
        self.backupDirectory = backupDirectory
        defer { Self.current = self }
        if let raw = UserDefaults.standard.string(forKey: Self.appearanceKey), let saved = Appearance(rawValue: raw) { appearance = saved }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let active = note.name == NSApplication.didBecomeActiveNotification
                MainActor.assumeIsolated { self?.appIsActive = active; self?.updateCapture() }
            }
        }
    }

    /// The version part of the firmware string ("v2.0.0 2025-11-03-17:54:55" gives "v2.0.0").
    nonisolated public static func firmwareVersion(from firmware: String) -> String {
        let version = firmware.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return version.isEmpty ? "Unknown" : version
    }

    // MARK: Live preview of lighting

    /// The lighting-related part of the configuration, which is shown on the keyboard while you edit it.
    private struct LightLook: Equatable {
        var lighting: LightingState
        var perKey: PerKeyRGB?
        var mixed: MixedRGB?
        var indicator: LEDIndicator?
    }
    private static func look(of c: KeyboardConfig) -> LightLook {
        LightLook(lighting: c.lighting, perKey: c.settings?.perKey, mixed: c.settings?.mixed, indicator: c.settings?.indicator)
    }

    nonisolated(unsafe) public static weak var current: AppModel?
    /// What the keyboard is showing right now (saved or previewed).
    @ObservationIgnored private var previewed: LightLook?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewBusy = false
    @ObservationIgnored private var previewWarned = false

    /// True while the keyboard shows lighting that has not been applied.
    public var needsPreviewRestore: Bool {
        guard let previewed, let onDevice else { return false }
        return previewed != Self.look(of: onDevice)
    }

    /// Edits to the lighting are sent to the keyboard a moment after you make them, without saving, so you see the real
    /// result before deciding. Apply keeps them; Revert (or quitting) puts the saved lighting back.
    private func schedulePreview() {
        guard state == .connected, !isApplying, let w = working, let previewed, Self.look(of: w) != previewed else { return }
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(8))
            guard !Task.isCancelled else { return }
            await self?.runPreview()
        }
    }

    private func runPreview() async {
        _ = await discoveryTask?.value      // not while the effect probe is mid-way
        guard !previewBusy, let device else { return }
        previewBusy = true
        defer { previewBusy = false }
        while state == .connected, !isApplying, let w = working, let before = previewed {
            let target = Self.look(of: w)
            if target == before { break }
            do {
                try await Self.sendPreview(from: before, to: target, device)
                previewed = target
            } catch {
                if !previewWarned { previewWarned = true; errorMessage = "The live preview on the keyboard stopped: \(Self.describe(error)). Apply still works." }
                break
            }
        }
    }

    private static func sendPreview(from a: LightLook, to b: LightLook, _ device: ViaDevice) async throws {
        if b.lighting != a.lighting { try await device.previewLighting(b.lighting, from: a.lighting) }
        if let pk = b.perKey, pk != a.perKey {
            let changed: Set<Int>? = a.perKey.map { old in Set(pk.colors.indices.filter { old.colors.indices.contains($0) ? old.colors[$0] != pk.colors[$0] : true }) }
            try await device.previewPerKeyRGB(pk, from: a.perKey, changedLEDs: changed)
        }
        if let m = b.mixed, m != a.mixed { try await device.previewMixedRGB(m, from: a.mixed) }
        if let i = b.indicator, i != a.indicator { try await device.previewLEDIndicator(i, from: a.indicator ?? i) }
    }

    /// Puts the saved lighting back on the keyboard (used when the app quits).
    public func restoreLivePreview() async {
        previewTask?.cancel()
        guard let device, let onDevice, let before = previewed else { return }
        let target = Self.look(of: onDevice)
        if target == before { return }
        try? await Self.sendPreview(from: before, to: target, device)
        previewed = target
    }

    // MARK: Appearance

    /// Follow the Mac, or stay in Light or Dark. Remembered between launches.
    public enum Appearance: String, CaseIterable, Sendable {
        case system, light, dark
        public var title: String { switch self { case .system: return "Match System"; case .light: return "Light"; case .dark: return "Dark" } }
        public var icon: String { switch self { case .system: return "circle.lefthalf.filled"; case .light: return "sun.max"; case .dark: return "moon" } }
        var nsAppearance: NSAppearance? {
            switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
        }
    }
    nonisolated private static let appearanceKey = "appearance"
    public var appearance: Appearance = .system {
        didSet {
            NSApplication.shared.appearance = appearance.nsAppearance
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
        }
    }
    /// System, then Light, then Dark, then back to System.
    public func cycleAppearance() {
        let all = Appearance.allCases
        appearance = all[(all.firstIndex(of: appearance)! + 1) % all.count]
    }

    /// Applies the remembered choice (call once the app is running; `init` cannot touch `NSApplication` early enough).
    public func applyStoredAppearance() { NSApplication.shared.appearance = appearance.nsAppearance }

    /// The keyboard picture for the "not connected" screen, which has no keyboard to read a layout from.
    public var offlineLayout: LayoutDefinition? { layout ?? (try? LayoutDefinition.v3AnsiEncoder()) }

    /// Looks for the keyboard every couple of seconds while it is not connected, so plugging it in is enough.
    public func startAutoConnect() {
        guard autoConnectTask == nil else { return }
        autoConnectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                if self.state == .notFound || self.state == .disconnected { await self.connect(quietly: true) }
            }
        }
    }

    @ObservationIgnored private var connectInProgress = false

    /// `quietly` is for the background search: no "Connecting…" screen and no alert if the keyboard is still missing.
    public func connect(quietly: Bool = false) async {
        // A second window, a double click, or the background search landing at the same moment must not open a second
        // session or wipe the edits on screen. A quiet connect never shows `.connecting`, so the flag covers it too.
        guard state != .connected, state != .connecting, !connectInProgress else { return }
        connectInProgress = true
        defer { connectInProgress = false }
        // Edits the user has made but not applied survive a reconnect: remember them, re-apply to the fresh read.
        var carried: (target: KeyboardConfig, changes: [ConfigChange])?
        if let onDevice, let working {
            let changes = ConfigStore.diff(from: onDevice, to: working)
            if !changes.isEmpty { carried = (working, changes) }
        }
        let before = state
        stopKeyTest()
        monitorTask?.cancel()
        lightWatchTask?.cancel()
        if !quietly { state = .connecting; errorMessage = nil }
        let transport: HIDTransport
        do { transport = try transportFactory() } catch {
            state = quietly && error as? ViaError == .disconnected ? before : Self.state(for: error, opening: true)
            return
        }
        let device = ViaDevice(transport: transport)
        self.device = device
        do {
            try await device.validate()
            macroCapacity = try await device.macroBufferSize()
            let config = try await ConfigStore.read(from: device)
            ledMap = config.settings?.perKey != nil ? try await device.ledMap(size: .v3) : nil
            customEffects = nil
            standardEffect = config.lighting.effect
            selectedKeys = []
            snapClickDrafts = [:]
            layout = try LayoutDefinition.v3AnsiEncoder()
            engine = ApplyEngine(device: device, backupDirectory: backupDirectory)
            onDevice = config
            previewed = Self.look(of: config)
            working = config
            // Selections from before the reconnect are kept, but never past the end of what this keyboard has.
            selectedLayer = min(max(selectedLayer, 0), max(config.keymap.count - 1, 0))
            macroSlot = min(max(macroSlot, 0), max(config.macros.count - 1, 0))
            if let s = selectedKey, !(config.keymap.first?.indices.contains(s.row) == true && config.keymap[0][s.row].indices.contains(s.col)) { selectedKey = nil }
            errorMessage = nil   // the unplug alert is over, however this connect was started
            if let carried {
                if (try? ConfigStore.validateCompatible(carried.target, against: config)) != nil {   // layout only: the edits themselves came from this app
                    for change in carried.changes { Self.apply(change, from: carried.target, to: &working!) }
                } else {
                    errorMessage = "Your unapplied edits were dropped because the keyboard's layout differs."
                }
            }
            state = .connected
            schedulePreview()   // edits carried over a reconnect show on the keyboard again
            watchForUnplug(transport)
            watchKeyboardLighting()
            if selectedPanel == .keyTest { startKeyTest() }   // Key Test was open when the keyboard went: carry on
        } catch {
            if quietly {
                // Seen but not ready yet (just plugged in): stay as we were and try again on the next pass.
                state = Self.state(for: error, opening: false) == .permissionDenied ? .permissionDenied : before
                if case .wrongDevice = Self.state(for: error, opening: false) { state = Self.state(for: error, opening: false) }
                return
            }
            state = Self.state(for: error, opening: false)
            errorMessage = Self.sentence(Self.describe(error))
        }
    }

    /// The keyboard's own backlight keys change the lighting; while you have no lighting edits pending, follow them.
    private func watchKeyboardLighting() {
        lightWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, self.state == .connected else { return }
                await self.followKeyboardLighting()
            }
        }
    }

    private func followKeyboardLighting() async {
        guard !isApplying, !previewBusy, discoveryTask == nil, let device, let onDevice, let working, let previewed,
              previewed == Self.look(of: onDevice), working.lighting == onDevice.lighting,
              let now = try? await device.lighting() else { return }
        // Re-check: an edit or an apply may have started while the keyboard was being asked.
        guard !isApplying, !previewBusy, self.onDevice?.lighting == onDevice.lighting, self.working?.lighting == onDevice.lighting,
              now != onDevice.lighting, !now.isStored(as: onDevice.lighting) || !onDevice.lighting.isStored(as: now) else { return }
        var saved = onDevice; saved.lighting = now
        var shown = working; shown.lighting = now
        self.onDevice = saved
        self.previewed = Self.look(of: saved)
        self.working = shown
        standardEffect = now.effect > 0 && now.effect < 23 ? now.effect : standardEffect
    }

    /// Notices the keyboard being pulled out while nothing is being written.
    private func watchForUnplug(_ transport: HIDTransport) {
        guard let source = transport as? ConnectionEventSource else { return }
        monitorTask = Task { [weak self] in
            for await event in source.events where event == .disconnected {
                self?.keyboardUnplugged()
                return
            }
        }
    }

    private func keyboardUnplugged() {
        guard state == .connected else { return }
        stopKeyTest()
        state = .disconnected
        errorMessage = "The keyboard was unplugged. Your edits are kept; plug it back in and it reconnects by itself."
    }

    public func setKey(layer: Int, row: Int, col: Int, _ code: Keycode) {
        guard working?.keymap.indices.contains(layer) == true,
              working!.keymap[layer].indices.contains(row),
              working!.keymap[layer][row].indices.contains(col) else { return }
        working!.keymap[layer][row][col] = code
    }

    public func setEncoder(layer: Int, index: Int, clockwise: Bool, _ code: Keycode) {
        guard working?.encoders.indices.contains(layer) == true,
              working!.encoders[layer].indices.contains(index) else { return }
        if clockwise { working!.encoders[layer][index].clockwise = code } else { working!.encoders[layer][index].counterClockwise = code }
    }

    /// Turns the Code Input text into the selected macro's steps.
    public func applyMacroCode() {
        guard let draft = macroCodeDraft else { return }
        do {
            try setMacro(slot: macroSlot, steps: try MacroText.parse(draft))
            macroCodeDrafts.removeValue(forKey: macroSlot)
            macroCodeError = nil
        } catch let e as MacroText.ParseError {
            macroCodeError = "Line \(e.line): \(e.message)"
        } catch {
            macroCodeError = Self.describe(error)
        }
    }

    public func setMacroTitle(_ title: String, slot: Int) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { macroTitles[slot] = nil } else { macroTitles[slot] = trimmed }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: macroTitles.map { (String($0.key), $0.value) }), forKey: "macroTitles")
    }

    /// Starts listening to the keys you press in this window (they are held back from the rest of the app while recording).
    public func startMacroRecording() {
        guard !isRecordingMacro, working != nil else { return }
        recordedEvents = []
        recordedKeyCount = 0
        isRecordingMacro = true
        macroMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]) { [weak self] ns in
            guard let self else { return ns }
            // NSEvent is not Sendable, so only a Bool crosses the isolation boundary.
            let swallowed: Bool = MainActor.assumeIsolated {
                guard self.isRecordingMacro else { return false }
                if let e = MacroRecorder.event(from: ns) {
                    self.recordedEvents.append(.init(code: e.code, isDown: e.isDown, time: ns.timestamp))
                    if e.isDown { self.recordedKeyCount += 1 }
                }
                return true
            }
            return swallowed ? nil : ns
        }
    }

    /// Stops recording and adds what was typed to the end of the selected macro.
    public func stopMacroRecording() {
        guard isRecordingMacro else { return }
        isRecordingMacro = false
        if let macroMonitor { NSEvent.removeMonitor(macroMonitor) }
        macroMonitor = nil
        // A key still held when recording stopped is released, so the macro cannot leave it stuck down.
        var events = recordedEvents
        var held: [UInt16] = []
        for e in events { if e.isDown { held.append(e.code) } else { held.removeAll { $0 == e.code } } }
        let end = events.last?.time ?? 0
        for code in held.reversed() { events.append(.init(code: code, isDown: false, time: end)) }
        recordedEvents = []
        guard !events.isEmpty, let slotSteps = working?.macros[macroSlot] else { return }
        let delay: MacroRecorder.Delay = macroDelay == .none ? .none : macroDelay == .dynamic ? .dynamic : .fixed(macroFixedDelayMs)
        do { try setMacro(slot: macroSlot, steps: slotSteps + MacroRecorder.steps(from: events, delay: delay)) } catch { report(error) }
    }

    /// Sets a macro slot's steps. Throws, and changes nothing, if the macros would not fit or contain unsupported text.
    public func setMacro(slot: Int, steps: [MacroStep]) throws {
        guard var candidate = working, candidate.macros.indices.contains(slot) else {
            throw ViaError.invalid("there is no macro slot \(slot)")
        }
        candidate.macros[slot] = steps
        _ = try MacroCodec.encode(candidate.macros, capacity: macroCapacity)
        working = candidate
    }

    public func setLighting(_ state: LightingState) {
        working?.lighting = state
    }

    public func exportBackup(to url: URL) throws {
        guard let onDevice else { throw ViaError.disconnected }
        try ConfigStore.save(onDevice, to: url)
    }

    /// What restoring `url` would change on the keyboard. Writes nothing.
    public func previewRestore(from url: URL) throws -> [ConfigChange] {
        guard let onDevice else { throw ViaError.disconnected }
        let backup = try ConfigStore.load(from: url)
        try ConfigStore.validateRestorable(backup, against: onDevice)
        return ConfigStore.diff(from: onDevice, to: backup)
    }

    /// Replaces the keyboard's keymap, knob, macros and lighting with the backup's. The keyboard's current state is
    /// saved to its own timestamped backup first, and `lastBackupURL` points at it. Refused while the keyboard is not
    /// connected or another write is running, before the working copy is touched.
    public func restore(from url: URL) async throws {
        guard state == .connected, let onDevice else { throw ViaError.disconnected }
        guard !isApplying else { throw ViaError.invalid("another write is still running") }
        _ = try previewRestore(from: url)
        let backup = try ConfigStore.load(from: url)
        lastBackupURL = try saveBackup(onDevice, named: "v3-keymap-before-restore")
        var target = onDevice
        target.keymap = backup.keymap
        target.encoders = backup.encoders
        target.macros = backup.macros
        target.lighting = backup.lighting
        if let b = backup.settings {
            if let d = b.debounce, target.settings?.debounce != nil { target.settings?.debounce = d.clamped }
            if b.snapClick != nil && target.settings?.snapClick != nil { target.settings?.snapClick = b.snapClick }
            if b.perKey != nil && target.settings?.perKey != nil { target.settings?.perKey = b.perKey }
            if b.mixed != nil && target.settings?.mixed != nil { target.settings?.mixed = b.mixed }
            if b.indicator != nil && target.settings?.indicator != nil { target.settings?.indicator = b.indicator }
        }
        working = target
        await applyPending()
        if !pending.isEmpty { throw ViaError.invalid(errorMessage ?? "the restore did not finish") }
        restorePreview = nil
    }

    // MARK: Device settings

    private func canSelect(_ p: MatrixPosition) -> Bool { ledMap?.ledIndex(row: p.row, col: p.col) != nil }

    public func toggleSelection(_ p: MatrixPosition) {
        guard canSelect(p) else { return }
        if selectedKeys.contains(p) { selectedKeys.remove(p) } else { selectedKeys.insert(p) }
    }

    public func selectAllKeys() {
        guard let rows = ledMap?.rows else { return }
        selectedKeys = Set(rows.indices.flatMap { r in rows[r].indices.compactMap { c in rows[r][c] != nil ? MatrixPosition(row: r, col: c) : nil } })
    }

    public func clearSelection() { selectedKeys = [] }

    /// The colour of the LED under a key (per-key RGB), if it has one.
    public func ledColour(at p: MatrixPosition) -> HSVColor? {
        guard let led = ledMap?.ledIndex(row: p.row, col: p.col), let colors = working?.settings?.perKey?.colors, colors.indices.contains(led) else { return nil }
        return colors[led]
    }

    /// The Mix RGB zone a key's LED belongs to, if it has an LED.
    public func zone(of p: MatrixPosition) -> Int? {
        guard let led = ledMap?.ledIndex(row: p.row, col: p.col), let regions = working?.settings?.mixed?.regions, regions.indices.contains(led) else { return nil }
        return Int(regions[led])
    }

    public func paintSelected(_ colour: HSVColor) {
        guard var perKey = working?.settings?.perKey, let map = ledMap else { return }
        for p in selectedKeys { if let led = map.ledIndex(row: p.row, col: p.col), perKey.colors.indices.contains(led) { perKey.colors[led] = colour } }
        working?.settings?.perKey = perKey
    }

    public func setPerKeyType(_ type: PerKeyType) { working?.settings?.perKey?.type = type }

    public func assignSelected(toZone zone: Int) {
        guard var mixed = working?.settings?.mixed, mixed.zones.indices.contains(zone), let map = ledMap else { return }
        for p in selectedKeys { if let led = map.ledIndex(row: p.row, col: p.col), mixed.regions.indices.contains(led) { mixed.regions[led] = UInt8(zone) } }
        working?.settings?.mixed = mixed
    }

    public func setMixedEffect(zone: Int, slot: Int, _ effect: MixedEffect) {
        guard working?.settings?.mixed?.zones.indices.contains(zone) == true,
              working!.settings!.mixed!.zones[zone].indices.contains(slot) else { return }
        working?.settings?.mixed?.zones[zone][slot] = effect
    }

    public func removeMixedEffect(zone: Int, slot: Int) { setMixedEffect(zone: zone, slot: slot, .unused) }

    public func setDebounce(_ settings: DebounceSettings) {
        guard working?.settings?.debounce != nil else { return }
        working?.settings?.debounce = settings.clamped
    }

    /// An incomplete pair is kept as a draft so the screen can show it, but it never becomes a pending change.
    public func setSnapClick(index: Int, _ slot: SnapClickSlot) {
        guard working?.settings?.snapClick?.indices.contains(index) == true else { return }
        if slot.isValid {
            snapClickDrafts.removeValue(forKey: index)
            working?.settings?.snapClick?[index] = slot
        } else {
            snapClickDrafts[index] = slot
        }
    }

    /// Which Snap Click key button has its chooser open.
    public struct SnapClickPick: Equatable, Sendable { public let index: Int; public let isSecond: Bool }
    public var snapClickPicking: SnapClickPick?

    /// Rows to show: pairs in use, and pairs still being filled in.
    public var snapClickVisibleRows: [Int] {
        guard let slots = working?.settings?.snapClick else { return [] }
        return slots.indices.filter { slots[$0].type != .none || snapClickDrafts[$0] != nil }
    }

    /// Starts a new pair in the first free slot (as a draft, so nothing is pending until both keys are chosen).
    @discardableResult
    public func addSnapClickPair() -> Int? {
        guard let slots = working?.settings?.snapClick,
              let free = slots.indices.first(where: { slots[$0].type == .none && snapClickDrafts[$0] == nil }) else { return nil }
        snapClickDrafts[free] = SnapClickSlot(type: .regular, key1: 0, key2: 0)
        return free
    }

    public func snapClickRow(_ index: Int) -> SnapClickSlot? { snapClickDrafts[index] ?? working?.settings?.snapClick.flatMap { $0.indices.contains(index) ? $0[index] : nil } }
    public func snapClickRowIsIncomplete(_ index: Int) -> Bool { snapClickDrafts[index] != nil }

    /// Finds which effect ids select per-key and Mix RGB (once per session). Briefly changes the live effect and puts it back.
    @discardableResult
    func ensureCustomEffects(silently: Bool = false) async -> Bool {
        if customEffects != nil { return true }
        if let task = discoveryTask { return await task.value }
        guard !isApplying else { return false }
        let task = Task { await discoverCustomEffects(silently: silently) }
        discoveryTask = task
        let ok = await task.value
        discoveryTask = nil
        return ok
    }

    private func discoverCustomEffects(silently: Bool) async -> Bool {
        guard let device, state == .connected, supportsPerKeyRGB || supportsMixedRGB else { return false }
        do {
            guard let ids = try await device.discoverCustomEffectIDs() else {
                if !silently { errorMessage = "This keyboard did not report its lighting effects, so Per-key RGB and Mix RGB cannot be switched on from here." }
                return false
            }
            customEffects = ids
            if standardEffect == ids.perKey || standardEffect == ids.mixed { standardEffect = 1 }
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Chooses between the standard effects and the two custom effects (a pending change until Apply).
    public func setLightingMode(_ mode: LightingMode) async {
        guard var lighting = working?.lighting else { return }
        switch mode {
        case .standard:
            if let ids = customEffects, lighting.effect == ids.perKey || lighting.effect == ids.mixed { lighting.effect = standardEffect }
        case .perKey, .mixed:
            guard await ensureCustomEffects(), let ids = customEffects, let now = working?.lighting else { return }
            lighting = now   // edits made while the probe ran are kept
            if lighting.effect != ids.perKey && lighting.effect != ids.mixed { standardEffect = lighting.effect }
            lighting.effect = mode == .perKey ? ids.perKey : ids.mixed
        }
        working?.lighting = lighting
    }

    public func startKeyTest() {
        guard state == .connected, keyTestTask == nil, let device else { return }
        updateCapture()
        keyTestTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let keys = try await device.pressedKeys()
                    guard !Task.isCancelled else { return }
                    if let self {
                        let fresh = keys.subtracting(self.pressedKeys)
                        if !fresh.isEmpty { self.playKeySound() }
                        for k in fresh { self.matrixCounts[k, default: 0] += 1 }
                        self.addTyped(fresh: fresh, held: keys)
                    }
                    self?.pressedKeys = keys
                    let now = Date()
                    for k in keys { self?.lastHeld[k] = now }
                } catch {
                    self?.keyTestFailed(error)
                    return
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    public func stopKeyTest() {
        keyTestTask?.cancel()
        keyTestTask = nil
        pressedKeys = []
        lastHeld = [:]
        trustWatch?.cancel(); trustWatch = nil
        capture.stop()
    }

    // MARK: Key Test: sound

    /// The sounds Key Test can play on each key press: the ones that come with macOS.
    public static let keySounds = ["Tink", "Pop", "Glass", "Bottle", "Frog", "Blow", "Funk", "Hero", "Morse", "Ping", "Purr", "Sosumi", "Submarine", "Basso"]
    public var keySoundOn = UserDefaults.standard.bool(forKey: "keySoundOn") {
        didSet { UserDefaults.standard.set(keySoundOn, forKey: "keySoundOn") }
    }
    public var keySound = UserDefaults.standard.string(forKey: "keySound").flatMap { AppModel.keySounds.contains($0) ? $0 : nil } ?? "Tink" {
        didSet { UserDefaults.standard.set(keySound, forKey: "keySound"); if keySoundOn { playKeySound() } }
    }

    private func playKeySound() {
        guard keySoundOn, let sound = NSSound(named: NSSound.Name(keySound)) else { return }
        (sound.copy() as? NSSound ?? sound).play()
    }

    // MARK: Key Test: holding keys back, counting presses, knob turns

    /// Starts or stops watching keys. While Key Test is open and this window is in front, key presses are held back
    /// so they do not also run (volume, brightness, shortcuts); in any other case the keyboard works as usual.
    private func updateCapture() {
        guard selectedPanel == .keyTest, state == .connected else { capture.stop(); return }
        captureAllowed = trustProbe()
        if captureAllowed {
            capture.start { [weak self] key in Task { @MainActor in self?.recordPress(key) } }
            capture.isSwallowing = appIsActive
        } else {
            // No prompt from here: the notice strip in Key Test says what access adds, and only its button asks for it.
            capture.stop()
            capture.isSwallowing = false
        }
        watchTrust()
    }

    /// Access can be granted or taken away in System Settings at any moment. While Key Test is open the grant is checked
    /// once a second, so the notice and the key capture follow it both ways.
    private func watchTrust() {
        guard trustWatch == nil else { return }
        trustWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.trustProbe() != self.captureAllowed { self.updateCapture() }
            }
        }
    }

    /// Adds what newly pressed keys would type (left to right along the row, so two keys pressed together come out in keyboard order).
    private func addTyped(fresh: Set<MatrixPosition>, held: Set<MatrixPosition>) {
        guard let keymap = onDevice?.keymap[selectedLayer] else { return }
        func code(_ p: MatrixPosition) -> UInt16 { MacKeyMap.normalised(keymap[p.row][p.col].raw) }
        let shift = held.contains { [0xE1, 0xE5].contains(code($0)) }
        for p in fresh.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }) {
            let c = code(p)
            if c == 0x39 { capsOn.toggle(); continue }
            TypedText.apply(code: c, shift: shift, capsLock: capsOn, to: &typedText)
        }
        if typedText.count > 4000 { typedText = String(typedText.suffix(3000)) }
    }

    public func clearTypedText() { typedText = ""; capsOn = false }

    public func resetKeyCounts() {
        keyCounts = [:]
        matrixCounts = [:]
        knobLeftTurns = 0
        knobRightTurns = 0
    }

    /// Presses counted for a key on screen.
    public func pressCount(at position: MatrixPosition) -> Int {
        // Exact press events (by key) need Accessibility access; presses seen in the keyboard's matrix always work. Show the larger.
        let seen = matrixCounts[position] ?? 0
        guard let code = onDevice?.keymap[selectedLayer][position.row][position.col] else { return seen }
        return max(seen, keyCounts[MacKeyMap.normalised(code.raw)] ?? 0)
    }

    /// A key was pressed. The knob sends the same keys as ordinary ones, so a moment later (when the matrix poll has
    /// caught up) it is told apart: a press that matches a knob action while no such key is held down was a knob turn.
    func recordPress(_ keycode: UInt16) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            self?.applyPress(keycode, heldCodes: self?.heldCodes() ?? [])
        }
    }

    private func heldCodes() -> Set<UInt16> {
        guard let keymap = onDevice?.keymap[selectedLayer] else { return [] }
        let recent = Date().addingTimeInterval(-0.15)
        let positions = pressedKeys.union(lastHeld.filter { $0.value > recent }.keys)
        return Set(positions.map { MacKeyMap.normalised(keymap[$0.row][$0.col].raw) })
    }

    func applyPress(_ keycode: UInt16, heldCodes: Set<UInt16>) {
        let code = MacKeyMap.normalised(keycode)
        if !heldCodes.contains(code), let knob = onDevice?.encoders[selectedLayer].first {
            let right = MacKeyMap.normalised(knob.clockwise.raw) == code, left = MacKeyMap.normalised(knob.counterClockwise.raw) == code
            if right != left {
                if right { knobRightTurns += 1 } else { knobLeftTurns += 1 }
                flashKnob(right: right)
                return
            }
        }
        keyCounts[code, default: 0] += 1
    }

    private func flashKnob(right: Bool) {
        knobFlashLeft = !right; knobFlashRight = right
        knobFlashTask?.cancel()
        knobFlashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.knobFlashLeft = false; self?.knobFlashRight = false
        }
    }

    private func keyTestFailed(_ error: Error) {
        stopKeyTest()   // the event tap and the trust watch go too, not only the poll
        errorMessage = Self.sentence(Self.describe(error))
        if let e = error as? ViaError, e == .disconnected || e == .timeout { state = .disconnected }
    }

    public func discardPending() {
        working = onDevice
        snapClickDrafts = [:]
        errorMessage = nil
    }

    public func applyPending() async {
        _ = await discoveryTask?.value      // never apply while the effect probe is mid-way
        previewTask?.cancel()
        while previewBusy { try? await Task.sleep(for: .milliseconds(10)) }   // nor while a preview is being sent
        guard state == .connected, !isApplying, let engine, let target = working, let current = onDevice, !pending.isEmpty else { return }
        isApplying = true
        errorMessage = nil
        defer { isApplying = false; schedulePreview() }
        let backupBefore = await engine.sessionBackupURL
        do {
            _ = try await engine.apply(target, current: current)
            onDevice = target
            previewed = Self.look(of: target)
        } catch ApplyError.partial(let written, let failed, let underlying) {
            var updated = current
            for change in written { Self.apply(change, from: target, to: &updated) }
            onDevice = updated
            // The keyboard still shows whatever was being previewed, apart from the lighting parts that were just written.
            if var shown = previewed { Self.copyLook(of: updated, written: written, into: &shown); previewed = shown }
            errorMessage = "Stopped at \"\(describe(failed))\" after writing \(plural(written.count, "change")): \(Self.describe(underlying))"
            if underlying == .disconnected || underlying == .timeout {
                state = .disconnected
                errorMessage! += ". That last item may have been partly written; it is checked again when you reconnect."
            } else if let device, let actual = try? await reread(device, keepingSavedLookExcept: written) {
                onDevice = actual   // trust the keyboard, not our estimate of what landed
            }
        } catch ApplyError.backupFailed(let message) {
            errorMessage = "Nothing was written: the backup could not be saved (\(message))"
        } catch {
            errorMessage = Self.sentence(Self.describe(error))
        }
        // Point at the session backup only when this apply made it, so a restore's or reset's own backup is not hidden.
        if let url = await engine.sessionBackupURL, url != backupBefore { lastBackupURL = url }
    }

    public func dismissError() { errorMessage = nil }

    /// Revert asks first when more than one change would be lost; a single change is just discarded.
    public func revertPending() {
        if pending.count > 1 { confirmingRevert = true } else { discardPending() }
    }

    /// Opens System Settings at Privacy & Security › Input Monitoring, where the app has to be switched on.
    public func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
    }

    /// Shows macOS's Accessibility prompt for Key Test's key counting and starts watching for the answer.
    public func requestKeyCaptureAccess() {
        trustPrompter()
        updateCapture()
    }

    /// Saves `config` as `<prefix>-<timestamp>.json` in the backup folder and returns where it went.
    private func saveBackup(_ config: KeyboardConfig, named prefix: String) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let url = backupDirectory.appendingPathComponent("\(prefix)-\(stamp).json")
        try ConfigStore.save(config, to: url)
        return url
    }

    /// Reads the keyboard back after a write went wrong. The lighting, per-key, Mix RGB and indicator values it reports are
    /// what it is showing right now, which may be a live preview that was never saved; for each of those that was not in
    /// `written`, the saved value in `onDevice` is kept so the unapplied edit stays pending.
    private func reread(_ device: ViaDevice, keepingSavedLookExcept written: [ConfigChange]) async throws -> KeyboardConfig {
        var fresh = try await ConfigStore.read(from: device)
        guard let saved = onDevice else { return fresh }
        let targets = written.map(\.target)
        if !targets.contains(.lighting) { fresh.lighting = saved.lighting }
        if let s = saved.settings, fresh.settings != nil {
            if !targets.contains(.perKeyRGB) { fresh.settings?.perKey = s.perKey }
            if !targets.contains(.mixedRGB) { fresh.settings?.mixed = s.mixed }
            if !targets.contains(.indicator) { fresh.settings?.indicator = s.indicator }
        }
        return fresh
    }

    /// Copies into `shown` the parts of the look that `written` says reached the keyboard.
    private static func copyLook(of c: KeyboardConfig, written: [ConfigChange], into shown: inout LightLook) {
        let targets = written.map(\.target)
        if targets.contains(.lighting) { shown.lighting = c.lighting }
        if targets.contains(.perKeyRGB) { shown.perKey = c.settings?.perKey }
        if targets.contains(.mixedRGB) { shown.mixed = c.settings?.mixed }
        if targets.contains(.indicator) { shown.indicator = c.settings?.indicator }
    }

    /// Puts every layer's keys and the knob back to the keyboard's factory settings. A backup of the current setup is saved
    /// first, and unapplied edits are discarded. Macros, lighting and the extra settings are left alone; a lighting edit
    /// that was being previewed is taken off the keyboard again. A reset that fails leaves the edits as they were.
    public func resetKeymapToFactory() async {
        _ = await discoveryTask?.value      // never reset while the effect probe is mid-way
        previewTask?.cancel()
        while previewBusy { try? await Task.sleep(for: .milliseconds(10)) }   // nor while a preview is being sent
        guard state == .connected, !isApplying, let device, let onDevice else { return }
        isApplying = true
        errorMessage = nil
        defer { isApplying = false; schedulePreview() }
        do {
            lastBackupURL = try saveBackup(onDevice, named: "v3-keymap-before-keymap-reset")
            try await device.resetKeymapToFactory()
            try? await Task.sleep(for: .milliseconds(150))
            // The read returns the live (possibly previewed) lighting; the saved look is kept, and `previewed` is left as
            // it is so schedulePreview puts the saved look back on the keyboard.
            let fresh = try await reread(device, keepingSavedLookExcept: [])
            self.onDevice = fresh
            working = fresh
            selectedKey = nil
        } catch {
            errorMessage = "The keymap was not reset: \(Self.describe(error))"
            if let actual = try? await reread(device, keepingSavedLookExcept: []) { self.onDevice = actual }
        }
    }

    /// How many of the macro buffer's bytes the current macros use.
    public var macroBytesUsed: Int {
        guard let macros = working?.macros, let bytes = try? MacroCodec.encode(macros, capacity: macroCapacity) else { return 0 }
        return (bytes.lastIndex(where: { $0 != 0 }) ?? -1) + 1
    }

    /// Shows an error from a UI action in the status bar.
    public func report(_ error: Error) { errorMessage = Self.sentence(Self.describe(error)) }

    private static func apply(_ change: ConfigChange, from target: KeyboardConfig, to config: inout KeyboardConfig) {
        switch change.target {
        case .key(let l, let r, let c, let code): config.keymap[l][r][c] = code
        case .encoder(let l, let i, let clockwise, let code):
            if clockwise { config.encoders[l][i].clockwise = code } else { config.encoders[l][i].counterClockwise = code }
        case .macros: config.macros = target.macros
        case .lighting: config.lighting = target.lighting
        case .debounce: config.settings?.debounce = target.settings?.debounce
        case .snapClick(let index):
            if let slot = target.settings?.snapClick?[index] { config.settings?.snapClick?[index] = slot }
        case .perKeyRGB: config.settings?.perKey = target.settings?.perKey
        case .mixedRGB: config.settings?.mixed = target.settings?.mixed
        case .indicator: config.settings?.indicator = target.settings?.indicator
        }
    }

    private static func state(for error: Error, opening: Bool) -> ConnectionState {
        switch error as? ViaError {
        case .permissionDenied: return .permissionDenied
        case .wrongDevice(let message): return .wrongDevice(message)
        default: return opening ? .notFound : .disconnected
        }
    }

    /// The change in the words the window uses: layer names instead of numbers, key labels instead of QMK names.
    /// The old key comes from what the keyboard has (`onDevice`); every change list in the app is measured from there.
    public func describe(_ change: ConfigChange) -> String {
        func layerName(_ l: Int) -> String { Self.layerNames.indices.contains(l) ? Self.layerNames[l] : "Layer \(l)" }
        func label(_ code: Keycode?) -> String { code.map { KeyLabels.label(for: $0).long } ?? "?" }
        switch change.target {
        case .key(let layer, let row, let col, let to):
            let keymap = onDevice?.keymap
            let old = keymap.flatMap { $0.indices.contains(layer) && $0[layer].indices.contains(row) && $0[layer][row].indices.contains(col) ? $0[layer][row][col] : nil }
            return "\(layerName(layer)): \(label(old)) → \(label(to))"
        case .encoder(let layer, let index, let clockwise, let to):
            let actions = onDevice?.encoders.indices.contains(layer) == true && onDevice!.encoders[layer].indices.contains(index) ? onDevice!.encoders[layer][index] : nil
            let old = actions.map { clockwise ? $0.clockwise : $0.counterClockwise }
            return "\(layerName(layer)) knob, turn \(clockwise ? "right" : "left"): \(label(old)) → \(label(to))"
        default:
            return Self.capitalised(change.description)
        }
    }

    /// The first letter capitalised, the rest left alone.
    static func capitalised(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// A message shown on its own: capitalised, with a full stop at the end.
    static func sentence(_ text: String) -> String {
        let out = capitalised(text)
        guard let last = out.last, !".!?".contains(last) else { return out }
        return out + "."
    }

    static func describe(_ error: Error) -> String {
        switch error as? ViaError {
        case .timeout: return "the keyboard did not answer in time"
        case .shortReply: return "the keyboard sent an incomplete reply"
        case .disconnected: return "the keyboard was disconnected"
        case .permissionDenied: return "macOS denied access to the keyboard (Input Monitoring)"
        case .unsupported(let command): return "the keyboard does not support command 0x\(String(command, radix: 16))"
        case .wrongDevice(let message), .invalid(let message), .rejected(let message): return message
        case .verifyMismatch(let items): return "the keyboard did not keep the change: \(items.joined(separator: "; "))"
        case .forbiddenCommand(let command): return "blocked unsafe command 0x\(String(command, radix: 16))"
        case nil: return "\(error)"
        }
    }
}
