import Foundation

public enum ConfigStore {
    /// The V3 has a single knob.
    public static let encoderCount = 1

    public static func read(from device: ViaDevice) async throws -> KeyboardConfig {
        let protocolVersion = try await device.protocolVersion()
        let layers = try await device.layerCount()
        let keymap = try await device.keymap(layers: layers, size: .v3)
        var encoders: [[EncoderActions]] = []
        for layer in 0..<layers {
            var row: [EncoderActions] = []
            for index in 0..<encoderCount {
                row.append(EncoderActions(
                    counterClockwise: try await device.encoder(layer: layer, index: index, clockwise: false),
                    clockwise: try await device.encoder(layer: layer, index: index, clockwise: true)))
            }
            encoders.append(row)
        }
        let macros = try MacroCodec.decode(try await device.macroBuffer(), slots: try await device.macroCount())
        let settings = try await readKeymap(from: device)
        return KeyboardConfig(
            vendorID: IOKitHIDTransport.vendorID, productID: IOKitHIDTransport.productID,
            protocolVersion: Int(protocolVersion), firmware: try await device.firmwareString(),
            keymap: keymap, encoders: encoders, macros: macros, lighting: try await device.lighting(), settings: settings)
    }

    /// Reads the extras the keyboard reports. A keyboard that does not answer the feature query, or reports none,
    /// gets nil, and none of the feature requests are sent.
    static func readKeymap(from device: ViaDevice) async throws -> KeymapSettings? {
        let features: KeymapFeatures
        do { features = try await device.keymapFeatures() } catch ViaError.unsupported { return nil }
        // Each feature is read on its own: one the keyboard refuses is hidden, and the ordinary keys stay manageable.
        func optional<T>(_ read: () async throws -> T) async throws -> T? {
            do { return try await read() } catch {
                switch error as? ViaError {
                case .rejected?, .unsupported?, .invalid?, .shortReply?: return nil
                default: throw error
                }
            }
        }
        var settings = KeymapSettings()
        if features.contains(.debounce) { settings.debounce = try await optional { try await device.debounce() } }
        if features.contains(.snapClick) { settings.snapClick = try await optional { try await device.snapClickSlots() } }
        if features.contains(.rgb) {
            // Per-key and Mix RGB come as a pair: the lighting modes need both or neither.
            if let perKey = try await optional({ try await device.perKeyRGB() }), let mixed = try await optional({ try await device.mixedRGB() }) {
                settings.perKey = perKey
                settings.mixed = mixed
            }
            if let indicator = try await optional({ try await device.ledIndicator() }), indicator.capsLockSupported { settings.indicator = indicator }
        }
        return settings == KeymapSettings() ? nil : settings
    }

