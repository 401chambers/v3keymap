import Foundation
import Testing
import ViaKit
import ViaKitTestSupport
@testable import KeymapCore

@MainActor
@Suite struct DualRoleBuilderTests {
    private func model() -> AppModel {
        AppModel(transportFactory: { throw ViaError.disconnected }, backupDirectory: FileManager.default.temporaryDirectory)
    }

    @Test func comboNeedsAModifierAndAKey() {
        let m = model()
        m.builderKind = .combo
        #expect(m.builtKeycode == nil)                                  // nothing chosen yet
        m.builderMods = [.shift]
        #expect(m.builtKeycode == nil)                                  // still no key
        m.builderKey = 0x04
        #expect(m.builtKeycode?.raw == 0x0204)
        m.builderMods = []
        #expect(m.builtKeycode == nil)                                  // a combo without a modifier is just a key
    }

    @Test func modTapAndLayerTapBuildTheRightCodes() {
        let m = model()
        m.builderKind = .modTap
        m.builderMods = [.ctrl, .shift]
        m.builderKey = 0x2C
        #expect(m.builtKeycode?.raw == 0x232C)
        m.builderKind = .layerTap
        m.builderLayer = 2
        #expect(m.builtKeycode?.raw == 0x422C)
    }

    @Test func oneShotNeedsNoKey() {
        let m = model()
        m.builderKind = .oneShot
        #expect(m.builtKeycode == nil)
        m.builderMods = [.shift]
        #expect(m.builtKeycode?.raw == 0x52A2)
    }

    @Test func rightHandModifiersBuildTheRightHandCode() {
        let m = model()
        m.builderKind = .combo
        m.builderMods = [.shift, .right]
        m.builderKey = 0x04
        #expect(m.builtKeycode?.raw == 0x1204)
    }

    @Test func newPickerCategoriesCoverTheNewKeys() {
        #expect(PickerCategory.mouse.contains(Keycode(raw: 0x00D1)))
        #expect(!PickerCategory.keys.contains(Keycode(raw: 0x00D1)))
        #expect(PickerCategory.dualRole.contains(Keycode(raw: 0x2204)))
    }
}
