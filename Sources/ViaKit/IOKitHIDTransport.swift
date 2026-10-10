import Foundation
import IOKit.hid

public enum ConnectionEvent: Sendable { case connected, disconnected }

/// A transport that can tell the app the keyboard was plugged in or pulled out.
public protocol ConnectionEventSource: Sendable {
    var events: AsyncStream<ConnectionEvent> { get }
}

/// The real keyboard: VIA raw HID channel (vendor 0x3434, product 0x0331, usage page 0xFF60, usage 0x61).
/// Exchanges are one request, one 32-byte reply, with a 1 second timeout.
///
/// Uses the run-loop flow proven by the probe (schedule manager, open, copy devices, register the
/// report callback); registering device callbacks after a dispatch-queue activation traps in IOKit.
public final class IOKitHIDTransport: HIDTransport, ConnectionEventSource, @unchecked Sendable {
    public static let vendorID = 0x3434, productID = 0x0331
    static let usagePage = 0xFF60, usage = 0x61
    static let timeout: TimeInterval = 1.0

    private let manager: IOHIDManager
    private let runLoopThread: Thread
    private let runLoop: CFRunLoop
    private let report = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let lock = NSLock()
    private var device: IOHIDDevice?
    private var pending: CheckedContinuation<[UInt8], Error>?
    private var requestID = 0
    /// The bytes a genuine reply echoes: the command, and for the 0xA7/0xA8 groups the sub-command too.
    private var expectedHeader: [UInt8] = []
    private let eventSink: AsyncStream<ConnectionEvent>.Continuation
    public let events: AsyncStream<ConnectionEvent>

    /// Throws `.disconnected` if the keyboard is not plugged in and `.permissionDenied` if macOS refuses access.
    public init() throws {
        var sink: AsyncStream<ConnectionEvent>.Continuation!
        events = AsyncStream { sink = $0 }
        eventSink = sink

        // Dedicated thread whose run loop delivers HID callbacks.
        let ready = DispatchSemaphore(value: 0)
        var loop: CFRunLoop!
        let thread = Thread {
            loop = CFRunLoopGetCurrent()
            ready.signal()
            while !Thread.current.isCancelled { CFRunLoopRunInMode(.defaultMode, 0.25, false) }
        }
        thread.name = "v3keymap.via.hid"
        thread.start()
        ready.wait()
        runLoopThread = thread
        runLoop = loop

        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID,
            kIOHIDPrimaryUsagePageKey: Self.usagePage, kIOHIDPrimaryUsageKey: Self.usage,
        ] as CFDictionary)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, _ in
            Unmanaged<IOKitHIDTransport>.fromOpaque(ctx!).takeUnretainedValue().detach()
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)

        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened == kIOReturnNotPermitted { shutDown(); throw ViaError.permissionDenied }
        guard let found = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else {
            shutDown()
            throw ViaError.disconnected
        }
        device = found
        IOHIDDeviceRegisterInputReportCallback(found, report, 64, { ctx, _, _, _, _, bytes, length in
            Unmanaged<IOKitHIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
                .received(Array(UnsafeBufferPointer(start: bytes, count: length)))
        }, Unmanaged.passUnretained(self).toOpaque())
        eventSink.yield(.connected)
    }

    deinit {
        shutDown()
        report.deallocate()
        eventSink.finish()
    }

    private func shutDown() {
        IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        runLoopThread.cancel()
    }

    private func takePending() -> CheckedContinuation<[UInt8], Error>? {
        lock.lock(); defer { lock.unlock() }
        let p = pending
        pending = nil
        return p
    }

    private func detach() {
        lock.lock(); device = nil; lock.unlock()
        takePending()?.resume(throwing: ViaError.disconnected)
        eventSink.yield(.disconnected)
    }

    private func received(_ bytes: [UInt8]) {
        // A late answer to an earlier (timed-out) request must not be taken as the answer to this one:
        // accept only the pending command's echo, or VIA's 0xFF "unhandled" reply.
        lock.lock()
        let matches = bytes.first == 0xFF || (bytes.count >= expectedHeader.count && Array(bytes.prefix(expectedHeader.count)) == expectedHeader)
        lock.unlock()
        guard matches else { return }
        takePending()?.resume(returning: bytes)
    }

    private func expire(_ id: Int) {
        lock.lock()
        guard requestID == id, let p = pending else { lock.unlock(); return }
        pending = nil
        lock.unlock()
        p.resume(throwing: ViaError.timeout)
    }

    public func exchange(_ request: [UInt8]) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            lock.lock()
            guard let device else { lock.unlock(); cont.resume(throwing: ViaError.disconnected); return }
            guard pending == nil else { lock.unlock(); cont.resume(throwing: ViaError.invalid("overlapping request")); return }
            requestID += 1
            let id = requestID
            expectedHeader = Array(request.prefix(request.first == 0xA7 || request.first == 0xA8 ? 2 : 1))
            pending = cont
            lock.unlock()

            let out = Array((request + [UInt8](repeating: 0, count: 32)).prefix(32))
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, out, out.count)
            if result != kIOReturnSuccess {
                takePending()?.resume(throwing: result == kIOReturnNotPermitted ? ViaError.permissionDenied : ViaError.disconnected)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) { [weak self] in self?.expire(id) }
        }
    }
}
