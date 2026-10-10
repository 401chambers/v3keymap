import Testing
import ViaKit
@testable import KeymapCore

@Suite struct MacroRecorderTests {
    private func e(_ code: UInt16, _ down: Bool, _ t: Double) -> MacroRecorder.Event { .init(code: code, isDown: down, time: t) }
    private let a: UInt16 = 0x04, b: UInt16 = 0x05, shift: UInt16 = 0xE1

    @Test func aKeyPressedAndReleasedAloneBecomesATap() {
        let steps = MacroRecorder.steps(from: [e(a, true, 0), e(a, false, 0.05)], delay: .none)
        #expect(steps == [.tap(Keycode(raw: a))])
    }

    @Test func overlappingKeysStayAsDownAndUp() {
        // Shift held while A is tapped.
        let steps = MacroRecorder.steps(from: [e(shift, true, 0), e(a, true, 0.1), e(a, false, 0.15), e(shift, false, 0.2)], delay: .none)
        #expect(steps == [.down(Keycode(raw: shift)), .tap(Keycode(raw: a)), .up(Keycode(raw: shift))])
    }

    @Test func recordedWaitsKeepRealPausesAndDropTinyOnes() {
        let steps = MacroRecorder.steps(from: [e(a, true, 0), e(a, false, 0.01), e(b, true, 0.5), e(b, false, 0.51), e(a, true, 0.515), e(a, false, 0.52)], delay: .dynamic)
        #expect(steps == [.tap(Keycode(raw: a)), .delay(ms: 490), .tap(Keycode(raw: b)), .tap(Keycode(raw: a))])
    }

    @Test func fixedWaitGoesBetweenEveryStep() {
        let steps = MacroRecorder.steps(from: [e(a, true, 0), e(a, false, 0.01), e(b, true, 0.3), e(b, false, 0.31)], delay: .fixed(50))
        #expect(steps == [.tap(Keycode(raw: a)), .delay(ms: 50), .tap(Keycode(raw: b))])
    }

    @Test func nothingRecordedGivesNoSteps() {
        #expect(MacroRecorder.steps(from: [], delay: .dynamic).isEmpty)
    }
}
