import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct ViaDeviceWriteTests {
    private func make() throws -> (SimulatedKeyboard, ViaDevice) {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        return (kb, ViaDevice(transport: kb))
    }

    @Test func setKeycodeReadsBack() async throws {
        let (_, dev) = try make()
        try await dev.setKeycode(layer: 0, row: 0, col: 0, Keycode(raw: 0x002B))
        let map = try await dev.keymap(layers: 4, size: .v3)
        #expect(map[0][0][0].raw == 0x002B)
        #expect(map[0][0][1].raw == 0x00BE)   // neighbour untouched
    }

    @Test func setEncoderReadsBack() async throws {
        let (_, dev) = try make()
        try await dev.setEncoder(layer: 0, index: 0, clockwise: true, Keycode(raw: 0x00AA))
        #expect(try await dev.encoder(layer: 0, index: 0, clockwise: true).raw == 0x00AA)
        #expect(try await dev.encoder(layer: 0, index: 0, clockwise: false).raw == 0x00AA)
    }

    @Test func macroBufferRoundTripsAtCapacity() async throws {
        let (_, dev) = try make()
        let bytes = (0..<1750).map { UInt8($0 % 251) }
        try await dev.setMacroBuffer(bytes)
        #expect(try await dev.macroBuffer() == bytes)
    }

    @Test func macroBufferOverCapacityRejectedBeforeWriting() async throws {
        let (kb, dev) = try make()
        await #expect(throws: ViaError.self) { try await dev.setMacroBuffer([UInt8](repeating: 1, count: 1751)) }
        #expect(!kb.sentCommands.contains(0x0F))
    }

    @Test func setLightingReadsBackAndSaves() async throws {
        let (kb, dev) = try make()
        var l = try await dev.lighting()
        l.brightness = 100
        try await dev.setLighting(l)
        #expect(try await dev.lighting().brightness == 100)
        #expect(kb.sentCommands.contains(0x09))
    }

    @Test func forbiddenCommandsNeverSent() async throws {
        let (kb, dev) = try make()
        try await dev.setKeycode(layer: 1, row: 0, col: 0, Keycode(raw: 0x0004))
        try await dev.setEncoder(layer: 1, index: 0, clockwise: false, Keycode(raw: 0x0004))
        try await dev.setMacroBuffer([1, 2, 3])
        var l = try await dev.lighting(); l.effect = 3
        try await dev.setLighting(l)
        #expect(!kb.sentCommands.contains(0x0A) && !kb.sentCommands.contains(0x0B))
        await #expect(throws: ViaError.forbiddenCommand(0x0B)) { _ = try await dev.send([0x0B]) }
        await #expect(throws: ViaError.forbiddenCommand(0x0A)) { _ = try await dev.send([0x0A]) }
        #expect(!kb.sentCommands.contains(0x0A) && !kb.sentCommands.contains(0x0B))
    }

    @Test func verifyMismatchReported() async throws {
        let (kb, dev) = try make()
        kb.ignoreWrites = true
        do {
            try await dev.setKeycode(layer: 0, row: 0, col: 0, Keycode(raw: 0x002B))
            Issue.record("expected verifyMismatch")
        } catch let ViaError.verifyMismatch(items) {
            #expect(items.count == 1)
        }
    }

    // Audit C1: like every other write, the indicator light is read back before it is saved to EEPROM.
    @Test func indicatorIsVerifiedBeforeItIsSaved() async throws {
        let (kb, dev) = try make()
        try await dev.setLEDIndicator(LEDIndicator(supportMask: 0x02, disabledMask: 0, hue: 10, saturation: 200))
        let reqs = kb.sentRequests
        let set = try #require(reqs.lastIndex { $0 == [0xA8, 0x04] })
        let get = try #require(reqs.lastIndex { $0 == [0xA8, 0x03] })
        let save = try #require(reqs.lastIndex { $0 == [0xA8, 0x02] })
        #expect(set < get && get < save)
    }
}
