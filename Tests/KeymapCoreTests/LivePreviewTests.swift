import Foundation
import Testing
import ViaKit
import ViaKitTestSupport
@testable import KeymapCore

@MainActor
@Suite struct LivePreviewTests {
    private func connected() async throws -> (SimulatedKeyboard, AppModel) {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let model = AppModel(transportFactory: { kb }, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("extras-preview-\(UUID().uuidString)"))
        await model.connect()
        return (kb, model)
    }

    private func onKeyboard(_ kb: SimulatedKeyboard) async throws -> LightingState { try await ViaDevice(transport: kb).lighting() }
    private func wait() async { try? await Task.sleep(for: .milliseconds(400)) }
    /// Waits (up to two seconds) for the keyboard to show the lighting the preview sends; timing varies with machine load.
    private func waitForPreview(_ kb: SimulatedKeyboard, until shown: (LightingState) -> Bool) async throws -> LightingState {
        var live = try await onKeyboard(kb)
        for _ in 0..<100 where !shown(live) {
            try await Task.sleep(for: .milliseconds(20))
            live = try await onKeyboard(kb)
        }
        return live
    }

    @Test func lightingEditsShowOnTheKeyboardRightAwayWithoutBeingSaved() async throws {
        let (kb, model) = try await connected()
        var l = try #require(model.working?.lighting)
        l.effect = 2; l.brightness = 120; l.hue = 90
        model.setLighting(l)
        let live = try await waitForPreview(kb) { $0.effect == 2 && $0.brightness == 120 && $0.hue == 90 }
        #expect(live.effect == 2 && live.brightness == 120 && live.hue == 90)
        #expect(!kb.sentRequests.contains([0x09, 3]))          // nothing saved yet
        #expect(model.needsPreviewRestore)
    }

    @Test func changesMadeWithTheKeyboardsOwnKeysAreFollowed() async throws {
        let (kb, model) = try await connected()
        let saved = try #require(model.onDevice?.lighting)
        var pressed = saved; pressed.effect = 5; pressed.speed = 31
        try await ViaDevice(transport: kb).previewLighting(pressed, from: saved)      // what a backlight key does on the keyboard
        try? await Task.sleep(for: .milliseconds(1800))
        #expect(model.working?.lighting.effect == 5 && model.working?.lighting.speed == 31)
        #expect(model.onDevice?.lighting.effect == 5)
        #expect(!model.needsPreviewRestore && model.pending.isEmpty)
    }

    @Test func revertPutsTheSavedLightingBack() async throws {
        let (kb, model) = try await connected()
        let saved = try #require(model.onDevice?.lighting)
        var l = saved; l.effect = 3; l.speed = 40
        model.setLighting(l)
        await wait()
        model.discardPending()
        await wait()
        let live = try await onKeyboard(kb)
        #expect(live.effect == saved.effect && live.speed == saved.speed)
        #expect(!model.needsPreviewRestore)
    }

    @Test func applyKeepsWhatWasPreviewedAndSavesIt() async throws {
        let (kb, model) = try await connected()
        var l = try #require(model.working?.lighting)
        l.effect = 2; l.hue = 33
        model.setLighting(l)
        await wait()
        await model.applyPending()
        #expect(model.pending.isEmpty && !model.needsPreviewRestore)
        #expect(kb.sentRequests.contains([0x09, 3]))
        let live = try await onKeyboard(kb)
        #expect(live.effect == 2 && live.hue == 33)
    }

    @Test func quittingRestoresTheSavedLighting() async throws {
        let (kb, model) = try await connected()
        let saved = try #require(model.onDevice?.lighting)
        var l = saved; l.effect = 4
        model.setLighting(l)
        await wait()
        await model.restoreLivePreview()
        #expect(try await onKeyboard(kb).effect == saved.effect)
    }

    @Test func perKeyPaintShowsLiveToo() async throws {
        let (kb, model) = try await connected()
        await model.setLightingMode(.perKey)
        await wait()
        model.toggleSelection(MatrixPosition(row: 1, col: 1))
        model.paintSelected(HSVColor(h: 10, s: 200, v: 255))
        await wait()
        let device = ViaDevice(transport: kb)
        let live = try await device.perKeyRGB()
        #expect(live.colors.contains(HSVColor(h: 10, s: 200, v: 255)))
    }

    // Audit A2 (probe A): a partial apply failure that is not a disconnect re-reads the keyboard. The read returns the
    // live, previewed lighting, which must not be mistaken for the saved look: the lighting edit stays pending.
    @Test func partialFailureKeepsPreviewedLightingPending() async throws {
        let (kb, model) = try await connected()
        let saved = try #require(model.onDevice?.lighting)
        var l = saved; l.effect = 2; l.hue = 33
        model.setLighting(l)
        await wait()
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        kb.ignoreWrites = true
        await model.applyPending()
        kb.ignoreWrites = false
        #expect(model.pending.count == 2)
        #expect(model.onDevice?.lighting == saved)
        #expect(!kb.sentRequests.contains([0x09, 3]))     // lighting was never saved
        #expect(model.needsPreviewRestore)
    }

    // Review Focus 2: the existing disconnect branch must still carry the lighting edit through to reconnect.
    @Test func disconnectDuringApplyStillCarriesTheLightingEdit() async throws {
        let (kb, model) = try await connected()
        var l = try #require(model.onDevice?.lighting); l.effect = 2; l.hue = 33
        model.setLighting(l)
        await wait()
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        kb.failAfter = kb.exchangeCount + 1
        await model.applyPending()
        kb.failAfter = nil
        #expect(model.state == .disconnected)
        #expect(model.pending.count == 2)
    }
}
