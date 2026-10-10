import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct KeymapConfigTests {
    @Test func readIncludesKeymapSettingsWhenSupported() async throws {
        let (_, _, c) = try await readRecordedConfig()
        let k = try #require(c.settings)
        #expect(k.debounce == DebounceSettings(type: .symEagerPerKey, time: 50))
        #expect(k.snapClick?.count == 20)
        #expect(k.perKey?.colors.count == 87)
        #expect(k.mixed?.zones.count == 2 && k.mixed?.regions.count == 87)
    }

    // Review Focus 4
    @Test func keyboardWithoutTheFeaturesGetsNoKeymapSettingsAndNoKeymapRequests() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        kb.keymapFeatures = 0
        let c = try await ConfigStore.read(from: ViaDevice(transport: kb))
        #expect(c.settings == nil)
        #expect(!kb.sentRequests.contains { $0[0] == 0xA7 || $0[0] == 0xA8 })
    }

    @Test func diffNamesEachKindOfChange() async throws {
        let (_, _, c) = try await readRecordedConfig()
        var t = c
        t.settings?.debounce = DebounceSettings(type: .symEagerPerRow, time: 20)
        t.settings?.snapClick?[4] = SnapClickSlot(type: .lastInput, key1: 4, key2: 7)
        t.settings?.perKey?.type = .breathing
        t.settings?.perKey?.colors[3] = HSVColor(h: 1, s: 2, v: 3)
        t.settings?.mixed?.regions[10] = 1
        t.settings?.mixed?.zones[0][1] = MixedEffect(effect: 3, hue: 0, sat: 255, speed: 100, durationMs: 4000)
        let changes = ConfigStore.diff(from: c, to: t)
        let text = changes.map(\.description).joined(separator: "\n")
        #expect(text.contains("Debounce") && text.contains("Snap Click slot 4") && text.contains("Per-key RGB") && text.contains("Mix RGB"))
        #expect(changes.count == 4)
        #expect(changes.contains { $0.target == .perKeyRGB } && changes.contains { $0.target == .mixedRGB } && changes.contains { $0.target == .debounce })
        #expect(changes.contains { if case .snapClick(index: 4) = $0.target { return true } else { return false } })
    }

    @Test func identicalKeymapSettingsProduceNoChanges() async throws {
        let (_, _, c) = try await readRecordedConfig()
        #expect(ConfigStore.diff(from: c, to: c).isEmpty)
    }

    // Review Focus 3
    @Test func backupMadeBeforeThisFeatureStillLoads() async throws {
        let (_, _, c) = try await readRecordedConfig()
        let data = try JSONEncoder().encode(c)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "settings")
        let old = try JSONSerialization.data(withJSONObject: object)
        let loaded = try JSONDecoder().decode(KeyboardConfig.self, from: old)
        #expect(loaded.settings == nil)
        #expect(loaded.keymap == c.keymap)
        try ConfigStore.validateRestorable(loaded, against: c)    // an old backup is still restorable
    }

    @Test func restoreRefusedForDifferentLEDCountOrZoneShape() async throws {
        let (_, _, c) = try await readRecordedConfig()
        var fewerLEDs = c; fewerLEDs.settings?.perKey?.colors.removeLast()
        var fewerRegions = c; fewerRegions.settings?.mixed?.regions.removeLast()
        var threeZones = c; threeZones.settings?.mixed?.zones.append(c.settings!.mixed!.zones[0])
        var fewerSlots = c; fewerSlots.settings?.snapClick?.removeLast()
        for bad in [fewerLEDs, fewerRegions, threeZones, fewerSlots] {
            #expect(throws: ViaError.self) { try ConfigStore.validateRestorable(bad, against: c) }
        }
    }

    @Test func restoreRefusedWhenTheBackupHasSettingsTheKeyboardLacks() async throws {
        let (_, _, c) = try await readRecordedConfig()
        var plain = c; plain.settings = nil
        #expect(throws: ViaError.self) { try ConfigStore.validateRestorable(c, against: plain) }
    }

    @Test func jsonRoundTripIncludesKeymap() async throws {
        let (_, _, c) = try await readRecordedConfig()
        let url = tempDirectory().appendingPathComponent("backup.json")
        try ConfigStore.save(c, to: url)
        #expect(try ConfigStore.load(from: url) == c)
    }

    // Audit A1 / Review Focus 1: a backup written by an earlier release may carry a dangerous keycode.
    @Test func backupWithBootloaderKeyIsNotRestorable() async throws {
        let (_, _, current) = try await readRecordedConfig()
        var backup = current
        backup.encoders[0][0].clockwise = Keycode(raw: 0x7C00)
        #expect(throws: ViaError.self) { try ConfigStore.validateRestorable(backup, against: current) }
        var macroBackup = current
        macroBackup.macros[0] = [.tap(Keycode(raw: 0x7C03))]
        #expect(throws: ViaError.self) { try ConfigStore.validateRestorable(macroBackup, against: current) }
        var keyBackup = current
        keyBackup.keymap[0][0][0] = Keycode(raw: 0x7C00)
        #expect(throws: ViaError.self) { try ConfigStore.validateRestorable(keyBackup, against: current) }
        var rawBackup = current
        rawBackup.macros[0] = [.raw([0x41, 0x00, 0x01, 0x05, 0x00, 0x7C])]
        #expect(throws: ViaError.self) { try ConfigStore.validateRestorable(rawBackup, against: current) }
    }

    // Review finding: a reconnect only needs the layouts to match; a keyboard that already holds QK_BOOT must not make
    // the app drop the user's carried edits.
    @Test func layoutCompatibilityIgnoresWhatTheKeyboardAlreadyHolds() async throws {
        let (_, _, current) = try await readRecordedConfig()
        var edited = current
        edited.keymap[3][0][12] = Keycode(raw: 0x7C00)
        try ConfigStore.validateCompatible(edited, against: current)
        var fewerLEDs = edited; fewerLEDs.settings?.perKey?.colors.removeLast()
        #expect(throws: ViaError.self) { try ConfigStore.validateCompatible(fewerLEDs, against: current) }
    }
}
