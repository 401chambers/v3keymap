import SwiftUI
import ViaKit

/// Macros: the slots on the left (with a name and a memory meter), and on the right tabs to record, edit steps, or type the macro as text.
struct MacrosView: View {
    let model: AppModel
    let working: KeyboardConfig
    @Environment(\.colorScheme) private var scheme

    private static func describe(_ step: MacroStep) -> (icon: String, text: String) {
        switch step {
        case .text(let t): return ("character.cursor.ibeam", "Type “\(t)”")
        case .tap(let k): return ("hand.tap", "Tap \(KeyLabels.label(for: k).long)")
        case .down(let k): return ("arrow.down.to.line", "Hold \(KeyLabels.label(for: k).long)")
        case .up(let k): return ("arrow.up.to.line", "Release \(KeyLabels.label(for: k).long)")
        case .delay(let ms): return ("clock", "Wait \(ms) ms")
        case .raw(let bytes): return ("exclamationmark.triangle", "Unreadable macro (\(bytes.count) bytes), kept as it is")
        }
    }

    @discardableResult
    private func save(_ steps: [MacroStep]) -> Bool {
        do { try model.setMacro(slot: model.macroSlot, steps: steps); return true } catch { model.report(error); return false }
    }

    private func addDraft(to steps: [MacroStep]) {
        let saved: Bool
        if model.macroAddKind == .text {
            saved = save(steps + [.text(model.macroDraft)])
        } else if let ms = Int(model.macroDraft), ms >= 0, ms <= 65535 {
            saved = save(steps + [.delay(ms: ms)])
        } else {
            model.report(ViaError.invalid("Enter a wait between 0 and 65535 milliseconds."))
            return
        }
        if saved { model.macroDraft = "" }   // a draft that was refused stays on screen to be fixed
    }

    var body: some View {
        content
            .confirmationDialog("Empty macro \(String(format: "M%02d", model.confirmingMacroClear ?? 0))?",
                                isPresented: Binding(get: { model.confirmingMacroClear != nil }, set: { if !$0 { model.confirmingMacroClear = nil } }),
                                titleVisibility: .visible) {
                Button("Empty Macro", role: .destructive) {
                    if let i = model.confirmingMacroClear { model.macroSlot = i; save([]) }
                    model.confirmingMacroClear = nil
                }
                Button("Cancel", role: .cancel) { model.confirmingMacroClear = nil }
            } message: {
                Text("Its steps are removed from the working copy; the keyboard keeps them until you Apply.")
            }
    }

    private var content: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(alignment: .top, spacing: Theme.paneGap) {
                slotList.frame(width: 240)
                VStack(alignment: .leading, spacing: 12) {
                    TabStrip(items: AppModel.MacroTab.allCases, selection: Binding(get: { model.macroTab }, set: { model.macroTab = $0 })) { $0.rawValue }
                        .frame(maxWidth: 320)
                    if model.macroTab == .configuration { configuration } else { codeInput }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(20)
    }

    // MARK: Slots

    private var slotList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Macros").font(.headline)
            Text("Pick a macro here, then give it a key with Keys › Macro.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(0..<working.macros.count, id: \.self) { i in slotRow(i) }
                }
                .padding(2)
            }
            let used = model.macroBytesUsed
            VStack(alignment: .leading, spacing: 4) {
                Gauge(value: Double(used), in: 0...Double(max(model.macroCapacity, 1))) { Text("Macro memory") }
                Text("\(used) of \(model.macroCapacity) bytes used").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .paneCard()
    }

    private func slotRow(_ i: Int) -> some View {
        let selected = model.macroSlot == i
        let count = working.macros[i].count
        return HStack(spacing: 10) {
            Text(String(format: "M%02d", i)).font(.callout.monospaced().weight(.semibold)).frame(width: 40)
            TextField("Name", text: Binding(get: { model.macroTitles[i] ?? "" }, set: { model.setMacroTitle($0, slot: i) }), prompt: Text(count == 0 ? "Empty" : plural(count, "step")))
                .labelsHidden().textFieldStyle(.plain)
            Button { model.confirmingMacroClear = i } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).disabled(count == 0).help("Empty this macro")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background { RoundedRectangle(cornerRadius: Theme.insetRadius).fill(selected ? Theme.selectionWash(scheme) : Theme.insetWash) }
        .contentShape(RoundedRectangle(cornerRadius: Theme.insetRadius))
        .onTapGesture { model.macroSlot = i }
    }

    // MARK: Configuration

