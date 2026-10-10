import Foundation
import Testing
import ViaKitTestSupport
@testable import ViaKit

@Suite struct LayoutTests {
    private func nonZeroLayer0Positions() async throws -> Set<[Int]> {
        let kb = try SimulatedKeyboard(fixtures: fixturesURL())
        let map = try await ViaDevice(transport: kb).keymap(layers: 4, size: .v3)
        var out = Set<[Int]>()
        for r in 0..<6 { for c in 0..<16 where map[0][r][c].raw != 0 { out.insert([r, c]) } }
        return out
    }

    @Test func everyKeyThatHasAKeycodeOnLayer0IsInTheLayout() async throws {
        let layout = try LayoutDefinition.v3AnsiEncoder()
        let inLayout = Set(layout.keys.map { [$0.row, $0.col] })
        let occupied = try await nonZeroLayer0Positions()
        #expect(occupied.subtracting(inLayout).isEmpty)
        #expect(layout.keys.count == occupied.count)
    }

    @Test func noTwoKeysShareAMatrixPosition() throws {
        let layout = try LayoutDefinition.v3AnsiEncoder()
        #expect(Set(layout.keys.map { [$0.row, $0.col] }).count == layout.keys.count)
    }

    @Test func allKeysFitTheV3Matrix() throws {
        let layout = try LayoutDefinition.v3AnsiEncoder()
        #expect(layout.keys.allSatisfy { $0.row < MatrixSize.v3.rows && $0.col < MatrixSize.v3.cols })
        #expect(layout.keys.allSatisfy { $0.width > 0 && $0.height > 0 })
    }

    @Test func knownKeysSitWhereTheKeyboardSaysTheyAre() throws {
        let keys = try LayoutDefinition.v3AnsiEncoder().keys
        let esc = try #require(keys.first { $0.row == 0 && $0.col == 0 })
        #expect(esc.x == 0 && esc.y == 0)
        let space = try #require(keys.first { $0.row == 5 && $0.col == 6 })
        #expect(space.width == 6.25)
    }
}
