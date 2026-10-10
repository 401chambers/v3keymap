import SwiftUI

/// The handful of values the views share, so a change in one place changes them everywhere.
enum Theme {
    /// Corner radius of a pane (the glass cards under the keyboard picture).
    static let paneRadius: CGFloat = 22
    /// Corner radius of the keyboard picture's plate.
    static let boardRadius: CGFloat = 26
    /// Corner radius of an inset inside a pane: a notice strip, a text editor, a selectable row.
    static let insetRadius: CGFloat = 12
    /// Corner radius of a list row inside a pane.
    static let rowRadius: CGFloat = 10
    /// The gap between panes, and between a pane and the strip above it.
    static let paneGap: CGFloat = 14
    /// Padding inside a pane.
    static let panePadding: CGFloat = 14

    /// A faint wash that sets an inset apart from the glass it sits on.
    static let insetWash = Color.primary.opacity(0.06)
    /// The wash on a selected tab or row: the Apply blue, a little stronger in Dark mode where it has less to stand out from.
    static func selectionWash(_ scheme: ColorScheme) -> Color { ApplyGlassStyle.blue.opacity(scheme == .dark ? 0.55 : 0.45) }
    /// Marks a key, knob or row that differs from what the keyboard has.
    static let changed = Color.orange
    /// Shows a key that is held down (Key Test).
    static let pressed = Color.green
    /// Inline warnings beside a field: a value the keyboard would refuse, a pair that is not complete.
    static let warning = Color.orange
}

extension View {
    /// The glass card every pane is drawn on.
    func paneCard() -> some View {
        padding(Theme.panePadding).glassEffect(.regular, in: .rect(cornerRadius: Theme.paneRadius))
    }
}
