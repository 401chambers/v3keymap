import Foundation

// extras. Requests are [group, sub-command, payload from byte 2]; replies are [group, sub-command, status,
// data from byte 3]. `send` already checks the echo and the status byte, so a refusal arrives as `.rejected`.
extension ViaDevice {
    static let keymapChunk = 9

    // MARK: Debounce

    public func debounce() async throws -> DebounceSettings {
        let r = try await send([Keymap.misc, Keymap.Misc.debounceGet])
        guard let type = DebounceType(rawValue: r[4]) else { throw ViaError.invalid("the keyboard reported an unknown debounce type \(r[4])") }
        return DebounceSettings(type: type, time: r[5])
    }

    /// Writes the setting (clamped to what the firmware allows). The keyboard saves it by itself.
    public func setDebounce(_ settings: DebounceSettings) async throws {
        let wanted = settings.clamped
        _ = try await send([Keymap.misc, Keymap.Misc.debounceSet, wanted.type.rawValue, wanted.time])
        let back = try await debounce()
        guard back == wanted else { throw ViaError.verifyMismatch(["debounce: wrote \(wanted), read \(back)"]) }
    }

    // MARK: Lock-key lights

    public func ledIndicator() async throws -> LEDIndicator {
        let r = try await send([Keymap.rgb, Keymap.RGB.ledIndicatorGet])
        return LEDIndicator(supportMask: r[3], disabledMask: r[4], hue: r[5], saturation: r[6])
    }

    /// Switches the lock-key lights and sets their shared colour, saves, and reads back to check.
    public func setLEDIndicator(_ value: LEDIndicator, save: Bool = true) async throws {
        let current = try await ledIndicator()
        // Only lights the keyboard has can be changed; the rest keep their state.
        let disabled = (value.disabledMask & current.supportMask) | (current.disabledMask & ~current.supportMask)
        _ = try await send([Keymap.rgb, Keymap.RGB.ledIndicatorSet, 0xE0 | disabled, value.hue, value.saturation, 255])
        let back = try await ledIndicator()
        guard back.disabledMask == disabled, back.hue == value.hue, back.saturation == value.saturation else {
            throw ViaError.verifyMismatch(["indicator light: wrote \(value), read \(back)"])
        }
        if save { _ = try await send([Keymap.rgb, Keymap.RGB.save]) }   // saved only once the read-back agrees
    }

    // MARK: Snap Click

    public func snapClickSlotCount() async throws -> Int {
        Int(try await send([Keymap.misc, Keymap.Misc.snapClickInfo])[3])
    }

    public func snapClickSlots() async throws -> [SnapClickSlot] {
        try await readSnapClick(start: 0, count: try await snapClickSlotCount())
    }

    private func readSnapClick(start: Int, count: Int) async throws -> [SnapClickSlot] {
        var out: [SnapClickSlot] = []
        var offset = 0
        while offset < count {
            let n = min(Self.keymapChunk, count - offset)
            let r = try await send([Keymap.misc, Keymap.Misc.snapClickGet, UInt8(start + offset), UInt8(n)])
            for i in 0..<n {
                guard let type = SnapClickType(rawValue: r[3 + i * 3]) else { throw ViaError.invalid("the keyboard reported an unknown Snap Click type") }
                out.append(SnapClickSlot(type: type, key1: r[4 + i * 3], key2: r[5 + i * 3]))
            }
            offset += n
        }
        return out
    }

    /// Writes `slots` starting at slot `start` (nothing is written if any pair is invalid or out of range) and verifies.
    /// Call `saveSnapClick()` afterwards to keep them across unplugging.
    public func setSnapClickSlots(_ slots: [SnapClickSlot], startingAt start: Int) async throws {
        guard slots.allSatisfy(\.isValid) else { throw ViaError.invalid("a Snap Click pair needs both keys") }
        let total = try await snapClickSlotCount()
        guard start >= 0, start + slots.count <= total else { throw ViaError.invalid("Snap Click slots \(start)..<\(start + slots.count) do not exist (the keyboard has \(total))") }
        var offset = 0
        while offset < slots.count {
            let n = min(Self.keymapChunk, slots.count - offset)
            let payload = slots[offset..<offset + n].flatMap { [$0.type.rawValue, $0.key1, $0.key2] }
            _ = try await send([Keymap.misc, Keymap.Misc.snapClickSet, UInt8(start + offset), UInt8(n)] + payload)
            offset += n
        }
        let back = try await readSnapClick(start: start, count: slots.count)
        guard back == slots else { throw ViaError.verifyMismatch(["Snap Click slots \(start)..<\(start + slots.count) differ after writing"]) }
    }

