import Foundation
import Testing
@testable import ViaKit

@Suite struct KeycodeFamiliesTests {
    @Test func mouseKeysSitAtTheirQMKCodes() {
        #expect(Keycode(raw: 0x00CD).name == "KC_MS_UP")
        #expect(Keycode(raw: 0x00D1).name == "KC_BTN1")
        #expect(Keycode(raw: 0x00D9).name == "KC_WH_U")
        #expect(Keycode(raw: 0x00DF).name == "KC_ACL2")
        #expect(Keycode(raw: 0x00CD).category == .mouse && Keycode(raw: 0x00DF).category == .mouse)
        for raw in UInt16(0x00CD)...0x00DF { #expect(Keycode(name: Keycode(raw: raw).name)?.raw == raw, "\(raw)") }
        #expect(Keycode.all.contains(Keycode(raw: 0x00D1)))
    }

    @Test func modifierComboNamesAndValues() {
        #expect(Keycode.combo(mods: .shift, key: 0x04).raw == 0x0204)
        #expect(Keycode(raw: 0x0204).name == "LSFT(KC_A)")
        #expect(Keycode(raw: 0x0304).name == "LCTL+LSFT(KC_A)")
        #expect(Keycode(raw: 0x1204).name == "RSFT(KC_A)")
        #expect(Keycode(raw: 0x0204).category == .dualRole)
        let parts = Keycode(raw: 0x0A05).comboParts      // gui + shift, B
        #expect(parts?.mods == [.shift, .gui] && parts?.key == 0x05)
    }

    @Test func modTapNamesAndValues() {
        #expect(Keycode.modTap(mods: .shift, key: 0x04).raw == 0x2204)
        #expect(Keycode(raw: 0x2204).name == "MT(LSFT, KC_A)")
        #expect(Keycode(raw: 0x2304).name == "MT(LCTL+LSFT, KC_A)")
        #expect(Keycode(raw: 0x2204).modTapParts?.mods == .shift && Keycode(raw: 0x2204).modTapParts?.key == 0x04)
        #expect(Keycode(raw: 0x2204).category == .dualRole)
    }

    @Test func layerTapNamesAndValues() {
        #expect(Keycode.layerTap(layer: 1, key: 0x04).raw == 0x4104)
        #expect(Keycode(raw: 0x4104).name == "LT(1, KC_A)")
        #expect(Keycode(raw: 0x4104).layerTapParts?.layer == 1 && Keycode(raw: 0x4104).layerTapParts?.key == 0x04)
    }

    @Test func oneShotModifierNamesAndValues() {
        #expect(Keycode.oneShotMod(.shift).raw == 0x52A2)
        #expect(Keycode(raw: 0x52A2).name == "OSM(LSFT)")
        #expect(Keycode(raw: 0x52A2).category == .dualRole)
    }

    @Test func existingLayerAndOneShotLayerKeysAreUnchanged() {
        #expect(Keycode(raw: 0x5221).name == "MO(1)")
        #expect(Keycode(raw: 0x5283).name == "OSL(3)")
    }

    @Test func everyBuiltFamilyRoundTripsByNameAndByRawValue() {
        var samples: [Keycode] = []
        let modSets: [ModifierSet] = [.ctrl, .shift, [.ctrl, .shift], [.alt, .gui], [.shift, .right], [.ctrl, .alt, .shift, .gui]]
        for m in modSets { for key: UInt8 in [0x04, 0x1E, 0x29, 0x2C, 0xE1] {
            samples += [Keycode.combo(mods: m, key: key), Keycode.modTap(mods: m, key: key)]
        } }
        for layer in 0..<4 { samples.append(Keycode.layerTap(layer: layer, key: 0x2C)) }
        for m in modSets { samples.append(Keycode.oneShotMod(m)) }
        for k in samples {
            #expect(Keycode(name: k.name)?.raw == k.raw, "\(k.name)")
            #expect(k.category == .dualRole, "\(k.name)")
        }
    }

    @Test func modifierSetTokensRoundTrip() {
        #expect(ModifierSet([.ctrl, .shift]).tokens == ["LCTL", "LSFT"])
        #expect(ModifierSet([.ctrl, .gui, .right]).tokens == ["RCTL", "RGUI"])
        #expect(ModifierSet(tokens: ["LCTL", "LSFT"]) == [.ctrl, .shift])
        #expect(ModifierSet(tokens: ["LCTL", "RSFT"]) == nil)     // left and right cannot be mixed
        #expect(ModifierSet(tokens: ["XXXX"]) == nil)
    }

    @Test func unknownCodesInTheNewRangesStillRoundTripAsHex() {
        let odd = Keycode(raw: 0x7E7F)
        #expect(Keycode(name: odd.name)?.raw == 0x7E7F)
    }
}
