import Foundation

// MARK: Debounce

/// How the keyboard filters key chatter. The numbers are the firmware's.
public enum DebounceType: UInt8, CaseIterable, Codable, Sendable {
    case symDeferGlobal = 0, symDeferPerRow, symDeferPerKey, symEagerPerRow, symEagerPerKey, asymEagerDeferPerKey, none

    public var title: String {
        switch self {
        case .symDeferGlobal: return "Wait for quiet (whole keyboard)"
        case .symDeferPerRow: return "Wait for quiet (per row)"
        case .symDeferPerKey: return "Wait for quiet (per key)"
        case .symEagerPerRow: return "Instant, then ignore (per row)"
        case .symEagerPerKey: return "Instant, then ignore (per key)"
        case .asymEagerDeferPerKey: return "Instant press, delayed release"
        case .none: return "No debounce"
        }
    }

    public var summary: String {
        switch self {
        case .symDeferGlobal: return "Reports a change only after the whole keyboard has been quiet for the delay. Best against chatter, adds the most delay."
        case .symDeferPerRow: return "Reports a change only after that row has been quiet for the delay."
        case .symDeferPerKey: return "Reports a change only after that key has been quiet for the delay."
        case .symEagerPerRow: return "Reports a change at once, then ignores that row for the delay."
        case .symEagerPerKey: return "Reports a change at once, then ignores that key for the delay. Fastest feel; the factory choice."
        case .asymEagerDeferPerKey: return "Presses register at once; releases wait for the delay (at most 127 ms)."
        case .none: return "No filtering at all. Fast, but a chattering switch will type twice."
        }
    }
}

public struct DebounceSettings: Codable, Equatable, Sendable {
    public var type: DebounceType
    /// Milliseconds, as the firmware describes it (at most 255).
    public var time: UInt8
    public init(type: DebounceType, time: UInt8) { self.type = type; self.time = time }

    /// The firmware limits the asymmetric type to 127 ms, so the app does too.
    public var clamped: DebounceSettings {
        DebounceSettings(type: type, time: type == .asymEagerDeferPerKey ? min(time, 127) : time)
    }
}

// MARK: Snap Click

/// What happens when two opposing keys are held at once. The numbers are the firmware's.
public enum SnapClickType: UInt8, CaseIterable, Codable, Sendable {
    case none = 0, regular, lastInput, firstKey, secondKey, neutral

    public var title: String {
        switch self {
        case .none: return "Off"
        case .regular: return "Regular"
        case .lastInput: return "Last input wins"
        case .firstKey: return "First key wins"
        case .secondKey: return "Second key wins"
        case .neutral: return "Neutral"
        }
    }

    public var summary: String {
        switch self {
        case .none: return "This pair does nothing special."
        case .regular: return "Hold both and the key pressed last wins; let go of it and the other one takes over."
        case .lastInput: return "The key you pressed last always wins while both are held."
        case .firstKey: return "The first key of the pair always wins while both are held."
        case .secondKey: return "The second key of the pair always wins while both are held."
        case .neutral: return "Hold both and neither registers; let go of one and the other registers."
        }
    }
}

public struct SnapClickSlot: Codable, Equatable, Sendable {
    public var type: SnapClickType
    public var key1: UInt8
    public var key2: UInt8
    public init(type: SnapClickType, key1: UInt8, key2: UInt8) { self.type = type; self.key1 = key1; self.key2 = key2 }

    /// The firmware rejects a pair with a type but a missing key.
    public var isValid: Bool { type == .none || (key1 != 0 && key2 != 0) }
    public static let empty = SnapClickSlot(type: .none, key1: 0, key2: 0)
}

// MARK: Per-key RGB

public struct HSVColor: Codable, Equatable, Sendable {
    public var h: UInt8
    public var s: UInt8
    public var v: UInt8
    public init(h: UInt8, s: UInt8, v: UInt8) { self.h = h; self.s = s; self.v = v }
}

public enum PerKeyType: UInt8, CaseIterable, Codable, Sendable {
    case solid = 0, breathing, reactiveSimple, reactiveMultiWide, reactiveSplash

