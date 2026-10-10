import Foundation

/// "1 key", "2 keys": a count with its noun.
public func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

extension String {
    /// Headline-style capitals: every word starts with a capital except the small joining words ("and", "to", "of" ...),
    /// which stay lower case unless they come first. The rest of each word is left as it is ("RGB", "Mac Base").
    public var titleCased: String {
        let small: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "with"]
        var out = ""
        var isFirst = true
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            let letters = word.lowercased().filter(\.isLetter)
            if !isFirst, small.contains(letters), letters == word.lowercased().trimmingCharacters(in: .punctuationCharacters) {
                out += word
            } else if let i = word.firstIndex(where: \.isLetter) {
                out += word[..<i] + word[i].uppercased() + word[word.index(after: i)...]
            } else {
                out += word
            }
            isFirst = false
            word = ""
        }
        for ch in self {
            if ch == " " { flush(); out.append(ch) } else { word.append(ch) }
        }
        flush()
        return out
    }
}

/// Builds the text you have typed from key presses, for Key Test's "Typed" box.
public enum TypedText {
    private static let letters = Array("abcdefghijklmnopqrstuvwxyz")
    private static let digits = Array("1234567890"), shiftedDigits = Array("!@#$%^&*()")
    private static let punctuation: [UInt16: (Character, Character)] = [
        0x2D: ("-", "_"), 0x2E: ("=", "+"), 0x2F: ("[", "{"), 0x30: ("]", "}"), 0x31: ("\\", "|"), 0x32: ("#", "~"),
        0x33: (";", ":"), 0x34: ("'", "\""), 0x35: ("`", "~"), 0x36: (",", "<"), 0x37: (".", ">"), 0x38: ("/", "?"),
    ]

    /// Adds what the key would type to `text` (Backspace removes the last character). Keys that type nothing are ignored.
    public static func apply(code: UInt16, shift: Bool, capsLock: Bool, to text: inout String) {
        switch code {
        case 0x04...0x1D:
            let c = letters[Int(code - 0x04)]
            text.append(shift != capsLock ? Character(c.uppercased()) : c)
        case 0x1E...0x27:
            text.append(shift ? shiftedDigits[Int(code - 0x1E)] : digits[Int(code - 0x1E)])
        case 0x28: text.append("\n")
        case 0x2A: if !text.isEmpty { text.removeLast() }
        case 0x2B: text.append("\t")
        case 0x2C: text.append(" ")
        default:
            if let p = punctuation[code] { text.append(shift ? p.1 : p.0) }
        }
    }
}
