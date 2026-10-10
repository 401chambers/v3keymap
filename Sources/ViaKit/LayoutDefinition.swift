import Foundation

/// One physical key: its matrix position and where to draw it (units of one standard key width).
public struct KeyPosition: Equatable, Codable, Sendable {
    public let row: Int
    public let col: Int
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

/// Key positions for the Keychron V3 ANSI Encoder, bundled so the app works offline.
public struct LayoutDefinition: Sendable {
    public let name: String
    public let keys: [KeyPosition]

    private struct File: Decodable { let name: String; let keys: [KeyPosition] }

    public static func v3AnsiEncoder() throws -> LayoutDefinition {
        guard let url = Bundle.module.url(forResource: "v3_ansi_encoder", withExtension: "json", subdirectory: "Resources") else {
            throw ViaError.invalid("the bundled V3 layout file is missing")
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return LayoutDefinition(name: file.name, keys: file.keys)
    }
}
