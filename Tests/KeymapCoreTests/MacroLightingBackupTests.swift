import Foundation
import Testing
import ViaKit
import ViaKitTestSupport
@testable import KeymapCore

@MainActor
@Suite struct MacroLightingBackupTests {
    private func connected() async throws -> (SimulatedKeyboard, AppModel) {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let model = AppModel(transportFactory: { kb },
                             backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("extras-app-tests-\(UUID().uuidString)"))
        await model.connect()
        return (kb, model)
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("extras-backup-\(UUID().uuidString).json")
    }

    // MARK: Macros

    @Test func editingAMacroIsPending() async throws {
        let (_, model) = try await connected()
        try model.setMacro(slot: 1, steps: [.text("hi"), .tap(Keycode(raw: 0x28))])
        #expect(model.pending.count == 1)
        #expect(model.pending[0].description.contains("M01"))
    }

    // Review Focus 3
    @Test func oversizedMacroIsRejectedAndLeavesEverythingAlone() async throws {
        let (kb, model) = try await connected()
        let sent = kb.sentCommands.count
        #expect(throws: ViaError.self) {
            try model.setMacro(slot: 0, steps: [.text(String(repeating: "a", count: 1750))])
        }
        #expect(model.pending.isEmpty)
        #expect(kb.sentCommands.count == sent)
    }

    @Test func nonASCIIMacroTextIsRejected() async throws {
        let (_, model) = try await connected()
        #expect(throws: ViaError.self) { try model.setMacro(slot: 0, steps: [.text("café")]) }
        #expect(model.pending.isEmpty)
    }

    @Test func appliedMacroReachesTheKeyboard() async throws {
        let (kb, model) = try await connected()
        try model.setMacro(slot: 2, steps: [.text("abc")])
        await model.applyPending()
        #expect(model.pending.isEmpty)
        let onKeyboard = try await ConfigStore.read(from: ViaDevice(transport: kb))
        #expect(onKeyboard.macros[2] == [.text("abc")])
    }

    // MARK: Lighting

    @Test func changingBrightnessIsOnePendingChange() async throws {
        let (_, model) = try await connected()
        var l = try #require(model.working?.lighting)
        l.brightness = 100
        model.setLighting(l)
        #expect(model.pending.count == 1)
        #expect(model.pending[0].description.contains("brightness"))
    }

    // MARK: Backup and restore

    @Test func previewOfAModifiedBackupListsExactlyTheDifferencesAndWritesNothing() async throws {
        let (kb, model) = try await connected()
        var modified = try #require(model.onDevice)
        modified.keymap[0][0][0] = Keycode(raw: 0x0004)
        modified.lighting.speed = 10
        let url = tempFile()
        try ConfigStore.save(modified, to: url)
        let sent = kb.sentCommands.count
        let changes = try model.previewRestore(from: url)
        #expect(changes.count == 2)
        #expect(kb.sentCommands.count == sent)
    }

    @Test func exportThenPreviewOfTheSameFileIsEmpty() async throws {
        let (_, model) = try await connected()
        let url = tempFile()
        try model.exportBackup(to: url)
        #expect(try model.previewRestore(from: url).isEmpty)
    }

    // Review Focus 4
    @Test func restoreFromADifferentKeyboardIsRefused() async throws {
        let (kb, model) = try await connected()
        var other = try #require(model.onDevice)
        other.productID = 0x0999
        let url = tempFile()
        try ConfigStore.save(other, to: url)
        let sent = kb.sentCommands.count
        await #expect(throws: ViaError.self) { try await model.restore(from: url) }
        #expect(kb.sentCommands.count == sent)
    }

    @Test func restoreWritesTheBackupToTheKeyboard() async throws {
        let (kb, model) = try await connected()
        var backup = try #require(model.onDevice)
        backup.keymap[2][0][1] = Keycode(raw: 0x0005)
        let url = tempFile()
        try ConfigStore.save(backup, to: url)
        try await model.restore(from: url)
        #expect(model.pending.isEmpty)
        let onKeyboard = try await ViaDevice(transport: kb).keymap(layers: 4, size: .v3)
        #expect(onKeyboard[2][0][1].raw == 0x0005)
        #expect(model.lastBackupURL != nil)   // the keyboard's previous state was saved first
    }

    // MARK: Restore

    private func backupFile(changing before: KeyboardConfig) throws -> URL {
        var backup = before
        backup.keymap[2][0][1] = Keycode(raw: 0x0005)
        let url = tempFile()
        try ConfigStore.save(backup, to: url)
        return url
    }

    // Audit A4 (probe B): after an earlier apply the engine's once-per-session backup is spent, so restore must save its own.
    @Test func restoreBacksUpTheStateItOverwrites() async throws {
        let (_, model) = try await connected()
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        await model.applyPending()
        let before = try #require(model.onDevice)
        try await model.restore(from: backupFile(changing: before))
        #expect(model.pending.isEmpty)
        let url = try #require(model.lastBackupURL)
        #expect(url.lastPathComponent.hasPrefix("v3-keymap-before-restore"))
        #expect(try ConfigStore.load(from: url) == before)
    }

    // Review minor: while Apply is still writing, restore is refused with a message that says so, not "unplugged".
    @Test func restoreWhileApplyingSaysSoInsteadOfDisconnected() async throws {
        let (_, model) = try await connected()
        let url = try backupFile(changing: #require(model.onDevice))
        for r in 0..<4 { for c in 0..<8 { model.setKey(layer: 1, row: r, col: c, Keycode(raw: 0x0004)) } }   // 32 writes keep Apply busy
        let apply = Task { await model.applyPending() }
        await Task.yield()
        #expect(model.isApplying)
        await #expect(throws: ViaError.invalid("another write is still running")) { try await model.restore(from: url) }
        await apply.value
        #expect(model.pending.isEmpty)
    }

    // Audit A5: a restore while unplugged must be refused before it touches the working copy.
    @Test func restoreWhileDisconnectedRefusesAndKeepsEdits() async throws {
        let (kb, model) = try await connected()
        let url = try backupFile(changing: #require(model.onDevice))
        model.setKey(layer: 0, row: 0, col: 0, Keycode(raw: 0x0004))
        kb.unplug()
        for _ in 0..<100 where model.state != .disconnected { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.state == .disconnected)
        await #expect(throws: ViaError.disconnected) { try await model.restore(from: url) }
        #expect(model.working?.keymap[0][0][0].raw == 0x0004)
        #expect(model.pending.count == 1)
    }
}
