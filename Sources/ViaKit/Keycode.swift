import Foundation

public enum KeycodeCategory: CaseIterable, Sendable {
    case basic, modifier, media, layer, macro, lighting, device, mouse, dualRole, special, unknown
}

/// A 16-bit QMK keycode as used by VIA protocol 12. Keycodes without a known name are
/// shown as hex and keep their raw value, so unknown keys survive a read/write round trip.
public struct Keycode: Hashable, Codable, Sendable {
    public let raw: UInt16

    public init(raw: UInt16) { self.raw = raw }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(UInt16.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    public var name: String {
        if let e = Self.byRaw[raw] { return e.name }
        if let n = Self.dangerousNames[raw] { return n }
        if let (prefix, n) = Self.layerParts(raw) { return "\(prefix)(\(n))" }
        if Self.macroRange.contains(raw) { return "MC_\(raw - Self.macroRange.lowerBound)" }
        if let p = comboParts { return "\(p.mods.tokens.joined(separator: "+"))(\(Keycode(raw: UInt16(p.key)).name))" }
        if let p = modTapParts { return "MT(\(p.mods.tokens.joined(separator: "+")), \(Keycode(raw: UInt16(p.key)).name))" }
        if let p = layerTapParts { return "LT(\(p.layer), \(Keycode(raw: UInt16(p.key)).name))" }
        if let m = oneShotModParts { return "OSM(\(m.tokens.joined(separator: "+")))" }
        return String(format: "0x%04X", raw)
    }

    public var category: KeycodeCategory {
        if let e = Self.byRaw[raw] { return e.category }
        if Self.layerParts(raw) != nil { return .layer }
        if Self.macroRange.contains(raw) { return .macro }
        if comboParts != nil || modTapParts != nil || layerTapParts != nil || oneShotModParts != nil { return .dualRole }
        if Self.keymapRange.contains(raw) { return .device }
        return .unknown
    }

    /// Parses a name produced by `name`: a table name, `MO(1)`-style layer key, `MC_3`, or `0x7E09`.
    public init?(name: String) {
        if let e = Self.byName[name] { self.init(raw: e.raw); return }
        if let raw = Self.dangerousNames.first(where: { $0.value == name })?.key { self.init(raw: raw); return }
        if name.hasPrefix("0x"), let v = UInt16(name.dropFirst(2), radix: 16) { self.init(raw: v); return }
        if name.hasPrefix("MC_"), let n = UInt16(name.dropFirst(3)), n < Self.macroRange.count {
            self.init(raw: Self.macroRange.lowerBound + n); return
        }
        if let family = Self.parseFamily(name) { self.init(raw: family.raw); return }
        if let open = name.firstIndex(of: "("), name.hasSuffix(")"),
           let base = Self.layerPrefixes.first(where: { $0.0 == name[..<open] })?.1,
           let n = UInt16(name[name.index(after: open)..<name.index(before: name.endIndex)]), n < 32 {
            self.init(raw: base + n); return
        }
        return nil
    }

    /// Keycodes offered in the picker (layer keys for this keyboard's 4 layers, macros 0-15).
    public static let all: [Keycode] = {
        var list = table.map { Keycode(raw: $0.raw) }
        for (_, base) in layerPrefixes { for n in UInt16(0)..<4 { list.append(Keycode(raw: base + n)) } }
        for n in UInt16(0)..<16 { list.append(Keycode(raw: macroRange.lowerBound + n)) }
        list += specialCombos.map { Keycode(raw: $0.raw) }
        list += spaceFnRaws.map { Keycode(raw: $0) }
        return list
    }()

    /// Shifted symbols and the lock-screen shortcuts: ordinary Shift or modifier combinations that the Special group offers as one key.
    /// `(raw, short label, long label)`.
    public static let specialCombos: [(raw: UInt16, short: String, long: String)] = {
        let shift: UInt16 = 0x0200
        let symbols: [(UInt16, String, String)] = [
            (0x35, "~", "Tilde"), (0x1E, "!", "Exclamation mark"), (0x1F, "@", "At sign"), (0x20, "#", "Hash"), (0x21, "$", "Dollar"),
            (0x22, "%", "Percent"), (0x23, "^", "Caret"), (0x24, "&", "Ampersand"), (0x25, "*", "Asterisk"), (0x26, "(", "Left parenthesis"),
            (0x27, ")", "Right parenthesis"), (0x2D, "_", "Underscore"), (0x2E, "+", "Plus"), (0x2F, "{", "Left brace"), (0x30, "}", "Right brace"),
            (0x31, "|", "Vertical bar"), (0x33, ":", "Colon"), (0x34, "\"", "Double quote"), (0x36, "<", "Less than"), (0x37, ">", "Greater than"),
            (0x38, "?", "Question mark"),
        ]
        var list = symbols.map { (raw: shift | $0.0, short: $0.1, long: "\($0.2) (Shift + key)") }
        list.append((raw: 0x0914, short: "Lock", long: "Lock Screen on Mac (Control + Command + Q)"))
        list.append((raw: 0x080F, short: "Lock", long: "Lock Screen on Windows (Windows + L)"))
        return list
    }()

    /// Space bar when tapped, a layer while held, for the keyboard's four layers.
    static let spaceFnRaws: [UInt16] = (0..<4).map { layerTap(layer: $0, key: 0x2C).raw }

    /// Keycodes shown on the picker's Special tab.
    public static let specialRaws: Set<UInt16> = Set(table.filter { $0.category == .special }.map(\.raw) + specialCombos.map(\.raw))

    /// Keycodes shown on the Layers tab besides the layer keys themselves.
    public static let layerKeymapRaws: Set<UInt16> = Set(spaceFnRaws)

    /// Keycodes that would put the keyboard into firmware-flash mode or wipe its settings. The app never writes these;
    /// they are named only so a refusal can say which key it found. They are not in `table`, so the picker never offers them.
    static let dangerousNames: [UInt16: String] = [0x7C00: "QK_BOOT", 0x7C03: "QK_CLEAR_EEPROM"]
    public static let dangerousRaws: Set<UInt16> = Set(dangerousNames.keys)
    public var isDangerous: Bool { Self.dangerousRaws.contains(raw) }

    // MARK: - Families built from parts

    /// Modifier(s) held with a key: `0x0100...0x1FFF`.
    public var comboParts: (mods: ModifierSet, key: UInt8)? {
        guard (0x0100...0x1FFF).contains(raw) else { return nil }
        let mods = ModifierSet(rawValue: UInt8((raw >> 8) & 0x1F))
        return mods.hasBase ? (mods, UInt8(raw & 0xFF)) : nil
    }

    /// A key that is a modifier while held and a normal key when tapped: `0x2000...0x3FFF`.
    public var modTapParts: (mods: ModifierSet, key: UInt8)? {
        guard (0x2000...0x3FFF).contains(raw) else { return nil }
        let mods = ModifierSet(rawValue: UInt8((raw >> 8) & 0x1F))
        return mods.hasBase ? (mods, UInt8(raw & 0xFF)) : nil
    }

    /// A key that switches to a layer while held and is a normal key when tapped: `0x4000...0x4FFF`.
    public var layerTapParts: (layer: Int, key: UInt8)? {
        guard (0x4000...0x4FFF).contains(raw) else { return nil }
        return (Int((raw >> 8) & 0xF), UInt8(raw & 0xFF))
    }

    /// A modifier that applies to the next key only: `0x52A0...0x52BF`.
    public var oneShotModParts: ModifierSet? {
        guard (0x52A0...0x52BF).contains(raw) else { return nil }
        let mods = ModifierSet(rawValue: UInt8(raw & 0x1F))
        return mods.hasBase ? mods : nil
    }

    public static func combo(mods: ModifierSet, key: UInt8) -> Keycode { Keycode(raw: UInt16(mods.rawValue) << 8 | UInt16(key)) }
    public static func modTap(mods: ModifierSet, key: UInt8) -> Keycode { Keycode(raw: 0x2000 | UInt16(mods.rawValue) << 8 | UInt16(key)) }
    public static func layerTap(layer: Int, key: UInt8) -> Keycode { Keycode(raw: 0x4000 | UInt16(layer & 0xF) << 8 | UInt16(key)) }
    public static func oneShotMod(_ mods: ModifierSet) -> Keycode { Keycode(raw: 0x52A0 | UInt16(mods.rawValue)) }

    /// Parses `LCTL+LSFT(KC_A)`, `MT(LSFT, KC_A)`, `LT(1, KC_A)` and `OSM(LSFT)`.
    private static func parseFamily(_ name: String) -> Keycode? {
        guard let open = name.firstIndex(of: "("), name.hasSuffix(")") else { return nil }
        let head = String(name[..<open])
        let inner = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
        func basicKey(_ text: String) -> UInt8? {
            guard let k = Keycode(name: text.trimmingCharacters(in: .whitespaces)), k.raw <= 0xFF else { return nil }
            return UInt8(k.raw)
        }
        switch head {
        case "MT":
            let parts = inner.components(separatedBy: ", ")
            guard parts.count == 2, let mods = ModifierSet(tokens: parts[0].components(separatedBy: "+")), let key = basicKey(parts[1]) else { return nil }
            return modTap(mods: mods, key: key)
        case "LT":
            let parts = inner.components(separatedBy: ", ")
            guard parts.count == 2, let layer = Int(parts[0]), (0..<16).contains(layer), let key = basicKey(parts[1]) else { return nil }
            return layerTap(layer: layer, key: key)
        case "OSM":
            guard let mods = ModifierSet(tokens: inner.components(separatedBy: "+")) else { return nil }
            return oneShotMod(mods)
        default:
            guard let mods = ModifierSet(tokens: head.components(separatedBy: "+")), let key = basicKey(inner) else { return nil }
            return combo(mods: mods, key: key)
        }
    }

    // MARK: - Tables

    private struct Entry { let raw: UInt16; let name: String; let category: KeycodeCategory }

    private static let layerPrefixes: [(String, UInt16)] = [
        ("TO", 0x5200), ("MO", 0x5220), ("DF", 0x5240), ("TG", 0x5260), ("OSL", 0x5280), ("TT", 0x52C0),
    ]
    private static let macroRange: Range<UInt16> = 0x7700..<0x7780
    private static let keymapRange: ClosedRange<UInt16> = 0x7E00...0x7EFF

    private static func layerParts(_ raw: UInt16) -> (String, UInt16)? {
        for (prefix, base) in layerPrefixes where raw >= base && raw < base + 32 { return (prefix, raw - base) }
        return nil
    }

    private static let table: [Entry] = {
        var t: [Entry] = [Entry(raw: 0x0000, name: "KC_NO", category: .basic), Entry(raw: 0x0001, name: "KC_TRNS", category: .basic)]
        func add(_ raw: UInt16, _ name: String, _ cat: KeycodeCategory = .basic) { t.append(Entry(raw: raw, name: name, category: cat)) }
        for (i, ch) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { add(0x04 + UInt16(i), "KC_\(ch)") }
        for (i, ch) in "1234567890".enumerated() { add(0x1E + UInt16(i), "KC_\(ch)") }
        let named: [(UInt16, String)] = [
            (0x28, "KC_ENT"), (0x29, "KC_ESC"), (0x2A, "KC_BSPC"), (0x2B, "KC_TAB"), (0x2C, "KC_SPC"),
            (0x2D, "KC_MINS"), (0x2E, "KC_EQL"), (0x2F, "KC_LBRC"), (0x30, "KC_RBRC"), (0x31, "KC_BSLS"),
            (0x32, "KC_NUHS"), (0x33, "KC_SCLN"), (0x34, "KC_QUOT"), (0x35, "KC_GRV"), (0x36, "KC_COMM"),
            (0x37, "KC_DOT"), (0x38, "KC_SLSH"), (0x39, "KC_CAPS"),
            (0x46, "KC_PSCR"), (0x47, "KC_SCRL"), (0x48, "KC_PAUS"), (0x49, "KC_INS"), (0x4A, "KC_HOME"),
            (0x4B, "KC_PGUP"), (0x4C, "KC_DEL"), (0x4D, "KC_END"), (0x4E, "KC_PGDN"), (0x4F, "KC_RGHT"),
            (0x50, "KC_LEFT"), (0x51, "KC_DOWN"), (0x52, "KC_UP"), (0x53, "KC_NUM"), (0x54, "KC_PSLS"),
            (0x55, "KC_PAST"), (0x56, "KC_PMNS"), (0x57, "KC_PPLS"), (0x58, "KC_PENT"), (0x62, "KC_P0"),
            (0x63, "KC_PDOT"), (0x65, "KC_APP"),
        ]
        for (r, n) in named { add(r, n) }
        for i in 1...12 { add(0x39 + UInt16(i), "KC_F\(i)") }
        for i in 13...24 { add(0x68 + UInt16(i - 13), "KC_F\(i)") }
        for i in 1...9 { add(0x58 + UInt16(i), "KC_P\(i)") }
        let mods = ["KC_LCTL", "KC_LSFT", "KC_LALT", "KC_LGUI", "KC_RCTL", "KC_RSFT", "KC_RALT", "KC_RGUI"]
        for (i, n) in mods.enumerated() { add(0xE0 + UInt16(i), n, .modifier) }
        let media: [(UInt16, String)] = [
            (0xA8, "KC_MUTE"), (0xA9, "KC_VOLU"), (0xAA, "KC_VOLD"), (0xAB, "KC_MNXT"), (0xAC, "KC_MPRV"),
            (0xAD, "KC_MSTP"), (0xAE, "KC_MPLY"), (0xAF, "KC_MSEL"), (0xB0, "KC_EJCT"), (0xB1, "KC_MAIL"),
            (0xB2, "KC_CALC"), (0xB3, "KC_MYCM"), (0xB4, "KC_WSCH"), (0xB5, "KC_WHOM"), (0xB6, "KC_WBAK"),
            (0xB7, "KC_WFWD"), (0xB8, "KC_WSTP"), (0xB9, "KC_WREF"), (0xBA, "KC_WFAV"), (0xBB, "KC_MFFD"),
            (0xBC, "KC_MRWD"), (0xBD, "KC_BRIU"), (0xBE, "KC_BRID"), (0xC0, "KC_ASST"), (0xC1, "KC_MCTL"),
            (0xC2, "KC_LPAD"),
        ]
        for (r, n) in media { add(r, n, .media) }
        // Lighting keys as laid out on this keyboard's Fn layer (toggle, modes, hue, sat, value, speed).
        let lighting = ["RGB_TOG", "RGB_MOD", "RGB_RMOD", "RGB_HUI", "RGB_HUD", "RGB_SAI", "RGB_SAD", "RGB_VAI", "RGB_VAD", "RGB_SPI", "RGB_SPD"]
        for (i, n) in lighting.enumerated() { add(0x7820 + UInt16(i), n, .lighting) }
        let mouse: [(UInt16, String)] = [
            (0xCD, "KC_MS_UP"), (0xCE, "KC_MS_DOWN"), (0xCF, "KC_MS_LEFT"), (0xD0, "KC_MS_RIGHT"),
            (0xD1, "KC_BTN1"), (0xD2, "KC_BTN2"), (0xD3, "KC_BTN3"), (0xD4, "KC_BTN4"), (0xD5, "KC_BTN5"), (0xD6, "KC_BTN6"), (0xD7, "KC_BTN7"), (0xD8, "KC_BTN8"),
            (0xD9, "KC_WH_U"), (0xDA, "KC_WH_D"), (0xDB, "KC_WH_L"), (0xDC, "KC_WH_R"), (0xDD, "KC_ACL0"), (0xDE, "KC_ACL1"), (0xDF, "KC_ACL2"),
        ]
        for (r, n) in mouse { add(r, n, .mouse) }
        // Keychron's own keys. Identified from where they sit in this keyboard's keymap: Option/Command pairs beside
        // the space bar on the Mac layer, Siri / screenshot at the top right, and Task View / File Explorer where the
        // Mac layer has Mission Control / Launchpad.
        let deviceKeys: [(UInt16, String)] = [
            (0x7E02, "KC_LOPTN"), (0x7E03, "KC_ROPTN"), (0x7E04, "KC_LCMMD"), (0x7E05, "KC_RCMMD"), (0x7E06, "KC_SIRI"),
            (0x7E07, "KC_TASK"), (0x7E08, "KC_FILE"), (0x7E09, "KC_SNAP"), (0x7E0A, "KC_CTANA"),
        ]
        for (r, n) in deviceKeys { add(r, n, .device) }
        // Keys the Special group offers, with the numbers Keychron's Launcher uses for this keyboard (VIA protocol 12).
        let special: [(UInt16, String)] = [
            (0x64, "KC_NUBS"), (0x87, "KC_RO"), (0x88, "KC_KANA"), (0x89, "KC_JYEN"), (0x8A, "KC_HENK"), (0x8B, "KC_MHEN"),
            (0x90, "KC_HAEN"), (0x91, "KC_HANJ"), (0x99, "KC_ERAS"), (0xA5, "KC_PWR"), (0xA6, "KC_SLEP"), (0xA7, "KC_WAKE"),
            (0x7013, "NK_TOGG"), (0x700B, "GUI_TOG"), (0x7C02, "DB_TOGG"), (0x7C16, "KC_GESC"),
            (0x7C18, "SC_LCPO"), (0x7C19, "SC_RCPC"), (0x7C1A, "SC_LSPO"), (0x7C1B, "SC_RSPC"), (0x7C1C, "SC_LAPO"), (0x7C1D, "SC_RAPC"), (0x7C1E, "SC_SENT"),
        ]
        for (r, n) in special { add(r, n, .special) }
        add(0x7C77, "FN_MO13", .layer)
        add(0x7C78, "FN_MO23", .layer)
        return t
    }()

    private static let byRaw: [UInt16: Entry] = Dictionary(uniqueKeysWithValues: table.map { ($0.raw, $0) })
    private static let byName: [String: Entry] = Dictionary(uniqueKeysWithValues: table.map { ($0.name, $0) })
}

/// The modifiers in a combo, Mod-Tap or one-shot key: control, shift, alt, gui, and whether they are the right-hand ones.
public struct ModifierSet: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue & 0x1F }
    public static let ctrl = ModifierSet(rawValue: 0x01)
    public static let shift = ModifierSet(rawValue: 0x02)
    public static let alt = ModifierSet(rawValue: 0x04)
    public static let gui = ModifierSet(rawValue: 0x08)
    public static let right = ModifierSet(rawValue: 0x10)

    /// True when at least one of control, shift, alt or gui is set (`.right` alone means nothing).
    public var hasBase: Bool { rawValue & 0x0F != 0 }

    /// `LCTL`, `LSFT`, `LALT`, `LGUI`, or the `R...` versions when `.right` is set.
    public var tokens: [String] {
        let side = contains(.right) ? "R" : "L"
        return [(ModifierSet.ctrl, "CTL"), (.shift, "SFT"), (.alt, "ALT"), (.gui, "GUI")].filter { contains($0.0) }.map { side + $0.1 }
    }

    public init?(tokens: [String]) {
        guard !tokens.isEmpty else { return nil }
        var set = ModifierSet()
        var side: Character?
        for token in tokens {
            guard token.count == 4, let first = token.first, first == "L" || first == "R" else { return nil }
            if let side, side != first { return nil }
            side = first
            switch token.dropFirst() {
            case "CTL": set.insert(.ctrl)
            case "SFT": set.insert(.shift)
            case "ALT": set.insert(.alt)
            case "GUI": set.insert(.gui)
            default: return nil
            }
        }
        if side == "R" { set.insert(.right) }
        self = set
    }
}