    private var configuration: some View {
        let slot = model.macroSlot
        let steps = working.macros[slot]
        return HStack(alignment: .top, spacing: Theme.paneGap) {
            VStack(alignment: .leading, spacing: 12) {
                Pane("Record") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            if model.isRecordingMacro { model.stopMacroRecording() } else { model.startMacroRecording() }
                        } label: {
                            Label(model.isRecordingMacro ? "Stop recording" : "Start recording", systemImage: model.isRecordingMacro ? "stop.circle.fill" : "record.circle")
                                .foregroundStyle(model.isRecordingMacro ? Color.red : Color.primary)
                        }
                        .buttonStyle(.bordered)
                        if model.isRecordingMacro {
                            Text("Type now: \(plural(model.recordedKeyCount, "key")) so far. Keys go into the macro, not the app.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Recorded keys are added to the end of M\(String(format: "%02d", slot)). Only keys pressed in this window are recorded.").font(.caption).foregroundStyle(.tertiary)
                        }
                        Text("Pauses").font(.subheadline.weight(.semibold)).padding(.top, 4)
                        Picker("Pauses", selection: Binding(get: { model.macroDelay }, set: { model.macroDelay = $0 })) {
                            ForEach(AppModel.MacroDelayChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.radioGroup).labelsHidden().disabled(model.isRecordingMacro)
                        if model.macroDelay == .fixed {
                            Stepper("\(model.macroFixedDelayMs) ms between steps", value: Binding(get: { model.macroFixedDelayMs }, set: { model.macroFixedDelayMs = $0 }), in: 10...2000, step: 10)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Pane("Add a step by hand") { addStep(steps) }
            }
            .frame(width: 290)
            Pane("Steps · M\(String(format: "%02d", slot))") {
                if steps.isEmpty {
                    Text("This macro is empty. Record keys, or add steps; they run in order when you press the key it is assigned to.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                let d = Self.describe(step)
                                HStack {
                                    Label(d.text, systemImage: d.icon).lineLimit(1)
                                    Spacer()
                                    Button { var c = steps; c.remove(at: index); save(c) } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless).help("Remove this step")
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background { RoundedRectangle(cornerRadius: Theme.rowRadius).fill(Theme.insetWash) }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func addStep(_ steps: [MacroStep]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Kind", selection: Binding(get: { model.macroAddKind }, set: { model.macroAddKind = $0 })) {
                ForEach(AppModel.MacroAddKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden()
            switch model.macroAddKind {
            case .text, .delay:
                HStack {
                    TextField("Value", text: Binding(get: { model.macroDraft }, set: { model.macroDraft = $0 }),
                              prompt: Text(model.macroAddKind == .text ? "Text to type" : "Milliseconds, for example 250"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .onSubmit { addDraft(to: steps) }
                    Button("Add") { addDraft(to: steps) }.buttonStyle(.bordered).disabled(model.macroDraft.isEmpty)
                }
            case .tap, .down, .up:
                KeycodePickerGrid(search: Binding(get: { model.keycodeSearch }, set: { model.keycodeSearch = $0 }),
                                  category: Binding(get: { model.pickerCategory }, set: { model.pickerCategory = $0 }), current: nil, compact: true, fixedHeight: 190, model: model) { code in
                    let step: MacroStep = model.macroAddKind == .tap ? .tap(code) : model.macroAddKind == .down ? .down(code) : .up(code)
                    save(steps + [step])
                }
            }
        }
    }

    // MARK: Code input

    private var codeInput: some View {
        let steps = working.macros[model.macroSlot]
        return Pane("Macro as text · M\(String(format: "%02d", model.macroSlot))") {
            VStack(alignment: .leading, spacing: 10) {
                Text("One step per line: tap KC_A, down KC_LSFT, up KC_LSFT, wait 250, type Hello. Lines starting with # are ignored.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { model.macroCodeDraft ?? MacroText.format(steps) }, set: { model.macroCodeDraft = $0; model.macroCodeError = nil }))
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background { RoundedRectangle(cornerRadius: Theme.insetRadius).fill(Theme.insetWash) }
                if let error = model.macroCodeError { Text(error).font(.caption).foregroundStyle(Theme.warning) }
                HStack {
                    Button("Update steps") { model.applyMacroCode() }.buttonStyle(.bordered).disabled(model.macroCodeDraft == nil)
                    Button("Discard") { model.macroCodeDraft = nil; model.macroCodeError = nil }.buttonStyle(.bordered).disabled(model.macroCodeDraft == nil)
                }
            }
        }
    }
}