    public func saveSnapClick() async throws {
        _ = try await send([Keymap.misc, Keymap.Misc.snapClickSave])
    }

    // MARK: RGB: general

    public func rgbProtocolVersion() async throws -> Int {
        let r = try await send([Keymap.rgb, Keymap.RGB.protocolVersion])
        return Int(r[3]) | Int(r[4]) << 8
    }

    public func rgbLEDCount() async throws -> Int {
        Int(try await send([Keymap.rgb, Keymap.RGB.ledCount])[3])
    }

    /// Which LED sits under each matrix key; one request per row.
    public func ledMap(size: MatrixSize) async throws -> LEDMap {
        let mask = (1 << size.cols) - 1
        var rows: [[UInt8]] = []
        for row in 0..<size.rows {
            let r = try await send([Keymap.rgb, Keymap.RGB.ledIndex, UInt8(row), UInt8(mask & 0xFF), UInt8((mask >> 8) & 0xFF), UInt8((mask >> 16) & 0xFF)])
            rows.append((0..<size.cols).map { r[3 + $0] })
        }
        return LEDMap(rawRows: rows)
    }

    /// Persists the per-key and Mix RGB settings so they survive unplugging.
    public func saveRGB() async throws {
        _ = try await send([Keymap.rgb, Keymap.RGB.save])
    }

    // MARK: Per-key RGB

    public func perKeyRGB() async throws -> PerKeyRGB {
        let typeByte = try await send([Keymap.rgb, Keymap.RGB.perKeyTypeGet])[3]
        guard let type = PerKeyType(rawValue: typeByte) else { throw ViaError.invalid("the keyboard reported an unknown per-key RGB type \(typeByte)") }
        return PerKeyRGB(type: type, colors: try await readPerKeyColours(Array(0..<(try await rgbLEDCount()))))
    }

    private func readPerKeyColours(_ leds: [Int]) async throws -> [HSVColor] {
        var out: [HSVColor] = []
        for run in Self.runs(of: leds, maxLength: Self.keymapChunk) {
            let r = try await send([Keymap.rgb, Keymap.RGB.perKeyColorGet, UInt8(run.first!), UInt8(run.count)])
            for i in 0..<run.count { out.append(HSVColor(h: r[3 + i * 3], s: r[4 + i * 3], v: r[5 + i * 3])) }
        }
        return out
    }

    /// Writes the type and the colours of `changedLEDs` (all LEDs when nil), then verifies by reading them back.
    /// Call `saveRGB()` afterwards to keep them.
    public func setPerKeyRGB(_ value: PerKeyRGB, changedLEDs: Set<Int>? = nil) async throws {
        let count = try await rgbLEDCount()
        guard value.colors.count == count else { throw ViaError.invalid("per-key RGB needs \(count) colours, got \(value.colors.count)") }
        let leds = (changedLEDs ?? Set(0..<count)).filter { (0..<count).contains($0) }.sorted()
        _ = try await send([Keymap.rgb, Keymap.RGB.perKeyTypeSet, value.type.rawValue])
        for run in Self.runs(of: leds, maxLength: Self.keymapChunk) {
            let payload = run.flatMap { [value.colors[$0].h, value.colors[$0].s, value.colors[$0].v] }
            _ = try await send([Keymap.rgb, Keymap.RGB.perKeyColorSet, UInt8(run.first!), UInt8(run.count)] + payload)
        }
        let back = try await readPerKeyColours(leds)
        guard back == leds.map({ value.colors[$0] }) else { throw ViaError.verifyMismatch(["per-key colours differ after writing"]) }
        let typeBack = try await send([Keymap.rgb, Keymap.RGB.perKeyTypeGet])[3]
        guard typeBack == value.type.rawValue else { throw ViaError.verifyMismatch(["per-key type: wrote \(value.type.rawValue), read \(typeBack)"]) }
    }

