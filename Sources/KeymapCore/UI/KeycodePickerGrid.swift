import SwiftUI
import ViaKit

/// The picker's tabs, in the order Keychron's Launcher uses.
public enum PickerCategory: String, CaseIterable, Sendable {
    case keys = "Basic", media = "Media", macros = "Macro", mouse = "Mouse", dualRole = "Hold/Tap", special = "Special", lighting = "Backlight", custom = "Custom", layers = "Layer"

    func contains(_ code: Keycode) -> Bool {
        switch self {
        case .special: return Keycode.specialRaws.contains(code.raw)
        case .layers: return code.category == .layer || Keycode.layerKeymapRaws.contains(code.raw)
        case .keys: return code.category == .basic || code.category == .modifier
        case .media: return code.category == .media
        case .mouse: return code.category == .mouse
        case .dualRole: return code.category == .dualRole && !Keycode.specialRaws.contains(code.raw) && !Keycode.layerKeymapRaws.contains(code.raw)
        case .macros: return code.category == .macro
        case .lighting: return code.category == .lighting
        case .custom: return code.category == .device || code.raw == 0xC1 || code.raw == 0xC2
        }
    }

    /// The tab's keys, grouped under headings where that helps (letters, numbers, ...).
    func sections(of codes: [Keycode]) -> [(title: String?, codes: [Keycode])] {
        let mine = codes.filter { contains($0) }
        func group(_ title: String, _ test: (Keycode) -> Bool) -> (title: String?, codes: [Keycode]) { (title, mine.filter(test)) }
        switch self {
        case .keys:
            let groups = [
                group("Letters") { (0x04...0x1D).contains($0.raw) },
                group("Numbers") { (0x1E...0x27).contains($0.raw) },
                group("Symbols") { (0x2D...0x38).contains($0.raw) },
                group("Editing and navigation") { $0.raw <= 1 || (0x28...0x2C).contains($0.raw) || $0.raw == 0x39 || (0x46...0x52).contains($0.raw) || $0.raw == 0x65 },
                group("Function keys") { (0x3A...0x45).contains($0.raw) || (0x68...0x73).contains($0.raw) },
                group("Keypad") { (0x53...0x63).contains($0.raw) },
                group("Modifiers") { $0.category == .modifier },
            ]
            return groups.filter { !$0.codes.isEmpty }
        case .special:
            let groups = [
                group("Shifted symbols") { ($0.raw & 0xFF00) == 0x0200 },
                group("International") { [0x32, 0x64, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x90, 0x91].contains($0.raw) },
                group("Typing") { [0x7C16, 0x99].contains($0.raw) || (0x7C18...0x7C1E).contains($0.raw) },
                group("System") { [0xA5, 0xA6, 0xA7, 0x700B, 0x7013, 0x7C02, 0x0914, 0x080F].contains($0.raw) },
            ]
            return groups.filter { !$0.codes.isEmpty }
        case .layers:
            let order = ["MO", "TG", "TT", "OSL", "TO", "DF"]
            func rank(_ c: Keycode) -> Int { order.firstIndex { c.name.hasPrefix($0 + "(") } ?? order.count }
            let layerKeys = mine.filter { $0.category == .layer && !$0.name.hasPrefix("FN_") }.sorted { (rank($0), $0.raw) < (rank($1), $1.raw) }
            let extras = mine.filter { !layerKeys.contains($0) }
            return [("Layer keys", layerKeys), ("Fn and Space keys", extras)].filter { !$0.1.isEmpty }.map { ($0.0, $0.1) }
        default:
            return mine.isEmpty ? [] : [(nil, mine)]
        }
    }
}

/// Category tabs and search on one row, then a grid of keycaps that fills the space it is given.
/// Hex codes such as `0x7E7F` can be typed too. `compact` stacks the controls for narrow places.
struct KeycodePickerGrid: View {
    @Binding var search: String
    @Binding var category: PickerCategory
    let current: Keycode?
    var compact = false
    var fixedHeight: CGFloat?
    /// Needed for the "Combos & dual-role" builder, whose state lives in the model.
    var model: AppModel?
    let onPick: (Keycode) -> Void

    private var query: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    private var results: [Keycode] {
        if query.isEmpty { return Keycode.all.filter { category.contains($0) } }
        return Keycode.all.filter {
            let l = KeyLabels.label(for: $0)
            return $0.name.lowercased().contains(query) || l.long.lowercased().contains(query) || l.short.lowercased().contains(query)
        }
    }

    private var typedCode: Keycode? {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard q.lowercased().hasPrefix("0x"), let k = Keycode(name: "0x" + q.dropFirst(2).uppercased()), !Keycode.all.contains(k), !k.isDangerous else { return nil }
        return k
    }

