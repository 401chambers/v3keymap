import Foundation
import Testing
import ViaKit
import ViaKitTestSupport
@testable import KeymapCore

/// The Changes panel and the restore preview describe edits in the window's own words.
@MainActor
@Suite struct ChangeWordingTests {
    private func connected() async throws -> AppModel {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let model = AppModel(transportFactory: { kb },
                             backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("wording-tests-\(UUID().uuidString)"))
        await model.connect()
        return model
    }

    @Test func keyChangeNamesTheLayerAndBothKeys() async throws {
        let model = try await connected()
        let old = try #require(model.working?.keymap[0][0][0])
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        let text = model.describe(model.pending[0])
        #expect(text.hasPrefix("Mac Base: "))
        #expect(text.contains(KeyLabels.label(for: old).long))
        #expect(text.hasSuffix("→ Key A"))
        #expect(!text.contains("row"))
    }

    @Test func knobChangeSaysWhichWayItTurns() async throws {
        let model = try await connected()
        model.setEncoder(layer: 1, index: 0, clockwise: false, Keycode(raw: 0x00AA))
        #expect(model.describe(model.pending[0]).hasPrefix("Mac Fn knob, turn left: "))
    }

    @Test func macroChangeUsesSlotNames() async throws {
        let model = try await connected()
        try model.setMacro(slot: 3, steps: [.tap(Keycode(raw: 0x0004))])
        #expect(model.describe(model.pending[0]) == "Macros: M03 changed")
    }

    @Test func otherChangesStartWithACapital() async throws {
        let model = try await connected()
        var l = try #require(model.working?.lighting)
        l.brightness = l.brightness == 0 ? 1 : 0
        model.setLighting(l)
        let text = model.describe(model.pending[0])
        #expect(text.hasPrefix("Lighting: brightness"))
        #expect(!text.hasSuffix("."))
    }

    @Test func errorsShownAloneReadAsSentences() {
        #expect(AppModel.sentence("the keyboard did not answer in time") == "The keyboard did not answer in time.")
        #expect(AppModel.sentence("Already a sentence.") == "Already a sentence.")
        #expect(AppModel.sentence("") == "")
    }
}