    // MARK: Mix RGB

    public func mixedRGB() async throws -> MixedRGB {
        let info = try await send([Keymap.rgb, Keymap.RGB.mixedInfo])
        let zoneCount = Int(info[3]), slotCount = Int(info[4])
        let ledCount = try await rgbLEDCount()
        var regions: [UInt8] = []
        for run in Self.runs(of: Array(0..<ledCount), maxLength: 29) {
            let r = try await send([Keymap.rgb, Keymap.RGB.regionsGet, UInt8(run.first!), UInt8(run.count)])
            regions += r[3..<3 + run.count]
        }
        var zones: [[MixedEffect]] = []
        for zone in 0..<zoneCount {
            var effects: [MixedEffect] = []
            for run in Self.runs(of: Array(0..<slotCount), maxLength: 3) {
                let r = try await send([Keymap.rgb, Keymap.RGB.effectListGet, UInt8(zone), UInt8(run.first!), UInt8(run.count)])
                for i in 0..<run.count {
                    let o = 3 + i * 8
                    let ms = UInt32(r[o + 4]) | UInt32(r[o + 5]) << 8 | UInt32(r[o + 6]) << 16 | UInt32(r[o + 7]) << 24
                    effects.append(MixedEffect(effect: r[o], hue: r[o + 1], sat: r[o + 2], speed: r[o + 3], durationMs: ms))
                }
            }
            zones.append(effects)
        }
        return MixedRGB(zones: zones, regions: regions)
    }

    /// Writes every zone assignment and effect, then verifies by reading everything back. Nothing is written when the
    /// shape does not match the keyboard. Call `saveRGB()` afterwards to keep it.
    public func setMixedRGB(_ value: MixedRGB) async throws {
        let info = try await send([Keymap.rgb, Keymap.RGB.mixedInfo])
        let zoneCount = Int(info[3]), slotCount = Int(info[4])
        let ledCount = try await rgbLEDCount()
        guard value.zones.count == zoneCount, value.zones.allSatisfy({ $0.count == slotCount }) else {
            throw ViaError.invalid("Mix RGB needs \(zoneCount) zones of \(slotCount) effects")
        }
        guard value.regions.count == ledCount, value.regions.allSatisfy({ Int($0) < zoneCount }) else {
            throw ViaError.invalid("Mix RGB needs a zone (0..<\(zoneCount)) for each of the \(ledCount) LEDs")
        }
        for run in Self.runs(of: Array(0..<ledCount), maxLength: 28) {
            _ = try await send([Keymap.rgb, Keymap.RGB.regionsSet, UInt8(run.first!), UInt8(run.count)] + run.map { value.regions[$0] })
        }
        for (zone, effects) in value.zones.enumerated() {
            for run in Self.runs(of: Array(0..<slotCount), maxLength: 3) {
                let payload = run.flatMap { i -> [UInt8] in
                    let e = effects[i]
                    return [e.effect, e.hue, e.sat, e.speed] + (0..<4).map { UInt8((e.durationMs >> (8 * UInt32($0))) & 0xFF) }
                }
                _ = try await send([Keymap.rgb, Keymap.RGB.effectListSet, UInt8(zone), UInt8(run.first!), UInt8(run.count)] + payload)
            }
        }
        guard try await mixedRGB() == value else { throw ViaError.verifyMismatch(["Mix RGB differs after writing"]) }
    }

    // MARK: Live preview (fast, unverified, never saved)

    /// Shows a Caps Lock light change at once: one write, no read-back. `old` supplies the lights the keyboard has.
    public func previewLEDIndicator(_ value: LEDIndicator, from old: LEDIndicator) async throws {
        let disabled = (value.disabledMask & old.supportMask) | (old.disabledMask & ~old.supportMask)
        _ = try await send([Keymap.rgb, Keymap.RGB.ledIndicatorSet, 0xE0 | disabled, value.hue, value.saturation, 255])
    }

