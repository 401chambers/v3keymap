import Foundation
import Testing
import ViaKit
import ViaKitTestSupport
@testable import KeymapCore

@MainActor
@Suite struct KeymapModelTests {
    private func connected(features: UInt8? = nil) async throws -> (SimulatedKeyboard, AppModel) {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        if let features { kb.keymapFeatures = features }
        let model = AppModel(transportFactory: { kb },
                             backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("extras-app-tests-\(UUID().uuidString)"))
        await model.connect()
        return (kb, model)
    }

    @Test func firmwareVersionDropsTheBuildDate() {
        #expect(AppModel.firmwareVersion(from: "v2.0.0 2025-11-03-17:54:55") == "v2.0.0")
        #expect(AppModel.firmwareVersion(from: "v1.2") == "v1.2")
        #expect(AppModel.firmwareVersion(from: "") == "Unknown")
    }

    @Test func connectLoadsKeymapSettings() async throws {
        let (_, model) = try await connected()
        #expect(model.supportsDebounce && model.supportsSnapClick && model.supportsPerKeyRGB && model.supportsMixedRGB)
        #expect(model.ledMap?.ledIndex(row: 0, col: 1) == 1)
        #expect(model.working?.settings?.perKey?.colors.count == 87)
    }

    // Review Focus 4
    @Test func aKeyboardWithoutTheFeaturesHidesThemAndNeverSendsTheirCommands() async throws {
        let (kb, model) = try await connected(features: 0)
        #expect(!model.supportsDebounce && !model.supportsSnapClick && !model.supportsPerKeyRGB && !model.supportsMixedRGB)
        #expect(model.ledMap == nil)
        #expect(!kb.sentRequests.contains { $0[0] == 0xA7 || $0[0] == 0xA8 })
    }

    @Test func paintingSelectedKeysChangesOnlyThoseLEDs() async throws {
        let (_, model) = try await connected()
        let before = try #require(model.working?.settings?.perKey?.colors)
        model.toggleSelection(MatrixPosition(row: 0, col: 0))
        model.toggleSelection(MatrixPosition(row: 0, col: 1))
        model.toggleSelection(MatrixPosition(row: 0, col: 13))        // the knob press has no LED: ignored
        #expect(model.selectedKeys.count == 2)
        model.paintSelected(HSVColor(h: 10, s: 20, v: 30))
        let after = try #require(model.working?.settings?.perKey?.colors)
        #expect(after[0] == HSVColor(h: 10, s: 20, v: 30) && after[1] == HSVColor(h: 10, s: 20, v: 30))
        #expect(zip(before, after).filter { $0 != $1 }.count == 2)
        #expect(model.pending.count == 1 && model.pending[0].target == .perKeyRGB)
    }

    @Test func selectAllAndClearSelection() async throws {
        let (_, model) = try await connected()
        model.selectAllKeys()
        #expect(model.selectedKeys.count == 87)                       // one per LED
        model.clearSelection()
        #expect(model.selectedKeys.isEmpty)
    }

    @Test func assigningKeysToAZoneMarksMixedRGBPending() async throws {
        let (_, model) = try await connected()
        model.toggleSelection(MatrixPosition(row: 2, col: 5))
        model.assignSelected(toZone: 1)
        #expect(model.pending.contains { $0.target == .mixedRGB })
        let led = try #require(model.ledMap?.ledIndex(row: 2, col: 5))
        #expect(model.working?.settings?.mixed?.regions[led] == 1)
        #expect(model.zone(of: MatrixPosition(row: 2, col: 5)) == 1)
    }

    @Test func editingAndRemovingMixedEffects() async throws {
        let (_, model) = try await connected()
        model.setMixedEffect(zone: 0, slot: 1, MixedEffect(effect: 7, hue: 10, sat: 200, speed: 90, durationMs: 3000))
        #expect(model.working?.settings?.mixed?.zones[0][1].effect == 7)
        model.removeMixedEffect(zone: 0, slot: 1)
        #expect(model.working?.settings?.mixed?.zones[0][1].isUsed == false)
        #expect(model.pending.isEmpty)                                 // back to the keyboard's own state
    }

