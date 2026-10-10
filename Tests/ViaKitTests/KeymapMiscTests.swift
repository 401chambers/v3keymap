import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct KeymapMiscTests {
    private func make() throws -> (SimulatedKeyboard, ViaDevice) {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        return (kb, ViaDevice(transport: kb))
    }

    @Test func readsRecordedDebounce() async throws {
        let (_, dev) = try make()
        #expect(try await dev.debounce() == DebounceSettings(type: .symEagerPerKey, time: 50))
    }

    @Test func setDebounceReadsBack() async throws {
        let (_, dev) = try make()
        try await dev.setDebounce(DebounceSettings(type: .symEagerPerRow, time: 10))
        #expect(try await dev.debounce() == DebounceSettings(type: .symEagerPerRow, time: 10))
    }

    @Test func asymmetricDebounceIsSentClampedAndStillVerifies() async throws {
        let (_, dev) = try make()
        try await dev.setDebounce(DebounceSettings(type: .asymEagerDeferPerKey, time: 200))
        #expect(try await dev.debounce() == DebounceSettings(type: .asymEagerDeferPerKey, time: 127))
    }

    @Test func snapClickHas20EmptySlots() async throws {
        let (_, dev) = try make()
        #expect(try await dev.snapClickSlotCount() == 20)
        let slots = try await dev.snapClickSlots()
        #expect(slots.count == 20 && slots.allSatisfy { $0 == .empty })
    }

    @Test func setsASlotAndReadsItBack() async throws {
        let (_, dev) = try make()
        try await dev.setSnapClickSlots([SnapClickSlot(type: .lastInput, key1: 4, key2: 7)], startingAt: 3)
        let slots = try await dev.snapClickSlots()
        #expect(slots[3] == SnapClickSlot(type: .lastInput, key1: 4, key2: 7))
        #expect(slots[2] == .empty && slots[4] == .empty)
    }

    // Review Focus 5
    @Test func slotWithMissingKeyIsRejectedBeforeAnyWrite() async throws {
        let (kb, dev) = try make()
        await #expect(throws: ViaError.self) {
            try await dev.setSnapClickSlots([SnapClickSlot(type: .regular, key1: 4, key2: 0)], startingAt: 0)
        }
        #expect(!kb.sentRequests.contains([0xA7, 0x09]))
    }

    @Test func manySlotsSplitIntoChunksOfNineAndAllLandInPlace() async throws {
        let (kb, dev) = try make()
        let incoming = (0..<12).map { SnapClickSlot(type: .regular, key1: UInt8(4 + $0), key2: UInt8(20 + $0)) }
        try await dev.setSnapClickSlots(incoming, startingAt: 4)
        let slots = try await dev.snapClickSlots()
        for i in 0..<12 { #expect(slots[4 + i] == incoming[i], "slot \(4 + i)") }
        #expect(slots[3] == .empty && slots[16] == .empty)
        #expect(kb.sentRequests.filter { $0 == [0xA7, 0x09] }.count == 2)   // 9 + 3
    }

    @Test func outOfRangeSlotsAreRejectedBeforeWriting() async throws {
        let (kb, dev) = try make()
        await #expect(throws: ViaError.self) {
            try await dev.setSnapClickSlots([SnapClickSlot.empty, SnapClickSlot.empty], startingAt: 19)
        }
        #expect(!kb.sentRequests.contains([0xA7, 0x09]))
    }

    @Test func savesOnlyWhenAsked() async throws {
        let (kb, dev) = try make()
        try await dev.setSnapClickSlots([SnapClickSlot(type: .neutral, key1: 4, key2: 7)], startingAt: 0)
        #expect(!kb.sentRequests.contains([0xA7, 0x0A]))
        try await dev.saveSnapClick()
        #expect(kb.sentRequests.contains([0xA7, 0x0A]))
    }
}
