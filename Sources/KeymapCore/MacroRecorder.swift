import AppKit
import ViaKit

/// Turns what you type while recording into macro steps.
public enum MacroRecorder {
    /// One key going down or up, and when.
    public struct Event: Equatable, Sendable {
        public let code: UInt16
        public let isDown: Bool
        public let time: TimeInterval
        public init(code: UInt16, isDown: Bool, time: TimeInterval) { self.code = code; self.isDown = isDown; self.time = time }
    }

    /// What to do about the pauses between keys.
    public enum Delay: Equatable, Sendable {
        /// Keys follow each other with no waits.
        case none
        /// Waits are recorded as they happened (pauses under 20 ms are ignored).
        case dynamic
        /// The same wait, in milliseconds, between every step.
        case fixed(Int)
    }

    /// Steps for `events`. A key pressed and released with nothing in between becomes a single tap.
    public static func steps(from events: [Event], delay: Delay) -> [MacroStep] {
        struct Piece { var step: MacroStep; var start: TimeInterval; var end: TimeInterval }
        var pieces: [Piece] = []
        var i = 0
        while i < events.count {
            let e = events[i]
            if e.isDown, i + 1 < events.count, !events[i + 1].isDown, events[i + 1].code == e.code {
                pieces.append(Piece(step: .tap(Keycode(raw: e.code)), start: e.time, end: events[i + 1].time))
                i += 2
            } else {
                pieces.append(Piece(step: e.isDown ? .down(Keycode(raw: e.code)) : .up(Keycode(raw: e.code)), start: e.time, end: e.time))
                i += 1
            }
        }
        var out: [MacroStep] = []
        for (n, piece) in pieces.enumerated() {
            if n > 0 {
                switch delay {
                case .none: break
                case .fixed(let ms): if ms > 0 { out.append(.delay(ms: min(ms, 65535))) }
                case .dynamic:
                    let ms = Int(((piece.start - pieces[n - 1].end) * 1000).rounded())
                    if ms >= 20 { out.append(.delay(ms: min(ms, 65535))) }
                }
            }
            out.append(piece.step)
        }
        return out
    }

    /// The QMK keycode for a key event the app can see, and whether it went down. Key repeats are ignored.
    static func event(from ns: NSEvent) -> (code: UInt16, isDown: Bool)? {
        switch ns.type {
        case .keyDown:
            if ns.isARepeat { return nil }
            return MacKeyMap.qmk(forVirtualKey: Int(ns.keyCode)).map { ($0, true) }
        case .keyUp:
            return MacKeyMap.qmk(forVirtualKey: Int(ns.keyCode)).map { ($0, false) }
        case .flagsChanged:
            let code = Int(ns.keyCode)
            if code == 57 { return nil }   // Caps Lock reports a change per press, not per release
            guard let m = MacKeyMap.modifiers[code] else { return nil }
            return (m.qmk, UInt64(ns.modifierFlags.rawValue) & m.mask != 0)
        case .systemDefined:
            guard ns.subtype.rawValue == 8 else { return nil }
            let data = ns.data1
            let isDown = ((data & 0xFF00) >> 8) == 0xA, isRepeat = (data & 1) != 0
            if isRepeat { return nil }
            return MacKeyMap.qmk(forMediaKey: (data & 0xFFFF0000) >> 16).map { ($0, isDown) }
        default: return nil
        }
    }
}
