import Foundation

// MARK: - Bible search assistant: reference autocomplete, phrase completion, live search helpers

public struct BibleSuggestion: Hashable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case reference, book, popular, phrase }
    public var id: String { kind.rawValue + ":" + text }
    public var text: String        // what goes into the search box (or the reference to open)
    public var title: String
    public var detail: String
    public var kind: Kind
    public init(text: String, title: String, detail: String, kind: Kind) {
        self.text = text; self.title = title; self.detail = detail; self.kind = kind
    }
}

public enum BibleAssist {
    /// Well-known passages offered while typing a book or a theme word.
    public static let popular: [(ref: String, theme: String)] = [
        ("John 3:16", "God so loved the world love salvation"),
        ("Psalm 23", "The Lord is my shepherd comfort"),
        ("Jeremiah 29:11", "plans to prosper hope future"),
        ("Romans 8:28", "all things work together good"),
        ("Philippians 4:13", "I can do all things strength"),
        ("Proverbs 3:5-6", "trust in the Lord with all your heart guidance"),
        ("Isaiah 40:31", "wait upon the Lord wings as eagles strength"),
        ("Joshua 1:9", "be strong and courageous fear"),
        ("Matthew 28:19-20", "great commission go make disciples"),
        ("Mark 16:15", "preach the gospel to every creature evangelism"),
        ("Acts 1:8", "power witnesses Holy Spirit"),
        ("Romans 12:1-2", "living sacrifice renew your mind worship"),
        ("1 Corinthians 13:4-7", "love is patient love is kind"),
        ("Galatians 5:22-23", "fruit of the Spirit"),
        ("Ephesians 2:8-9", "saved by grace through faith"),
        ("Ephesians 6:10-18", "armour of God spiritual warfare"),
        ("Hebrews 11:1", "faith is the substance of things hoped for"),
        ("2 Timothy 3:16-17", "all scripture is inspired word"),
        ("Psalm 91", "dwells in the secret place protection"),
        ("Matthew 6:33", "seek first the kingdom"),
        ("John 14:6", "the way the truth and the life"),
        ("Psalm 46:10", "be still and know that I am God"),
        ("Isaiah 53:5", "wounded for our transgressions healing"),
        ("James 5:14-16", "prayer of faith heal the sick healing"),
        ("Malachi 3:10", "tithes storehouse giving"),
        ("2 Corinthians 5:17", "new creation old things passed away"),
        ("1 John 1:9", "confess our sins forgiveness"),
        ("Philippians 4:6-7", "do not be anxious prayer peace"),
        ("Lamentations 3:22-23", "his mercies are new every morning faithfulness"),
        ("Micah 6:8", "do justly love mercy walk humbly")
    ]

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func romanToArabic(_ s: String) -> String {
        var t = s
        for (r, a) in [("iii ", "3 "), ("ii ", "2 "), ("i ", "1 ")] where t.hasPrefix(r) { t = a + t.dropFirst(r.count); break }
        return t
    }

    /// Splits "1 jo 3:16" into ("1 jo", "3:16").
    static func split(_ text: String) -> (book: String, numbers: String) {
        let s = romanToArabic(fold(text))
        let chars = Array(s)
        var i = chars.count
        while i > 0, "0123456789:-, ".contains(chars[i - 1]) { i -= 1 }
        var book = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
        var nums = String(chars[i...]).trimmingCharacters(in: .whitespaces)
        if book.isEmpty, let first = nums.first, "123".contains(first) {
            // only an ordinal typed so far ("1 ")
            book = String(first); nums = ""
        }
        // "1jo" → "1 jo"
        if let f = book.first, "123".contains(f), book.count > 1, book[book.index(after: book.startIndex)] != " " {
            book = String(f) + " " + book.dropFirst()
        }
        return (book, nums)
    }

    static func matches(_ info: BibleBookInfo, _ fragment: String, extra: [String]) -> Int? {
        let names = [info.name] + info.aliases + extra
        for (rank, n) in names.enumerated() {
            let f = fold(n)
            let compact = f.replacingOccurrences(of: " ", with: "")
            let fragCompact = fragment.replacingOccurrences(of: " ", with: "")
            if f.hasPrefix(fragment) || compact.hasPrefix(fragCompact) { return rank == 0 ? 0 : 1 }
        }
        // "psalms" vs "psalm", "song of songs" by word start
        if fold(info.name).split(separator: " ").contains(where: { $0.hasPrefix(fragment) }) && fragment.count >= 3 { return 2 }
        return nil
    }

    /// True when the text is probably a reference rather than words to search.
    public static func looksLikeReference(_ text: String, extraNames: [Int: [String]] = [:]) -> Bool {
        let (book, nums) = split(text)
        guard !book.isEmpty else { return false }
        let hasBook = BibleBookInfo.all.contains { matches($0, book, extra: extraNames[$0.number] ?? []) != nil }
        return hasBook && (!nums.isEmpty || book.split(separator: " ").count <= 3)
    }

