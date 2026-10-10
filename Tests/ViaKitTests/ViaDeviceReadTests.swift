import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct ViaDeviceReadTests {
    private func make() throws -> (SimulatedKeyboard, ViaDevice) {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        return (kb, ViaDevice(transport: kb))
    }

    @Test func protocolVersionIs12() async throws {
        let (_, dev) = try make()
        #expect(try await dev.protocolVersion() == 0x000C)
    }

    @Test func layerCountIs4() async throws {
        let (_, dev) = try make()
        #expect(try await dev.layerCount() == 4)
    }

    @Test func keymapMatchesRecordedKeyboard() async throws {
        let (_, dev) = try make()
        let map = try await dev.keymap(layers: 4, size: .v3)
        #expect(map.count == 4 && map[0].count == 6 && map[0][0].count == 16)
        #expect(map[0][0][0].raw == 0x0029)   // Esc
        #expect(map[0][0][1].raw == 0x00BE)   // Mac base: F1 is brightness down
        #expect(map[0][1][0].raw == 0x0035)   // `
    }

    /// Regression: the V3 matrix is 6x16. Assuming 17 columns shifts every layer after the first.
    @Test func layersAreAlignedToTheirOwnMatrix() async throws {
        let (_, dev) = try make()
        let map = try await dev.keymap(layers: 4, size: .v3)
        #expect(MatrixSize.v3 == MatrixSize(rows: 6, cols: 16))
        #expect(map[0][0][0].raw == 0x0029)   // layer 0, Mac base: Esc
        #expect(map[1][0][0].raw == 0x0001)   // layer 1, Mac Fn: transparent
        #expect(map[1][0][1].raw == 0x003A)   // layer 1: F1
        #expect(map[2][0][0].raw == 0x0029)   // layer 2, Windows base: Esc
        #expect(map[2][0][1].raw == 0x003A)   // layer 2: F1
        #expect(map[3][0][0].raw == 0x0001)   // layer 3, Windows Fn: transparent
        #expect(map[3][0][1].raw == 0x00BE)   // layer 3: brightness down
    }

    @Test func encoderActionsPerLayer() async throws {
        let (_, dev) = try make()
        #expect(try await dev.encoder(layer: 0, index: 0, clockwise: true).raw == 0x00A9)
        #expect(try await dev.encoder(layer: 0, index: 0, clockwise: false).raw == 0x00AA)
        #expect(try await dev.encoder(layer: 1, index: 0, clockwise: false).raw == 0x7828)
    }

    @Test func macroInfoAndBuffer() async throws {
        let (_, dev) = try make()
        #expect(try await dev.macroCount() == 16)
        #expect(try await dev.macroBufferSize() == 1750)
        #expect(try await dev.macroBuffer().count == 1750)
    }

    @Test func lightingMatchesRecordedKeyboard() async throws {
        let (_, dev) = try make()
        let l = try await dev.lighting()
        #expect(l == LightingState(brightness: 255, effect: 5, speed: 127, hue: 0, saturation: 252))
    }

    @Test func firmwareString() async throws {
        let (_, dev) = try make()
        #expect(try await dev.firmwareString().hasPrefix("v2.0.0"))
    }

    @Test func matrixStateIdleIsAllZero() async throws {
        let (_, dev) = try make()
        let m = try await dev.matrixState()
        #expect(!m.isEmpty && m.prefix(12).allSatisfy { $0 == 0 })
    }

    // Review Focus 2
    @Test func truncatedReplyFailsWholeKeymapRead() async throws {
        let (kb, dev) = try make()
        kb.truncateAtRequest = 5
        await #expect(throws: ViaError.shortReply) {
            _ = try await dev.keymap(layers: 4, size: .v3)
        }
    }

    @Test func unsupportedChannelThrows() async throws {
        let (_, dev) = try make()
        await #expect(throws: ViaError.unsupported(command: 0x08)) {
            _ = try await dev.customValue(channel: 1, id: 1)
        }
    }

    /// The real keyboard answers one request at a time; concurrent callers (e.g. key-test polling during an
    /// apply) must queue behind each other instead of overlapping.
    @Test func concurrentCallsNeverOverlapOnTheTransport() async throws {
        let (kb, dev) = try make()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try? await dev.layerCount() } }
            for _ in 0..<20 { group.addTask { _ = try? await dev.pressedKeys() } }
        }
        #expect(kb.maxInflight == 1)
    }

    /// A reply that echoes a different offset than was asked for (e.g. a late answer to an earlier request)
    /// must not be accepted as the answer to this one.
    @Test func replyForADifferentOffsetIsRejected() async throws {
        let (kb, dev) = try make()
        kb.replyTransform = { n, reply in
            guard n == 2 else { return reply }
            var wrong = reply
            wrong[2] = wrong[2] &+ 28
            return wrong
        }
        await #expect(throws: ViaError.self) { _ = try await dev.keymap(layers: 4, size: .v3) }
    }
}
