import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct KeymapEffectIDTests {
    private func make() throws -> (SimulatedKeyboard, ViaDevice) {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        return (kb, ViaDevice(transport: kb))
    }

    @Test func discoversTheLastTwoEffectsFromTheClampedMaximum() async throws {
        let (_, dev) = try make()
        #expect(try await dev.discoverCustomEffectIDs() == CustomEffectIDs(perKey: 48, mixed: 49))
    }

    @Test func restoresTheOriginalEffect() async throws {
        let (_, dev) = try make()
        let before = try await dev.lighting().effect
        _ = try await dev.discoverCustomEffectIDs()
        #expect(try await dev.lighting().effect == before)
        #expect(before == 5)
    }

    @Test func restoresEvenWhenAReadFails() async throws {
        let (kb, dev) = try make()
        kb.truncateAtRequest = kb.exchangeCount + 3     // read original, set 255, then the read-back is cut short
        await #expect(throws: ViaError.self) { _ = try await dev.discoverCustomEffectIDs() }
        #expect(try await dev.lighting().effect == 5)
    }

    @Test func returnsNilWhenTheKeyboardDoesNotClamp() async throws {
        let (kb, dev) = try make()
        kb.clampsEffects = false
        #expect(try await dev.discoverCustomEffectIDs() == nil)
        #expect(try await dev.lighting().effect == 5)
    }

    @Test func neverSavesToEEPROM() async throws {
        let (kb, dev) = try make()
        _ = try await dev.discoverCustomEffectIDs()
        #expect(!kb.sentRequests.contains { $0[0] == 0x09 })      // VIA "custom save"
    }

    // Audit B4: after the effect is put back, the firmware ignores speed/colour writes for a moment (seen on the real
    // keyboard, not modelled by the simulator), so restore must wait as setLighting does. Only the order and the wait
    // can be checked here.
    @Test func probeRestoreWaitsBeforeRewritingLook() async throws {
        let (kb, dev) = try make()
        let t0 = Date()
        _ = try await dev.discoverCustomEffectIDs()
        let elapsed = Date().timeIntervalSince(t0)
        #expect(try await dev.lighting().effect == 5)
        #expect(elapsed >= 0.12)
        let heads = kb.sentRequestHeads
        let effectRestore = try #require(heads.lastIndex(of: [0x07, 3, 2]))
        let speedRestore = try #require(heads.lastIndex(of: [0x07, 3, 3]))
        let colourRestore = try #require(heads.lastIndex(of: [0x07, 3, 4]))
        #expect(effectRestore < speedRestore && speedRestore < colourRestore)
    }
}
