import Foundation

public struct ApplyResult: Sendable {
    /// Set only when this call saved the session's backup.
    public let backupURL: URL?
    public let written: [ConfigChange]
}

public enum ApplyError: Error {
    /// A write failed part-way: `written` made it to the keyboard, `failed` and everything after it did not.
    case partial(written: [ConfigChange], failed: ConfigChange, underlying: ViaError)
    case backupFailed(String)
}

/// Writes the difference between two configs to the keyboard. Saves one backup of `current` before the
/// session's first write, and verifies every write by read-back (inside `ViaDevice`).
public actor ApplyEngine {
    private let device: ViaDevice
    private let backupDirectory: URL
    private var backedUp = false
    /// The backup saved for this session, once the first write has been prepared.
    public private(set) var sessionBackupURL: URL?

    public init(device: ViaDevice, backupDirectory: URL) {
        self.device = device
        self.backupDirectory = backupDirectory
    }

    public func apply(_ target: KeyboardConfig, current: KeyboardConfig) async throws -> ApplyResult {
        let changes = ConfigStore.diff(from: current, to: target)
        guard !changes.isEmpty else { return ApplyResult(backupURL: nil, written: []) }

        // Nothing touches the keyboard until every precondition has passed. Only what is about to be written is checked
        // for dangerous keycodes: a key another tool put on the keyboard is not this apply's business.
        for change in changes {
            switch change.target {
            case .key(let l, let r, let c, let code) where code.isDangerous: throw ConfigStore.dangerousKeyError(code, at: "layer \(l), row \(r), col \(c)")
            case .encoder(let l, let i, let cw, let code) where code.isDangerous: throw ConfigStore.dangerousKeyError(code, at: "knob \(i) layer \(l), \(cw ? "clockwise" : "counter-clockwise")")
            default: break
            }
        }
        var macroBytes: [UInt8]?
        if changes.contains(where: { $0.target == .macros }) {
            try ConfigStore.validateSafe(macros: target.macros)
            macroBytes = try MacroCodec.encode(target.macros, capacity: try await device.macroBufferSize())
        }
        for change in changes {
            if case .snapClick(let index) = change.target, let slot = target.settings?.snapClick?[index], !slot.isValid {
                throw ViaError.invalid("Snap Click slot \(index + 1) has a type but a missing key")
            }
        }
        if changes.contains(where: { $0.target == .mixedRGB }), let m = target.settings?.mixed, m.regions.contains(where: { Int($0) >= m.zones.count }) {
            throw ViaError.invalid("Mix RGB assigns a key to a zone that does not exist")
        }
        var backupURL: URL?
        if !backedUp {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let url = backupDirectory.appendingPathComponent("v3-keymap-backup-\(stamp)-\(UUID().uuidString.prefix(4)).json")
            do { try ConfigStore.save(current, to: url) } catch { throw ApplyError.backupFailed("\(error.localizedDescription)") }
            backedUp = true
            backupURL = url
            sessionBackupURL = url
        }

        // The Snap Click and RGB groups are saved to the keyboard only once every change in the group has been written,
        // so a failure part-way leaves the keyboard's saved settings untouched.
        var snapRemaining = changes.filter { if case .snapClick = $0.target { return true } else { return false } }.count
        var rgbRemaining = changes.filter { $0.target == .perKeyRGB || $0.target == .mixedRGB }.count

        let snapTotal = snapRemaining, rgbTotal = rgbRemaining
        var written: [ConfigChange] = []
        for change in changes {
            do {
                switch change.target {
                case .key(let layer, let row, let col, let code):
                    try await device.setKeycode(layer: layer, row: row, col: col, code)
                case .encoder(let layer, let index, let clockwise, let code):
                    try await device.setEncoder(layer: layer, index: index, clockwise: clockwise, code)
                case .macros:
                    try await device.setMacroBuffer(macroBytes ?? [])
                case .lighting:
                    try await device.setLighting(target.lighting)
                case .indicator:
                    if let indicator = target.settings?.indicator { try await device.setLEDIndicator(indicator) }
                case .debounce:
                    if let debounce = target.settings?.debounce { try await device.setDebounce(debounce) }
                case .snapClick(let index):
                    if let slot = target.settings?.snapClick?[index] {
                        try await device.setSnapClickSlots([slot], startingAt: index)
                        snapRemaining -= 1
                        if snapRemaining == 0 { try await device.saveSnapClick() }
                    }
                case .perKeyRGB:
                    if let perKey = target.settings?.perKey {
                        let before = current.settings?.perKey?.colors ?? []
                        let changed = Set(perKey.colors.indices.filter { before.indices.contains($0) ? before[$0] != perKey.colors[$0] : true })
                        try await device.setPerKeyRGB(perKey, changedLEDs: changed)
                        rgbRemaining -= 1
                        if rgbRemaining == 0 { try await device.saveRGB() }
                    }
                case .mixedRGB:
                    if let mixed = target.settings?.mixed {
                        try await device.setMixedRGB(mixed)
                        rgbRemaining -= 1
                        if rgbRemaining == 0 { try await device.saveRGB() }
                    }
                }
                written.append(change)
            } catch {
                // What already landed in a Snap Click or RGB group is live on the keyboard; save it so the keyboard's saved
                // state matches what the app re-reads, instead of silently losing it at the next unplug.
                if snapRemaining < snapTotal { try? await device.saveSnapClick() }
                if rgbRemaining < rgbTotal || (rgbTotal > 0 && (change.target == .perKeyRGB || change.target == .mixedRGB)) { try? await device.saveRGB() }
                throw ApplyError.partial(written: written, failed: change, underlying: (error as? ViaError) ?? .invalid("\(error)"))
            }
        }
        return ApplyResult(backupURL: backupURL, written: written)
    }
}
