/// A key's position in the switch matrix.
public struct MatrixPosition: Hashable, Sendable {
    public let row: Int
    public let col: Int
    public init(row: Int, col: Int) { self.row = row; self.col = col }
}
