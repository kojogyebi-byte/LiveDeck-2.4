import Foundation

/// Metadata of an installed Bible version (one SQLite file per version).
public struct BibleVersionInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String            // unique, filename-safe (e.g. "BSB", "eng_kjv", "user-NKJV")
    public var name: String
    public var abbreviation: String
    public var language: String       // ISO 639 code or name
    public var languageName: String
    public var license: String        // licence text or URL
    public var source: String         // "Free Use Bible API", "Zefania XML file", …
    public var rightToLeft: Bool
    public var verseCount: Int
    public var installed: Date

    public init(id: String, name: String, abbreviation: String, language: String = "", languageName: String = "",
                license: String = "", source: String = "", rightToLeft: Bool = false, verseCount: Int = 0, installed: Date = Date()) {
        self.id = id; self.name = name; self.abbreviation = abbreviation; self.language = language
        self.languageName = languageName; self.license = license; self.source = source; self.rightToLeft = rightToLeft
        self.verseCount = verseCount; self.installed = installed
    }
}

public struct BibleVerse: Hashable, Sendable {
    public var book: Int, chapter: Int, verse: Int
    public var text: String
}

public struct BibleBookEntry: Hashable, Sendable {
    public var number: Int
    public var name: String
    public var chapters: Int
}

/// Read/query one installed Bible. File format: SQLite ("*.ldbible"), schema below.
public final class BibleStore {
    public let info: BibleVersionInfo
    private let db: SQLiteDB
    public private(set) var hasFTS = false
    private lazy var bookNameCache: [Int: String] = loadBookNames()

    public init(url: URL) throws {
        db = try SQLiteDB(path: url.path, readOnly: true)
        var meta: [String: String] = [:]
        try db.query("SELECT key, value FROM meta") { meta[$0.text(0)] = $0.text(1) }
        info = BibleVersionInfo(
            id: meta["id"] ?? url.deletingPathExtension().lastPathComponent,
            name: meta["name"] ?? "Bible", abbreviation: meta["abbreviation"] ?? "",
            language: meta["language"] ?? "", languageName: meta["languageName"] ?? "",
            license: meta["license"] ?? "", source: meta["source"] ?? "",
            rightToLeft: meta["rtl"] == "1", verseCount: Int(meta["verseCount"] ?? "") ?? 0,
            installed: ISO8601DateFormatter().date(from: meta["installed"] ?? "") ?? Date())
        try? db.query("SELECT name FROM sqlite_master WHERE name = 'verses_fts'") { _ in self.hasFTS = true }
    }

    public var books: [BibleBookEntry] {
        var out: [BibleBookEntry] = []
        try? db.query("SELECT number, name, chapters FROM books ORDER BY number") {
            out.append(BibleBookEntry(number: $0.int(0), name: $0.text(1), chapters: $0.int(2)))
        }
        return out
    }

    private func loadBookNames() -> [Int: String] {
        var m: [Int: String] = [:]
        for b in books { m[b.number] = b.name }
        return m
    }

    public func bookName(_ n: Int) -> String { bookNameCache[n] ?? BibleBookInfo.byNumber(n)?.name ?? "Book \(n)" }

    /// The translation's own book names, for reference parsing in any language.
    public var bookNameMap: [Int: [String]] { bookNameCache.mapValues { [$0] } }

    public func verseCount(book: Int, chapter: Int) -> Int {
        var n = 0
        try? db.query("SELECT MAX(verse) FROM verses WHERE book = ? AND chapter = ?", [.int(book), .int(chapter)]) { n = $0.int(0) }
        return n
    }

    public func verses(_ ref: ScriptureReference) -> [BibleVerse] {
        var out: [BibleVerse] = []
        let lo = ref.startChapter * 1000 + max(0, ref.startVerse)
        let hi = ref.endChapter * 1000 + (ref.endVerse > 0 ? ref.endVerse : 999)
        let sql = """
            SELECT book, chapter, verse, text FROM verses
            WHERE book = ? AND chapter * 1000 + verse BETWEEN ? AND ?
            ORDER BY chapter, verse
            """
        try? db.query(sql, [.int(ref.book), .int(lo), .int(hi)]) {
            out.append(BibleVerse(book: $0.int(0), chapter: $0.int(1), verse: $0.int(2), text: $0.text(3)))
        }
        return out
    }

