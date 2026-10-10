import Foundation
import Testing
@testable import ViaKit

@Suite struct MacroCodecTests {
    private let empty = [[MacroStep]](repeating: [], count: 16)

    private func macros(slot0: [MacroStep]) -> [[MacroStep]] {
        var m = empty
        m[0] = slot0
        return m
    }

    @Test func allZeroBufferDecodesToSixteenEmptyMacros() throws {
        let decoded = try MacroCodec.decode([UInt8](repeating: 0, count: 1750), slots: 16)
        #expect(decoded.count == 16)
        #expect(decoded.allSatisfy { $0.isEmpty })
    }

    @Test func textThenTapRoundTripsWithExpectedBytes() throws {
        let input = macros(slot0: [.text("hello"), .tap(Keycode(raw: 0x28))])
        let bytes = try MacroCodec.encode(input, capacity: 1750)
        #expect(bytes.count == 1750)
        #expect(Array(bytes.prefix(9)) == [0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x01, 0x01, 0x28, 0x00])
        #expect(try MacroCodec.decode(bytes, slots: 16) == input)
    }

    @Test func delayRoundTripsAsDecimalDigits() throws {
        let input = macros(slot0: [.delay(ms: 250)])
        let bytes = try MacroCodec.encode(input, capacity: 1750)
        #expect(Array(bytes.prefix(7)) == [0x01, 0x04, 0x32, 0x35, 0x30, 0x7C, 0x00])
        #expect(try MacroCodec.decode(bytes, slots: 16) == input)
    }

    @Test func downAndUpPairRoundTrips() throws {
        let input = macros(slot0: [.down(Keycode(raw: 0xE1)), .tap(Keycode(raw: 0x04)), .up(Keycode(raw: 0xE1))])
        let bytes = try MacroCodec.encode(input, capacity: 1750)
        #expect(Array(bytes.prefix(10)) == [0x01, 0x02, 0xE1, 0x01, 0x01, 0x04, 0x01, 0x03, 0xE1, 0x00])
        #expect(try MacroCodec.decode(bytes, slots: 16) == input)
    }

    @Test func keycodeAbove0xFFUsesSixteenBitAction() throws {
        let input = macros(slot0: [.tap(Keycode(raw: 0x5221))])
        let bytes = try MacroCodec.encode(input, capacity: 1750)
        #expect(Array(bytes.prefix(5)) == [0x01, 0x05, 0x21, 0x52, 0x00])
        #expect(try MacroCodec.decode(bytes, slots: 16) == input)
    }

    @Test func emptySlotsPreservedAroundAFilledOne() throws {
        var input = empty
        input[3] = [.text("x")]
        let decoded = try MacroCodec.decode(try MacroCodec.encode(input, capacity: 1750), slots: 16)
        #expect(decoded == input)
        #expect(decoded[2].isEmpty && decoded[4].isEmpty)
    }

    // Review Focus 3
    @Test func nonASCIIAndControlTextRejected() {
        #expect(throws: ViaError.self) { try MacroCodec.encode(macros(slot0: [.text("café")]), capacity: 1750) }
        #expect(throws: ViaError.self) { try MacroCodec.encode(macros(slot0: [.text("a\u{01}b")]), capacity: 1750) }
    }

    @Test func overCapacityRejectedWithByteCount() {
        let big = macros(slot0: [.text(String(repeating: "a", count: 1750))])
        do {
            _ = try MacroCodec.encode(big, capacity: 1750)
            Issue.record("expected invalid")
        } catch ViaError.invalid(let message) {
            #expect(message.contains("1766"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    // Review finding: one macro this app cannot read must not stop the keyboard from being edited at all.
    @Test func unreadableSlotIsKeptAsRawBytesAndSurvivesARoundTrip() throws {
        var buffer = [UInt8](repeating: 0, count: 1750)
        buffer.replaceSubrange(0..<6, with: [0x01, 0x09, 0x41, 0x00, 0x6F, 0x6B])   // slot 0: unknown action; slot 1: "ok"
        let decoded = try MacroCodec.decode(buffer, slots: 16)
        #expect(decoded[0] == [.raw([0x01, 0x09, 0x41])])
        #expect(decoded[1] == [.text("ok")])
        #expect(try MacroCodec.encode(decoded, capacity: 1750) == buffer)
    }

    @Test func truncatedActionAtTheEndBecomesRawInsteadOfFailing() throws {
        let decoded = try MacroCodec.decode([0x01], slots: 16)
        #expect(decoded[0] == [.raw([0x01])])
        #expect(decoded.count == 16)
    }

    // Audit A1: the bootloader (0x7C00) and EEPROM-wipe (0x7C03) keycodes must never be encoded into a macro.
    @Test func dangerousKeycodesAreRefusedInMacros() {
        #expect(throws: ViaError.self) { try MacroCodec.encode([[.tap(Keycode(raw: 0x7C00))]], capacity: 64) }
        #expect(throws: ViaError.self) { try MacroCodec.encode([[.down(Keycode(raw: 0x7C03))]], capacity: 64) }
        #expect(throws: ViaError.self) { try MacroCodec.encode([[.raw([0x01, 0x05, 0x03, 0x7C])]], capacity: 64) }   // raw down QK_CLEAR_EEPROM
        #expect(throws: Never.self) { try MacroCodec.encode([[.tap(Keycode(raw: 0x7C01))]], capacity: 64) }
    }

    // Review finding: a 0x00 inside a raw step ends the macro early on the keyboard, so bytes after it become the next
    // slot (here: tap QK_BOOT), and a trailing incomplete action borrows its missing bytes from the next slot.
    @Test func rawStepsCannotSmuggleBytesPastTheSlotEnd() {
        #expect(throws: ViaError.self) { try MacroCodec.encode([[.raw([0x41, 0x00, 0x01, 0x05, 0x00, 0x7C])]], capacity: 64) }
        #expect(throws: ViaError.self) { try MacroCodec.encode([[.raw([0x01, 0x05])]], capacity: 64) }       // 16-bit tap, no keycode
        #expect(throws: ViaError.self) { try MacroCodec.encode([[.raw([0x41, 0x01, 0x01])]], capacity: 64) } // 8-bit tap, no keycode
        #expect(throws: ViaError.self) { try MacroCodec.encode([[.raw([0x01])]], capacity: 64) }             // prefix, no action
        #expect(throws: Never.self) { try MacroCodec.encode([[.raw([0x01, 0x09, 0x41])]], capacity: 64) }    // unknown action: still kept
    }
}
