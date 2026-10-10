import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct KeymapApplyTests {
    private func edited(_ c: KeyboardConfig) -> KeyboardConfig {
        var t = c
        t.settings?.debounce = DebounceSettings(type: .symEagerPerRow, time: 20)
        t.settings?.snapClick?[2] = SnapClickSlot(type: .lastInput, key1: 4, key2: 7)
        t.settings?.perKey?.type = .breathing
        t.settings?.perKey?.colors[3] = HSVColor(h: 1, s: 2, v: 3)
        t.settings?.mixed?.regions[10] = 1
        t.settings?.mixed?.zones[0][1] = MixedEffect(effect: 3, hue: 0, sat: 255, speed: 100, durationMs: 4000)
        return t
    }

    @Test func appliesDebounceSnapClickPerKeyAndMix() async throws {
        let (kb, dev, current) = try await readRecordedConfig()
        let target = edited(current)
        let result = try await ApplyEngine(device: dev, backupDirectory: tempDirectory()).apply(target, current: current)
        #expect(result.written.count == 4)
        #expect(try await ConfigStore.read(from: dev) == target)
        #expect(kb.sentRequests.contains([0xA7, 0x0A]) && kb.sentRequests.contains([0xA8, 0x02]))   // Snap Click and RGB saved
    }

    @Test func savesRGBOnceAndOnlyWhenNeeded() async throws {
        let (kb, dev, current) = try await readRecordedConfig()
        var onlyDebounce = current
        onlyDebounce.settings?.debounce = DebounceSettings(type: .symEagerPerKey, time: 40)
        _ = try await ApplyEngine(device: dev, backupDirectory: tempDirectory()).apply(onlyDebounce, current: current)
        #expect(!kb.sentRequests.contains([0xA8, 0x02]) && !kb.sentRequests.contains([0xA7, 0x0A]))

        let now = try await ConfigStore.read(from: dev)
        _ = try await ApplyEngine(device: dev, backupDirectory: tempDirectory()).apply(edited(now), current: now)
        #expect(kb.sentRequests.filter { $0 == [0xA8, 0x02] }.count == 1)
    }

    @Test func snapClickChangesWriteOnlyTheChangedSlots() async throws {
        let (kb, dev, current) = try await readRecordedConfig()
        var t = current
        t.settings?.snapClick?[2] = SnapClickSlot(type: .regular, key1: 4, key2: 7)
        t.settings?.snapClick?[5] = SnapClickSlot(type: .neutral, key1: 26, key2: 22)
        _ = try await ApplyEngine(device: dev, backupDirectory: tempDirectory()).apply(t, current: current)
        #expect(kb.sentRequests.filter { $0 == [0xA7, 0x09] }.count == 2)
        #expect(try await dev.snapClickSlots()[5] == SnapClickSlot(type: .neutral, key1: 26, key2: 22))
    }

    // Review Focus 1
    @Test func aRejectedWriteStopsAndNamesTheItem() async throws {
        let (kb, dev, current) = try await readRecordedConfig()
        var t = current
        t.settings?.snapClick?[2] = SnapClickSlot(type: .regular, key1: 4, key2: 7)
        t.settings?.snapClick?[5] = SnapClickSlot(type: .neutral, key1: 26, key2: 22)
        kb.rejectNextKeymapWrite = true
        do {
            _ = try await ApplyEngine(device: dev, backupDirectory: tempDirectory()).apply(t, current: current)
            Issue.record("expected a partial failure")
        } catch ApplyError.partial(let written, let failed, let underlying) {
            #expect(written.isEmpty)
            #expect(failed.description.contains("Snap Click slot 2"))
            if case .rejected = underlying {} else { Issue.record("underlying was \(underlying)") }
        }
        #expect(kb.sentRequests.filter { $0 == [0xA7, 0x09] }.count == 1)      // slot 5 was never attempted
        #expect(!kb.sentRequests.contains([0xA7, 0x0A]))                         // and nothing was saved
    }

    @Test func aFailureAfterEarlierWritesLeavesThoseWritesInPlace() async throws {
        let (kb, dev, current) = try await readRecordedConfig()
        let engine = ApplyEngine(device: dev, backupDirectory: tempDirectory())

        var withDebounce = current
        withDebounce.settings?.debounce = DebounceSettings(type: .symEagerPerRow, time: 20)
        _ = try await engine.apply(withDebounce, current: current)          // lands

        var withSnap = withDebounce
        withSnap.settings?.snapClick?[2] = SnapClickSlot(type: .regular, key1: 4, key2: 7)
        kb.rejectNextKeymapWrite = true
        do {
            _ = try await engine.apply(withSnap, current: withDebounce)
            Issue.record("expected a partial failure")
        } catch ApplyError.partial(let written, let failed, _) {
            #expect(written.isEmpty && failed.description.contains("Snap Click slot 2"))
        }
        #expect(try await dev.debounce() == DebounceSettings(type: .symEagerPerRow, time: 20))   // the earlier write is still there
        #expect(try await dev.snapClickSlots()[2] == .empty)                                      // the rejected one is not
    }

    // Review: a bad target must be refused before anything is written.
    @Test func anInvalidSnapClickRowOrZoneWritesNothing() async throws {
        let (kb, dev, current) = try await readRecordedConfig()
        var t = current
        t.settings?.snapClick?[2] = SnapClickSlot(type: .regular, key1: 0, key2: 7)
        t.keymap[0][1][1] = Keycode(raw: 0x0004)
        await #expect(throws: ViaError.self) {
            _ = try await ApplyEngine(device: dev, backupDirectory: tempDirectory()).apply(t, current: current)
        }
        #expect(kb.sentRequests.filter { $0.first == 0x05 }.isEmpty)      // no key was written either

        var z = current
        z.settings?.mixed?.regions[0] = 9
        await #expect(throws: ViaError.self) {
            _ = try await ApplyEngine(device: dev, backupDirectory: tempDirectory()).apply(z, current: current)
        }
        #expect(try await ConfigStore.read(from: dev) == current)
    }

    @Test func aBackupWithABadSnapClickRowIsRefused() async throws {
        let (_, _, current) = try await readRecordedConfig()
        var backup = current
        backup.settings?.snapClick?[0] = SnapClickSlot(type: .regular, key1: 4, key2: 0)
        #expect(throws: ViaError.self) { try ConfigStore.validateRestorable(backup, against: current) }
    }
}

@Suite struct ApplyScopeTests {
    /// Only what is about to be written is checked: a half-filled Snap Click slot the keyboard already holds does not
    /// stop an unrelated key change from being applied.
    @Test func anUntouchedInvalidSnapClickSlotDoesNotBlockOtherWrites() async throws {
        let (_, dev, read) = try await readRecordedConfig()
        var current = read
        current.settings?.snapClick?[7] = SnapClickSlot(type: .regular, key1: 4, key2: 0)
        var target = current
        target.keymap[0][1][1] = Keycode(raw: 0x0005)
        let result = try await ApplyEngine(device: dev, backupDirectory: tempDirectory()).apply(target, current: current)
        #expect(result.written.count == 1)
    }

    @Test func anInvalidSnapClickSlotThatIsBeingWrittenIsRefused() async throws {
        let (_, dev, current) = try await readRecordedConfig()
        var target = current
        target.settings?.snapClick?[7] = SnapClickSlot(type: .regular, key1: 4, key2: 0)
        await #expect(throws: ViaError.self) {
            _ = try await ApplyEngine(device: dev, backupDirectory: tempDirectory()).apply(target, current: current)
        }
    }
}