    /// Full-text search (FTS5 when available, LIKE otherwise). Returns at most `limit` verses.
    public func search(_ query: String, limit: Int = 100) -> [BibleVerse] {
        let q = query.trimmed
        guard q.count >= 2 else { return [] }
        var out: [BibleVerse] = []
        if hasFTS {
            let terms = q.split(separator: " ").map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"" }.joined(separator: " ")
            let sql = """
                SELECT v.book, v.chapter, v.verse, v.text FROM verses_fts f JOIN verses v ON v.rowid = f.rowid
                WHERE verses_fts MATCH ? ORDER BY v.book, v.chapter, v.verse LIMIT ?
                """
            try? db.query(sql, [.text(terms), .int(limit)]) {
                out.append(BibleVerse(book: $0.int(0), chapter: $0.int(1), verse: $0.int(2), text: $0.text(3)))
            }
            if !out.isEmpty { return out }
        }
        try? db.query("SELECT book, chapter, verse, text FROM verses WHERE text LIKE ? ORDER BY book, chapter, verse LIMIT ?",
                      [.text("%" + q + "%"), .int(limit)]) {
            out.append(BibleVerse(book: $0.int(0), chapter: $0.int(1), verse: $0.int(2), text: $0.text(3)))
        }
        return out
    }

    public func parseReference(_ text: String) -> ScriptureReference? {
        ScriptureReferenceParser.parse(text, extraNames: bookNameMap)
    }

    // MARK: Slides

    /// Splits a passage into slides: at most `maxChars` characters per slide, never splitting
    /// mid-word; long verses break at sentence / clause boundaries.
    public static func slideTexts(_ verses: [BibleVerse], maxChars: Int = 280, verseNumbers: Bool = true)
        -> [(text: String, first: BibleVerse, last: BibleVerse)] {
        var out: [(String, BibleVerse, BibleVerse)] = []
        var buf = ""
        var first: BibleVerse?
        var last: BibleVerse?
        func flush() {
            if let f = first, let l = last, !buf.trimmed.isEmpty { out.append((buf.trimmed, f, l)) }
            buf = ""; first = nil; last = nil
        }
        for v in verses {
            let prefix = verseNumbers ? superscript(v.verse) + " " : ""
            let piece = prefix + v.text.trimmed
            if !buf.isEmpty && buf.count + 1 + piece.count > maxChars { flush() }
            if piece.count > maxChars {
                for part in splitLong(piece, maxChars: maxChars) {
                    if !buf.isEmpty { flush() }
                    buf = part; first = v; last = v
                    flush()
                }
                continue
            }
            if first == nil { first = v }
            last = v
            buf += (buf.isEmpty ? "" : " ") + piece
        }
        flush()
        return out
    }

    static func splitLong(_ s: String, maxChars: Int) -> [String] {
        var parts: [String] = []
        var rest = Substring(s)
        while rest.count > maxChars {
            let window = rest.prefix(maxChars)
            let breakers: [Character] = [".", ";", ":", "!", "?", ","]
            var cut = window.lastIndex { breakers.contains($0) }.map { window.index(after: $0) }
            if cut == nil || window.distance(from: window.startIndex, to: cut ?? window.startIndex) < maxChars / 3 {
                cut = window.lastIndex(of: " ") ?? window.endIndex
            }
            let end = cut ?? window.endIndex
            parts.append(String(rest[rest.startIndex..<end]).trimmed)
            rest = rest[end...].drop { $0 == " " }
        }
        if !rest.isEmpty { parts.append(String(rest).trimmed) }
        return parts
    }

    public static func superscript(_ n: Int) -> String {
        let map: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]
        return String(String(n).compactMap { map[$0] })
    }

    public func slides(_ ref: ScriptureReference, theme: Theme, maxChars: Int = 280, verseNumbers: Bool = true) -> [Slide] {
        let v = verses(ref)
        return BibleStore.slideTexts(v, maxChars: maxChars, verseNumbers: verseNumbers).map { part in
            let r = ScriptureReference(book: part.first.book, startChapter: part.first.chapter, startVerse: part.first.verse,
                                       endChapter: part.last.chapter, endVerse: part.last.verse)
            let label = r.display(bookName: bookName(part.first.book)) + (info.abbreviation.isEmpty ? "" : " (\(info.abbreviation))")
            return Slide(label: label, elements: [
                .textBox(part.text, role: .scriptureText, style: theme.body, in: theme.bodyFrame),
                .textBox(label, role: .scriptureReference, style: theme.reference, in: theme.referenceFrame)
            ])
        }
    }
}