    // Review Focus 5
    @Test func aSnapClickRowWithoutBothKeysIsFlaggedAndNeverPending() async throws {
        let (_, model) = try await connected()
        model.setSnapClick(index: 3, SnapClickSlot(type: .regular, key1: 4, key2: 0))
        #expect(model.pending.isEmpty)
        #expect(model.snapClickRowIsIncomplete(3))
        model.setSnapClick(index: 3, SnapClickSlot(type: .regular, key1: 4, key2: 7))
        #expect(!model.snapClickRowIsIncomplete(3))
        #expect(model.pending.count == 1)
    }

    @Test func asymmetricDebounceIsClampedTo127() async throws {
        let (_, model) = try await connected()
        model.setDebounce(DebounceSettings(type: .asymEagerDeferPerKey, time: 200))
        #expect(model.working?.settings?.debounce?.time == 127)
    }

    @Test func switchingToPerKeyDiscoversTheIdsOnceAndSelectsTheEffect() async throws {
        let (kb, model) = try await connected()
        #expect(model.lightingMode == .standard)
        await model.setLightingMode(.perKey)
        #expect(model.customEffects == CustomEffectIDs(perKey: 48, mixed: 49))
        #expect(model.working?.lighting.effect == 48 && model.lightingMode == .perKey)
        let setsAfterFirst = kb.sentRequests.filter { $0[0] == 0x07 }.count
        await model.setLightingMode(.mixed)
        #expect(model.working?.lighting.effect == 49 && model.lightingMode == .mixed)
        #expect(kb.sentRequests.filter { $0[0] == 0x07 }.count == setsAfterFirst)      // no second discovery
        await model.setLightingMode(.standard)
        #expect(model.lightingMode == .standard)
        #expect(model.working?.lighting.effect != 48 && model.working?.lighting.effect != 49)
    }

    @Test func aFailedDiscoveryKeepsStandardModeAndSaysWhy() async throws {
        let (kb, model) = try await connected()
        kb.clampsEffects = false
        await model.setLightingMode(.perKey)
        #expect(model.lightingMode == .standard)
        #expect(model.errorMessage != nil)
    }

    // Review Focus 1
    @Test func aRejectedApplyReReadsTheKeyboardAndKeepsTheEdit() async throws {
        let (kb, model) = try await connected()
        let original = try #require(model.working?.settings?.perKey?.colors[0])
        model.toggleSelection(MatrixPosition(row: 0, col: 0))
        model.paintSelected(HSVColor(h: 1, s: 2, v: 3))
        kb.rejectNextKeymapWrite = true
        await model.applyPending()
        #expect(model.state == .connected)
        #expect(model.errorMessage != nil)
        #expect(model.onDevice?.settings?.perKey?.colors[0] == original)     // the keyboard did not take it, and the app knows
        #expect(model.pending.count == 1)                                     // the edit is still there to retry
    }

    @Test func applyWritesAllTheNewSettings() async throws {
        let (kb, model) = try await connected()
        model.toggleSelection(MatrixPosition(row: 0, col: 0))
        model.paintSelected(HSVColor(h: 9, s: 8, v: 7))
        model.toggleSelection(MatrixPosition(row: 0, col: 0))
        model.toggleSelection(MatrixPosition(row: 2, col: 5))
        model.assignSelected(toZone: 1)
        model.setDebounce(DebounceSettings(type: .symEagerPerRow, time: 20))
        model.setSnapClick(index: 2, SnapClickSlot(type: .lastInput, key1: 4, key2: 7))
        #expect(model.pending.count == 4)
        await model.applyPending()
        #expect(model.pending.isEmpty)
        let onKeyboard = try await ConfigStore.read(from: ViaDevice(transport: kb))
        #expect(onKeyboard.settings == model.working?.settings)
    }

