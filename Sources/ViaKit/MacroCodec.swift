import Foundation

public enum MacroStep: Equatable, Codable, Sendable {
    case text(String)
    case tap(Keycode)
    case down(Keycode)
    case up(Keycode)
    case delay(ms: Int)
    /// A macro this app cannot read (made by another tool or a different format). Kept byte for byte so it survives.
    case raw([UInt8])
}

/// Converts the keyboard's raw macro buffer to editable steps and back, using QMK's dynamic-macro
/// format: each macro ends with 0x00; text is printable ASCII; actions are `0x01` plus an action code.
///
/// - `01 01/02/03 kc`: tap/down/up with an 8-bit keycode
/// - `01 05/06/07 lo hi`: tap/down/up with a 16-bit keycode (used for keycodes above 0xFF)
/// - `01 04 <digits> 7C`: delay in milliseconds, as ASCII decimal digits ending with `|`
public enum MacroCodec {
    private static let prefix: UInt8 = 0x01
    private static let delayCode: UInt8 = 0x04
    private static let delayEnd: UInt8 = 0x7C

    public static func encode(_ macros: [[MacroStep]], capacity: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        for macro in macros {
            for step in macro { try append(step, to: &out) }
            out.append(0)
        }
        guard out.count <= capacity else {
            throw ViaError.invalid("macros need \(out.count) bytes but the keyboard has room for \(capacity)")
        }
        return out + [UInt8](repeating: 0, count: capacity - out.count)
    }

    private static func append(_ step: MacroStep, to out: inout [UInt8]) throws {
        switch step {
        case .text(let s):
            for scalar in s.unicodeScalars {
                guard (0x20...0x7E).contains(scalar.value) else {
                    throw ViaError.invalid("macro text can only contain printable ASCII characters; found U+\(String(scalar.value, radix: 16, uppercase: true))")
                }
                out.append(UInt8(scalar.value))
            }
        case .tap(let k): try appendKey(k, base: 1, to: &out)
        case .down(let k): try appendKey(k, base: 2, to: &out)
        case .up(let k): try appendKey(k, base: 3, to: &out)
        case .raw(let bytes):
            try validate(raw: bytes)   // kept byte for byte, but only if the bytes stay inside this slot and press no dangerous key
            out += bytes
        case .delay(let ms):
            guard ms >= 0 else { throw ViaError.invalid("macro delay cannot be negative") }
            out += [prefix, delayCode] + Array(String(ms).utf8) + [delayEnd]
        }
    }

    /// Checks bytes this app did not create before they go to the keyboard. On the keyboard a macro ends at its first
    /// 0x00 and an action takes its operands from whatever bytes follow, so a zero inside the step or an action cut
    /// short at its end would turn the next slot's bytes into keys this slot presses. Unknown actions are left alone.
    public static func validate(raw bytes: [UInt8]) throws {
        if bytes.contains(0) { throw ViaError.invalid("a raw macro step cannot contain 00: that byte ends the macro on the keyboard") }
        func incomplete() -> ViaError { ViaError.invalid("a raw macro step ends in the middle of an action, which would borrow bytes from the next macro") }
        var i = 0
        while i < bytes.count {
            guard bytes[i] == prefix else { i += 1; continue }
            guard i + 1 < bytes.count else { throw incomplete() }
            switch bytes[i + 1] {
            case 1, 2, 3:
                guard i + 2 < bytes.count else { throw incomplete() }
                try refuseDangerous(Keycode(raw: UInt16(bytes[i + 2])))
                i += 3
            case 5, 6, 7:
                guard i + 3 < bytes.count else { throw incomplete() }
                try refuseDangerous(Keycode(raw: UInt16(bytes[i + 2]) | UInt16(bytes[i + 3]) << 8))
                i += 4
            case delayCode:
                guard let end = bytes[(i + 2)...].firstIndex(of: delayEnd) else { throw incomplete() }
                i = end + 1
            default:
                return   // an action this app does not know: its length is unknown, so the rest is kept as it is
            }
        }
    }

    static func refuseDangerous(_ k: Keycode) throws {
        guard !k.isDangerous else {
            throw ViaError.invalid("\(k.name) would put the keyboard into flash mode or erase its settings, so it cannot be used in a macro")
        }
    }

    private static func appendKey(_ k: Keycode, base: UInt8, to out: inout [UInt8]) throws {
        try refuseDangerous(k)
        if k.raw <= 0xFF {
            out += [prefix, base, UInt8(k.raw)]
        } else {
            out += [prefix, base + 4, UInt8(k.raw & 0xFF), UInt8(k.raw >> 8)]
        }
    }

    public static func decode(_ buffer: [UInt8], slots: Int) throws -> [[MacroStep]] {
        var macros: [[MacroStep]] = []
        var i = 0
        while macros.count < slots && i < buffer.count {
            let start = i
            do {
                macros.append(try parseSlot(buffer, &i))
            } catch {
                // Not a macro this app understands: keep its bytes as they are and carry on with the next slot.
                var end = start
                while end < buffer.count && buffer[end] != 0 { end += 1 }
                macros.append([.raw(Array(buffer[start..<end]))])
                i = min(end + 1, buffer.count)
            }
        }
        while macros.count < slots { macros.append([]) }
        return macros
    }

    /// Parses one macro starting at `i`, consuming its terminating 0x00 (if any).
    private static func parseSlot(_ buffer: [UInt8], _ i: inout Int) throws -> [MacroStep] {
        var steps: [MacroStep] = []
        var text = ""
        func flushText() { if !text.isEmpty { steps.append(.text(text)); text = "" } }
        while i < buffer.count {
            let b = buffer[i]
            switch b {
            case 0:
                i += 1
                flushText()
                return steps
            case prefix:
                flushText()
                guard i + 1 < buffer.count else { throw ViaError.invalid("macro buffer ends in the middle of an action") }
                let code = buffer[i + 1]
                switch code {
                case 1, 2, 3:
                    guard i + 2 < buffer.count else { throw ViaError.invalid("macro buffer ends in the middle of an action") }
                    steps.append(key(code, raw: UInt16(buffer[i + 2])))
                    i += 3
                case 5, 6, 7:
                    guard i + 3 < buffer.count else { throw ViaError.invalid("macro buffer ends in the middle of an action") }
                    steps.append(key(code - 4, raw: UInt16(buffer[i + 2]) | UInt16(buffer[i + 3]) << 8))
                    i += 4
                case delayCode:
                    var j = i + 2
                    var ms = 0
                    while j < buffer.count && buffer[j] != delayEnd {
                        guard (0x30...0x39).contains(buffer[j]) else { throw ViaError.invalid("bad macro delay digit 0x\(String(buffer[j], radix: 16))") }
                        ms = ms * 10 + Int(buffer[j] - 0x30)
                        j += 1
                    }
                    guard j < buffer.count else { throw ViaError.invalid("macro delay is missing its end marker") }
                    steps.append(.delay(ms: ms))
                    i = j + 1
                default:
                    throw ViaError.invalid("unknown macro action 0x\(String(code, radix: 16))")
                }
            case 0x20...0x7E:
                text.unicodeScalars.append(Unicode.Scalar(b)); i += 1
            default:
                throw ViaError.invalid("unexpected byte 0x\(String(b, radix: 16)) in macro text")
            }
        }
        flushText()
        return steps
    }

    private static func key(_ kind: UInt8, raw: UInt16) -> MacroStep {
        switch kind {
        case 1: return .tap(Keycode(raw: raw))
        case 2: return .down(Keycode(raw: raw))
        default: return .up(Keycode(raw: raw))
        }
    }
}