// MARK: - Writing a Bible file

/// Builds a `.ldbible` SQLite file from any importer. Writes to a temp file, then moves into place.
public final class BibleWriter {
    private let db: SQLiteDB
    private let tempURL: URL
    private let finalURL: URL
    private var info: BibleVersionInfo
    private var count = 0
    private var insert: SQLiteDB.Statement?
    private var bookNames: [Int: String] = [:]
    private var bookChapters: [Int: Int] = [:]

    public init(info: BibleVersionInfo, destination: URL) throws {
        self.info = info
        finalURL = destination
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        tempURL = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        db = try SQLiteDB(path: tempURL.path)
        try db.exec("""
            PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE books (number INTEGER PRIMARY KEY, code TEXT, name TEXT, chapters INTEGER);
            CREATE TABLE verses (book INTEGER, chapter INTEGER, verse INTEGER, text TEXT, PRIMARY KEY (book, chapter, verse));
            BEGIN;
            """)
        insert = try db.prepare("INSERT OR REPLACE INTO verses (book, chapter, verse, text) VALUES (?, ?, ?, ?)")
    }

    public func setBookName(_ book: Int, _ name: String) { if !name.trimmed.isEmpty { bookNames[book] = name.trimmed } }

    public func add(book: Int, chapter: Int, verse: Int, text: String) {
        let t = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed
        guard (1...66).contains(book), chapter > 0, verse > 0, !t.isEmpty else { return }
        insert?.bind([.int(book), .int(chapter), .int(verse), .text(t)])
        if insert?.run() == true { count += 1 }
        bookChapters[book] = max(bookChapters[book] ?? 0, chapter)
    }

    public var verseCount: Int { count }

    @discardableResult
    public func finish() throws -> BibleVersionInfo {
        guard count > 0 else {
            insert = nil; db.close(); try? FileManager.default.removeItem(at: tempURL)
            throw PresentationKitError.badFormat("no verses were found")
        }
        for (book, chapters) in bookChapters {
            let code = BibleBookInfo.byNumber(book)?.code ?? ""
            let name = bookNames[book] ?? BibleBookInfo.byNumber(book)?.name ?? "Book \(book)"
            try db.run("INSERT OR REPLACE INTO books (number, code, name, chapters) VALUES (?, ?, ?, ?)",
                       [.int(book), .text(code), .text(name), .int(chapters)])
        }
        info.verseCount = count
        info.installed = Date()
        let meta: [String: String] = [
            "id": info.id, "name": info.name, "abbreviation": info.abbreviation, "language": info.language,
            "languageName": info.languageName, "license": info.license, "source": info.source,
            "rtl": info.rightToLeft ? "1" : "0", "verseCount": String(count),
            "installed": ISO8601DateFormatter().string(from: info.installed), "format": "ldbible-1"
        ]
        for (k, v) in meta { try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(k), .text(v)]) }
        try db.exec("COMMIT")
        // Full-text index (FTS5 if this SQLite build has it; search falls back to LIKE otherwise).
        if (try? db.exec("CREATE VIRTUAL TABLE verses_fts USING fts5(text, content='verses', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2')")) != nil {
            try? db.exec("INSERT INTO verses_fts(verses_fts) VALUES('rebuild')")
        }
        try? db.exec("VACUUM")
        insert = nil
        db.close()
        let fm = FileManager.default
        if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
        try fm.moveItem(at: tempURL, to: finalURL)
        return info
    }

    public func cancel() {
        insert = nil
        db.close()
        try? FileManager.default.removeItem(at: tempURL)
    }
}
