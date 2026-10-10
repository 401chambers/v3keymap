import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct KeymapProtocolTests {
    private func make() throws -> (SimulatedKeyboard, ViaDevice) {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        return (kb, ViaDevice(transport: kb))
    }

    @Test func keymapFeaturesReportsDebounceSnapClickAndRGB() async throws {
        let (_, dev) = try make()
        let features = try await dev.keymapFeatures()
        #expect(features.contains([.debounce, .snapClick, .rgb]))
    }

    @Test func allowListRefusesDFUAndLanguageAndWireless() async throws {
        let (kb, dev) = try make()
        let before = kb.sentRequests.count
        for request: [UInt8] in [[0xA7, 0x02], [0xA7, 0x04, 0x00], [0xA7, 0x0B], [0xAA], [0xAB], [0xA9]] {
            await #expect(throws: ViaError.self) { _ = try await dev.send(request) }
        }
        #expect(kb.sentRequests.count == before)
    }

    @Test func allowListAcceptsTheDocumentedKeymapCommands() {
        for request: [UInt8] in [[0xA1], [0xA2], [0xA7, 0x05], [0xA7, 0x06, 4, 50], [0xA7, 0x07], [0xA7, 0x08, 0, 3],
                                 [0xA7, 0x09, 0, 1, 1, 4, 7], [0xA7, 0x0A], [0xA8, 0x01], [0xA8, 0x02], [0xA8, 0x03], [0xA8, 0x04, 0xE0, 0, 255, 255], [0xA8, 0x05], [0xA8, 0x06, 0, 0xFF, 0xFF, 0],
                                 [0xA8, 0x0F, 0, 0, 1]] {
            #expect(ViaDevice.isAllowed(request), "\(request)")
        }
        #expect(!ViaDevice.isAllowed([]))
        #expect(!ViaDevice.isAllowed([0x0A]) && !ViaDevice.isAllowed([0x0B]))
    }

    // Audit C2: nothing in the app sends 0xA0 or 0xA3, so the allowlist must not admit them.
    @Test func unusedKeychronCommandsAreRefused() {
        #expect(!ViaDevice.isAllowed([0xA0]))
        #expect(!ViaDevice.isAllowed([0xA3]))
    }

    @Test func nonZeroStatusBecomesRejected() async throws {
        let (kb, dev) = try make()
        kb.rejectNextKeymapWrite = true
        do {
            _ = try await dev.send([0xA7, 0x06, 4, 50])
            Issue.record("expected rejected")
        } catch ViaError.rejected {
        } catch {
            Issue.record("wrong error \(error)")
        }
        // The flag is one-shot: the next identical write succeeds.
        _ = try await dev.send([0xA7, 0x06, 4, 50])
    }

    @Test func replyForADifferentSubcommandIsRejected() async throws {
        let (kb, dev) = try make()
        kb.replyTransform = { _, reply in var r = reply; r[1] = 0x07; return r }
        await #expect(throws: ViaError.self) { _ = try await dev.send([0xA7, 0x05]) }
    }
}
