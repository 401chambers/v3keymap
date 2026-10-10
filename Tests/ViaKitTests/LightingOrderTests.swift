import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

/// The real V3 ignores brightness while the effect is None and rounds the colour then; the simulator behaves the same.
@Suite struct LightingOrderTests {
    private func device(effect: UInt8, brightness: UInt8 = 239) async throws -> (SimulatedKeyboard, ViaDevice) {
        let (kb, dev, _) = try await readRecordedConfig()
        var l = try await dev.lighting()
        l.effect = effect; l.brightness = brightness; l.saturation = 255
        try await dev.setLighting(l)
        return (kb, dev)
    }

    @Test func turningAnEffectOnAndSettingBrightnessInOneWriteWorks() async throws {
        let (_, dev) = try await device(effect: 1, brightness: 150)
        var off = try await dev.lighting(); off.effect = 0
        try await dev.setLighting(off)
        var on = try await dev.lighting(); on.effect = 2; on.brightness = 200
        try await dev.setLighting(on)
        #expect(try await dev.lighting() == on)
    }

    @Test func turningLightingOffKeepsTheBrightnessChosenFirst() async throws {
        let (_, dev) = try await device(effect: 1, brightness: 239)
        var off = try await dev.lighting(); off.effect = 0; off.brightness = 100
        try await dev.setLighting(off)
        let read = try await dev.lighting()
        #expect(read.effect == 0 && read.brightness == 100)
    }

    @Test func brightnessCannotChangeWhileNoEffectIsRunningAndIsLeftAlone() async throws {
        let (_, dev) = try await device(effect: 1, brightness: 180)
        var off = try await dev.lighting(); off.effect = 0
        try await dev.setLighting(off)
        var again = try await dev.lighting(); again.brightness = 50
        try await dev.setLighting(again)               // does not throw
        #expect(try await dev.lighting().brightness == 180)
    }
}
