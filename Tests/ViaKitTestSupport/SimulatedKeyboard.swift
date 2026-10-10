import Foundation
import ViaKit

/// Stateful fake keyboard for tests. Seeded from replies recorded from the real V3
/// (fixtures.json), then implements the VIA commands the app uses over that memory.
/// Anything it does not implement gets a VIA "unhandled" reply (first byte 0xFF).
public final class SimulatedKeyboard: HIDTransport, ConnectionEventSource, @unchecked Sendable {
    static let rows = 6, cols = 16, layers = 4

    private let lock = NSLock()
    private var recorded: [String: [UInt8]] = [:]   // static replies (protocol version, layer count, ...)
    private var keymap = [UInt8](repeating: 0, count: 816)   // size of the recorded buffer (4 layers x 6 x 16 x 2 = 768 are real)
    private var macros = [UInt8](repeating: 0, count: 1750)
    private var factoryKeymap: [UInt8] = []
    private var factoryEncoders: [[UInt8]: [UInt8]] = [:]
    private var encoders: [[UInt8]: [UInt8]] = [:]   // [layer, index, cw] -> [hi, lo]
    private var lighting: [UInt8: [UInt8]] = [:]     // RGB matrix value id -> bytes
    // extras, seeded from Fixtures/extras.json
    private var debounceState: [UInt8] = [4, 50]
    private var snapSlots: [[UInt8]] = Array(repeating: [0, 0, 0], count: 20)
    private var ledMapRows: [[UInt8]] = []
    private var perKeyType: UInt8 = 0
    private var indicatorState: [UInt8] = [0x1F, 0x00, 0, 255]   // support mask, disabled mask, hue, saturation
    private var perKeyColors: [[UInt8]] = []
    private var mixZones = 2, mixSlots = 5
    private var regions: [UInt8] = []
    private var effectLists: [[[UInt8]]] = []      // [zone][slot] = [effect, hue, sat, speed, t0, t1, t2, t3]
    private var _sent: [UInt8] = []
    private var exchanges = 0
    private var inflight = 0
    private var _sentReq: [[UInt8]] = []
    private var _sentHeads: [[UInt8]] = []
    private var _maxInflight = 0

    public let events: AsyncStream<ConnectionEvent>
    private let eventSink: AsyncStream<ConnectionEvent>.Continuation
    /// Changes the reply to request number N (1-based), e.g. to simulate a stale or corrupted reply.
    public var replyTransform: ((Int, [UInt8]) -> [UInt8])?

    /// The cable is pulled: every later exchange fails and `events` reports it.
    public func unplug() {
        lock.withLock { failAfter = exchanges }
        eventSink.yield(.disconnected)
    }
    public func replug() {
        lock.withLock { failAfter = nil }
        eventSink.yield(.connected)
    }
    /// Puts a keycode straight into the keyboard's memory (for testing keys another tool put there, which this app refuses to write).
    public func seedKeycode(layer: Int, row: Int, col: Int, _ raw: UInt16) {
        lock.withLock {
            let i = keymapIndex(UInt8(layer), UInt8(row), UInt8(col))
            keymap[i] = UInt8(raw >> 8); keymap[i + 1] = UInt8(raw & 0xFF)
        }
    }
    /// Overwrites the start of the macro memory (for testing macros the app did not create).
    public func setMacroBuffer(_ bytes: [UInt8]) {
        lock.withLock { macros.replaceSubrange(0..<bytes.count, with: bytes) }
    }

    /// Throw `.disconnected` once this many exchanges have completed.
    public var failAfter: Int?
    /// Return a short reply for this (1-based) request number.
    public var truncateAtRequest: Int?
    /// Acknowledge writes without changing memory (simulates a write that did not stick).
    public var ignoreWrites = false
    /// Answer "get protocol version" with this value instead of the recorded one.
    public var protocolVersionOverride: UInt16?
    /// Keys currently held down, as [row, col] pairs (shown in the switch-matrix reply).
    public var heldKeys: Set<[Int]> = []

    public var sentCommands: [UInt8] { lock.withLock { _sent } }
    public var exchangeCount: Int { lock.withLock { exchanges } }
    /// The first two bytes (command, sub-command) of every request, in order.
    public var sentRequests: [[UInt8]] { lock.withLock { _sentReq } }
    /// The first three bytes (command, sub-command, id) of every request, in order.
    public var sentRequestHeads: [[UInt8]] { lock.withLock { _sentHeads } }
    /// Which extras this keyboard reports (command 0xA2, byte 2). 0xF1 is what the real V3 reports.
    public var keymapFeatures: UInt8 = 0xF1
    /// Answer the next extra write with status 1 (rejected) instead of applying it.
    public var rejectNextKeymapWrite = false
    /// The id of the last custom effect (mixed RGB) on this simulated keyboard.
    public var mixedEffectID: UInt8 = 49
    /// Real keyboards clamp an out-of-range lighting effect to the last valid one; turn this off to model one that does not.
    public var clampsEffects = true
    /// Highest number of exchanges that were in progress at the same time (the real keyboard allows only one).
    public var maxInflight: Int { lock.withLock { _maxInflight } }

