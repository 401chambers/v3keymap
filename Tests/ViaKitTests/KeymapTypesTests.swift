import Foundation
import Testing
@testable import ViaKit

@Suite struct KeymapTypesTests {
    @Test func debounceTypesHaveTheFirmwareNumbering() {
        #expect(DebounceType.symDeferGlobal.rawValue == 0)
        #expect(DebounceType.symEagerPerKey.rawValue == 4)
        #expect(DebounceType.asymEagerDeferPerKey.rawValue == 5)
        #expect(DebounceType.none.rawValue == 6)
        #expect(DebounceType.allCases.count == 7)
    }

    @Test func asymmetricDebounceClampsTo127() {
        #expect(DebounceSettings(type: .asymEagerDeferPerKey, time: 200).clamped.time == 127)
        #expect(DebounceSettings(type: .symEagerPerKey, time: 200).clamped.time == 200)
    }

    @Test func everyDebounceAndSnapClickTypeHasPlainEnglishText() {
        for t in DebounceType.allCases { #expect(!t.title.isEmpty && !t.summary.isEmpty) }
        for t in SnapClickType.allCases { #expect(!t.title.isEmpty && !t.summary.isEmpty) }
    }

    @Test func snapClickTypesHaveTheFirmwareNumbering() {
        #expect(SnapClickType.none.rawValue == 0)
        #expect(SnapClickType.regular.rawValue == 1)
        #expect(SnapClickType.neutral.rawValue == 5)
    }

    // Review Focus 5
    @Test func snapClickSlotNeedsBothKeysWhenTyped() {
        #expect(!SnapClickSlot(type: .regular, key1: 4, key2: 0).isValid)
        #expect(!SnapClickSlot(type: .lastInput, key1: 0, key2: 7).isValid)
        #expect(SnapClickSlot(type: .regular, key1: 4, key2: 7).isValid)
        #expect(SnapClickSlot(type: .none, key1: 0, key2: 0).isValid)
    }

    @Test func perKeyTypesHaveTheFirmwareNumbering() {
        #expect(PerKeyType.solid.rawValue == 0)
        #expect(PerKeyType.reactiveSplash.rawValue == 4)
        #expect(PerKeyType.allCases.count == 5)
    }

    @Test func mixedEffectZeroMeansUnused() {
        #expect(!MixedEffect(effect: 0, hue: 0, sat: 0, speed: 0, durationMs: 0).isUsed)
        #expect(MixedEffect(effect: 5, hue: 0, sat: 255, speed: 127, durationMs: 5000).isUsed)
    }

    @Test func settingsRoundTripThroughJSON() throws {
        let settings = KeymapSettings(
            debounce: DebounceSettings(type: .symEagerPerKey, time: 50),
            snapClick: [SnapClickSlot(type: .lastInput, key1: 4, key2: 7), SnapClickSlot(type: .none, key1: 0, key2: 0)],
            perKey: PerKeyRGB(type: .breathing, colors: [HSVColor(h: 1, s: 2, v: 3), HSVColor(h: 255, s: 0, v: 128)]),
            mixed: MixedRGB(zones: [[MixedEffect(effect: 5, hue: 0, sat: 255, speed: 127, durationMs: 5000)], []], regions: [0, 1, 1]))
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(KeymapSettings.self, from: data) == settings)
    }

    @Test func ledMapReturnsNilForKeysWithoutALED() {
        let map = LEDMap(rawRows: [[0, 1, 255, 3], [4, 5, 6, 7]])
        #expect(map.ledIndex(row: 0, col: 1) == 1)
        #expect(map.ledIndex(row: 0, col: 2) == nil)
        #expect(map.ledIndex(row: 1, col: 3) == 7)
        #expect(map.ledIndex(row: 9, col: 0) == nil && map.ledIndex(row: 0, col: 9) == nil)
    }
}
