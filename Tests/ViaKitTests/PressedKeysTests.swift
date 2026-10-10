import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct PressedKeysTests {
    @Test func idleKeyboardHasNoPressedKeys() async throws {
        let dev = ViaDevice(transport: try SimulatedKeyboard(fixtures: fixturesURL()))
        #expect(try await dev.pressedKeys().isEmpty)
    }

    @Test func heldKeysAreDecodedToMatrixPositions() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        kb.heldKeys = [[0, 0], [2, 5], [3, 9], [5, 15]]
        let pressed = try await ViaDevice(transport: kb).pressedKeys()
        #expect(pressed == [MatrixPosition(row: 0, col: 0), MatrixPosition(row: 2, col: 5),
                            MatrixPosition(row: 3, col: 9), MatrixPosition(row: 5, col: 15)])
    }

    @Test func pollingSendsOnlyTheReadOnlyMatrixCommand() async throws {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let dev = ViaDevice(transport: kb)
        _ = try await dev.pressedKeys()
        #expect(kb.sentCommands == [0x02])
    }

    /// Recorded from the real keyboard by holding one known key at a time (reply bytes from byte 3 on, bytes shown by index).
    @Test func realKeyboardReadingsDecodeToTheKeysThatWerePressed() throws {
        func bytes(_ index: Int, _ value: UInt8) -> [UInt8] { var b = [UInt8](repeating: 0, count: 30); b[index] = value; return b }
        let recorded: [(String, [UInt8], MatrixPosition)] = [
            ("1", bytes(3, 0x02), MatrixPosition(row: 1, col: 1)),
            ("Backspace", bytes(2, 0x20), MatrixPosition(row: 1, col: 13)),
            ("Tab", bytes(5, 0x01), MatrixPosition(row: 2, col: 0)),
            ("Q", bytes(5, 0x02), MatrixPosition(row: 2, col: 1)),
            ("Enter", bytes(6, 0x20), MatrixPosition(row: 3, col: 13)),
            ("Caps", bytes(7, 0x01), MatrixPosition(row: 3, col: 0)),
            ("/", bytes(8, 0x08), MatrixPosition(row: 4, col: 11)),
            ("Right Shift", bytes(8, 0x20), MatrixPosition(row: 4, col: 13)),
            ("Left Shift", bytes(9, 0x01), MatrixPosition(row: 4, col: 0)),
            ("Left Control", bytes(11, 0x01), MatrixPosition(row: 5, col: 0)),
            ("Space", bytes(11, 0x40), MatrixPosition(row: 5, col: 6)),
        ]
        for (name, raw, expected) in recorded {
            #expect(try ViaDevice.pressedKeys(inMatrixBytes: raw, size: .v3) == [expected], "\(name)")
        }
    }
}
