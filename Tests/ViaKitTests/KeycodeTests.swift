import Foundation
import Testing
@testable import ViaKit

@Suite struct KeycodeTests {
    @Test func namesFromThisKeyboard() {
        #expect(Keycode(raw: 0x0029).name == "KC_ESC")
        #expect(Keycode(raw: 0x7C00).name == "QK_BOOT" && Keycode(raw: 0x7C03).name == "QK_CLEAR_EEPROM")   // named so refusals read well
        #expect(Keycode(name: "QK_BOOT") == Keycode(raw: 0x7C00))
        #expect(!Keycode.all.contains(Keycode(raw: 0x7C00)) && !Keycode.all.contains(Keycode(raw: 0x7C03)))  // but never offered
        #expect(Keycode(raw: 0x00A9).name == "KC_VOLU")
        #expect(Keycode(raw: 0x00AA).name == "KC_VOLD")
    }

    @Test func layerKeysDecode() {
        #expect(Keycode(raw: 0x5221).name == "MO(1)")
        #expect(Keycode(raw: 0x5221).category == .layer)
        #expect(Keycode(raw: 0x5223).name == "MO(3)")
    }

    @Test func nameRoundTripForEveryPickerKeycode() {
        for k in Keycode.all {
            #expect(Keycode(name: k.name)?.raw == k.raw, "\(k.name)")
        }
    }

    @Test func pickerKeycodesAreUnique() {
        #expect(Set(Keycode.all.map(\.raw)).count == Keycode.all.count)
        #expect(Set(Keycode.all.map(\.name)).count == Keycode.all.count)
    }

    @Test func unknownKeycodePreserved() throws {
        let k = Keycode(raw: 0x7E7F)
        #expect(!k.name.isEmpty)
        #expect(k.raw == 0x7E7F)
        #expect(Keycode(name: k.name)?.raw == 0x7E7F)
        let data = try JSONEncoder().encode([k])
        let back = try JSONDecoder().decode([Keycode].self, from: data)
        #expect(back[0].raw == 0x7E7F)
    }

    /// Positions on this keyboard show what these are: Option/Command pairs next to the space bar on the Mac layer,
    /// Siri/screenshot at the top right, and Task View / File Explorer where Mac has Mission Control / Launchpad.
    @Test func keymapSpecialKeysHaveNames() {
        let expected: [(UInt16, String)] = [
            (0x7E02, "KC_LOPTN"), (0x7E03, "KC_ROPTN"), (0x7E04, "KC_LCMMD"), (0x7E05, "KC_RCMMD"),
            (0x7E06, "KC_SIRI"), (0x7E07, "KC_TASK"), (0x7E08, "KC_FILE"), (0x7E09, "KC_SNAP"), (0x7E0A, "KC_CTANA"),
        ]
        for (raw, name) in expected {
            #expect(Keycode(raw: raw).name == name)
            #expect(Keycode(raw: raw).category == .device)
            #expect(Keycode(name: name)?.raw == raw)
        }
    }
}
