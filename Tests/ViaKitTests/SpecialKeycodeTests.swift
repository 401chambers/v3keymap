import Testing
@testable import ViaKit

@Suite struct SpecialKeycodeTests {
    @Test func specialKeysUseTheNumbersFromKeymapsLauncher() {
        #expect(Keycode(name: "NK_TOGG")?.raw == 0x7013)
        #expect(Keycode(name: "KC_GESC")?.raw == 0x7C16)
        #expect(Keycode(name: "SC_LSPO")?.raw == 0x7C1A)
        #expect(Keycode(name: "SC_SENT")?.raw == 0x7C1E)
        #expect(Keycode(name: "KC_HANJ")?.raw == 0x91)
        #expect(Keycode(name: "FN_MO13")?.raw == 0x7C77)
        #expect(Keycode(name: "FN_MO23")?.raw == 0x7C78)
        #expect(Keycode(raw: 0x7C77).category == .layer)
    }

    @Test func shiftedSymbolsAndLockScreenAreOnTheSpecialTab() {
        #expect(Keycode.specialRaws.contains(0x0235))   // ~
        #expect(Keycode.specialRaws.contains(0x0914))   // lock screen on Mac
        #expect(Keycode.specialRaws.contains(0x7C1A))
        #expect(!Keycode.specialRaws.contains(0x04))
    }

    @Test func spaceFnKeysAreLayerTapSpace() {
        #expect(Keycode.spaceFnRaws.count == 4)
        #expect(Keycode(raw: Keycode.spaceFnRaws[2]).layerTapParts?.layer == 2)
        #expect(Keycode(raw: Keycode.spaceFnRaws[2]).layerTapParts?.key == 0x2C)
    }

    @Test func flashAndEraseKeycodesAreRefused() {
        #expect(Keycode(raw: 0x7C00).isDangerous)
        #expect(Keycode(raw: 0x7C03).isDangerous)
        #expect(!Keycode(raw: 0x7C16).isDangerous)
    }

    @Test func noSpecialKeycodeSharesANameOrNumber() {
        let all = Keycode.all
        #expect(Set(all.map(\.raw)).count == all.count)
    }
}
