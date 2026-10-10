import SwiftUI

/// A row of rounded tabs on one glass bar, like the tab rows of Keychron's Launcher. Scrolls sideways when the window is narrow.
struct TabStrip<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    @Environment(\.colorScheme) private var scheme

    private var row: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                let on = item == selection
                Button { selection = item } label: {
                    Text(title(item).titleCased)
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background { if on { Capsule().fill(Theme.selectionWash(scheme)) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
    }

    /// As wide as its tabs need (left aligned); scrolls sideways only when the window is too narrow for them.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row.glassEffect(.regular, in: .capsule).frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) { row }.glassEffect(.regular, in: .capsule)
        }
    }
}
