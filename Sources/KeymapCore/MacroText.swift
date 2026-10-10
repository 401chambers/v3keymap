import ViaKit

/// A macro as plain text, one step per line, for the Code Input tab:
///
///     tap KC_A
///     down KC_LSFT
///     up KC_LSFT
///     wait 250
///     type Hello there
public enum MacroText {
    public struct ParseError: Error, Equatable { public let line: Int; public let message: String }

    public static func format(_ steps: [MacroStep]) -> String {
        steps.map { step -> String in
            switch step {
            case .text(let t): return "type \(t)"
            case .tap(let k): return "tap \(k.name)"
            case .down(let k): return "down \(k.name)"
            case .up(let k): return "up \(k.name)"
            case .delay(let ms): return "wait \(ms)"
            case .raw(let bytes): return "raw " + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            }
        }.joined(separator: "\n")
    }

    public static func parse(_ text: String) throws -> [MacroStep] {
        var steps: [MacroStep] = []
        // "\r\n" is one Character to Swift, so Windows line endings are normalised before the split.
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (index, rawLine) in normalised.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let n = index + 1
            // Indentation is not part of the step; trailing spaces after `type` are.
            let line = rawLine.drop(while: \.isWhitespace)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let space = line.firstIndex(where: \.isWhitespace) else { throw ParseError(line: n, message: "“\(trimmed)” needs something after the word, for example: tap KC_A") }
            let word = line[..<space].lowercased()
            let rest = String(line[line.index(after: space)...])
            switch word {
            case "type":
                steps.append(.text(rest))
            case "wait":
                guard let ms = Int(rest.trimmingCharacters(in: .whitespaces)), (0...65535).contains(ms) else {
                    throw ParseError(line: n, message: "wait needs a number of milliseconds between 0 and 65535")
                }
                steps.append(.delay(ms: ms))
            case "tap", "down", "up":
                let name = rest.trimmingCharacters(in: .whitespaces)
                guard let code = Keycode(name: name) else { throw ParseError(line: n, message: "“\(name)” is not a key name this app knows (for example KC_A, KC_LSFT or 0x0029)") }
                steps.append(word == "tap" ? .tap(code) : word == "down" ? .down(code) : .up(code))
            case "raw":
                let bytes = rest.split(separator: " ").compactMap { UInt8($0, radix: 16) }
                guard !bytes.isEmpty, bytes.count == rest.split(separator: " ").count else { throw ParseError(line: n, message: "raw needs hex bytes such as 01 04 31 7C") }
                steps.append(.raw(bytes))
            default:
                throw ParseError(line: n, message: "“\(word)” is not a step. Use tap, down, up, wait or type.")
            }
        }
        return steps
    }
}
