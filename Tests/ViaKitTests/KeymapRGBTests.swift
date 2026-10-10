import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct KeymapRGBTests {
    private func make() throws -> (SimulatedKeyboard, ViaDevice) {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        return (kb, ViaDevice(transport: kb))
    }

    @Test func protocolVersionAndLEDCount() async throws {
        let (_, dev) = try make()
        #expect(try await dev.rgbProtocolVersion() == 1)
        #expect(try await dev.rgbLEDCount() == 87)
    }

    @Test func ledMapMatchesTheKeyboard() async throws {
        let (_, dev) = try make()
        let map = try await dev.ledMap(size: .v3)
        #expect(map.ledIndex(row: 0, col: 0) == 0)
        #expect(map.ledIndex(row: 0, col: 1) == 1)
        #expect(map.ledIndex(row: 0, col: 13) == nil)      // the knob press has no LED
        #expect(map.ledIndex(row: 5, col: 15) == 0x55)
        #expect(map.ledIndex(row: 4, col: 1) == nil)
    }

    @Test func readsAll87PerKeyColours() async throws {
        let (_, dev) = try make()
        let perKey = try await dev.perKeyRGB()
        #expect(perKey.type == .solid)
        #expect(perKey.colors.count == 87)
        #expect(perKey.colors[0] == HSVColor(h: 0, s: 255, v: 255))
        #expect(perKey.colors[1].h == 0x2B)
    }

    // Review Focus 2
    @Test func settingAllColoursHitsEveryLEDAcrossChunks() async throws {
        let (kb, dev) = try make()
        let colours = (0..<87).map { HSVColor(h: UInt8($0), s: 200, v: 100) }
        try await dev.setPerKeyRGB(PerKeyRGB(type: .breathing, colors: colours))
        let back = try await dev.perKeyRGB()
        #expect(back.type == .breathing)
        for i in 0..<87 { #expect(back.colors[i] == colours[i], "LED \(i)") }
        #expect(kb.sentRequests.filter { $0 == [0xA8, 0x0A] }.count == 10)    // nine chunks of 9, one of 6
    }

    @Test func settingOnlyChangedLEDsSendsOnlyThose() async throws {
        let (kb, dev) = try make()
        var perKey = try await dev.perKeyRGB()
        let original = perKey
        for i in [3, 4, 40] { perKey.colors[i] = HSVColor(h: 9, s: 9, v: 9) }
        try await dev.setPerKeyRGB(perKey, changedLEDs: [3, 4, 40])
        let back = try await dev.perKeyRGB()
        #expect(back == perKey)
        #expect(back.colors[5] == original.colors[5])
        #expect(kb.sentRequests.filter { $0 == [0xA8, 0x0A] }.count == 2)     // run 3...4 and run 40
    }

    @Test func readsRecordedMixDefaults() async throws {
        let (_, dev) = try make()
        let mixed = try await dev.mixedRGB()
        #expect(mixed.zones.count == 2 && mixed.zones.allSatisfy { $0.count == 5 })
        #expect(mixed.zones[0][0] == MixedEffect(effect: 5, hue: 0, sat: 255, speed: 127, durationMs: 5000))
        #expect(mixed.zones[1][0].effect == 2)
        #expect(mixed.zones[0][1...].allSatisfy { !$0.isUsed })
        #expect(mixed.regions.count == 87 && mixed.regions.filter { $0 != 0 }.count == 4)
    }

    @Test func zoneAssignmentSurvivesChunkBoundaries() async throws {
        let (kb, dev) = try make()
        var mixed = try await dev.mixedRGB()
        for led in [27, 28, 29, 56, 57] { mixed.regions[led] = 1 }
        try await dev.setMixedRGB(mixed)
        #expect(try await dev.mixedRGB() == mixed)
        #expect(kb.sentRequests.filter { $0 == [0xA8, 0x0D] }.count == 4)     // 28 + 28 + 28 + 3
    }

    @Test func effectListRoundTripsIncludingLongDurations() async throws {
        let (_, dev) = try make()
        var mixed = try await dev.mixedRGB()
        mixed.zones[0][1] = MixedEffect(effect: 12, hue: 30, sat: 200, speed: 80, durationMs: 6000)
        mixed.zones[1][4] = MixedEffect(effect: 7, hue: 1, sat: 2, speed: 3, durationMs: 70_000)
        try await dev.setMixedRGB(mixed)
        let back = try await dev.mixedRGB()
        #expect(back.zones[0][1].durationMs == 6000)
        #expect(back.zones[1][4].durationMs == 70_000)
        #expect(back == mixed)
    }

    @Test func wrongShapeIsRejectedBeforeWriting() async throws {
        let (kb, dev) = try make()
        let good = try await dev.mixedRGB()
        var threeZones = good; threeZones.zones.append([MixedEffect](repeating: .unused, count: 5))
        var sixSlots = good; sixSlots.zones[0].append(.unused)
        var shortRegions = good; shortRegions.regions.removeLast()
        var badRegion = good; badRegion.regions[0] = 2
        for bad in [threeZones, sixSlots, shortRegions, badRegion] {
            await #expect(throws: ViaError.self) { try await dev.setMixedRGB(bad) }
        }
        #expect(!kb.sentRequests.contains([0xA8, 0x0D]) && !kb.sentRequests.contains([0xA8, 0x0F]))
        await #expect(throws: ViaError.self) { try await dev.setPerKeyRGB(PerKeyRGB(type: .solid, colors: [HSVColor(h: 0, s: 0, v: 0)])) }
        #expect(!kb.sentRequests.contains([0xA8, 0x0A]))
    }

    @Test func saveRGBSendsTheSaveCommand() async throws {
        let (kb, dev) = try make()
        try await dev.saveRGB()
        #expect(kb.sentRequests.contains([0xA8, 0x02]))
    }
}
