import Testing
import ViaKit
@testable import KeymapCore

@Suite struct MacroTextTests {
    @Test func roundTripsEveryKindOfStep() throws {
        let steps: [MacroStep] = [.text("Hello there"), .tap(Keycode(raw: 0x04)), .down(Keycode(raw: 0xE1)), .up(Keycode(raw: 0xE1)), .delay(ms: 250), .raw([1, 4, 0x31, 0x7C])]
        #expect(try MacroText.parse(MacroText.format(steps)) == steps)
    }

    @Test func ignoresBlankLinesAndComments() throws {
        #expect(try MacroText.parse("\n# a comment\ntap KC_A\n\n") == [.tap(Keycode(raw: 0x04))])
    }

    @Test func keepsSpacesInTypedText() throws {
        #expect(try MacroText.parse("type  two  spaces ") == [.text(" two  spaces ")])
    }

    @Test func namesTheLineThatIsWrong() {
        #expect(throws: MacroText.ParseError.self) { _ = try MacroText.parse("tap KC_A\nhold KC_B") }
        #expect(throws: MacroText.ParseError.self) { _ = try MacroText.parse("wait fast") }
        #expect(throws: MacroText.ParseError.self) { _ = try MacroText.parse("tap NOPE") }
        do { _ = try MacroText.parse("tap KC_A\nwait 99999") } catch let e as MacroText.ParseError { #expect(e.line == 2) } catch {}
    }

    // Audit C3: indentation and Windows line endings are not part of the step.
    @Test func indentedAndCRLFLinesParse() throws {
        #expect(try MacroText.parse("  tap KC_A\r\n\ttype hi\r\n") == [.tap(Keycode(name: "KC_A")!), .text("hi")])
    }
}
