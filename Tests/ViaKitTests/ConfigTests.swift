import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("extras-tests-\(UUID().uuidString)")
}

func readRecordedConfig() async throws -> (SimulatedKeyboard, ViaDevice, KeyboardConfig) {
    let kb = try SimulatedKeyboard(fixtures: fixturesURL())
    let dev = ViaDevice(transport: kb)
    return (kb, dev, try await ConfigStore.read(from: dev))
}

@Suite struct ConfigTests {
    @Test func readFromKeyboardCapturesEverything() async throws {
        let (_, _, c) = try await readRecordedConfig()
        #expect(c.vendorID == 0x3434 && c.productID == 0x0331 && c.protocolVersion == 0x000C)
        #expect(c.firmware.hasPrefix("v2.0.0"))
        #expect(c.keymap.count == 4 && c.keymap[0][0][0].raw == 0x0029)
        #expect(c.encoders.count == 4 && c.encoders[0][0].clockwise.raw == 0x00A9 && c.encoders[1][0].counterClockwise.raw == 0x7828)
        #expect(c.macros.count == 16 && c.macros.allSatisfy { $0.isEmpty })
        #expect(c.lighting == LightingState(brightness: 255, effect: 5, speed: 127, hue: 0, saturation: 252))
    }

    @Test func jsonSaveLoadRoundTrips() async throws {
        let (_, _, c) = try await readRecordedConfig()
        let url = tempDirectory().appendingPathComponent("backup.json")
        try ConfigStore.save(c, to: url)
        #expect(try ConfigStore.load(from: url) == c)
    }

    @Test func diffOfIdenticalConfigsIsEmpty() async throws {
        let (_, _, c) = try await readRecordedConfig()
        #expect(ConfigStore.diff(from: c, to: c).isEmpty)
    }

    @Test func diffOfOneKeyNamesLayerRowAndColumn() async throws {
        let (_, _, c) = try await readRecordedConfig()
        var t = c
        t.keymap[2][3][4] = Keycode(raw: 0x0005)
        let changes = ConfigStore.diff(from: c, to: t)
        #expect(changes.count == 1)
        #expect(changes[0].description.contains("layer 2") && changes[0].description.contains("row 3") && changes[0].description.contains("col 4"))
        #expect(changes[0].target == .key(layer: 2, row: 3, col: 4, to: Keycode(raw: 0x0005)))
    }

    // Review Focus 4
    @Test func restoreRefusedForDifferentDeviceProtocolOrLayerCount() async throws {
        let (_, _, c) = try await readRecordedConfig()
        var otherProduct = c; otherProduct.productID = 0x0999
        var otherProtocol = c; otherProtocol.protocolVersion = 9
        var fewerLayers = c; fewerLayers.keymap.removeLast(); fewerLayers.encoders.removeLast()
        for bad in [otherProduct, otherProtocol, fewerLayers] {
            #expect(throws: ViaError.self) { try ConfigStore.validateRestorable(bad, against: c) }
        }
        try ConfigStore.validateRestorable(c, against: c)
    }
}
