import Testing
@testable import ViaKit

@Suite struct LightingEffectTests {
    @Test func namesForTheEffectsNearTheStartOfQMKsList() {
        #expect(RGBMatrixEffect.name(for: 0) == "None")
        #expect(RGBMatrixEffect.name(for: 1) == "Solid Color")
        #expect(RGBMatrixEffect.name(for: 2) == "Breathing")   // numbering from Keychron's Launcher definition for the V3 Knob
    }

    @Test func unknownEffectsStillGetAName() {
        #expect(RGBMatrixEffect.name(for: 200) == "Effect 200")
    }

    @Test func tableHasNoDuplicateIDs() {
        #expect(Set(RGBMatrixEffect.all.map(\.id)).count == RGBMatrixEffect.all.count)
    }
}