    public static func save(_ config: KeyboardConfig, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> KeyboardConfig {
        try JSONDecoder().decode(KeyboardConfig.self, from: Data(contentsOf: url))
    }

    /// The error for a bootloader or EEPROM-wipe keycode found at `place`.
    static func dangerousKeyError(_ code: Keycode, at place: String) -> ViaError {
        .invalid("\(code.name) on \(place) would put the keyboard into flash mode or erase its settings; it cannot be written")
    }

    /// Refuses a config that would put the bootloader or EEPROM-wipe keycode on a key, the knob or in a macro: the check
    /// for a whole config that is about to be restored. Apply checks only the entries it is going to write.
    public static func validateSafe(_ config: KeyboardConfig) throws {
        for (l, layer) in config.keymap.enumerated() {
            for (r, row) in layer.enumerated() {
                for (c, code) in row.enumerated() where code.isDangerous { throw dangerousKeyError(code, at: "layer \(l), row \(r), col \(c)") }
            }
        }
        for (l, layer) in config.encoders.enumerated() {
            for (i, actions) in layer.enumerated() {
                if actions.clockwise.isDangerous { throw dangerousKeyError(actions.clockwise, at: "knob \(i) layer \(l), clockwise") }
                if actions.counterClockwise.isDangerous { throw dangerousKeyError(actions.counterClockwise, at: "knob \(i) layer \(l), counter-clockwise") }
            }
        }
        try validateSafe(macros: config.macros)
    }

    /// Refuses macros that would press a dangerous key, directly or through raw bytes that spill into the next slot.
    public static func validateSafe(macros: [[MacroStep]]) throws {
        for (slot, macro) in macros.enumerated() {
            for step in macro {
                switch step {
                case .tap(let k), .down(let k), .up(let k):
                    if k.isDangerous { throw dangerousKeyError(k, at: "macro slot \(slot)") }
                case .raw(let bytes):
                    do { try MacroCodec.validate(raw: bytes) } catch ViaError.invalid(let why) { throw ViaError.invalid("macro slot \(slot): \(why)") }
                case .text, .delay: break
                }
            }
        }
    }

    /// A backup can only be restored onto the same kind of device it came from, and never one that would press a dangerous key.
    public static func validateRestorable(_ backup: KeyboardConfig, against current: KeyboardConfig) throws {
        try validateSafe(backup)
        try validateCompatible(backup, against: current)
    }

    /// Whether `backup`'s layout fits `current`'s keyboard (layers, keys, knob, macro slots, settings shapes). Says nothing
    /// about the keycodes themselves: edits carried over a reconnect only need this check.
    public static func validateCompatible(_ backup: KeyboardConfig, against current: KeyboardConfig) throws {
        func refuse(_ why: String) throws -> Never { throw ViaError.wrongDevice("backup cannot be restored: \(why)") }
        if backup.vendorID != current.vendorID || backup.productID != current.productID {
            try refuse("it is from a different keyboard (\(String(backup.vendorID, radix: 16)):\(String(backup.productID, radix: 16)))")
        }
        if backup.protocolVersion != current.protocolVersion {
            try refuse("it uses VIA protocol \(backup.protocolVersion), this keyboard uses \(current.protocolVersion)")
        }
        if backup.keymap.count != current.keymap.count {
            try refuse("it has \(backup.keymap.count) layers, this keyboard has \(current.keymap.count)")
        }
        if backup.keymap.map({ $0.count }) != current.keymap.map({ $0.count })
            || backup.keymap.map({ $0.map { $0.count } }) != current.keymap.map({ $0.map { $0.count } }) {
            try refuse("its key layout does not match this keyboard")
        }
        if backup.encoders.map({ $0.count }) != current.encoders.map({ $0.count }) {
            try refuse("its knob layout does not match this keyboard")
        }
        if backup.macros.count != current.macros.count {
            try refuse("it has \(backup.macros.count) macro slots, this keyboard has \(current.macros.count)")
        }
        if let b = backup.settings {
            let c = current.settings
            if b.debounce != nil && c?.debounce == nil { try refuse("it has debounce settings this keyboard does not report") }
            if b.indicator != nil && c?.indicator == nil { try refuse("it has an indicator light setting this keyboard does not report") }
            if let bs = b.snapClick {
                if let bad = bs.firstIndex(where: { !$0.isValid }) { try refuse("Snap Click slot \(bad + 1) has a type but a missing key") }
                guard let cs = c?.snapClick else { try refuse("it has Snap Click settings this keyboard does not report") }
                if bs.count != cs.count { try refuse("it has \(bs.count) Snap Click slots, this keyboard has \(cs.count)") }
            }
            if let bp = b.perKey {
                guard let cp = c?.perKey else { try refuse("it has per-key RGB settings this keyboard does not report") }
                if bp.colors.count != cp.colors.count { try refuse("it has colours for \(bp.colors.count) LEDs, this keyboard has \(cp.colors.count)") }
            }
            if let bm = b.mixed {
                guard let cm = c?.mixed else { try refuse("it has Mix RGB settings this keyboard does not report") }
                if bm.regions.count != cm.regions.count { try refuse("its Mix RGB covers \(bm.regions.count) LEDs, this keyboard has \(cm.regions.count)") }
                if bm.regions.contains(where: { Int($0) >= bm.zones.count }) { try refuse("its Mix RGB assigns keys to a zone that does not exist") }
                if bm.zones.count != cm.zones.count || bm.zones.map({ $0.count }) != cm.zones.map({ $0.count }) {
                    try refuse("its Mix RGB zones are shaped differently from this keyboard's")
                }
            }
        }
    }

    /// Changes needed to turn `from` into `to`, in write order: keys, knob, macros, lighting.
    public static func diff(from: KeyboardConfig, to: KeyboardConfig) -> [ConfigChange] {
        var changes: [ConfigChange] = []
        for l in 0..<min(from.keymap.count, to.keymap.count) {
            for r in 0..<min(from.keymap[l].count, to.keymap[l].count) {
                for c in 0..<min(from.keymap[l][r].count, to.keymap[l][r].count) where from.keymap[l][r][c] != to.keymap[l][r][c] {
                    let (old, new) = (from.keymap[l][r][c], to.keymap[l][r][c])
                    changes.append(ConfigChange(
                        description: "layer \(l), row \(r), col \(c): \(old.name) → \(new.name)",
                        target: .key(layer: l, row: r, col: c, to: new)))
                }
            }
        }
        for l in 0..<min(from.encoders.count, to.encoders.count) {
            for i in 0..<min(from.encoders[l].count, to.encoders[l].count) {
                let (a, b) = (from.encoders[l][i], to.encoders[l][i])
                if a.counterClockwise != b.counterClockwise {
                    changes.append(ConfigChange(
                        description: "knob layer \(l), counter-clockwise: \(a.counterClockwise.name) → \(b.counterClockwise.name)",
                        target: .encoder(layer: l, index: i, clockwise: false, to: b.counterClockwise)))
                }
                if a.clockwise != b.clockwise {
                    changes.append(ConfigChange(
                        description: "knob layer \(l), clockwise: \(a.clockwise.name) → \(b.clockwise.name)",
                        target: .encoder(layer: l, index: i, clockwise: true, to: b.clockwise)))
                }
            }
        }
        let changedSlots = (0..<min(from.macros.count, to.macros.count)).filter { from.macros[$0] != to.macros[$0] }
        if !changedSlots.isEmpty {
            changes.append(ConfigChange(description: "Macros: \(changedSlots.map { String(format: "M%02d", $0) }.joined(separator: ", ")) changed", target: .macros))
        }
        if from.lighting != to.lighting {
            var parts: [String] = []
            if from.lighting.brightness != to.lighting.brightness { parts.append("brightness \(from.lighting.brightness) → \(to.lighting.brightness)") }
            if from.lighting.effect != to.lighting.effect { parts.append("effect \(RGBMatrixEffect.name(for: from.lighting.effect)) → \(RGBMatrixEffect.name(for: to.lighting.effect))") }
            if from.lighting.speed != to.lighting.speed { parts.append("speed \(from.lighting.speed) → \(to.lighting.speed)") }
            if from.lighting.hue != to.lighting.hue { parts.append("hue \(from.lighting.hue) → \(to.lighting.hue)") }
            if from.lighting.saturation != to.lighting.saturation { parts.append("saturation \(from.lighting.saturation) → \(to.lighting.saturation)") }
            changes.append(ConfigChange(description: "Lighting: " + parts.joined(separator: ", "), target: .lighting))
        }
        changes += keymapChanges(from: from.settings, to: to.settings)
        return changes
    }

    // MARK: Device settings

    private static func keyName(_ code: UInt8) -> String { Keycode(raw: UInt16(code)).name }

    private static func describe(_ slot: SnapClickSlot) -> String {
        slot.type == .none ? "off" : "\(slot.type.title) (\(keyName(slot.key1)) / \(keyName(slot.key2)))"
    }

    private static func keymapChanges(from: KeymapSettings?, to: KeymapSettings?) -> [ConfigChange] {
        guard let from, let to else { return [] }
        var changes: [ConfigChange] = []
        if let a = from.debounce, let b = to.debounce, a != b {
            changes.append(ConfigChange(description: "Debounce: \(a.type.title), \(a.time) ms → \(b.type.title), \(b.time) ms", target: .debounce))
        }
        if let a = from.snapClick, let b = to.snapClick {
            for i in 0..<min(a.count, b.count) where a[i] != b[i] {
                changes.append(ConfigChange(description: "Snap Click slot \(i): \(describe(a[i])) → \(describe(b[i]))", target: .snapClick(index: i)))
            }
        }
        if let a = from.indicator, let b = to.indicator, a != b {
            var parts: [String] = []
            if a.capsLockEnabled != b.capsLockEnabled { parts.append(b.capsLockEnabled ? "switched on" : "switched off") }
            if a.hue != b.hue || a.saturation != b.saturation { parts.append("colour changed") }
            changes.append(ConfigChange(description: "Caps Lock light: " + parts.joined(separator: ", "), target: .indicator))
        }
        if let a = from.perKey, let b = to.perKey, a != b {
            var parts: [String] = []
            if a.type != b.type { parts.append("type \(a.type.title) → \(b.type.title)") }
            let colours = zip(a.colors, b.colors).filter { $0 != $1 }.count
            if colours > 0 { parts.append("\(colours) key colour\(colours == 1 ? "" : "s") changed") }
            changes.append(ConfigChange(description: "Per-key RGB: " + parts.joined(separator: ", "), target: .perKeyRGB))
        }
        if let a = from.mixed, let b = to.mixed, a != b {
            var parts: [String] = []
            let moved = zip(a.regions, b.regions).filter { $0 != $1 }.count
            if moved > 0 { parts.append("\(moved) key\(moved == 1 ? "" : "s") moved between zones") }
            for z in 0..<min(a.zones.count, b.zones.count) where a.zones[z] != b.zones[z] { parts.append("zone \(z + 1) effects changed") }
            changes.append(ConfigChange(description: "Mix RGB: " + parts.joined(separator: ", "), target: .mixedRGB))
        }
        return changes
    }
}
