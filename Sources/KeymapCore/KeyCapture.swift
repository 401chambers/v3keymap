import AppKit
import ApplicationServices
import CoreGraphics

/// Turns macOS key events into QMK keycodes so Key Test can count presses and see knob turns.
public enum MacKeyMap {
    /// Macs name keys by position-based virtual key codes; QMK keycodes for letters, digits and so on are USB HID usages.
    static let table: [Int: UInt16] = [
        0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0A, 4: 0x0B, 34: 0x0C, 38: 0x0D, 40: 0x0E, 37: 0x0F,
        46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15, 1: 0x16, 17: 0x17, 32: 0x18, 9: 0x19, 13: 0x1A, 7: 0x1B,
        16: 0x1C, 6: 0x1D, 18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24, 28: 0x25, 25: 0x26, 29: 0x27,
        36: 0x28, 53: 0x29, 51: 0x2A, 48: 0x2B, 49: 0x2C, 27: 0x2D, 24: 0x2E, 33: 0x2F, 30: 0x30, 42: 0x31, 41: 0x33, 39: 0x34,
        50: 0x35, 43: 0x36, 47: 0x37, 44: 0x38, 57: 0x39,
        122: 0x3A, 120: 0x3B, 99: 0x3C, 118: 0x3D, 96: 0x3E, 97: 0x3F, 98: 0x40, 100: 0x41, 101: 0x42, 109: 0x43, 103: 0x44, 111: 0x45,
        114: 0x49, 115: 0x4A, 116: 0x4B, 117: 0x4C, 119: 0x4D, 121: 0x4E, 124: 0x4F, 123: 0x50, 125: 0x51, 126: 0x52,
        160: 0xC1, 131: 0xC2,   // Mission Control, Launchpad
    ]
    /// Modifier keys arrive as "flags changed" events: virtual key code, the keycode, and the device-specific flag bit.
    static let modifiers: [Int: (qmk: UInt16, mask: UInt64)] = [
        59: (0xE0, 0x0001), 56: (0xE1, 0x0002), 60: (0xE5, 0x0004), 55: (0xE3, 0x0008), 54: (0xE7, 0x0010),
        58: (0xE2, 0x0020), 61: (0xE6, 0x0040), 62: (0xE4, 0x2000),
    ]
    /// Media keys arrive as system events with an NX key type.
    static let media: [Int: UInt16] = [
        0: 0xA9, 1: 0xAA, 7: 0xA8, 2: 0xBD, 3: 0xBE, 16: 0xAE, 17: 0xAB, 18: 0xAC, 19: 0xBB, 20: 0xBC,
    ]

    public static func qmk(forVirtualKey code: Int) -> UInt16? { table[code] }
    public static func qmk(forMediaKey type: Int) -> UInt16? { media[type] }

    /// Keychron's explicit left/right Option and Command keycodes send the same keys as the standard ones.
    public static func normalised(_ keycode: UInt16) -> UInt16 {
        switch keycode {
        case 0x7E02: return 0xE2
        case 0x7E03: return 0xE6
        case 0x7E04: return 0xE3
        case 0x7E05: return 0xE7
        default: return keycode
        }
    }
}

/// While Key Test is open and this app is in front, swallows keyboard events so pressing keys does not also run them
/// (volume, brightness, shortcuts), and reports each fresh press. Needs the Accessibility permission to swallow events.
/// Mouse and trackpad are never touched.
public final class KeyCapture: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let lock = NSLock()
    private var swallowing = false
    private var pressHandler: (@Sendable (UInt16) -> Void)?

    public init() {}
    deinit { stop() }

    public static var isTrusted: Bool { AXIsProcessTrusted() }
    /// Shows macOS's own "allow Accessibility" prompt.
    public static func requestTrust() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    public var isRunning: Bool { tap != nil }

    public var isSwallowing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return swallowing }
        set { lock.lock(); swallowing = newValue; lock.unlock() }
    }

    /// Starts watching (and, when `isSwallowing` is set, swallowing). Returns false without the permission.
    @discardableResult
    public func start(onPress: @escaping @Sendable (UInt16) -> Void) -> Bool {
        if tap != nil { return true }
        guard Self.isTrusted else { return false }
        pressHandler = onPress
        let mask: CGEventMask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(0) { $0 | (1 << $1.rawValue) } | (1 << 14)
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                              callback: { _, type, event, ctx in
            let capture = Unmanaged<KeyCapture>.fromOpaque(ctx!).takeUnretainedValue()
            return capture.handle(type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    public func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil; tap = nil; pressHandler = nil
        isSwallowing = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if let key = pressedKey(type: type, event: event) { pressHandler?(key) }
        return isSwallowing ? nil : Unmanaged.passUnretained(event)
    }

    /// The QMK keycode of a fresh press (not a key repeat or a release), if this event is one.
    private func pressedKey(type: CGEventType, event: CGEvent) -> UInt16? {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            return event.getIntegerValueField(.keyboardEventAutorepeat) == 0 ? MacKeyMap.qmk(forVirtualKey: code) : nil
        case .flagsChanged:
            if code == 57 { return 0x39 }          // Caps Lock reports a change on each press
            guard let m = MacKeyMap.modifiers[code] else { return nil }
            return event.flags.rawValue & m.mask != 0 ? m.qmk : nil
        default:
            guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return nil }
            let data = ns.data1
            let isDown = ((data & 0xFF00) >> 8) == 0xA, isRepeat = (data & 1) != 0
            return isDown && !isRepeat ? MacKeyMap.qmk(forMediaKey: (data & 0xFFFF0000) >> 16) : nil
        }
    }
}
