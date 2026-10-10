import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct IndicatorLightTests {
    @Test func readsTheCapsLockLight() async throws {
        let (_, _, current) = try await readRecordedConfig()
        let i = try #require(current.settings?.indicator)
        #expect(i.capsLockSupported && i.capsLockEnabled)
    }

    @Test func switchesTheLightOffAndChangesItsColourAndSavesIt() async throws {
        let (kb, dev, current) = try await readRecordedConfig()
        var target = current
        target.settings?.indicator?.capsLockEnabled = false
        target.settings?.indicator?.hue = 170
        target.settings?.indicator?.saturation = 200
        let result = try await ApplyEngine(device: dev, backupDirectory: tempDirectory()).apply(target, current: current)
        #expect(result.written.count == 1)
        #expect(try await ConfigStore.read(from: dev) == target)
        #expect(kb.sentRequests.contains([0xA8, 0x02]))   // saved
        #expect(kb.sentRequests.contains([0xA8, 0x04]))
    }

    @Test func diffDescribesIt() async throws {
        let (_, _, current) = try await readRecordedConfig()
        var b = current
        b.settings?.indicator?.capsLockEnabled = false
        let changes = ConfigStore.diff(from: current, to: b)
        #expect(changes.map(\.target) == [.indicator])
        #expect(changes[0].description.contains("switched off"))
    }
}
