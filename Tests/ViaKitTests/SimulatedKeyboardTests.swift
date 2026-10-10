import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct SimulatedKeyboardTests {
    @Test func protocolVersionReply() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let reply = try await kb.exchange([0x01])
        #expect(reply.count == 32)
        #expect(reply[1] == 0x00 && reply[2] == 0x0C)
    }

    @Test func unknownCommandEchoes0xFF() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let reply = try await kb.exchange([0xFE])
        #expect(reply[0] == 0xFF)
    }

    @Test func sentCommandsRecorded() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        _ = try await kb.exchange([0x01])
        _ = try await kb.exchange([0xFE])
        #expect(kb.sentCommands == [0x01, 0xFE])
    }
}
