import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct ApplyEngineTests {
    private func edited(_ c: KeyboardConfig, keys: [(Int, Int, Int, UInt16)]) -> KeyboardConfig {
        var t = c
        for (l, r, col, raw) in keys { t.keymap[l][r][col] = Keycode(raw: raw) }
        return t
    }

    @Test func applyWritesKeyAndMakesOneBackupBeforeWriting() async throws {
        let (_, dev, current) = try await readRecordedConfig()
        let dir = tempDirectory()
        let engine = ApplyEngine(device: dev, backupDirectory: dir)

        let first = try await engine.apply(edited(current, keys: [(0, 0, 0, 0x002B)]), current: current)
        let backup = try #require(first.backupURL)
        #expect(try ConfigStore.load(from: backup) == current)
        #expect(first.written.count == 1)
        #expect(try await dev.keymap(layers: 4, size: .v3)[0][0][0].raw == 0x002B)

        let now = try await ConfigStore.read(from: dev)
        let second = try await engine.apply(edited(now, keys: [(0, 0, 1, 0x002C)]), current: now)
        #expect(second.backupURL == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
    }

    @Test func backupFailureBlocksEveryWrite() async throws {
        let (kb, dev, current) = try await readRecordedConfig()
        let before = kb.sentCommands.count
        let engine = ApplyEngine(device: dev, backupDirectory: URL(fileURLWithPath: "/dev/null/no-such-dir"))
        await #expect(throws: ApplyError.self) {
            _ = try await engine.apply(self.edited(current, keys: [(0, 0, 0, 0x002B)]), current: current)
        }
        #expect(kb.sentCommands.count == before)
    }

    // Review Focus 1
    @Test func disconnectMidApplyReportsWhatWasWritten() async throws {
        let (kb, dev, current) = try await readRecordedConfig()
        let target = edited(current, keys: [(0, 0, 0, 0x0004), (0, 0, 1, 0x0005), (0, 0, 2, 0x0006)])
        let snapshot = target
        // Each key write is 2 exchanges (set + read-back): allow 2 keys, then the third write's read-back fails.
        kb.failAfter = kb.exchangeCount + 5
        let engine = ApplyEngine(device: dev, backupDirectory: tempDirectory())
        do {
            _ = try await engine.apply(target, current: current)
            Issue.record("expected a partial failure")
        } catch ApplyError.partial(let written, let failed, let underlying) {
            #expect(written.count == 2)
            #expect(failed.description.contains("col 2"))
            #expect(underlying == .disconnected)
        }
        #expect(target == snapshot)
    }

    // Review Focus 3 (engine level)
    @Test func oversizedMacrosRejectedBeforeAnyWrite() async throws {
        let (kb, dev, current) = try await readRecordedConfig()
        var target = current
        target.macros[0] = [.text(String(repeating: "a", count: 1750))]
        let before = kb.sentCommands.count
        let engine = ApplyEngine(device: dev, backupDirectory: tempDirectory())
        await #expect(throws: ViaError.self) { _ = try await engine.apply(target, current: current) }
        let writeCommands: Set<UInt8> = [0x05, 0x07, 0x09, 0x0F, 0x15]   // keycode, custom value, save, macro buffer, encoder
        #expect(Set(kb.sentCommands[before...]).isDisjoint(with: writeCommands))
    }

    @Test func applyWritesMacrosAndLighting() async throws {
        let (_, dev, current) = try await readRecordedConfig()
        var target = current
        target.macros[1] = [.text("hi"), .tap(Keycode(raw: 0x28))]
        target.lighting.brightness = 100
        target.encoders[0][0].clockwise = Keycode(raw: 0x00AA)
        let result = try await ApplyEngine(device: dev, backupDirectory: tempDirectory()).apply(target, current: current)
        #expect(result.written.count == 3)
        let back = try await ConfigStore.read(from: dev)
        #expect(back.macros[1] == target.macros[1])
        #expect(back.lighting.brightness == 100)
        #expect(back.encoders[0][0].clockwise.raw == 0x00AA)
    }

    // Audit A1: a dangerous keycode anywhere in the target is refused before the backup and before any write.
    @Test func applyRefusesDangerousKeyBeforeWriting() async throws {
        let (kb, dev, current) = try await readRecordedConfig()
        var target = current
        target.keymap[0][0][0] = Keycode(raw: 0x7C03)
        let dir = tempDirectory()
        let before = kb.sentCommands.count
        let engine = ApplyEngine(device: dev, backupDirectory: dir)
        await #expect(throws: ViaError.self) { _ = try await engine.apply(target, current: current) }
        #expect(!kb.sentCommands[before...].contains(0x05))      // no setKeycode went out
        #expect(!FileManager.default.fileExists(atPath: dir.path))   // no backup either: the folder is only made for one
    }

    // Review finding: QK_BOOT already on a layer (put there by another tool) must not stop every other Apply.
    @Test func applyIgnoresADangerousKeyThatIsAlreadyOnTheKeyboard() async throws {
        let (kb, dev, _) = try await readRecordedConfig()
        kb.seedKeycode(layer: 3, row: 0, col: 12, 0x7C00)
        let current = try await ConfigStore.read(from: dev)
        #expect(current.keymap[3][0][12].raw == 0x7C00)
        let target = edited(current, keys: [(0, 0, 0, 0x002B)])
        let result = try await ApplyEngine(device: dev, backupDirectory: tempDirectory()).apply(target, current: current)
        #expect(result.written.count == 1)
        #expect(try await dev.keymap(layers: 4, size: .v3)[0][0][0].raw == 0x002B)
    }
}