    public init(fixtures: URL) throws {
        var sink: AsyncStream<ConnectionEvent>.Continuation!
        events = AsyncStream { sink = $0 }
        eventSink = sink
        let data = try Data(contentsOf: fixtures)
        let pairs = try JSONDecoder().decode([[String: String]].self, from: data)
        for p in pairs {
            guard let reqHex = p["req"], let resHex = p["res"] else { continue }
            let req = Self.bytes(fromHex: reqHex), res = Self.bytes(fromHex: resHex)
            recorded[reqHex] = res
            guard res.first != 0xFF, res.count == 32 else { continue }
            switch req[0] {
            case 0x12:
                let off = Int(req[1]) << 8 | Int(req[2]), n = Int(req[3])
                keymap.replaceSubrange(off..<off + n, with: res[4..<4 + n])
            case 0x0E:
                let off = Int(req[1]) << 8 | Int(req[2]), n = Int(req[3])
                macros.replaceSubrange(off..<off + n, with: res[4..<4 + n])
            case 0x14:
                encoders[[req[1], req[2], req[3]]] = [res[4], res[5]]
            case 0x08 where req[1] == 3:
                lighting[req[2]] = [res[3], res[4]]
            default: break
            }
        }
        factoryKeymap = keymap
        factoryEncoders = encoders
        let keymapURL = fixtures.deletingLastPathComponent().appendingPathComponent("extras.json")
        if let data = try? Data(contentsOf: keymapURL), let k = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func ints(_ key: String) -> [Int] { k[key] as? [Int] ?? [] }
            func grid(_ key: String) -> [[Int]] { k[key] as? [[Int]] ?? [] }
            keymapFeatures = UInt8(k["features"] as? Int ?? 0)
            debounceState = ints("debounce").map { UInt8($0) }
            snapSlots = grid("snapSlots").map { $0.map { UInt8($0) } }
            ledMapRows = grid("ledMapRows").map { $0.map { UInt8($0) } }
            perKeyType = UInt8(k["perKeyType"] as? Int ?? 0)
            perKeyColors = grid("perKeyColors").map { $0.map { UInt8($0) } }
            let mix = ints("mixInfo"); if mix.count == 2 { mixZones = mix[0]; mixSlots = mix[1] }
            regions = ints("regions").map { UInt8($0) }
            effectLists = (k["effectLists"] as? [[[Int]]] ?? []).map { zone in zone.map { e in
                [UInt8(e[0]), UInt8(e[1]), UInt8(e[2]), UInt8(e[3]), UInt8(e[4] & 0xFF), UInt8((e[4] >> 8) & 0xFF), UInt8((e[4] >> 16) & 0xFF), UInt8((e[4] >> 24) & 0xFF)] } }
        }
    }

    public func exchange(_ request: [UInt8]) async throws -> [UInt8] {
        lock.withLock { inflight += 1; _maxInflight = max(_maxInflight, inflight) }
        defer { lock.withLock { inflight -= 1 } }
        await Task.yield()   // lets other callers run while this exchange is "on the wire"
        return try lock.withLock {
            if let limit = failAfter, exchanges >= limit { throw ViaError.disconnected }
            exchanges += 1
            _sent.append(request.first ?? 0)
            _sentReq.append(Array(request.prefix(2)))
            _sentHeads.append(Array(request.prefix(3)))
            let req = Array((request + [UInt8](repeating: 0, count: max(0, 32 - request.count))).prefix(32))
            var reply = handle(req)
            if truncateAtRequest == exchanges { reply = Array(reply.prefix(4)) }
            if let transform = replyTransform { reply = transform(exchanges, reply) }
            return reply
        }
    }

    private func pad(_ b: [UInt8]) -> [UInt8] { Array((b + [UInt8](repeating: 0, count: 32)).prefix(32)) }
    private var unhandled: [UInt8] { [0xFF] + [UInt8](repeating: 0, count: 31) }

    private func keymapIndex(_ layer: UInt8, _ row: UInt8, _ col: UInt8) -> Int {
        ((Int(layer) * Self.rows + Int(row)) * Self.cols + Int(col)) * 2
    }

    private func handle(_ req: [UInt8]) -> [UInt8] {
        switch req[0] {
        case 0x01 where protocolVersionOverride != nil:
            let v = protocolVersionOverride!
            return pad([0x01, UInt8(v >> 8), UInt8(v & 0xFF)])
        case 0x02 where req[1] == 0x03:   // switch matrix state: one extra byte after the id (as on the real V3), then 2 bytes per row (high byte first), 6 rows
            var bytes = [UInt8](repeating: 0, count: Self.rows * 2)
            for key in heldKeys where key[0] < Self.rows && key[1] < Self.cols {
                bytes[key[0] * 2 + (key[1] >= 8 ? 0 : 1)] |= UInt8(1 << (key[1] % 8))
            }
            return pad([0x02, 0x03, 0x00] + bytes)
        case 0x04:   // get keycode
            let i = keymapIndex(req[1], req[2], req[3])
            return pad(Array(req.prefix(4)) + [keymap[i], keymap[i + 1]])
        case 0x12:   // get keymap buffer
            let off = Int(req[1]) << 8 | Int(req[2]), n = min(Int(req[3]), 28)
            guard off + n <= keymap.count else { return unhandled }
            return pad(Array(req.prefix(4)) + keymap[off..<off + n])
        case 0x0E:   // get macro buffer
            let off = Int(req[1]) << 8 | Int(req[2]), n = min(Int(req[3]), 28)
            guard off + n <= macros.count else { return unhandled }
            return pad(Array(req.prefix(4)) + macros[off..<off + n])
        case 0x14:   // get encoder
            guard let kc = encoders[[req[1], req[2], req[3]]] else { return unhandled }
            return pad(Array(req.prefix(4)) + kc)
        case 0x08:   // get custom value
            guard req[1] == 3, let v = lighting[req[2]] else { return unhandled }
            return pad(Array(req.prefix(3)) + v)
        case 0x06:   // dynamic keymap reset: keys and knob back to the factory ones
            if !ignoreWrites { keymap = factoryKeymap; encoders = factoryEncoders }
            return req
        case 0x05:   // set keycode
            if !ignoreWrites {
                let i = keymapIndex(req[1], req[2], req[3])
                keymap[i] = req[4]; keymap[i + 1] = req[5]
            }
            return req
        case 0x15:   // set encoder
            if !ignoreWrites { encoders[[req[1], req[2], req[3]]] = [req[4], req[5]] }
            return req
        case 0x0F:   // set macro buffer
            let off = Int(req[1]) << 8 | Int(req[2]), n = min(Int(req[3]), 28)
            guard off + n <= macros.count else { return unhandled }
            if !ignoreWrites { macros.replaceSubrange(off..<off + n, with: req[4..<4 + n]) }
            return req
        case 0x07:   // set custom value
            guard req[1] == 3 else { return unhandled }
            if !ignoreWrites {
                let isEffect = req[2] == 2 && clampsEffects
                // As on the real V3: while the effect is None the keyboard ignores brightness and rounds the colour's saturation.
                let effectNow = lighting[2]?[0] ?? 1
                if req[2] == 1 && effectNow == 0 { return req }
                var value = [isEffect ? min(req[3], mixedEffectID) : req[3], req[4]]
                if req[2] == 4 && effectNow == 0 { value[1] = min(value[1], 252) }
                lighting[req[2]] = value
            }
            return req
        case 0x09:   // custom save
            return req
        case 0xA2:
            return pad([0xA2, 0x00, keymapFeatures, 0x03])
        case 0xA7:
            return handleMisc(req)
        case 0xA8:
            return handleRGB(req)
        default:
            return recorded[Self.hex(req)] ?? unhandled
        }
    }

    // MARK: Extra groups (layouts as in the spec; limits as in the firmware)

    private func reply(_ req: [UInt8], status: UInt8 = 0, data: [UInt8] = []) -> [UInt8] { pad([req[0], req[1], status] + data) }

    /// Returns a rejection if a one-shot rejection was requested for a write; otherwise nil.
    private func rejectionIfRequested(_ req: [UInt8], isWrite: Bool) -> [UInt8]? {
        guard isWrite, rejectNextKeymapWrite else { return nil }
        rejectNextKeymapWrite = false
        return reply(req, status: 1)
    }

    private func handleMisc(_ req: [UInt8]) -> [UInt8] {
        let sub = req[1]
        let hasDebounce = keymapFeatures & 0x20 != 0, hasSnap = keymapFeatures & 0x40 != 0
        guard (hasDebounce && (0x05...0x06).contains(sub)) || (hasSnap && (0x07...0x0A).contains(sub)) else { return unhandled }
        if let r = rejectionIfRequested(req, isWrite: [0x06, 0x09, 0x0A].contains(sub)) { return r }
        switch sub {
        case 0x05: return reply(req, data: [0, debounceState[0], debounceState[1]])
        case 0x06:
            guard req[2] < 7 else { return reply(req, status: 1) }
            debounceState = [req[2], req[2] == 5 ? min(req[3], 127) : req[3]]
            return reply(req)
        case 0x07: return reply(req, data: [UInt8(snapSlots.count)])
        case 0x08:
            let start = Int(req[2]), count = Int(req[3])
            guard count <= 9, start + count <= snapSlots.count else { return reply(req, status: 1) }
            return reply(req, data: snapSlots[start..<start + count].flatMap { $0 })
        case 0x09:
            let start = Int(req[2]), count = Int(req[3])
            guard count <= 9, start + count <= snapSlots.count else { return reply(req, status: 1) }
            let incoming = (0..<count).map { Array(req[(4 + $0 * 3)..<(7 + $0 * 3)]) }
            guard incoming.allSatisfy({ $0[0] < 6 && ($0[0] == 0 || ($0[1] != 0 && $0[2] != 0)) }) else { return reply(req, status: 1) }
            for (i, slot) in incoming.enumerated() { snapSlots[start + i] = slot }
            return reply(req)
        default: return reply(req)   // 0x0A save
        }
    }

    private func handleRGB(_ req: [UInt8]) -> [UInt8] {
        guard keymapFeatures & 0x80 != 0 else { return unhandled }
        let sub = req[1]
        guard sub == 0x01 || sub == 0x02 || sub == 0x03 || sub == 0x04 || (0x05...0x0F).contains(sub) else { return unhandled }
        if let r = rejectionIfRequested(req, isWrite: [0x02, 0x04, 0x08, 0x0A, 0x0D, 0x0F].contains(sub)) { return r }
        switch sub {
        case 0x01: return reply(req, data: [1, 0])
        case 0x02: return reply(req)
        case 0x03: return reply(req, data: [indicatorState[0], indicatorState[1], indicatorState[2], indicatorState[3]])
        case 0x04:
            indicatorState[1] = req[2] & 0x1F
            indicatorState[2] = req[3]; indicatorState[3] = req[4]
            return reply(req)
        case 0x05: return reply(req, data: [UInt8(perKeyColors.count)])
        case 0x06:
            let row = Int(req[2]), mask = Int(req[3]) | Int(req[4]) << 8 | Int(req[5]) << 16
            guard row < ledMapRows.count else { return reply(req, status: 1) }
            return reply(req, data: (0..<16).map { mask & (1 << $0) != 0 ? ledMapRows[row][$0] : 0xFF })
        case 0x07: return reply(req, data: [perKeyType])
        case 0x08:
            guard req[2] < 5 else { return reply(req, status: 1) }
            perKeyType = req[2]
            return reply(req)
        case 0x09:
            let start = Int(req[2]), count = Int(req[3])
            guard count <= 9, start + count <= perKeyColors.count else { return reply(req, status: 1) }
            return reply(req, data: perKeyColors[start..<start + count].flatMap { $0 })
        case 0x0A:
            let start = Int(req[2]), count = Int(req[3])
            guard count <= 9, start + count <= perKeyColors.count else { return reply(req, status: 1) }
            for i in 0..<count { perKeyColors[start + i] = Array(req[(4 + i * 3)..<(7 + i * 3)]) }
            return reply(req)
        case 0x0B: return reply(req, data: [UInt8(mixZones), UInt8(mixSlots)])
        case 0x0C:
            let start = Int(req[2]), count = Int(req[3])
            guard count <= 29, start + count <= regions.count else { return reply(req, status: 1) }
            return reply(req, data: Array(regions[start..<start + count]))
        case 0x0D:
            let start = Int(req[2]), count = Int(req[3])
            guard count <= 28, start + count <= regions.count, (0..<count).allSatisfy({ Int(req[4 + $0]) < mixZones }) else { return reply(req, status: 1) }
            for i in 0..<count { regions[start + i] = req[4 + i] }
            return reply(req)
        case 0x0E:
            let zone = Int(req[2]), start = Int(req[3]), count = Int(req[4])
            guard count <= 3, zone < mixZones, start + count <= mixSlots else { return reply(req, status: 1) }
            return reply(req, data: effectLists[zone][start..<start + count].flatMap { $0 })
        default:   // 0x0F
            let zone = Int(req[2]), start = Int(req[3]), count = Int(req[4])
            guard count <= 3, zone < mixZones, start + count <= mixSlots else { return reply(req, status: 1) }
            let incoming = (0..<count).map { Array(req[(5 + $0 * 8)..<(13 + $0 * 8)]) }
            guard incoming.allSatisfy({ $0[0] < mixedEffectID }) else { return reply(req, status: 1) }
            for (i, e) in incoming.enumerated() { effectLists[zone][start + i] = e }
            return reply(req)
        }
    }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    static func bytes(fromHex s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
}

/// The recorded replies from the real keyboard (see Fixtures/fixtures.json).
public func fixturesURL() -> URL {
    Bundle.module.url(forResource: "fixtures", withExtension: "json", subdirectory: "Fixtures")!
}
