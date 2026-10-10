import Foundation

/// Which extras the keyboard reports (reply byte 2 of command `0xA2`).
public struct KeymapFeatures: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let debounce = KeymapFeatures(rawValue: 0x20)
    public static let snapClick = KeymapFeatures(rawValue: 0x40)
    public static let rgb = KeymapFeatures(rawValue: 0x80)
}

/// Extra raw-HID command numbers (group, then sub-command in the second byte).
enum Keymap {
    static let supportFeature: UInt8 = 0xA2

    /// Misc group.
    static let misc: UInt8 = 0xA7
    enum Misc {
        static let debounceGet: UInt8 = 0x05
        static let debounceSet: UInt8 = 0x06
        static let snapClickInfo: UInt8 = 0x07
        static let snapClickGet: UInt8 = 0x08
        static let snapClickSet: UInt8 = 0x09
        static let snapClickSave: UInt8 = 0x0A
    }

    /// RGB group.
    static let rgb: UInt8 = 0xA8
    enum RGB {
        static let protocolVersion: UInt8 = 0x01
        static let save: UInt8 = 0x02
        static let ledIndicatorGet: UInt8 = 0x03
        static let ledIndicatorSet: UInt8 = 0x04
        static let ledCount: UInt8 = 0x05
        static let ledIndex: UInt8 = 0x06
        static let perKeyTypeGet: UInt8 = 0x07
        static let perKeyTypeSet: UInt8 = 0x08
        static let perKeyColorGet: UInt8 = 0x09
        static let perKeyColorSet: UInt8 = 0x0A
        static let mixedInfo: UInt8 = 0x0B
        static let regionsGet: UInt8 = 0x0C
        static let regionsSet: UInt8 = 0x0D
        static let effectListGet: UInt8 = 0x0E
        static let effectListSet: UInt8 = 0x0F
    }
}

extension ViaDevice {
    /// The only requests the app may ever send. Anything else (firmware update, language, wireless, report rate,
    /// factory test, the full VIA settings wipe and bootloader) is refused before it reaches the keyboard.
    static func isAllowed(_ bytes: [UInt8]) -> Bool {
        guard let command = bytes.first else { return false }
        switch command {
        case 0x01, 0x02, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x12, 0x13, 0x14, 0x15,
             0xA1, 0xA2:
            return true
        case Keymap.misc:
            return bytes.count >= 2 && (0x05...0x0A).contains(bytes[1])
        case Keymap.rgb:
            return bytes.count >= 2 && (bytes[1] == 0x01 || bytes[1] == 0x02 || bytes[1] == 0x03 || bytes[1] == 0x04 || (0x05...0x0F).contains(bytes[1]))
        default:
            return false
        }
    }

    /// Puts the keyboard's own factory keymap and knob actions back (VIA's "dynamic keymap reset"). Macros, lighting and
    /// the extra settings are not touched. The caller saves a backup first and re-reads the keyboard afterwards.
    public func resetKeymapToFactory() async throws {
        _ = try await send([0x06])
    }

    public func keymapFeatures() async throws -> KeymapFeatures {
        KeymapFeatures(rawValue: try await send([Keymap.supportFeature])[2])
    }
}
