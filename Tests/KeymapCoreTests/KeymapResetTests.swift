import Foundation
import Testing
import ViaKit
import ViaKitTestSupport
@testable import KeymapCore

@MainActor
@Suite struct KeymapResetTests {
    private func connected() async throws -> (SimulatedKeyboard, AppModel, URL) {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("extras-reset-tests-\(UUID().uuidString)")
        let model = AppModel(transportFactory: { kb }, backupDirectory: dir)
        await model.connect()
        return (kb, model, dir)
    }

    @Test func resetPutsTheFactoryKeysBackSavesABackupAndLeavesMacrosAlone() async throws {
        let (kb, model, dir) = try await connected()
        let factory = try #require(model.onDevice)
        model.setKey(layer: 0, row: 1, col: 1, Keycode(raw: 0x04))
        model.setEncoder(layer: 0, index: 0, clockwise: true, Keycode(raw: 0x05))
        await model.applyPending()
        #expect(model.pending.isEmpty && model.onDevice?.keymap[0][1][1] == Keycode(raw: 0x04))

        await model.resetKeymapToFactory()
        #expect(model.errorMessage == nil)
        #expect(model.onDevice?.keymap == factory.keymap)
        #expect(model.onDevice?.encoders == factory.encoders)
        #expect(model.working == model.onDevice)
        #expect(model.onDevice?.macros == factory.macros && model.onDevice?.lighting == factory.lighting)
        #expect(kb.sentRequests.contains([0x06]))
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("before-keymap-reset") }
        #expect(backups.count == 1)
    }

    @Test func resetDiscardsUnappliedEdits() async throws {
        let (_, model, _) = try await connected()
        let factory = try #require(model.onDevice)
        model.setKey(layer: 2, row: 0, col: 0, Keycode(raw: 0x04))
        #expect(!model.pending.isEmpty)
        await model.resetKeymapToFactory()
        #expect(model.pending.isEmpty && model.working?.keymap == factory.keymap)
    }

    // Audit A3 (probe C): the post-reset read returns the live preview. The saved lighting must stay the saved lighting,
    // nothing is saved to the keyboard, and the preview mechanism puts the saved look back on the keyboard.
    @Test func resetKeepsTheSavedLightingAndRestoresIt() async throws {
        let (kb, model, _) = try await connected()
        let saved = try #require(model.onDevice?.lighting)
        var l = saved; l.effect = 3; l.speed = 40
        model.setLighting(l)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await ViaDevice(transport: kb).lighting().effect == 3)      // the preview is showing
        await model.resetKeymapToFactory()
        #expect(model.errorMessage == nil)
        #expect(model.onDevice?.lighting == saved)
        #expect(model.pending.isEmpty)
        #expect(!kb.sentRequests.contains([0x09, 3]))                            // never saved
        try await Task.sleep(for: .milliseconds(400))
        let live = try await ViaDevice(transport: kb).lighting()
        #expect(live.effect == saved.effect && live.speed == saved.speed)       // the saved look is back
        #expect(!model.needsPreviewRestore)
    }

    // Audit A3: a reset that never happened must not throw away the edits that were waiting.
    @Test func failedResetKeepsUnappliedEdits() async throws {
        let (kb, model, _) = try await connected()
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        kb.replyTransform = { _, reply in reply[0] == 0x06 ? [0xFF] + [UInt8](repeating: 0, count: 31) : reply }   // only the reset fails
        await model.resetKeymapToFactory()
        kb.replyTransform = nil
        #expect(model.working?.keymap[0][0][0].raw == 0x0004)
        #expect(model.errorMessage?.hasPrefix("The keymap was not reset") == true)
    }
}
