import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Online lyrics search
//
// Free sources that need no account or key:
//  • LRCLIB (lrclib.net) — open, community-built lyrics database with a free JSON API.
//  • Lyrics.ovh (api.lyrics.ovh) — free API; needs artist + exact title.
// Plus web sites opened inside the app (Hymnary.org public-domain hymn texts, Genius, Musixmatch…)
// where the user selects the words and brings them into the editor.
//
// Lyrics found online still belong to their authors/publishers. Projecting copyrighted songs in
// church requires a licence such as CCLI or OneLicense; public-domain hymns are free to use.

public enum LyricsProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case lrclib = "LRCLIB"
    case lyricsOvh = "Lyrics.ovh"
    public var id: String { rawValue }
    public var detail: String {
        switch self {
        case .lrclib: return "Free, open lyrics database — search by title, artist or any words. No account needed."
        case .lyricsOvh: return "Free lyrics API — enter the artist and the exact song title."
        }
    }
}

public struct LyricsHit: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double?
    public var lyrics: String
    public var provider: String
    public init(id: String, title: String, artist: String, album: String = "", duration: Double? = nil, lyrics: String, provider: String) {
        self.id = id; self.title = title; self.artist = artist; self.album = album
        self.duration = duration; self.lyrics = lyrics; self.provider = provider
    }
    public var firstLine: String { lyrics.components(separatedBy: "\n").first { !$0.trimmed.isEmpty } ?? "" }
}

public struct LyricsWebSite: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let detail: String
    let template: String          // {q} is replaced by the URL-encoded query
    public init(name: String, detail: String, template: String) { self.name = name; self.detail = detail; self.template = template }
    public func url(for query: String) -> URL? {
        let q = query.trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
        return URL(string: template.replacingOccurrences(of: "{q}", with: q))
    }

    public static let all: [LyricsWebSite] = [
        LyricsWebSite(name: "Hymnary.org", detail: "Hymns — full texts of public-domain hymns",
                      template: "https://hymnary.org/search?qu={q}"),
        LyricsWebSite(name: "Hymnal.net", detail: "Hymns and gospel songs",
                      template: "https://duckduckgo.com/?q=site%3Ahymnal.net+{q}"),
        LyricsWebSite(name: "Genius", detail: "Contemporary and gospel songs",
                      template: "https://genius.com/search?q={q}"),
        LyricsWebSite(name: "Musixmatch", detail: "Large multilingual lyrics catalogue",
                      template: "https://www.musixmatch.com/search?query={q}"),
        LyricsWebSite(name: "AZLyrics", detail: "Popular and worship songs",
                      template: "https://duckduckgo.com/?q=site%3Aazlyrics.com+{q}"),
        LyricsWebSite(name: "CCLI SongSelect", detail: "Official licensed worship lyrics (free or paid CCLI account)",
                      template: "https://duckduckgo.com/?q=site%3Asongselect.ccli.com+{q}"),
        LyricsWebSite(name: "Web search", detail: "Any site — e.g. African gospel songs",
                      template: "https://duckduckgo.com/?q={q}+lyrics")
    ]
}

public enum LyricsSearch {
    public static let userAgent = "LiveDeckStudio/4.2 (macOS church production app; https://github.com/)"

    static func q(_ s: String) -> String {
        s.trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
    }

    /// Structured search when a title is given, otherwise free text.
    public static func lrclibURL(query: String, title: String = "", artist: String = "") -> URL? {
        if !title.trimmed.isEmpty {
            var s = "https://lrclib.net/api/search?track_name=\(q(title))"
            if !artist.trimmed.isEmpty { s += "&artist_name=\(q(artist))" }
            return URL(string: s)
        }
        let text = [query, artist].map { $0.trimmed }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return URL(string: "https://lrclib.net/api/search?q=\(q(text))")
    }

    public static func lyricsOvhURL(artist: String, title: String) -> URL? {
        let a = artist.trimmed, t = title.trimmed
        guard !a.isEmpty, !t.isEmpty else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        guard let ea = a.addingPercentEncoding(withAllowedCharacters: allowed),
              let et = t.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://api.lyrics.ovh/v1/\(ea)/\(et)")
    }

    // MARK: Parsers (pure — unit tested)

