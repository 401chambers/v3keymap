import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct DeviceGuardTests {
    @Test func validateAcceptsV3() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        try await ViaDevice(transport: kb).validate()
    }

    @Test func validateRejectsWrongProtocol() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        kb.protocolVersionOverride = 0x0009
        do {
            try await ViaDevice(transport: kb).validate()
            Issue.record("expected wrongDevice")
        } catch ViaError.wrongDevice(let message) {
            #expect(message.contains("0x9"))
        }
    }
}
