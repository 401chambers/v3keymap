import Foundation
import Testing
import ViaKit
import ViaKitTestSupport
@testable import KeymapCore

@MainActor
@Suite struct ReconnectTests {
    private func connected() async throws -> (SimulatedKeyboard, AppModel) {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let model = AppModel(transportFactory: { kb },
                             backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("extras-app-tests-\(UUID().uuidString)"))
        await model.connect()
        return (kb, model)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // Review Focus 1, end to end: the user's edits must survive an unplug and a reconnect.
    @Test func unappliedEditsSurviveUnplugAndReconnect() async throws {
        let (kb, model) = try await connected()
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        model.setKey(layer: 0, row: 0, col: 1, Keycode(raw: 0x0005))
        kb.failAfter = kb.exchangeCount          // the cable goes before anything is written
        await model.applyPending()
        #expect(model.state == .disconnected)
        #expect(model.pending.count == 2)

        kb.replug()
        await model.connect()
        #expect(model.state == .connected)
        #expect(model.pending.count == 2)

        await model.applyPending()
        #expect(model.pending.isEmpty)
        let onKeyboard = try await ViaDevice(transport: kb).keymap(layers: 4, size: .v3)
        #expect(onKeyboard[0][0][0].raw == 0x0004 && onKeyboard[0][0][1].raw == 0x0005)
    }

    // If the first write did land before the cable went, the reconnect shows the truth: only the second is left.
    @Test func reconnectShowsWhatActuallyLanded() async throws {
        let (kb, model) = try await connected()
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        model.setKey(layer: 0, row: 0, col: 1, Keycode(raw: 0x0005))
        kb.failAfter = kb.exchangeCount + 1      // first key's write lands, its read-back fails
        await model.applyPending()
        kb.replug()
        await model.connect()
        #expect(model.state == .connected)
        #expect(model.pending.count == 1)
        #expect(model.onDevice?.keymap[0][0][0].raw == 0x0004)
    }

    // A second window (or any repeated connect) must not wipe edits or open a second session.
    @Test func connectWhileConnectedChangesNothing() async throws {
        let (kb, model) = try await connected()
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        let sent = kb.sentCommands.count
        await model.connect()
        #expect(model.pending.count == 1)
        #expect(kb.sentCommands.count == sent)
    }

    // Unplugging while idle must be noticed without waiting for the next write.
    @Test func idleUnplugShowsDisconnected() async throws {
        let (kb, model) = try await connected()
        kb.unplug()
        await waitUntil { model.state == .disconnected }
        #expect(model.state == .disconnected)
        #expect(model.errorMessage != nil)
    }

    // After a failure part-way through, the app must show what the keyboard really holds.
    @Test func afterAPartialFailureTheAppReReadsTheKeyboard() async throws {
        let (kb, model) = try await connected()
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        model.setKey(layer: 0, row: 0, col: 1, Keycode(raw: 0x0005))
        // key 1: set+read-back; key 2: set succeeds, its read-back reply is cut short.
        kb.truncateAtRequest = kb.exchangeCount + 4
        await model.applyPending()
        #expect(model.state == .connected)
        let onKeyboard = try await ViaDevice(transport: kb).keymap(layers: 4, size: .v3)
        #expect(onKeyboard[0][0][1].raw == 0x0005)                       // the write did land
        #expect(model.onDevice?.keymap[0][0][1].raw == 0x0005)           // and the app knows it
        #expect(model.pending.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test func aMacroTheAppCannotReadDoesNotBlockConnecting() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        kb.setMacroBuffer([0x01, 0x09, 0x41, 0x00])
        let model = AppModel(transportFactory: { kb }, backupDirectory: FileManager.default.temporaryDirectory)
        await model.connect()
        #expect(model.state == .connected)
        #expect(model.working?.macros[0] == [.raw([0x01, 0x09, 0x41])])
    }

    // Audit B1 (probe E): a matrix poll that fails marks the keyboard disconnected and stops Key Test; once the keyboard is
    // back and Key Test is still the open panel, the polling resumes by itself.
    @Test func keyTestResumesAfterReconnect() async throws {
        let (kb, model) = try await connected()
        model.selectedPanel = .keyTest
        try await Task.sleep(for: .milliseconds(100))
        kb.failAfter = kb.exchangeCount
        await waitUntil { model.state == .disconnected }
        #expect(model.state == .disconnected)
        kb.failAfter = nil
        await model.connect(quietly: true)
        #expect(model.state == .connected)
        let before = kb.sentRequests.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(kb.sentRequests[before...].contains([0x02, 0x03]))      // switch-matrix polls resumed
    }

    // Audit B2 (probe D): the background search and a click on Connect at the same moment must not read the keyboard twice.
    @Test func concurrentConnectRunsOneSessionRead() async throws {
        let (kb, model) = try await connected()
        kb.unplug()
        await waitUntil { model.state == .disconnected }
        kb.replug()
        let before = kb.sentCommands.filter { $0 == 0x11 }.count          // layer count: read once per session
        let quiet = Task { await model.connect(quietly: true) }
        await Task.yield()
        await model.connect()
        await quiet.value
        #expect(model.state == .connected)
        #expect(kb.sentCommands.filter { $0 == 0x11 }.count - before == 1)
    }

    // Review finding: a keyboard that already holds QK_BOOT on a layer must not have the user's edits dropped on reconnect.
    @Test func carriedEditsSurviveReconnectWhenTheKeyboardHoldsABootKey() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        kb.seedKeycode(layer: 3, row: 0, col: 12, 0x7C00)
        let model = AppModel(transportFactory: { kb }, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("extras-app-tests-\(UUID().uuidString)"))
        await model.connect()
        #expect(model.state == .connected)
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        kb.unplug()
        await waitUntil { model.state == .disconnected }
        kb.replug()
        await model.connect()
        #expect(model.state == .connected)
        #expect(model.pending.count == 1)
        #expect(model.errorMessage == nil)
        await model.applyPending()
        #expect(model.pending.isEmpty)
    }

    // Audit B3: the unplug alert must not outlive a successful quiet reconnect.
    @Test func quietReconnectClearsTheUnplugAlert() async throws {
        let (kb, model) = try await connected()
        kb.unplug()
        await waitUntil { model.state == .disconnected }
        #expect(model.errorMessage != nil)
        kb.replug()
        await model.connect(quietly: true)
        #expect(model.state == .connected)
        #expect(model.errorMessage == nil)
    }
}