    @Test func restoreFromABackupAlsoRestoresTheKeymapSettings() async throws {
        let (kb, model) = try await connected()
        var backup = try #require(model.onDevice)
        backup.settings?.debounce = DebounceSettings(type: .symDeferPerKey, time: 12)
        backup.settings?.snapClick?[1] = SnapClickSlot(type: .neutral, key1: 4, key2: 7)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("extras-restore-\(UUID().uuidString).json")
        try ConfigStore.save(backup, to: url)
        try await model.restore(from: url)
        let onKeyboard = try await ConfigStore.read(from: ViaDevice(transport: kb))
        #expect(onKeyboard.settings?.debounce == DebounceSettings(type: .symDeferPerKey, time: 12))
        #expect(onKeyboard.settings?.snapClick?[1] == SnapClickSlot(type: .neutral, key1: 4, key2: 7))
    }
}

@MainActor
@Suite struct SnapClickRowsTests {
    private func connected() async throws -> AppModel {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let model = AppModel(transportFactory: { kb }, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("extras-rows-\(UUID().uuidString)"))
        await model.connect()
        return model
    }

    @Test func rowsAppearOnlyForPairsInUseOrBeingEdited() async throws {
        let model = try await connected()
        #expect(model.snapClickVisibleRows.isEmpty)
        model.setSnapClick(index: 4, SnapClickSlot(type: .regular, key1: 4, key2: 0))        // incomplete: a draft
        #expect(model.snapClickVisibleRows == [4])
        model.setSnapClick(index: 2, SnapClickSlot(type: .lastInput, key1: 4, key2: 7))
        #expect(model.snapClickVisibleRows == [2, 4])
        model.setSnapClick(index: 2, .empty)
        #expect(model.snapClickVisibleRows == [4])
    }

    @Test func addingAPairUsesTheFirstFreeSlotAsADraftAndStopsWhenFull() async throws {
        let model = try await connected()
        #expect(model.addSnapClickPair() == 0)
        #expect(model.snapClickRowIsIncomplete(0))
        #expect(model.pending.isEmpty)                                 // a draft is never pending
        #expect(model.addSnapClickPair() == 1)
        for i in 2..<20 { model.setSnapClick(index: i, SnapClickSlot(type: .regular, key1: 4, key2: 7)) }
        model.setSnapClick(index: 0, SnapClickSlot(type: .regular, key1: 4, key2: 7))
        model.setSnapClick(index: 1, SnapClickSlot(type: .regular, key1: 4, key2: 7))
        #expect(model.addSnapClickPair() == nil)                       // all 20 slots are in use
    }

    @Test func clearingADraftRemovesItsRow() async throws {
        let model = try await connected()
        let index = try #require(model.addSnapClickPair())
        model.setSnapClick(index: index, .empty)
        #expect(model.snapClickVisibleRows.isEmpty && !model.snapClickRowIsIncomplete(index))
    }
}

@MainActor
@Suite struct LightingModeRaceTests {
    @Test func anEditMadeDuringTheEffectProbeIsKept() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let model = AppModel(transportFactory: { kb }, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("race-\(UUID().uuidString)"))
        await model.connect()
        var edited = try #require(model.working?.lighting)
        edited.brightness = edited.brightness == 77 ? 78 : 77
        let switching = Task { await model.setLightingMode(.perKey) }
        for _ in 0..<20 { await Task.yield() }     // let the switch reach the probe's first await
        model.setLighting(edited)                  // the slider moves while the probe runs
        await switching.value
        #expect(model.lightingMode == .perKey)
        #expect(model.working?.lighting.brightness == edited.brightness)
    }

    @Test func reconnectClampsSelectionsToTheKeyboard() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let model = AppModel(transportFactory: { kb }, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("clamp-\(UUID().uuidString)"))
        model.macroSlot = 99
        model.selectedLayer = 9
        await model.connect()
        let macros = try #require(model.working?.macros.count)
        let layers = try #require(model.working?.keymap.count)
        #expect(model.macroSlot == macros - 1)
        #expect(model.selectedLayer == layers - 1)
    }
}
