import Foundation

// MARK: - Media playlists (videos, audio and images in one input)

public enum PlaylistItemKind: String, Codable, Sendable { case video, audio, image

    public static func from(fileExtension ext: String) -> PlaylistItemKind? {
        let e = ext.lowercased()
        if ["mp4", "mov", "m4v", "avi", "mkv", "mpg", "mpeg"].contains(e) { return .video }
        if ["mp3", "m4a", "wav", "aif", "aiff", "aac", "flac", "caf"].contains(e) { return .audio }
        if ["png", "jpg", "jpeg", "heic", "heif", "gif", "bmp", "tif", "tiff", "webp"].contains(e) { return .image }
        return nil
    }
}

public struct PlaylistItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var title: String
    public var kind: PlaylistItemKind
    public var imageSeconds: Double      // images only; 0 = use the playlist default
    public var enabled: Bool
    public init(id: UUID = UUID(), path: String, title: String? = nil, kind: PlaylistItemKind, imageSeconds: Double = 0, enabled: Bool = true) {
        self.id = id; self.path = path
        self.title = title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        self.kind = kind; self.imageSeconds = imageSeconds; self.enabled = enabled
    }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

public struct Playlist: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [PlaylistItem]
    public var loop: Bool
    public var shuffle: Bool
    public var autoAdvance: Bool
    public var imageSeconds: Double
    public var startOnProgram: Bool

    public init(id: UUID = UUID(), name: String = "Playlist", items: [PlaylistItem] = [], loop: Bool = true, shuffle: Bool = false,
                autoAdvance: Bool = true, imageSeconds: Double = 8, startOnProgram: Bool = true) {
        self.id = id; self.name = name; self.items = items; self.loop = loop; self.shuffle = shuffle
        self.autoAdvance = autoAdvance; self.imageSeconds = imageSeconds; self.startOnProgram = startOnProgram
    }

    enum CodingKeys: String, CodingKey { case id, name, items, loop, shuffle, autoAdvance, imageSeconds, startOnProgram }
    public init(from decoder: Decoder) throws {
        let d = Playlist()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); name = c.value(.name, d.name); items = c.value(.items, [PlaylistItem]())
        loop = c.value(.loop, d.loop); shuffle = c.value(.shuffle, d.shuffle); autoAdvance = c.value(.autoAdvance, d.autoAdvance)
        imageSeconds = c.value(.imageSeconds, d.imageSeconds); startOnProgram = c.value(.startOnProgram, d.startOnProgram)
    }

    public func seconds(for item: PlaylistItem) -> Double { item.imageSeconds > 0 ? item.imageSeconds : max(1, imageSeconds) }

    /// Index of the next playable item after `current` (nil at the end when not looping).
    public func nextIndex(after current: Int?, random: () -> Double = { Double.random(in: 0..<1) }) -> Int? {
        let playable = items.indices.filter { items[$0].enabled }
        guard !playable.isEmpty else { return nil }
        if shuffle && playable.count > 1 {
            let others = playable.filter { $0 != current }
            return others[min(others.count - 1, Int(random() * Double(others.count)))]
        }
        guard let cur = current else { return playable.first }
        if let n = playable.first(where: { $0 > cur }) { return n }
        return loop ? playable.first : nil
    }

    public func previousIndex(before current: Int?) -> Int? {
        let playable = items.indices.filter { items[$0].enabled }
        guard !playable.isEmpty else { return nil }
        guard let cur = current else { return playable.last }
        if let p = playable.last(where: { $0 < cur }) { return p }
        return loop ? playable.last : playable.first
    }

    public mutating func add(paths: [String]) -> Int {
        var n = 0
        for p in paths {
            guard let k = PlaylistItemKind.from(fileExtension: URL(fileURLWithPath: p).pathExtension) else { continue }
            items.append(PlaylistItem(path: p, kind: k)); n += 1
        }
        return n
    }
}

/// Saved playlists (Library/playlists.json).
public final class PlaylistLibrary {
    public let url: URL
    public private(set) var playlists: [Playlist]
    public init(libraryRoot: URL) {
        url = libraryRoot.appendingPathComponent("playlists.json")
        playlists = (try? JSONFile.read([Playlist].self, from: url)) ?? []
    }
    public func save(_ p: Playlist) {
        if let i = playlists.firstIndex(where: { $0.id == p.id }) { playlists[i] = p } else { playlists.append(p) }
        try? JSONFile.write(playlists, to: url)
    }
    public func delete(_ id: UUID) { playlists.removeAll { $0.id == id }; try? JSONFile.write(playlists, to: url) }
}

// MARK: - Zoom meeting links

public struct ZoomMeeting: Hashable, Sendable {
    public var id: String          // digits only
    public var passcode: String
    public var host: String        // e.g. us02web.zoom.us

    public init(id: String, passcode: String = "", host: String = "zoom.us") { self.id = id; self.passcode = passcode; self.host = host }

    /// Accepts an invite link (https://us02web.zoom.us/j/85012345678?pwd=abc) or a meeting ID ("850 1234 5678").
    public static func parse(_ text: String, passcode: String = "") -> ZoomMeeting? {
        let t = text.trimmed
        if let u = URL(string: t), let host = u.host, host.contains("zoom.us") {
            let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
            let parts = u.path.split(separator: "/").map(String.init)
            var id = ""
            if let i = parts.firstIndex(where: { $0 == "j" || $0 == "join" || $0 == "w" || $0 == "s" }), i + 1 < parts.count { id = parts[i + 1] }
            if let conf = comps?.queryItems?.first(where: { $0.name == "confno" })?.value { id = conf }
            let pwd = comps?.queryItems?.first(where: { $0.name == "pwd" })?.value ?? passcode
            let digits = id.filter { $0.isNumber }
            return digits.count >= 9 ? ZoomMeeting(id: digits, passcode: pwd, host: host) : nil
        }
        let digits = t.filter { $0.isNumber }
        guard digits.count >= 9, digits.count <= 12, t.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { return nil }
        return ZoomMeeting(id: digits, passcode: passcode)
    }

    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? s }

    /// Opens the Zoom desktop app and joins.
    public func appURL(displayName: String = "") -> URL? {
        var s = "zoommtg://zoom.us/join?action=join&confno=\(id)"
        if !passcode.isEmpty { s += "&pwd=\(ZoomMeeting.enc(passcode))" }
        if !displayName.trimmed.isEmpty { s += "&uname=\(ZoomMeeting.enc(displayName.trimmed))" }
        return URL(string: s)
    }

    /// Browser join page (fallback when the app is not installed).
    public var webURL: URL? {
        URL(string: "https://app.zoom.us/wc/join/\(id)" + (passcode.isEmpty ? "" : "?pwd=\(ZoomMeeting.enc(passcode))"))
    }

    public var displayID: String {
        let d = Array(id)
        switch d.count {
        case 11: return "\(String(d[0..<3])) \(String(d[3..<7])) \(String(d[7...]))"
        case 10: return "\(String(d[0..<3])) \(String(d[3..<6])) \(String(d[6...]))"
        default: return id
        }
    }
}