    /// Shows per-key colours at once: only the keys that changed, no read-back.
    public func previewPerKeyRGB(_ value: PerKeyRGB, from old: PerKeyRGB?, changedLEDs: Set<Int>?) async throws {
        if old?.type != value.type { _ = try await send([Keymap.rgb, Keymap.RGB.perKeyTypeSet, value.type.rawValue]) }
        let leds = (changedLEDs ?? Set(value.colors.indices)).filter { value.colors.indices.contains($0) }.sorted()
        for run in Self.runs(of: leds, maxLength: Self.keymapChunk) {
            let payload = run.flatMap { [value.colors[$0].h, value.colors[$0].s, value.colors[$0].v] }
            _ = try await send([Keymap.rgb, Keymap.RGB.perKeyColorSet, UInt8(run.first!), UInt8(run.count)] + payload)
        }
    }

    /// Shows Mix RGB changes at once: only the zone assignments and effects that changed, no read-back.
    public func previewMixedRGB(_ value: MixedRGB, from old: MixedRGB?) async throws {
        guard let old, old.regions.count == value.regions.count, old.zones.count == value.zones.count else { return try await setMixedRGB(value) }
        let changedRegions = value.regions.indices.filter { old.regions[$0] != value.regions[$0] }
        for run in Self.runs(of: changedRegions, maxLength: 28) {
            _ = try await send([Keymap.rgb, Keymap.RGB.regionsSet, UInt8(run.first!), UInt8(run.count)] + run.map { value.regions[$0] })
        }
        for (zone, effects) in value.zones.enumerated() where zone < old.zones.count && old.zones[zone].count == effects.count {
            let changed = effects.indices.filter { old.zones[zone][$0] != effects[$0] }
            for run in Self.runs(of: changed, maxLength: 3) {
                let payload = run.flatMap { i -> [UInt8] in
                    let e = effects[i]
                    return [e.effect, e.hue, e.sat, e.speed] + (0..<4).map { UInt8((e.durationMs >> (8 * UInt32($0))) & 0xFF) }
                }
                _ = try await send([Keymap.rgb, Keymap.RGB.effectListSet, UInt8(zone), UInt8(run.first!), UInt8(run.count)] + payload)
            }
        }
    }

    /// Splits sorted indices into runs of consecutive numbers, each at most `maxLength` long.
    static func runs(of indices: [Int], maxLength: Int) -> [[Int]] {
        var result: [[Int]] = []
        for i in indices {
            if let last = result.last?.last, i == last + 1, result[result.count - 1].count < maxLength {
                result[result.count - 1].append(i)
            } else {
                result.append([i])
            }
        }
        return result
    }

    // MARK: Custom lighting effects

    public func setLightingEffect(_ id: UInt8) async throws {
        _ = try await send([0x07, Self.lightingChannel, 2, id])       // VIA custom value set, effect; not saved
    }

    /// Asks the keyboard for its highest effect id by setting an out-of-range effect and reading back what it clamped to,
    /// then puts the original effect back (whatever happens). Nothing is saved. Returns nil if the keyboard does not clamp.
    public func discoverCustomEffectIDs() async throws -> CustomEffectIDs? {
        let before = try await lighting()
        func restore() async throws {
            try await setLightingEffect(before.effect)
            // Changing the effect makes the firmware adjust colour and speed too (seen on the real keyboard), so put them
            // back, after the pause the firmware needs before it accepts them again (as `setLighting` does).
            try await Task.sleep(for: .milliseconds(120))
            _ = try await send([0x07, Self.lightingChannel, 3, before.speed])
            _ = try await send([0x07, Self.lightingChannel, 4, before.hue, before.saturation])
        }
        let highest: UInt8
        do {
            try await setLightingEffect(255)
            highest = try await customValue(channel: Self.lightingChannel, id: 2)[0]
        } catch {
            do { try await restore() } catch { throw ViaError.invalid("could not put the lighting effect back after probing: \(error)") }
            throw error
        }
        try await restore()
        guard highest != 255, highest >= 2 else { return nil }
        return CustomEffectIDs(perKey: highest - 1, mixed: highest)
    }
}

/// Which lighting effect ids select per-key RGB and Mix RGB on this keyboard. They are the last two effects, in this order,
/// so they are found from how many effects the keyboard has.
public struct CustomEffectIDs: Equatable, Sendable {
    public let perKey: UInt8
    public let mixed: UInt8
    public init(perKey: UInt8, mixed: UInt8) { self.perKey = perKey; self.mixed = mixed }
}
