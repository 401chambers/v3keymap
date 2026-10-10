/// Names for this keyboard's RGB matrix effects. The numbers and names are the ones Keychron's own Launcher uses for the
/// V3 Knob (ids 0-22 are the keyboard's built-in effects; per-key and Mix RGB are separate custom effects above them).
public enum RGBMatrixEffect {
    public struct Effect: Equatable, Sendable {
        public let id: UInt8
        public let name: String
    }

    public static let all: [Effect] = [
        "None", "Solid Color", "Breathing", "Band Spiral Val", "Cycle All", "Cycle Left Right", "Cycle Up Down",
        "Rainbow Moving Chevron", "Cycle Out In", "Cycle Out In Dual", "Cycle Pinwheel", "Cycle Spiral", "Dual Beacon",
        "Rainbow Beacon", "Jellybean Raindrops", "Pixel Rain", "Typing Heatmap", "Digital Rain", "Reactive Simple",
        "Reactive Multiwide", "Reactive Multinexus", "Splash", "Solid Splash",
    ].enumerated().map { Effect(id: UInt8($0.offset), name: $0.element) }

    /// Effects that use a colour of their own (the Launcher shows a colour picker for these).
    public static let usesColour: Set<UInt8> = [1, 2, 3]

    public static func name(for id: UInt8) -> String {
        all.first { $0.id == id }?.name ?? "Effect \(id)"
    }
}