    /// Book and reference completions for what is typed so far.
    public static func referenceSuggestions(_ text: String, extraNames: [Int: [String]] = [:], limit: Int = 6) -> [BibleSuggestion] {
        let (book, nums) = split(text)
        guard !book.isEmpty, !(book.count == 1 && "123".contains(book)) || nums.isEmpty else { return [] }
        let ranked = BibleBookInfo.all.compactMap { b -> (BibleBookInfo, Int)? in
            matches(b, book, extra: extraNames[b.number] ?? []).map { (b, $0) }
        }
        .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.number < $1.0.number }
        guard !ranked.isEmpty else { return [] }
        var out: [BibleSuggestion] = []
        if !nums.isEmpty, let best = ranked.first?.0 {
            let clean = nums.replacingOccurrences(of: " ", with: "")
            let chapter = Int(clean.split(separator: ":").first ?? "") ?? 0
            if chapter >= 1 && chapter <= best.chapters {
                out.append(BibleSuggestion(text: "\(best.name) \(clean)", title: "\(best.name) \(clean)", detail: "Open this passage", kind: .reference))
            } else {
                out.append(BibleSuggestion(text: "\(best.name) ", title: best.name, detail: "Chapters 1–\(best.chapters)", kind: .book))
            }
            for p in popular where popularIn(p.ref, best, chapter: chapter) && !out.contains(where: { $0.text == p.ref }) {
                out.append(BibleSuggestion(text: p.ref, title: p.ref, detail: p.theme.capitalizedFirst, kind: .popular))
            }
        } else {
            for (b, _) in ranked.prefix(limit) {
                out.append(BibleSuggestion(text: "\(b.name) ", title: b.name, detail: b.chapters == 1 ? "1 chapter" : "\(b.chapters) chapters", kind: .book))
            }
            if let best = ranked.first?.0 {
                for p in popular where popularIn(p.ref, best, chapter: nil) { out.append(BibleSuggestion(text: p.ref, title: p.ref, detail: p.theme.capitalizedFirst, kind: .popular)) }
            }
        }
        return Array(out.prefix(limit + 2))
    }

    static func popularIn(_ ref: String, _ book: BibleBookInfo, chapter: Int?) -> Bool {
        let (b, nums) = split(ref)
        guard matches(book, b, extra: []) != nil, BibleBookInfo.all.first(where: { matches($0, b, extra: []) != nil })?.number == book.number else { return false }
        guard let chapter else { return true }
        return Int(nums.split(separator: ":").first ?? "") == chapter
    }

    /// Famous passages whose theme matches the typed words ("love", "healing", "fear").
    public static func themeSuggestions(_ text: String, limit: Int = 4) -> [BibleSuggestion] {
        let words = fold(text).split(separator: " ").map(String.init).filter { $0.count >= 3 }
        guard !words.isEmpty else { return [] }
        return popular.filter { p in
            let hay = fold(p.theme + " " + p.ref)
            return words.allSatisfy { hay.contains($0) }
        }
        .prefix(limit)
        .map { BibleSuggestion(text: $0.ref, title: $0.ref, detail: $0.theme.capitalizedFirst, kind: .popular) }
    }

    /// FTS5 query: every word must appear, the last one may be unfinished ("grace fai" → "grace" "fai"*).
    /// Text in quotes is searched as an exact phrase.
    public static func ftsQuery(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.count >= 3, t.hasPrefix("\""), t.hasSuffix("\"") {
            let inner = t.dropFirst().dropLast().replacingOccurrences(of: "\"", with: "")
            return inner.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "\"" + inner + "\""
        }
        let words = t.replacingOccurrences(of: "\"", with: "").split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" })
            .map { String($0).filter { $0.isLetter || $0.isNumber || $0 == "'" } }.filter { !$0.isEmpty }
        guard let last = words.last else { return nil }
        let head = words.dropLast().map { "\"\($0)\"" }
        let tail = last.count >= 2 ? "\"\(last)\"*" : "\"\(last)\""
        return (head + [tail]).joined(separator: " ")
    }

    /// Completes the phrase being typed from the verses found so far ("the lord is my" → "the lord is my shepherd").
    public static func phraseCompletions(query: String, in verses: [BibleVerse], limit: Int = 5) -> [BibleSuggestion] {
        let q = fold(query).replacingOccurrences(of: "\"", with: "").split(separator: " ").map(String.init)
        guard !q.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for v in verses {
            let words = fold(v.text).split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
            guard words.count >= q.count else { continue }
            var i = 0
            while i + q.count <= words.count {
                var ok = true
                for k in 0..<q.count {
                    let w = words[i + k]
                    if k == q.count - 1 ? !w.hasPrefix(q[k]) : w != q[k] { ok = false; break }
                }
                if ok {
                    let end = min(words.count, i + q.count + 2)
                    let phrase = words[i..<end].joined(separator: " ")
                    if phrase.count > fold(query).count { counts[phrase, default: 0] += 1 }
                    break
                }
                i += 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { BibleSuggestion(text: $0.key, title: $0.key, detail: $0.value == 1 ? "1 verse" : "\($0.value) verses", kind: .phrase) }
    }

    /// How many results fall in each book (for filter chips), in canonical order.
    public static func bookCounts(_ verses: [BibleVerse]) -> [(book: Int, count: Int)] {
        var c: [Int: Int] = [:]
        for v in verses { c[v.book, default: 0] += 1 }
        return c.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Words of the query (for highlighting).
    public static func highlightTerms(_ query: String) -> [String] {
        fold(query).replacingOccurrences(of: "\"", with: "").split(separator: " ").map(String.init).filter { $0.count >= 2 }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
