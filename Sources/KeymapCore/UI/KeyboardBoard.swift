import SwiftUI
import ViaKit

/// The keyboard picture: every keycap in its place, on a quiet plate.
struct KeyboardBoard: View {
    let layout: LayoutDefinition
    let keymap: [[Keycode]]
    let original: [[Keycode]]
    var pressed: Set<MatrixPosition> = []
    var selected: MatrixPosition?
    var knobHighlighted = false
    var knobTurns: KnobTurns?
    var knobChanged = false
    /// Keys picked for painting or zone assignment (per-key and Mixed lighting).
    var selection: Set<MatrixPosition> = []
    /// The colour of the LED under a key; nil draws the normal keycap.
    var ledColour: ((MatrixPosition) -> Color?)?
    /// The Mix RGB zone of a key's LED; tints the cap and shows its number.
    var zoneOf: ((MatrixPosition) -> Int?)?
    /// Key Test: how many times a key has been pressed; shown as a small number on the cap once above zero.
    var pressCount: ((MatrixPosition) -> Int)?
    var knobFlashLeft = false
    var knobFlashRight = false
    /// False draws the board without its glass (the offline preview, where there is nothing behind it to refract).
    var glass = true
    let onSelect: (MatrixPosition) -> Void

    private var widthUnits: CGFloat { CGFloat(layout.keys.map { $0.x + $0.width }.max() ?? 18) }
    private var heightUnits: CGFloat { CGFloat(layout.keys.map { $0.y + $0.height }.max() ?? 6) }

    var body: some View {
        GeometryReader { geo in
            let pad: CGFloat = 16
            let unit = max(10, min((geo.size.width - pad * 2) / widthUnits, (geo.size.height - pad * 2) / heightUnits))
            ZStack(alignment: .topLeading) {
                ForEach(layout.keys, id: \.self.matrixID) { key in
                    let pos = MatrixPosition(row: key.row, col: key.col)
                    let code = keymap[key.row][key.col]
                    let led = ledColour?(pos)
                    Button { onSelect(pos) } label: {
                        if pos == KnobLayout.press {
                            KnobView(diameter: unit * CGFloat(key.width) - 4,
                                     highlighted: knobHighlighted, selected: selected == pos,
                                     changed: knobChanged || code != original[key.row][key.col], pressed: pressed.contains(pos),
                                     flashLeft: knobFlashLeft, flashRight: knobFlashRight)
                        } else {
                            Keycap(label: KeyLabels.label(for: code),
                                   width: unit * CGFloat(key.width) - 4, height: unit * CGFloat(key.height) - 4,
                                   selected: selected == pos || selection.contains(pos), changed: code != original[key.row][key.col], pressed: pressed.contains(pos),
                                   fill: led ?? zoneOf?(pos).map(Self.zoneColour), badge: zoneOf?(pos).map { "\($0 + 1)" } ?? pressCount.flatMap { c in c(pos) > 0 ? "\(c(pos))" : nil },
                                   legend: led.map { $0.isDark ? Color.white : Color.black })
                        }
                    }
                    .buttonStyle(KeycapButtonStyle())
                    .help(pos == KnobLayout.press ? knobHelp(code) : KeyLabels.label(for: code).long)
                    .position(x: unit * CGFloat(key.x + key.width / 2) + pad, y: unit * CGFloat(key.y + key.height / 2) + pad)
                }
            }
            .frame(width: unit * widthUnits + pad * 2, height: unit * heightUnits + pad * 2, alignment: .topLeading)
            .glassEffect(glass ? .regular : .identity, in: .rect(cornerRadius: Theme.boardRadius))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio((widthUnits + 1.4) / (heightUnits + 1.4), contentMode: .fit)
    }
}

extension KeyboardBoard {
    fileprivate func knobHelp(_ press: Keycode) -> String {
        var text = "Knob press: \(KeyLabels.label(for: press).long)"
        if let t = knobTurns { text += "\nTurn left: \(t.left.long)\nTurn right: \(t.right.long)" }
        return text
    }
}

extension KeyboardBoard {
    /// Colours for the Mix RGB zones.
    static func zoneColour(_ zone: Int) -> Color { [Color.blue, .orange, .green, .pink][zone % 4].opacity(0.45) }
}

extension KeyPosition {
    var matrixID: Int { row * 100 + col }
}