    private var searchField: some View {
        TextField("Search", text: $search, prompt: Text("Search keys, for example volume or 0x7E09"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
    }

    private var tabs: some View {
        TabStrip(items: PickerCategory.allCases, selection: $category) { $0.rawValue }
    }

    var body: some View {
        let results = self.results   // filtered once per redraw, not once per use
        VStack(alignment: .leading, spacing: 10) {
            if query.isEmpty { tabs }
            HStack(spacing: 12) {
                if !query.isEmpty { Text("\(results.count) match\(results.count == 1 ? "" : "es")").foregroundStyle(.secondary) }
                searchField
            }
            if let model, category == .dualRole, query.isEmpty {
                DualRoleBuilder(model: model, onPick: onPick)
            } else {
                if let model, category == .custom, query.isEmpty { AnyKeycodeField(model: model, onPick: onPick) }
                if let model, category == .layers, query.isEmpty { LayerHelp(model: model) }
                grid(results)
            }
        }
    }

    @ViewBuilder private func grid(_ results: [Keycode]) -> some View {
        let sections: [(title: String?, codes: [Keycode])] = query.isEmpty ? category.sections(of: Keycode.all) : [(nil, results)]
        let content = ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let typed = typedCode { LazyVGrid(columns: columns, spacing: 8) { tile(typed) } }
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 8) {
                        if let title = section.title { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
                        LazyVGrid(columns: columns, spacing: 8) { ForEach(section.codes, id: \.raw) { tile($0) } }
                    }
                }
            }
            .padding(2)
            if results.isEmpty && typedCode == nil && !query.isEmpty {
                Text("No key matches “\(search)”.").foregroundStyle(.secondary).padding(.top, 16)
            }
        }
        if let fixedHeight { content.frame(height: fixedHeight) } else { content.frame(maxHeight: .infinity) }
    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 58, maximum: 76), spacing: 8)] }

    private func tile(_ code: Keycode) -> some View {
        var label = KeyLabels.label(for: code)
        if code.raw == 0 { label = KeyLabel(short: "None", long: label.long, style: .transparent) }
        return Button { onPick(code) } label: {
            // Every MO(n) key reads "Fn" on the keyboard picture, so the picker shows which layer each one is for.
            Keycap(label: label, width: 58, height: 48, selected: code == current, badge: code.name.hasPrefix("MO(") ? String(code.name.dropFirst(3).dropLast()) : nil)
        }
        .buttonStyle(KeycapButtonStyle())
        .help("\(label.long)  ·  \(code.name)")
    }
}


/// "Any": type a keycode as hex (for example 0x0029) and use it. Codes that would flash or wipe the keyboard are refused.
private struct AnyKeycodeField: View {
    let model: AppModel
    let onPick: (Keycode) -> Void
    private var text: Binding<String> { Binding(get: { model.anyKeycodeText }, set: { model.anyKeycodeText = $0 }) }

    private var code: Keycode? {
        let t = model.anyKeycodeText.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "0x", with: "")
        guard !t.isEmpty, t.count <= 4, let v = UInt16(t, radix: 16) else { return nil }
        return Keycode(raw: v)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("Any keycode").foregroundStyle(.secondary)
            TextField("Hex", text: text, prompt: Text("0x0029"))
                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 110)
            Button("Use") { if let code, !code.isDangerous { onPick(code) } }
                .buttonStyle(.bordered).disabled(code == nil || code?.isDangerous == true)
            if code?.isDangerous == true {
                Text("That code would put the keyboard into flash mode or erase it, so it is not allowed.").font(.caption).foregroundStyle(Theme.warning)
            } else if let code {
                Text(KeyLabels.label(for: code).long).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}


/// What the layer keys do, in a pop-over behind a "?".
private struct LayerHelp: View {
    let model: AppModel
    var body: some View {
        Label("What do these do?", systemImage: "questionmark.circle")
            .font(.caption).foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onHover { model.showingLayerHelp = $0 }
            .popover(isPresented: Binding(get: { model.showingLayerHelp }, set: { model.showingLayerHelp = $0 }), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach([
                        ("MO(n)", "Hold to use layer n. Let go and you are back where you were."),
                        ("TG(n)", "Tap to switch layer n on or off."),
                        ("TT(n)", "Hold it like MO. Tap it several times in a row and it toggles like TG."),
                        ("OSL(n)", "Layer n for the next key you press only."),
                        ("TO(n)", "Switch to layer n and stay there."),
                        ("DF(n)", "Make layer n the default one."),
                        ("Fn1(3), Fn2(3)", "Hold for layer 1 or 2. Hold both together for layer 3."),
                        ("Space Fn n", "Space when tapped, layer n while held."),
                    ], id: \.0) { item in
                        VStack(alignment: .leading, spacing: 1) { Text(item.0).font(.callout.weight(.semibold)); Text(item.1).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("After the keyboard loses power it starts on its default layer again.").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(14).frame(width: 320)
            }
    }
}
