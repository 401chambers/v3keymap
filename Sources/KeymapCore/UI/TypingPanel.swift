import SwiftUI
import ViaKit

/// Typing: how the keyboard filters key chatter (debounce) and what happens when two opposing keys are held (Snap Click).
struct TypingPanel: View {
    let model: AppModel

    var body: some View {
        if !model.supportsDebounce && !model.supportsSnapClick {
            ContentUnavailableView("No Typing Settings", systemImage: "slider.horizontal.3",
                                   description: Text("This keyboard does not report debounce or Snap Click settings."))
        } else {
            Form {
                if let debounce = model.working?.settings?.debounce { debounceSection(debounce) }
                if model.supportsSnapClick { snapClickSection }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: Debounce

    private func debounceSection(_ d: DebounceSettings) -> some View {
        let limit = d.type == .asymEagerDeferPerKey ? 127.0 : 255.0
        return Section {
            Picker("Method", selection: Binding(get: { d.type }, set: { model.setDebounce(DebounceSettings(type: $0, time: d.time)) })) {
                ForEach(DebounceType.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(d.type.summary).font(.callout).foregroundStyle(.secondary)
            LabeledContent("Delay") {
                HStack {
                    Slider(value: Binding(get: { Double(d.time) }, set: { model.setDebounce(DebounceSettings(type: d.type, time: UInt8($0.rounded()))) }), in: 0...limit)
                        .disabled(d.type == .none)
                    Text("\(d.time) ms").monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                }
            }
        } header: {
            Text("Debounce")
        } footer: {
            Text("Debounce stops one key press from registering twice. Too little can make a worn switch type double; too much makes keys feel slow. The change is saved on the keyboard when you press Apply.")
        }
    }

    // MARK: Snap Click

    private var snapClickSection: some View {
        let rows = model.snapClickVisibleRows
        return Section {
            if rows.isEmpty {
                Text("No pairs yet. A pair is two keys that fight each other, like A and D or left and right, so you can choose which one wins when both are held.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.self) { index in snapClickRow(index) }
            Button("Add a pair") { model.addSnapClickPair() }
                .disabled(rows.count >= (model.working?.settings?.snapClick?.count ?? 0))
        } header: {
            Text("Snap Click")
        } footer: {
            Text("Applies to ordinary keys. A pair needs both keys chosen before it can be applied.")
        }
    }

    private func snapClickRow(_ index: Int) -> some View {
        let slot = model.snapClickRow(index) ?? .empty
        let incomplete = model.snapClickRowIsIncomplete(index)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Picker("Type", selection: Binding(get: { slot.type }, set: { var s = slot; s.type = $0; model.setSnapClick(index: index, s) })) {
                    ForEach(SnapClickType.allCases.filter { $0 != .none }, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 180)
                keyButton(index, slot: slot, second: false)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                keyButton(index, slot: slot, second: true)
                Spacer(minLength: 0)
                Button { model.setSnapClick(index: index, .empty) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove this pair")
            }
            Text(incomplete ? "Choose both keys; this pair is not applied yet." : slot.type.summary)
                .font(.caption).foregroundStyle(incomplete ? Theme.warning : Color.secondary)
        }
        .padding(.vertical, 2)
    }

    private func keyButton(_ index: Int, slot: SnapClickSlot, second: Bool) -> some View {
        let code = second ? slot.key2 : slot.key1
        return Button { model.snapClickPicking = .init(index: index, isSecond: second) } label: {
            if code == 0 { Text("Choose a key…") } else { Text(KeyLabels.label(for: Keycode(raw: UInt16(code))).long) }
        }
        .popover(isPresented: Binding(get: { model.snapClickPicking == .init(index: index, isSecond: second) }, set: { if !$0 { model.snapClickPicking = nil } })) {
            BasicKeyChooser { key in
                var s = model.snapClickRow(index) ?? .empty
                if second { s.key2 = UInt8(key.raw) } else { s.key1 = UInt8(key.raw) }
                model.setSnapClick(index: index, s)
                model.snapClickPicking = nil
            }
        }
    }
}
