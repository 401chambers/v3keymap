import Testing
@testable import KeymapCore

@Suite struct TextHelpersTests {
    @Test func titleCaseCapitalisesWordsButNotSmallJoiningWords() {
        #expect("Effect and colour".titleCased == "Effect and Colour")
        #expect("Brightness and speed".titleCased == "Brightness and Speed")
        #expect("Knob · Mac Base · turn left: Volume down".titleCased == "Knob · Mac Base · Turn Left: Volume Down")
        #expect("Change “3” to".titleCased == "Change “3” to")
        #expect("Add a step by hand".titleCased == "Add a Step by Hand")
        #expect("Caps Lock light".titleCased == "Caps Lock Light")
        #expect("Per-key RGB".titleCased == "Per-key RGB")
        #expect("the end".titleCased == "The End")
    }

    @Test func typedTextFollowsShiftCapsAndBackspace() {
        var t = ""
        func press(_ c: UInt16, shift: Bool = false, caps: Bool = false) { TypedText.apply(code: c, shift: shift, capsLock: caps, to: &t) }
        press(0x0B, shift: true); press(0x08); press(0x0F); press(0x0F); press(0x12)   // H e l l o
        press(0x36); press(0x2C); press(0x1A); press(0x12)                              // , space w o
        press(0x2A)                                                                       // backspace
        press(0x12); press(0x1E, shift: true)                                            // o !
        #expect(t == "Hello, wo!")
        var u = ""
        TypedText.apply(code: 0x04, shift: true, capsLock: true, to: &u)   // shift cancels caps
        #expect(u == "a")
    }
}
