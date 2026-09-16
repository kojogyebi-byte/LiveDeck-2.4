import Foundation

/// A passage: one book, from chapter:verse to chapter:verse (verse 0 = whole chapter end).
public struct ScriptureReference: Hashable, Codable, Sendable {
    public var book: Int
    public var startChapter: Int
    public var startVerse: Int        // 0 = from the start of the chapter
    public var endChapter: Int
    public var endVerse: Int          // 0 = to the end of endChapter

    public init(book: Int, startChapter: Int, startVerse: Int = 0, endChapter: Int? = nil, endVerse: Int = 0) {
        self.book = book; self.startChapter = startChapter; self.startVerse = startVerse
        self.endChapter = endChapter ?? startChapter; self.endVerse = endVerse
    }

    public var bookInfo: BibleBookInfo? { BibleBookInfo.byNumber(book) }

    /// "John 3:16", "John 3:16-18", "Psalms 23", "Genesis 1:1–2:3"
    public func display(bookName: String? = nil) -> String {
        let name = bookName ?? bookInfo?.name ?? "Book \(book)"
        var s = "\(name) \(startChapter)"
        if startVerse > 0 { s += ":\(startVerse)" }
        if endChapter != startChapter {
            s += "–\(endChapter)" + (endVerse > 0 ? ":\(endVerse)" : "")
        } else if endVerse > 0 && endVerse != startVerse {
            s += "–\(endVerse)"
        }
        return s
    }
}

public enum ScriptureReferenceParser {
    /// Parses references such as "John 3:16", "jn 3 16", "1 Cor 13:4-7", "1Co13", "Ps 23",
    /// "Song of Solomon 2:1-4", "Gen 1:1-2:3", "Rom 8:28–39". Optional extra names
    /// (e.g. a translation's own book names) are matched too.
    public static func parse(_ input: String, extraNames: [Int: [String]] = [:]) -> ScriptureReference? {
        var s = input.trimmed
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: ".", with: " ")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !s.isEmpty else { return nil }

        // Split into book part and numeric part: the numeric part is the trailing run of digits : - , space
        // but a leading ordinal ("1 John") belongs to the book.
        let chars = Array(s)
        var idx = chars.count
        while idx > 0, "0123456789:- ,".contains(chars[idx - 1]) { idx -= 1 }
        var bookPart = String(chars[0..<idx]).trimmed
        var numPart = String(chars[idx...]).trimmed
        if bookPart.isEmpty {
            // Whole string numeric-ish, e.g. "1 John" was eaten: "1" followed by name is impossible here → try splitting first token
            return nil
        }
        // "1Co13" → book "1Co", nums "13" handled; "John3:16" → idx stops at "n" ✓
        // If the book part ends with an ordinal only (e.g. input "2"), fail.
        if bookPart.allSatisfy({ $0.isNumber || $0 == " " }) { return nil }
        numPart = numPart.replacingOccurrences(of: " ", with: ":")
        while numPart.contains("::") { numPart = numPart.replacingOccurrences(of: "::", with: ":") }
        if numPart.hasPrefix(":") { numPart.removeFirst() }
        numPart = numPart.replacingOccurrences(of: ":-", with: "-").replacingOccurrences(of: "-:", with: "-")

        guard let book = matchBook(bookPart, extraNames: extraNames) else { return nil }
        bookPart = ""
        let info = BibleBookInfo.byNumber(book)

        // Single-chapter books: "Jude 3" means verse 3.
        if info?.chapters == 1, !numPart.contains(":") {
            let r = numPart.split(separator: "-").compactMap { Int($0) }
            guard let a = r.first else { return ScriptureReference(book: book, startChapter: 1) }
            return ScriptureReference(book: book, startChapter: 1, startVerse: a, endVerse: r.count > 1 ? r[1] : a)
        }

        if numPart.isEmpty { return ScriptureReference(book: book, startChapter: 1) }
        let halves = numPart.split(separator: "-", maxSplits: 1).map(String.init)
        let start = halves[0].split(separator: ":").compactMap { Int($0) }
        guard let sc = start.first, sc > 0 else { return nil }
        let sv = start.count > 1 ? start[1] : 0
        var ec = sc, ev = sv
        if halves.count > 1 {
            let end = halves[1].split(separator: ":").compactMap { Int($0) }
            if end.count >= 2 { ec = end[0]; ev = end[1] }
            else if let e = end.first { if sv > 0 { ev = e } else { ec = e; ev = 0 } }
        }
        if ec < sc || (ec == sc && ev > 0 && ev < sv) { return nil }
        return ScriptureReference(book: book, startChapter: sc, startVerse: sv, endChapter: ec, endVerse: ev)
    }

    static func normalise(_ s: String) -> String {
        s.searchFolded.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "first", with: "1").replacingOccurrences(of: "second", with: "2")
            .replacingOccurrences(of: "third", with: "3")
            .replacingOccurrences(of: "^iii", with: "3", options: .regularExpression)
            .replacingOccurrences(of: "^ii", with: "2", options: .regularExpression)
            .replacingOccurrences(of: "^i(?=[a-z])", with: "1", options: .regularExpression)
    }

    public static func matchBook(_ raw: String, extraNames: [Int: [String]] = [:]) -> Int? {
        let key = normalise(raw)
        guard !key.isEmpty else { return nil }
        var candidates: [(Int, String)] = []
        for b in BibleBookInfo.all {
            candidates.append((b.number, normalise(b.name)))
            candidates.append((b.number, normalise(b.code)))
            for a in b.aliases { candidates.append((b.number, normalise(a))) }
        }
        for (n, names) in extraNames { for nm in names { candidates.append((n, normalise(nm))) } }
        if let exact = candidates.first(where: { $0.1 == key }) { return exact.0 }
        // unique prefix match ("phili" → Philippians, "phile" → Philemon)
        let pref = Set(candidates.filter { $0.1.hasPrefix(key) }.map { $0.0 })
        if pref.count == 1 { return pref.first }
        if pref.count > 1, key.count >= 2 {
            // prefer the book whose canonical name starts with the key and is shortest
            return pref.min { a, b in (BibleBookInfo.byNumber(a)?.name.count ?? 99) < (BibleBookInfo.byNumber(b)?.name.count ?? 99) }
        }
        return nil
    }
}
