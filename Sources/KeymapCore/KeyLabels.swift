import Foundation
import ViaKit

/// How a key is tinted on the keyboard picture.
public enum KeyStyle: Sendable { case standard, modifier, media, layer, macro, lighting, mouse, dualRole, transparent, special }

/// What to print on a keycap (`short`), how to describe it in words (`long`), and its tint.
public struct KeyLabel: Equatable, Sendable {
    public let short: String
    public let long: String
    public let style: KeyStyle

    /// "L" or "R" for modifiers that exist on both sides of the keyboard, so the cap can show which one it is.
    public var side: String? {
        guard style == .modifier else { return nil }
        if long.hasPrefix("Left") { return "L" }
        if long.hasPrefix("Right") { return "R" }
        return nil
    }
}

/// Turns QMK keycodes into labels a person recognises: `KC_BRID` becomes "Bright −", `MO(1)` becomes "Fn".
/// Codes it has no label for show as hex and are never changed.
public enum KeyLabels {
    public static func label(for code: Keycode) -> KeyLabel {
        if code.raw == 0 { return KeyLabel(short: "", long: "Does nothing", style: .transparent) }
        if code.raw == 1 { return KeyLabel(short: "▽", long: "Transparent: does what the layer below does", style: .transparent) }
        let name = code.name
        if let known = table[name] { return known }
        if code.category == .layer, let (prefix, n) = layerParts(name) { return layerLabel(prefix, n) }
        if code.category == .macro, name.hasPrefix("MC_"), let n = Int(name.dropFirst(3)) {
            return KeyLabel(short: "M\(n)", long: "Run macro \(n)", style: .macro)
        }
        if let p = code.comboParts {
            let key = label(for: Keycode(raw: UInt16(p.key)))
            return KeyLabel(short: symbols(p.mods) + key.short, long: "\(plain(key)) with \(words(p.mods))", style: .dualRole)
        }
        if let p = code.modTapParts {
            let key = label(for: Keycode(raw: UInt16(p.key)))
            return KeyLabel(short: "\(key.short)/\(symbols(p.mods))", long: "\(plain(key)) when tapped, \(words(p.mods)) when held", style: .dualRole)
        }
        if let p = code.layerTapParts {
            let key = label(for: Keycode(raw: UInt16(p.key)))
            let names = AppModel.layerNames
            let layer = names.indices.contains(p.layer) ? "layer \(p.layer) (\(names[p.layer]))" : "layer \(p.layer)"
            return KeyLabel(short: "\(key.short)/L\(p.layer)", long: "\(plain(key)) when tapped, \(layer) while held", style: .dualRole)
        }
        if let m = code.oneShotModParts {
            return KeyLabel(short: "OS \(symbols(m))", long: "\(words(m)) for the next key only", style: .dualRole)
        }
        if name.hasPrefix("KC_") {
            let rest = String(name.dropFirst(3))
            if rest.count == 1 { return KeyLabel(short: rest, long: "Key \(rest)", style: .standard) }
            return KeyLabel(short: rest, long: rest, style: style(for: code.category))
        }
        return KeyLabel(short: name, long: "Unknown key \(name)", style: .special)
    }

    /// A single character reads best on its own ("A with Shift"); other keys use their full description.
    private static func plain(_ label: KeyLabel) -> String { label.short.count == 1 ? label.short : label.long }

    private static func symbols(_ mods: ModifierSet) -> String {
        [(ModifierSet.ctrl, "⌃"), (.shift, "⇧"), (.alt, "⌥"), (.gui, "⌘")].filter { mods.contains($0.0) }.map(\.1).joined()
    }

    private static func words(_ mods: ModifierSet) -> String {
        let side = mods.contains(.right) ? "Right " : ""
        return [(ModifierSet.ctrl, "Control"), (.shift, "Shift"), (.alt, "Alt"), (.gui, "Command")]
            .filter { mods.contains($0.0) }.map { side + $0.1 }.joined(separator: " + ")
    }

    private static func style(for category: KeycodeCategory) -> KeyStyle {
        switch category {
        case .modifier: return .modifier
        case .media, .device: return .media
        case .layer: return .layer
        case .macro: return .macro
        case .lighting: return .lighting
        case .mouse: return .mouse
        case .dualRole: return .dualRole
        case .basic: return .standard
        case .special: return .special
        case .unknown: return .special
        }
    }

    private static func layerParts(_ name: String) -> (String, Int)? {
        guard let open = name.firstIndex(of: "("), name.hasSuffix(")"),
              let n = Int(name[name.index(after: open)..<name.index(before: name.endIndex)]) else { return nil }
        return (String(name[..<open]), n)
    }

