import Foundation

// MARK: - Tolerant decoding helpers
//
// Library files must stay readable for years: every document type decodes missing
// keys to defaults instead of failing, so adding fields never breaks old files.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
    }
}

/// Plain RGBA colour (0…1) — CoreGraphics-free so the model is portable and testable.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static let white = RGBAColor(1, 1, 1)
    public static let black = RGBAColor(0, 0, 0)
    public static let clear = RGBAColor(0, 0, 0, 0)

    /// "#RRGGBB" or "#RRGGBBAA"
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        } else {
            self.init(Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255,
                      Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        }
    }
    public var hex: String {
        func c(_ x: Double) -> String { String(format: "%02X", Int((min(1, max(0, x)) * 255).rounded())) }
        return "#" + c(r) + c(g) + c(b) + (a < 1 ? c(a) : "")
    }
}

/// Rectangle in canvas units (origin top-left, like a design tool).
public struct ElementFrame: Codable, Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

public struct CanvasSize: Codable, Hashable, Sendable {
    public var width: Int, height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public static let hd = CanvasSize(width: 1920, height: 1080)
    public static let uhd = CanvasSize(width: 3840, height: 2160)
}

extension String {
    /// Case- and diacritic-insensitive folding used for all library search.
    public var searchFolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum PresentationKitError: Error, LocalizedError, Equatable {
    case sqlite(String)
    case badFormat(String)
    case notFound(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let m): return "Database error: \(m)"
        case .badFormat(let m): return "Unrecognised file: \(m)"
        case .notFound(let m): return "Not found: \(m)"
        case .network(let m): return "Network error: \(m)"
        }
    }
}

/// Atomic JSON persistence shared by all stores.
enum JSONFile {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(T.self, from: Data(contentsOf: url))
    }
}
