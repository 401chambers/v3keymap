import Foundation
import Testing
import ViaKit
import ViaKitTestSupport
@testable import KeymapCore

@Suite struct MacKeyMapTests {
    @Test func virtualKeysMapToQMKKeycodes() {
        #expect(MacKeyMap.qmk(forVirtualKey: 12) == 0x14)     // Q
        #expect(MacKeyMap.qmk(forVirtualKey: 49) == 0x2C)     // Space
        #expect(MacKeyMap.qmk(forVirtualKey: 126) == 0x52)    // Up arrow
        #expect(MacKeyMap.qmk(forVirtualKey: 9999) == nil)
    }

    @Test func mediaKeysMapToQMKKeycodes() {
        #expect(MacKeyMap.qmk(forMediaKey: 0) == 0xA9)        // volume up
        #expect(MacKeyMap.qmk(forMediaKey: 1) == 0xAA)        // volume down
        #expect(MacKeyMap.qmk(forMediaKey: 7) == 0xA8)        // mute
    }

    @Test func keymapOptionAndCommandKeysCountAsTheStandardOnes() {
        #expect(MacKeyMap.normalised(0x7E02) == 0xE2)
        #expect(MacKeyMap.normalised(0x7E05) == 0xE7)
        #expect(MacKeyMap.normalised(0x0004) == 0x0004)
    }
}

@MainActor
@Suite struct KeyTestCountingTests {
    private func connected() async throws -> AppModel {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let model = AppModel(transportFactory: { kb },
                             backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("extras-app-tests-\(UUID().uuidString)"))
        await model.connect()
        return model
    }

    @Test func eachPressAddsOneToItsKey() async throws {
        let model = try await connected()
        model.applyPress(0x14, heldCodes: [0x14])
        model.applyPress(0x14, heldCodes: [0x14])
        model.applyPress(0x04, heldCodes: [0x04])
        #expect(model.keyCounts[0x14] == 2 && model.keyCounts[0x04] == 1)
        model.resetKeyCounts()
        #expect(model.keyCounts.isEmpty)
    }

    @Test func aKnobActionWithNoSuchKeyHeldIsAKnobTurn() async throws {
        let model = try await connected()
        let knob = try #require(model.onDevice?.encoders[0].first)
        model.applyPress(knob.clockwise.raw, heldCodes: [])
        #expect(model.knobRightTurns == 1 && model.knobLeftTurns == 0 && model.knobFlashRight && !model.knobFlashLeft)
        model.applyPress(knob.counterClockwise.raw, heldCodes: [])
        #expect(model.knobLeftTurns == 1 && model.knobFlashLeft && !model.knobFlashRight)
        #expect(model.keyCounts.isEmpty)
    }

    @Test func theSameKeyOnTheKeyboardIsCountedAsAKeyNotAKnobTurn() async throws {
        let model = try await connected()
        let knob = try #require(model.onDevice?.encoders[0].first)
        model.applyPress(knob.clockwise.raw, heldCodes: [MacKeyMap.normalised(knob.clockwise.raw)])
        #expect(model.knobRightTurns == 0)
        #expect(model.keyCounts[MacKeyMap.normalised(knob.clockwise.raw)] == 1)
    }

    @Test func pressCountsShowOnEveryKeyWithThatKeycode() async throws {
        let model = try await connected()
        let keymap = try #require(model.onDevice?.keymap[0])
        model.applyPress(0x14, heldCodes: [0x14])
        let q = try #require((0..<keymap.count).flatMap { r in (0..<keymap[r].count).map { MatrixPosition(row: r, col: $0) } }.first { keymap[$0.row][$0.col].raw == 0x14 })
        #expect(model.pressCount(at: q) == 1)
        #expect(model.pressCount(at: MatrixPosition(row: 0, col: 0)) == 0)
    }
}

@MainActor
@Suite struct MatrixCountingTests {
    @Test func withoutAccessibilityEachNewPressInTheMatrixIsCounted() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let model = AppModel(transportFactory: { kb }, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("extras-count-\(UUID().uuidString)"))
        await model.connect()
        let q = MatrixPosition(row: 2, col: 1)
        model.selectedPanel = .keyTest
        for _ in 0..<2 {
            kb.heldKeys = [[q.row, q.col]]
            try await Task.sleep(for: .milliseconds(120))
            kb.heldKeys = []
            try await Task.sleep(for: .milliseconds(120))
        }
        model.selectedPanel = .keys
        #expect(model.pressCount(at: q) >= 1)
        model.resetKeyCounts()
        #expect(model.pressCount(at: q) == 0)
    }

    // The Accessibility notice must follow the grant both ways: gone once access is given, back if it is taken away later.
    @Test func accessStateFollowsAccessibilityGrantAndRevocation() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let model = AppModel(transportFactory: { kb }, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("extras-keytest-\(UUID().uuidString)"))
        nonisolated(unsafe) var trusted = false
        model.trustProbe = { trusted }
        await model.connect()
        model.selectedPanel = .keyTest
        #expect(!model.captureAllowed)
        trusted = true
        for _ in 0..<60 where !model.captureAllowed { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.captureAllowed)
        trusted = false
        for _ in 0..<60 where model.captureAllowed { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!model.captureAllowed)
        model.selectedPanel = .keys
    }

    // Opening Key Test must not pop macOS's Accessibility prompt by itself (the notice strip is the invitation);
    // only the Allow Access button asks.
    @Test func openingKeyTestDoesNotPromptButAllowAccessDoes() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let model = AppModel(transportFactory: { kb }, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("extras-keytest-\(UUID().uuidString)"))
        nonisolated(unsafe) var prompts = 0
        model.trustProbe = { false }
        model.trustPrompter = { prompts += 1 }
        await model.connect()
        model.selectedPanel = .keyTest
        try await Task.sleep(for: .milliseconds(1200))      // past one watcher tick
        #expect(prompts == 0)
        model.requestKeyCaptureAccess()
        #expect(prompts == 1)
        model.selectedPanel = .keys
    }
}
