import Foundation

public struct EncoderActions: Codable, Equatable, Sendable {
    public var counterClockwise: Keycode
    public var clockwise: Keycode
    public init(counterClockwise: Keycode, clockwise: Keycode) {
        self.counterClockwise = counterClockwise
        self.clockwise = clockwise
    }
}

/// Everything the app can read from and write to the keyboard. Also the backup file format.
public struct KeyboardConfig: Codable, Equatable, Sendable {
    public var vendorID: Int
    public var productID: Int
    public var protocolVersion: Int
    public var firmware: String
    /// `[layer][row][col]`
    public var keymap: [[[Keycode]]]
    /// `[layer][encoder index]`
    public var encoders: [[EncoderActions]]
    /// One entry per macro slot.
    public var macros: [[MacroStep]]
    public var lighting: LightingState
    /// extras; nil when the keyboard does not report them (and absent in backups made before they existed).
    public var settings: KeymapSettings?

    public init(vendorID: Int, productID: Int, protocolVersion: Int, firmware: String,
                keymap: [[[Keycode]]], encoders: [[EncoderActions]], macros: [[MacroStep]], lighting: LightingState,
                settings: KeymapSettings? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.protocolVersion = protocolVersion
        self.firmware = firmware
        self.keymap = keymap
        self.encoders = encoders
        self.macros = macros
        self.lighting = lighting
        self.settings = settings
    }
}

/// One difference between two configs, with what to write to remove it.
public struct ConfigChange: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case key(layer: Int, row: Int, col: Int, to: Keycode)
        case encoder(layer: Int, index: Int, clockwise: Bool, to: Keycode)
        case macros
        case lighting
        case debounce
        case snapClick(index: Int)
        case perKeyRGB
        case mixedRGB
        case indicator
    }
    public let description: String
    public let target: Target
    public init(description: String, target: Target) {
        self.description = description
        self.target = target
    }
}
