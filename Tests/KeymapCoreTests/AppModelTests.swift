import Foundation
import Testing
import ViaKit
import ViaKitTestSupport
@testable import KeymapCore

@MainActor
@Suite struct AppModelTests {
    private func makeModel(_ kb: SimulatedKeyboard) -> AppModel {
        AppModel(transportFactory: { kb },
                 backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("extras-app-tests-\(UUID().uuidString)"))
    }

    private func connected() async throws -> (SimulatedKeyboard, AppModel) {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let model = makeModel(kb)
        await model.connect()
        return (kb, model)
    }

    @Test func connectReadsTheKeyboard() async throws {
        let (_, model) = try await connected()
        #expect(model.state == .connected)
        #expect(model.working?.keymap.count == 4)
        #expect(model.pending.isEmpty)
    }

    @Test func settingAKeyIsPendingAndDoesNotTouchTheDevice() async throws {
        let (kb, model) = try await connected()
        let sent = kb.sentCommands.count
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        #expect(model.pending.count == 1)
        #expect(kb.sentCommands.count == sent)
    }

    @Test func revertingAKeyEmptiesPending() async throws {
        let (_, model) = try await connected()
        let original = try #require(model.working?.keymap[0][0][0])
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        model.setKey(layer: 0, row: 0, col: 0, original)
        #expect(model.pending.isEmpty)
    }

    @Test func missingKeyboardMeansNotFound() async {
        let model = AppModel(transportFactory: { throw ViaError.disconnected }, backupDirectory: FileManager.default.temporaryDirectory)
        await model.connect()
        #expect(model.state == .notFound)
    }

    @Test func deniedAccessMeansPermissionDenied() async {
        let model = AppModel(transportFactory: { throw ViaError.permissionDenied }, backupDirectory: FileManager.default.temporaryDirectory)
        await model.connect()
        #expect(model.state == .permissionDenied)
    }

    @Test func unexpectedProtocolMeansWrongDevice() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        kb.protocolVersionOverride = 0x0009
        let model = makeModel(kb)
        await model.connect()
        guard case .wrongDevice = model.state else { Issue.record("state was \(model.state)"); return }
        #expect(model.working == nil)
    }

    @Test func applyWritesPendingAndMakesABackup() async throws {
        let (kb, model) = try await connected()
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        await model.applyPending()
        #expect(model.pending.isEmpty)
        #expect(model.lastBackupURL != nil)
        let onDevice = try await ViaDevice(transport: kb).keymap(layers: 4, size: .v3)
        #expect(onDevice[0][0][0].raw == 0x0004)
    }

    // Review Focus 1
    @Test func unplugDuringApplyKeepsEveryEditAndShowsDisconnected() async throws {
        let (kb, model) = try await connected()
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        model.setKey(layer: 0, row: 0, col: 1, Keycode(raw: 0x0005))
        kb.failAfter = kb.exchangeCount + 1
        await model.applyPending()
        #expect(model.state == .disconnected)
        #expect(model.pending.count == 2)
        #expect(model.errorMessage != nil)
        #expect(model.lastBackupURL != nil)   // the user can still find the backup after a failed apply
    }

    @Test func unplugAfterFirstKeyKeepsOnlyTheUnwrittenOne() async throws {
        let (kb, model) = try await connected()
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        model.setKey(layer: 0, row: 0, col: 1, Keycode(raw: 0x0005))
        kb.failAfter = kb.exchangeCount + 2
        await model.applyPending()
        #expect(model.state == .disconnected)
        #expect(model.pending.count == 1)
    }

    // MARK: Knob

    @Test func changingTheKnobIsPendingAndNamesTheKnob() async throws {
        let (_, model) = try await connected()
        model.setEncoder(layer: 0, index: 0, clockwise: true, Keycode(raw: 0x00AA))
        #expect(model.pending.count == 1)
        #expect(model.pending[0].description.contains("knob"))
        model.setEncoder(layer: 0, index: 0, clockwise: true, Keycode(raw: 0x00A9))   // original value
        #expect(model.pending.isEmpty)
    }

    // MARK: Key Test

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func keyTestShowsHeldKeysAndStopsWhenAsked() async throws {
        let (kb, model) = try await connected()
        let before = kb.sentCommands.count
        kb.heldKeys = [[0, 0]]
        model.startKeyTest()
        await waitUntil { model.pressedKeys == [MatrixPosition(row: 0, col: 0)] }
        #expect(model.pressedKeys == [MatrixPosition(row: 0, col: 0)])

        model.stopKeyTest()
        #expect(model.pressedKeys.isEmpty)
        let after = kb.sentCommands.count
        try? await Task.sleep(for: .milliseconds(150))
        #expect(kb.sentCommands.count == after)                       // polling really stopped
        #expect(Set(kb.sentCommands[before...]) == [0x02])            // and it only ever read the matrix
    }

    @Test func keyTestStopsWhenTheKeyboardDisappears() async throws {
        let (kb, model) = try await connected()
        kb.failAfter = kb.exchangeCount + 3
        model.startKeyTest()
        await waitUntil { model.state == .disconnected }
        #expect(model.state == .disconnected)
        #expect(model.pressedKeys.isEmpty)
    }

    // Audit D1 / Review Focus 4: switching macro slots must not throw away Code Input text typed for another slot.
    @Test func codeInputDraftsAreKeptPerSlot() throws {
        let m = makeModel(try SimulatedKeyboard(fixtures: fixturesURL()))
        m.macroSlot = 0
        m.macroCodeDraft = "tap KC_A"
        m.macroSlot = 3
        #expect(m.macroCodeDraft == nil)
        m.macroSlot = 0
        #expect(m.macroCodeDraft == "tap KC_A")
    }

    @Test func applyingCodeInputClearsOnlyThatSlotsDraft() async throws {
        let (_, m) = try await connected()
        m.macroSlot = 1; m.macroCodeDraft = "tap KC_A"
        m.macroSlot = 2; m.macroCodeDraft = "not a step"
        m.macroSlot = 1
        m.applyMacroCode()
        #expect(m.macroCodeDraft == nil && m.macroCodeError == nil)
        #expect(m.working?.macros[1] == [.tap(Keycode(raw: 0x0004))])
        m.macroSlot = 2
        #expect(m.macroCodeDraft == "not a step")
    }
}