    public static func parseLRCLIB(_ data: Data) -> [LyricsHit] {
        let arr: [[String: Any]]
        if let a = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { arr = a }
        else if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { arr = [o] }   // /api/get
        else { return [] }
        var seen = Set<String>()
        return arr.compactMap { o in
            if (o["instrumental"] as? Bool) == true { return nil }
            var text = (o["plainLyrics"] as? String) ?? ""
            if text.trimmed.isEmpty, let synced = o["syncedLyrics"] as? String { text = stripLRCTimestamps(synced) }
            text = clean(text)
            guard !text.isEmpty else { return nil }
            let title = (o["trackName"] as? String) ?? (o["name"] as? String) ?? ""
            let artist = (o["artistName"] as? String) ?? ""
            // the same song often appears once per album release — keep the first copy of identical words
            let key = (title + "|" + artist + "|" + text.prefix(200)).lowercased()
            guard seen.insert(key).inserted else { return nil }
            let idValue = o["id"].map { "\($0)" } ?? UUID().uuidString
            return LyricsHit(id: "lrclib-\(idValue)", title: title, artist: artist,
                             album: (o["albumName"] as? String) ?? "", duration: o["duration"] as? Double,
                             lyrics: text, provider: "LRCLIB")
        }
    }

    public static func parseLyricsOvh(_ data: Data, artist: String, title: String) -> LyricsHit? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var text = o["lyrics"] as? String else { return nil }
        // Lyrics.ovh prefixes a French "Paroles de la chanson … par …" line
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if let first = lines.first, first.lowercased().hasPrefix("paroles de la chanson") { lines.removeFirst() }
        text = clean(lines.joined(separator: "\n"))
        guard !text.isEmpty else { return nil }
        return LyricsHit(id: "ovh-\(artist.lowercased())-\(title.lowercased())", title: title.trimmed, artist: artist.trimmed,
                         lyrics: text, provider: "Lyrics.ovh")
    }

    public static func stripLRCTimestamps(_ s: String) -> String {
        s.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: "^(\\s*\\[[0-9:.]+\\])+\\s*", with: "", options: .regularExpression)
        }
        .filter { !$0.hasPrefix("[") || SectionKind.parseHeader($0) != nil }     // drop [ar:] [ti:] tags
        .joined(separator: "\n")
    }

    /// Normalises line endings and spacing: no trailing spaces, at most one blank line in a row.
    public static func clean(_ s: String) -> String {
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        var out: [String] = []
        for l in lines {
            if l.trimmed.isEmpty { if let last = out.last, !last.isEmpty { out.append("") } }
            else { out.append(l) }
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// Builds a library song from edited lyrics (section headers such as "Verse 1" / "[Chorus]" are recognised;
    /// a blank line starts a new slide).
    public static func song(title: String, artist: String, lyrics: String, source: String) -> Song {
        var s = SongImporter.plainText(lyrics, fallbackTitle: title.trimmed.isEmpty ? "Untitled" : title.trimmed)
        if !title.trimmed.isEmpty { s.title = title.trimmed }
        if s.author.isEmpty { s.author = artist.trimmed }
        s.source = source.isEmpty ? "Online lyrics" : source
        return s
    }

    // MARK: Network

    public static func search(_ provider: LyricsProvider, query: String, title: String, artist: String,
                              completion: @escaping (Result<[LyricsHit], Error>) -> Void) {
        let url: URL?
        switch provider {
        case .lrclib: url = lrclibURL(query: query, title: title, artist: artist)
        case .lyricsOvh: url = lyricsOvhURL(artist: artist, title: title.trimmed.isEmpty ? query : title)
        }
        guard let url else {
            completion(.failure(PresentationKitError.badFormat(provider == .lyricsOvh ? "enter the artist and the song title" : "type something to search")))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(PresentationKitError.network(err.localizedDescription))); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, status != 404 else { completion(.success([])); return }
            guard status < 400 else { completion(.failure(PresentationKitError.network("server returned \(status)"))); return }
            switch provider {
            case .lrclib: completion(.success(parseLRCLIB(data)))
            case .lyricsOvh:
                let t = title.trimmed.isEmpty ? query : title
                completion(.success(parseLyricsOvh(data, artist: artist, title: t).map { [$0] } ?? []))
            }
        }.resume()
    }
}