    public var title: String {
        switch self {
        case .solid: return "Solid"
        case .breathing: return "Breathing"
        case .reactiveSimple: return "Reactive"
        case .reactiveMultiWide: return "Reactive, wide"
        case .reactiveSplash: return "Splash"
        }
    }
}

public struct PerKeyRGB: Codable, Equatable, Sendable {
    public var type: PerKeyType
    /// One colour per LED, in the keyboard's LED order.
    public var colors: [HSVColor]
    public init(type: PerKeyType, colors: [HSVColor]) { self.type = type; self.colors = colors }
}

// MARK: Mix RGB

public struct MixedEffect: Codable, Equatable, Sendable {
    /// A lighting effect id; 0 means this slot is unused.
    public var effect: UInt8
    public var hue: UInt8
    public var sat: UInt8
    public var speed: UInt8
    public var durationMs: UInt32
    public init(effect: UInt8, hue: UInt8, sat: UInt8, speed: UInt8, durationMs: UInt32) {
        self.effect = effect; self.hue = hue; self.sat = sat; self.speed = speed; self.durationMs = durationMs
    }
    public var isUsed: Bool { effect != 0 }
    public static let unused = MixedEffect(effect: 0, hue: 0, sat: 0, speed: 0, durationMs: 0)
}

public struct MixedRGB: Codable, Equatable, Sendable {
    /// `[zone][slot]`
    public var zones: [[MixedEffect]]
    /// The zone each LED belongs to.
    public var regions: [UInt8]
    public init(zones: [[MixedEffect]], regions: [UInt8]) { self.zones = zones; self.regions = regions }
}

// MARK: All together

/// The keyboard's lock-key lights (Caps Lock on the V3): which exist, which are switched on, and their shared colour.
public struct LEDIndicator: Codable, Equatable, Sendable {
    /// Bit 0 Num Lock, 1 Caps Lock, 2 Scroll Lock, 3 Compose, 4 Kana: set when the keyboard has that light.
    public var supportMask: UInt8
    /// Same bits: set when that light is switched OFF.
    public var disabledMask: UInt8
    public var hue: UInt8
    public var saturation: UInt8
    public init(supportMask: UInt8, disabledMask: UInt8, hue: UInt8, saturation: UInt8) {
        self.supportMask = supportMask & 0x1F; self.disabledMask = disabledMask & 0x1F; self.hue = hue; self.saturation = saturation
    }

    static let capsBit: UInt8 = 0x02
    public var capsLockSupported: Bool { supportMask & Self.capsBit != 0 }
    public var capsLockEnabled: Bool {
        get { disabledMask & Self.capsBit == 0 }
        set { if newValue { disabledMask &= ~Self.capsBit } else { disabledMask |= Self.capsBit } }
    }
    public var colour: HSVColor { HSVColor(h: hue, s: saturation, v: 255) }
}

/// Everything the extras add to the configuration. Each part is nil when the keyboard lacks that feature.
public struct KeymapSettings: Codable, Equatable, Sendable {
    public var debounce: DebounceSettings?
    public var snapClick: [SnapClickSlot]?
    public var perKey: PerKeyRGB?
    public var mixed: MixedRGB?
    public var indicator: LEDIndicator?
    public init(debounce: DebounceSettings? = nil, snapClick: [SnapClickSlot]? = nil, perKey: PerKeyRGB? = nil, mixed: MixedRGB? = nil, indicator: LEDIndicator? = nil) {
        self.debounce = debounce; self.snapClick = snapClick; self.perKey = perKey; self.mixed = mixed; self.indicator = indicator
    }
}

/// Which LED sits under each matrix position (not every position has one; the knob press does not).
public struct LEDMap: Equatable, Sendable {
    public let rows: [[UInt8?]]
    public init(rows: [[UInt8?]]) { self.rows = rows }
    /// Builds a map from the firmware's raw rows, where 0xFF means "no LED".
    public init(rawRows: [[UInt8]]) { self.rows = rawRows.map { $0.map { $0 == 0xFF ? nil : $0 } } }

    public func ledIndex(row: Int, col: Int) -> Int? {
        guard rows.indices.contains(row), rows[row].indices.contains(col), let led = rows[row][col] else { return nil }
        return Int(led)
    }
}
