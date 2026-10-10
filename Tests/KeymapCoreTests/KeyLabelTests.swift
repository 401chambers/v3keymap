import Testing
import ViaKit
@testable import KeymapCore

@Suite struct KeyLabelTests {
    private func label(_ raw: UInt16) -> KeyLabel { KeyLabels.label(for: Keycode(raw: raw)) }

    @Test func everyDayKeysReadLikeTheKeyTop() {
        #expect(label(0x0029).short == "Esc")
        #expect(label(0x0004).short == "A")
        #expect(label(0x001E).short == "1")
        #expect(label(0x002A).short == "⌫")
        #expect(label(0x0028).short == "↩")
        #expect(label(0x002C).short == "Space")
        #expect(label(0x0052).short == "↑")
    }

    @Test func modifiersUseMacSymbolsAndAreStyledAsModifiers() {
        #expect(label(0x00E1).short == "⇧")
        #expect(label(0x00E0).short == "⌃")
        #expect(label(0x7E04).short == "⌘")      // Explicit left Command
        #expect(label(0x7E02).short == "⌥")      // Explicit left Option
        #expect(label(0x00E1).style == .modifier)
    }

    @Test func mediaKeysAreSpelledOutWithATint() {
        #expect(label(0x00BE).short == "Bright −")
        #expect(label(0x00BE).long == "Brightness down")
        #expect(label(0x00A9).short == "Vol +")
        #expect(label(0x00A8).long == "Mute")
        #expect(label(0x00A9).style == .media)
        #expect(label(0x00C1).long == "Mission Control")
    }

    @Test func layerMacroAndLightingKeysExplainThemselves() {
        #expect(label(0x5221).short == "Fn")
        #expect(label(0x5221).long == "Hold to use layer 1 (Mac Fn)")
        #expect(label(0x5221).style == .layer)
        #expect(label(0x7700 + 3).short == "M3")
        #expect(label(0x7700 + 3).style == .macro)
        #expect(label(0x7827).long == "Backlight: brightness up")
        #expect(label(0x7827).style == .lighting)
    }

    @Test func transparentAndEmptyKeys() {
        #expect(label(0x0001).short == "▽")
        #expect(label(0x0001).long == "Transparent: does what the layer below does")
        #expect(label(0x0001).style == .transparent)
        #expect(label(0x0000).short == "")
        #expect(label(0x0000).long == "Does nothing")
    }

    // Review Focus 5 again, for the new labels: unknown codes stay visible and exact.
    @Test func unknownCodesFallBackToHex() {
        #expect(label(0x7E7F).short == "0x7E7F")
        #expect(label(0x7E7F).long == "Unknown key 0x7E7F")
        #expect(label(0x7E7F).style == .special)
    }

    @Test func everyPickerKeycodeHasANonEmptyDescription() {
        for k in Keycode.all {
            let l = KeyLabels.label(for: k)
            #expect(!l.long.isEmpty, "\(k.name)")
            if k.raw != 0 { #expect(!l.short.isEmpty, "\(k.name)") }
        }
    }

    @Test func mouseKeysAreReadable() {
        #expect(label(0x00CD).short == "Mouse ↑" && label(0x00CD).long == "Move the mouse up")
        #expect(label(0x00D1).short == "Click" && label(0x00D1).long == "Left mouse button")
        #expect(label(0x00D9).short == "Scroll ↑")
        #expect(label(0x00D1).style == .mouse)
    }

    @Test func comboModTapLayerTapAndOneShotExplainThemselves() {
        #expect(label(0x0204).short == "⇧A")
        #expect(label(0x0204).long == "A with Shift")
        #expect(label(0x0304).short == "⌃⇧A")
        #expect(label(0x2204).short == "A/⇧")
        #expect(label(0x2204).long == "A when tapped, Shift when held")
        #expect(label(0x4104).short == "A/L1")
        #expect(label(0x4104).long == "A when tapped, layer 1 (Mac Fn) while held")
        #expect(label(0x52A2).short == "OS ⇧")
        #expect(label(0x52A2).long == "Shift for the next key only")
        #expect(label(0x0204).style == .dualRole && label(0x2204).style == .dualRole)
    }

    @Test func rightHandModifiersAreSaid() {
        #expect(label(0x1204).long == "A with Right Shift")
        #expect(label(0x1204).short == "⇧A")
    }
}