    private static func layerLabel(_ prefix: String, _ n: Int) -> KeyLabel {
        let names = AppModel.layerNames
        let layer = names.indices.contains(n) ? "layer \(n) (\(names[n]))" : "layer \(n)"
        switch prefix {
        case "MO": return KeyLabel(short: "Fn", long: "Hold to use \(layer)", style: .layer)
        case "TO": return KeyLabel(short: "→\(n)", long: "Switch to \(layer)", style: .layer)
        case "TG": return KeyLabel(short: "Tog \(n)", long: "Toggle \(layer) on or off", style: .layer)
        case "TT": return KeyLabel(short: "TT \(n)", long: "Hold for \(layer); tap several times to toggle it", style: .layer)
        case "DF": return KeyLabel(short: "Def \(n)", long: "Make \(layer) the default", style: .layer)
        default: return KeyLabel(short: "OS \(n)", long: "Use \(layer) for the next key only", style: .layer)
        }
    }

    private static let table: [String: KeyLabel] = {
        var t: [String: KeyLabel] = [:]
        func add(_ name: String, _ short: String, _ long: String, _ style: KeyStyle = .standard) {
            t[name] = KeyLabel(short: short, long: long, style: style)
        }
        for (name, short, long) in [
            ("KC_ENT", "↩", "Enter"), ("KC_ESC", "Esc", "Escape"), ("KC_BSPC", "⌫", "Backspace"), ("KC_TAB", "Tab", "Tab"),
            ("KC_SPC", "Space", "Space bar"), ("KC_MINS", "-", "Minus"), ("KC_EQL", "=", "Equals"), ("KC_LBRC", "[", "Left bracket"),
            ("KC_RBRC", "]", "Right bracket"), ("KC_BSLS", "\\", "Backslash"), ("KC_NUHS", "#", "Hash (non-US)"),
            ("KC_SCLN", ";", "Semicolon"), ("KC_QUOT", "'", "Quote"), ("KC_GRV", "`", "Grave accent"), ("KC_COMM", ",", "Comma"),
            ("KC_DOT", ".", "Full stop"), ("KC_SLSH", "/", "Slash"), ("KC_CAPS", "Caps", "Caps Lock"),
            ("KC_PSCR", "PrtSc", "Print Screen"), ("KC_SCRL", "ScrLk", "Scroll Lock"), ("KC_PAUS", "Pause", "Pause"),
            ("KC_INS", "Ins", "Insert"), ("KC_HOME", "Home", "Home"), ("KC_PGUP", "PgUp", "Page Up"), ("KC_DEL", "Del", "Delete"),
            ("KC_END", "End", "End"), ("KC_PGDN", "PgDn", "Page Down"), ("KC_RGHT", "→", "Right arrow"),
            ("KC_LEFT", "←", "Left arrow"), ("KC_DOWN", "↓", "Down arrow"), ("KC_UP", "↑", "Up arrow"), ("KC_NUM", "Num", "Num Lock"),
            ("KC_PSLS", "/", "Keypad slash"), ("KC_PAST", "*", "Keypad asterisk"), ("KC_PMNS", "−", "Keypad minus"),
            ("KC_PPLS", "+", "Keypad plus"), ("KC_PENT", "↩", "Keypad enter"), ("KC_P0", "0", "Keypad 0"),
            ("KC_PDOT", ".", "Keypad full stop"), ("KC_APP", "Menu", "Menu key"),
        ] { add(name, short, long) }
        for i in 1...9 { add("KC_P\(i)", "\(i)", "Keypad \(i)") }
        for i in 1...24 { add("KC_F\(i)", "F\(i)", "F\(i)") }
        for (name, short, long) in [
            ("KC_LCTL", "⌃", "Left Control"), ("KC_LSFT", "⇧", "Left Shift"), ("KC_LALT", "⌥", "Left Alt / Option"),
            ("KC_LGUI", "⌘", "Left Windows / Command"), ("KC_RCTL", "⌃", "Right Control"), ("KC_RSFT", "⇧", "Right Shift"),
            ("KC_RALT", "⌥", "Right Alt / Option"), ("KC_RGUI", "⌘", "Right Windows / Command"),
            ("KC_LOPTN", "⌥", "Left Option"), ("KC_ROPTN", "⌥", "Right Option"), ("KC_LCMMD", "⌘", "Left Command"),
            ("KC_RCMMD", "⌘", "Right Command"),
        ] { add(name, short, long, .modifier) }
        for (name, short, long) in [
            ("KC_MUTE", "Mute", "Mute"), ("KC_VOLU", "Vol +", "Volume up"), ("KC_VOLD", "Vol −", "Volume down"),
            ("KC_MNXT", "Next", "Next track"), ("KC_MPRV", "Prev", "Previous track"), ("KC_MSTP", "Stop", "Stop"),
            ("KC_MPLY", "Play", "Play / Pause"), ("KC_MSEL", "Media", "Media select"), ("KC_EJCT", "Eject", "Eject"),
            ("KC_MAIL", "Mail", "Mail"), ("KC_CALC", "Calc", "Calculator"), ("KC_MYCM", "PC", "My Computer"),
            ("KC_WSCH", "Search", "Web search"), ("KC_WHOM", "Home", "Browser home"), ("KC_WBAK", "Back", "Browser back"),
            ("KC_WFWD", "Fwd", "Browser forward"), ("KC_WSTP", "Stop", "Browser stop"), ("KC_WREF", "Reload", "Browser refresh"),
            ("KC_WFAV", "Fav", "Browser favourites"), ("KC_MFFD", "FF", "Fast forward"), ("KC_MRWD", "Rew", "Rewind"),
            ("KC_BRIU", "Bright +", "Brightness up"), ("KC_BRID", "Bright −", "Brightness down"),
            ("KC_ASST", "Assist", "Assistant"), ("KC_MCTL", "Mission", "Mission Control"), ("KC_LPAD", "Launch", "Launchpad"),
            ("KC_SIRI", "Siri", "Siri"), ("KC_TASK", "Tasks", "Task View"), ("KC_FILE", "Files", "File Explorer"),
            ("KC_SNAP", "Snap", "Screenshot"), ("KC_CTANA", "Search", "Windows Search"),
        ] { add(name, short, long, .media) }
        for (name, short, long) in [
            ("KC_MS_UP", "Mouse ↑", "Move the mouse up"), ("KC_MS_DOWN", "Mouse ↓", "Move the mouse down"),
            ("KC_MS_LEFT", "Mouse ←", "Move the mouse left"), ("KC_MS_RIGHT", "Mouse →", "Move the mouse right"),
            ("KC_BTN1", "Click", "Left mouse button"), ("KC_BTN2", "R-Click", "Right mouse button"), ("KC_BTN3", "M-Click", "Middle mouse button"),
            ("KC_BTN4", "Btn 4", "Mouse button 4"), ("KC_BTN5", "Btn 5", "Mouse button 5"), ("KC_BTN6", "Btn 6", "Mouse button 6"),
            ("KC_BTN7", "Btn 7", "Mouse button 7"), ("KC_BTN8", "Btn 8", "Mouse button 8"),
            ("KC_WH_U", "Scroll ↑", "Scroll up"), ("KC_WH_D", "Scroll ↓", "Scroll down"), ("KC_WH_L", "Scroll ←", "Scroll left"), ("KC_WH_R", "Scroll →", "Scroll right"),
            ("KC_ACL0", "Slow", "Mouse speed: slow"), ("KC_ACL1", "Medium", "Mouse speed: medium"), ("KC_ACL2", "Fast", "Mouse speed: fast"),
        ] { add(name, short, long, .mouse) }
        for (name, short, long) in [
            ("RGB_TOG", "Light", "Backlight: on / off"), ("RGB_MOD", "Fx +", "Backlight: next effect"),
            ("RGB_RMOD", "Fx −", "Backlight: previous effect"), ("RGB_HUI", "Hue +", "Backlight: hue up"),
            ("RGB_HUD", "Hue −", "Backlight: hue down"), ("RGB_SAI", "Sat +", "Backlight: saturation up"),
            ("RGB_SAD", "Sat −", "Backlight: saturation down"), ("RGB_VAI", "Lit +", "Backlight: brightness up"),
            ("RGB_VAD", "Lit −", "Backlight: brightness down"), ("RGB_SPI", "Spd +", "Backlight: speed up"),
            ("RGB_SPD", "Spd −", "Backlight: speed down"),
        ] { add(name, short, long, .lighting) }
        for (name, short, long) in [
            ("KC_NUBS", "\\", "Backslash (non-US)"), ("KC_RO", "Ro", "Japanese Ro"), ("KC_KANA", "かな", "Japanese Kana"), ("KC_JYEN", "¥", "Yen"),
            ("KC_HENK", "変換", "Japanese Henkan"), ("KC_MHEN", "無変換", "Japanese Muhenkan"), ("KC_HAEN", "한영", "Korean Han/Yeong"),
            ("KC_HANJ", "漢字", "Hanja"), ("KC_ERAS", "Erase", "Alternate Erase"), ("KC_PWR", "Power", "Power"), ("KC_SLEP", "Sleep", "Sleep"),
            ("KC_WAKE", "Wake", "Wake"), ("NK_TOGG", "NKRO", "Toggle N-key rollover"), ("GUI_TOG", "Lock Win", "Lock the Windows / Command key"),
            ("DB_TOGG", "Debug", "Toggle debug output"), ("KC_GESC", "`Esc", "Escape, or grave accent with Shift or Command"),
            ("SC_LCPO", "⌃(", "Left Control when held, ( when tapped"), ("SC_RCPC", "⌃)", "Right Control when held, ) when tapped"),
            ("SC_LSPO", "⇧(", "Left Shift when held, ( when tapped"), ("SC_RSPC", "⇧)", "Right Shift when held, ) when tapped"),
            ("SC_LAPO", "⌥(", "Left Alt when held, ( when tapped"), ("SC_RAPC", "⌥)", "Right Alt when held, ) when tapped"),
            ("SC_SENT", "⇧↩", "Right Shift when held, Enter when tapped"),
        ] { add(name, short, long, .special) }
        add("FN_MO13", "Fn1(3)", "Hold for layer 1; hold with Fn2 as well for layer 3", .layer)
        add("FN_MO23", "Fn2(3)", "Hold for layer 2; hold with Fn1 as well for layer 3", .layer)
        for c in Keycode.specialCombos { add(Keycode(raw: c.raw).name, c.short, c.long, .special) }
        return t
    }()
}
