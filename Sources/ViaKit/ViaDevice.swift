import Foundation

public struct MatrixSize: Equatable, Sendable {
    public let rows: Int
    public let cols: Int
    public init(rows: Int, cols: Int) { self.rows = rows; self.cols = cols }
    /// Keychron V3 TKL: 6 rows x 16 columns (verified against the keyboard's own keymap data).
    public static let v3 = MatrixSize(rows: 6, cols: 16)
}

/// RGB matrix lighting values (VIA custom channel 3).
public struct LightingState: Equatable, Codable, Sendable {
    /// Whether the keyboard kept what was asked. With the effect None it ignores brightness and rounds the colour, so only
    /// the effect and speed are compared then.
    public func isStored(as read: LightingState) -> Bool {
        effect == 0 ? (read.effect == 0 && read.speed == speed) : self == read
    }

    public var brightness: UInt8
    public var effect: UInt8
    public var speed: UInt8
    public var hue: UInt8
    public var saturation: UInt8

    public init(brightness: UInt8, effect: UInt8, speed: UInt8, hue: UInt8, saturation: UInt8) {
        self.brightness = brightness
        self.effect = effect
        self.speed = speed
        self.hue = hue
        self.saturation = saturation
    }
}

/// Typed VIA protocol 12 commands over a `HIDTransport`.
public actor ViaDevice {
    enum Command {
        static let protocolVersion: UInt8 = 0x01
        static let keyboardValue: UInt8 = 0x02
        static let getKeycode: UInt8 = 0x04
        static let setKeycode: UInt8 = 0x05
        static let customSet: UInt8 = 0x07
        static let customGet: UInt8 = 0x08
        static let customSave: UInt8 = 0x09
        static let eepromReset: UInt8 = 0x0A       // never sent
        static let bootloaderJump: UInt8 = 0x0B    // never sent
        static let macroCount: UInt8 = 0x0C
        static let macroBufferSize: UInt8 = 0x0D
        static let macroGetBuffer: UInt8 = 0x0E
        static let macroSetBuffer: UInt8 = 0x0F
        static let layerCount: UInt8 = 0x11
        static let keymapGetBuffer: UInt8 = 0x12
        static let getEncoder: UInt8 = 0x14
        static let setEncoder: UInt8 = 0x15
        static let keymapFirmware: UInt8 = 0xA1
    }

    /// Commands whose reply repeats the first N bytes of the request.
    static let echoedHeaderLength: [UInt8: Int] = [0x04: 4, 0x05: 4, 0x07: 3, 0x08: 3, 0x0E: 4, 0x0F: 4, 0x12: 4, 0x13: 4, 0x14: 4, 0x15: 4]

    static let chunk = 28          // data bytes per buffer read/write (32-byte report minus 4 header bytes)
    static let lightingChannel: UInt8 = 3

    private let transport: HIDTransport
    // The keyboard answers one request at a time, but actor methods interleave at `await`. This FIFO lock
    // makes callers (e.g. Key Test polling during an apply) queue behind each other instead of overlapping.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(transport: HIDTransport) { self.transport = transport }

    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// Single choke point for every request: frames the reply and maps VIA's "unhandled" answer.
    func send(_ bytes: [UInt8]) async throws -> [UInt8] {
        guard Self.isAllowed(bytes) else { throw ViaError.forbiddenCommand(bytes.first ?? 0) }
        await acquire()
        defer { release() }
        let reply = try await transport.exchange(bytes)
        guard reply.count == 32 else { throw ViaError.shortReply }
        if reply[0] == 0xFF { throw ViaError.unsupported(command: bytes[0]) }
        guard reply[0] == bytes[0] else { throw ViaError.invalid("reply to 0x\(String(bytes[0], radix: 16)) was 0x\(String(reply[0], radix: 16))") }
        // The keyboard echoes the request's header (layer/row/col, offset, channel/id). A reply for a different
        // header is a stale or corrupted answer, not the one we asked for.
        if let n = Self.echoedHeaderLength[bytes[0]], bytes.count >= n, Array(reply[1..<n]) != Array(bytes[1..<n]) {
            throw ViaError.invalid("the keyboard answered a different request than command 0x\(String(bytes[0], radix: 16))")
        }
        if bytes[0] == Keymap.misc || bytes[0] == Keymap.rgb {
            // Extra replies are [group, sub-command, status, data...]; status 0 means accepted.
            guard bytes.count >= 2, reply[1] == bytes[1] else {
                throw ViaError.invalid("the keyboard answered a different extra request than 0x\(String(bytes[0], radix: 16)) 0x\(String(bytes.count >= 2 ? bytes[1] : 0, radix: 16))")
            }
            if reply[2] != 0 {
                throw ViaError.rejected("the keyboard refused extra request 0x\(String(bytes[0], radix: 16)) 0x\(String(bytes[1], radix: 16))")
            }
        }
        return reply
    }

    private func be16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }

    private func readBuffer(command: UInt8, total: Int) async throws -> [UInt8] {
        var out: [UInt8] = []
        var offset = 0
        while offset < total {
            let n = min(Self.chunk, total - offset)
            let r = try await send([command, UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(n)])
            out += r[4..<4 + n]
            offset += n
        }
        return out
    }

    public func protocolVersion() async throws -> UInt16 {
        UInt16(be16(try await send([Command.protocolVersion]), 1))
    }

    public func layerCount() async throws -> Int {
        Int(try await send([Command.layerCount])[1])
    }

    /// Keymap indexed `[layer][row][col]`.
    public func keymap(layers: Int, size: MatrixSize) async throws -> [[[Keycode]]] {
        let bytes = try await readBuffer(command: Command.keymapGetBuffer, total: layers * size.rows * size.cols * 2)
        return (0..<layers).map { l in
            (0..<size.rows).map { r in
                (0..<size.cols).map { c in
                    let i = ((l * size.rows + r) * size.cols + c) * 2
                    return Keycode(raw: UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                }
            }
        }
    }

    public func encoder(layer: Int, index: Int, clockwise: Bool) async throws -> Keycode {
        let r = try await send([Command.getEncoder, UInt8(layer), UInt8(index), clockwise ? 1 : 0])
        return Keycode(raw: UInt16(be16(r, 4)))
    }

    public func macroCount() async throws -> Int {
        Int(try await send([Command.macroCount])[1])
    }

    public func macroBufferSize() async throws -> Int {
        be16(try await send([Command.macroBufferSize]), 1)
    }

    public func macroBuffer() async throws -> [UInt8] {
        try await readBuffer(command: Command.macroGetBuffer, total: try await macroBufferSize())
    }

    /// Raw bytes (reply bytes 3...4) of a VIA custom value.
    public func customValue(channel: UInt8, id: UInt8) async throws -> [UInt8] {
        let r = try await send([Command.customGet, channel, id])
        return [r[3], r[4]]
    }

    public func lighting() async throws -> LightingState {
        let ch = Self.lightingChannel
        let brightness = try await customValue(channel: ch, id: 1)[0]
        let effect = try await customValue(channel: ch, id: 2)[0]
        let speed = try await customValue(channel: ch, id: 3)[0]
        let color = try await customValue(channel: ch, id: 4)
        return LightingState(brightness: brightness, effect: effect, speed: speed, hue: color[0], saturation: color[1])
    }

    /// Raw switch-matrix state bytes (bit per key); all zero when no key is pressed. The real keyboard puts one extra byte
    /// between the command id and the row data (found by pressing known keys on the V3), so the rows start at reply byte 3.
    public func matrixState() async throws -> [UInt8] {
        Array(try await send([Command.keyboardValue, 0x03])[3...])
    }

    /// Keys currently held down.
    public func pressedKeys(size: MatrixSize = .v3) async throws -> Set<MatrixPosition> {
        try Self.pressedKeys(inMatrixBytes: try await matrixState(), size: size)
    }

    /// Decodes matrix row data: 2 bytes per row, columns 8-15 first, then columns 0-7, one bit per column.
    static func pressedKeys(inMatrixBytes bytes: [UInt8], size: MatrixSize) throws -> Set<MatrixPosition> {
        let bytesPerRow = (size.cols + 7) / 8
        guard bytes.count >= size.rows * bytesPerRow else { throw ViaError.shortReply }
        var pressed = Set<MatrixPosition>()
        for row in 0..<size.rows {
            var value = 0
            for b in 0..<bytesPerRow { value = value << 8 | Int(bytes[row * bytesPerRow + b]) }
            for col in 0..<size.cols where (value >> col) & 1 == 1 { pressed.insert(MatrixPosition(row: row, col: col)) }
        }
        return pressed
    }

    public func firmwareString() async throws -> String {
        let r = try await send([Command.keymapFirmware])
        let text = r[1...].prefix(while: { $0 != 0 })
        return String(decoding: text, as: UTF8.self)
    }

    // MARK: - Writes (each verified by reading back)

    private func refuseDangerous(_ code: Keycode) throws {
        guard !code.isDangerous else {
            throw ViaError.invalid("\(code.name) would put the keyboard into flash mode or erase its settings; it cannot be written")
        }
    }

    public func setKeycode(layer: Int, row: Int, col: Int, _ code: Keycode) async throws {
        try refuseDangerous(code)
        let at = [UInt8(layer), UInt8(row), UInt8(col)]
        _ = try await send([Command.setKeycode] + at + [UInt8(code.raw >> 8), UInt8(code.raw & 0xFF)])
        let back = be16(try await send([Command.getKeycode] + at), 4)
        if back != Int(code.raw) {
            throw ViaError.verifyMismatch(["layer \(layer) row \(row) col \(col): wrote 0x\(String(code.raw, radix: 16)), read 0x\(String(back, radix: 16))"])
        }
    }

    public func setEncoder(layer: Int, index: Int, clockwise: Bool, _ code: Keycode) async throws {
        try refuseDangerous(code)
        let at = [UInt8(layer), UInt8(index), clockwise ? 1 : 0]
        _ = try await send([Command.setEncoder] + at + [UInt8(code.raw >> 8), UInt8(code.raw & 0xFF)])
        let back = be16(try await send([Command.getEncoder] + at), 4)
        if back != Int(code.raw) {
            throw ViaError.verifyMismatch(["encoder layer \(layer) index \(index) \(clockwise ? "cw" : "ccw"): wrote 0x\(String(code.raw, radix: 16)), read 0x\(String(back, radix: 16))"])
        }
    }

    /// Writes `bytes` at the start of the macro buffer; the rest of the buffer is left as it is.
    public func setMacroBuffer(_ bytes: [UInt8]) async throws {
        let size = try await macroBufferSize()
        guard bytes.count <= size else {
            throw ViaError.invalid("macros need \(bytes.count) bytes but the keyboard has room for \(size)")
        }
        var offset = 0
        while offset < bytes.count {
            let n = min(Self.chunk, bytes.count - offset)
            _ = try await send([Command.macroSetBuffer, UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(n)] + bytes[offset..<offset + n])
            offset += n
        }
        let back = try await readBuffer(command: Command.macroGetBuffer, total: bytes.count)
        if let first = zip(back, bytes).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            throw ViaError.verifyMismatch(["macro buffer differs from byte \(first)"])
        }
    }

    /// Writes the lighting and checks it. The keyboard ignores brightness while the effect is None, so the order matters:
    /// to turn an effect on, the effect goes first; to turn lighting off, brightness and colour go first. With no effect
    /// running before or after, brightness cannot change and is left alone.
    public func setLighting(_ state: LightingState) async throws {
        let ch = Self.lightingChannel
        let current = try await lighting()
        func writeEffect() async throws {
            _ = try await send([Command.customSet, ch, 2, state.effect])
            // The keyboard takes a moment to switch effect; a brightness sent straight after is ignored.
            if state.effect != current.effect { try await Task.sleep(for: .milliseconds(120)) }
        }
        func writeLook() async throws {
            if state.effect != 0 || current.effect != 0 { _ = try await send([Command.customSet, ch, 1, state.brightness]) }
            _ = try await send([Command.customSet, ch, 3, state.speed])
            _ = try await send([Command.customSet, ch, 4, state.hue, state.saturation])
        }
        if state.effect == 0 {
            try await writeLook()
            try await writeEffect()
            _ = try await send([Command.customSet, ch, 4, state.hue, state.saturation])
        } else {
            try await writeEffect()
            try await writeLook()
        }
        let back = try await lighting()
        guard state.isStored(as: back) else { throw ViaError.verifyMismatch(["lighting: wrote \(state), read \(back)"]) }
        _ = try await send([Command.customSave, ch])
    }

    /// Shows lighting on the keyboard without saving it: only what differs from `old` is sent, in the order the V3 needs
    /// (see `setLighting`). The keyboard goes back to its saved lighting when it is unplugged, or when the old values are sent again.
    static let previewSettle: Duration = .milliseconds(40)

    public func previewLighting(_ new: LightingState, from old: LightingState) async throws {
        let ch = Self.lightingChannel
        // The keyboard ignores brightness and colour writes sent straight after an effect change, so a short wait follows one.
        if new.effect != old.effect && new.effect != 0 {
            _ = try await send([Command.customSet, ch, 2, new.effect])
            try await Task.sleep(for: Self.previewSettle)
        }
        if new.brightness != old.brightness && (new.effect != 0 || old.effect != 0) { _ = try await send([Command.customSet, ch, 1, new.brightness]) }
        if new.speed != old.speed { _ = try await send([Command.customSet, ch, 3, new.speed]) }
        if new.hue != old.hue || new.saturation != old.saturation { _ = try await send([Command.customSet, ch, 4, new.hue, new.saturation]) }
        if new.effect == 0 && old.effect != 0 { _ = try await send([Command.customSet, ch, 2, 0]) }
    }

    static let supportedProtocol: UInt16 = 0x000C

    /// Refuses to continue unless the device speaks the VIA protocol version this app was built for.
    public func validate() async throws {
        let v = try await protocolVersion()
        guard v == Self.supportedProtocol else {
            throw ViaError.wrongDevice("VIA protocol 0x\(String(v, radix: 16)); this app supports 0x\(String(Self.supportedProtocol, radix: 16))")
        }
    }
}
