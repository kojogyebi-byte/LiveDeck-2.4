import Foundation

// MARK: - Offline English dictionary (Princeton WordNet + CMU pronunciations)
//
// Built into one SQLite file (.lddict):
//   words(word PRIMARY KEY lowercased, display, phonetic, data JSON {"s":[[pos,definition,example]], "y":[synonyms], "a":[antonyms]})
//   exceptions(form, base)   — irregular forms (went → go, mice → mouse)
//   meta(key, value)

public enum ARPAbet {
    static let phones: [String: String] = [
        "AA": "ɑ", "AE": "æ", "AH": "ʌ", "AO": "ɔ", "AW": "aʊ", "AY": "aɪ", "B": "b", "CH": "tʃ", "D": "d", "DH": "ð",
        "EH": "ɛ", "ER": "ɝ", "EY": "eɪ", "F": "f", "G": "ɡ", "HH": "h", "IH": "ɪ", "IY": "i", "JH": "dʒ", "K": "k",
        "L": "l", "M": "m", "N": "n", "NG": "ŋ", "OW": "oʊ", "OY": "ɔɪ", "P": "p", "R": "r", "S": "s", "SH": "ʃ",
        "T": "t", "TH": "θ", "UH": "ʊ", "UW": "u", "V": "v", "W": "w", "Y": "j", "Z": "z", "ZH": "ʒ"
    ]

    static let onsets: Set<String> = ["PR", "BR", "TR", "DR", "KR", "GR", "FR", "THR", "PL", "BL", "KL", "GL", "FL", "SL",
                                      "SP", "ST", "SK", "SM", "SN", "SW", "TW", "KW", "SHR", "DW", "PY", "BY", "KY", "FY", "MY", "HHY"]

    /// "D AO1 G" → "/ˈdɔɡ/" (stress mark placed before the stressed syllable's onset)
    public static func ipa(_ arpabet: String) -> String {
        struct Phone { var base: String; var stress: Character?; var vowel: Bool }
        let list: [Phone] = arpabet.split(separator: " ").compactMap { token in
            var t = String(token)
            var stress: Character?
            if let last = t.last, last.isNumber { stress = last; t.removeLast() }
            guard phones[t] != nil else { return nil }
            return Phone(base: t, stress: stress, vowel: stress != nil)
        }
        var marks: [Int: String] = [:]
        for (i, p) in list.enumerated() where p.stress == "1" || p.stress == "2" {
            var start = i
            while start > 0 && !list[start - 1].vowel { start -= 1 }
            if start > 0 {                                           // not word-initial: keep a legal onset only
                let cluster = list[start..<i].map { $0.base }
                if cluster.count >= 3, onsets.contains(cluster.suffix(3).joined()) { start = i - 3 }
                else if cluster.count >= 2, onsets.contains(cluster.suffix(2).joined()) { start = i - 2 }
                else if !cluster.isEmpty { start = i - 1 }
            }
            marks[start] = p.stress == "1" ? "ˈ" : "ˌ"
        }
        var out = ""
        for (i, p) in list.enumerated() {
            if let m = marks[i] { out += m }
            if p.base == "AH" && p.stress == "0" { out += "ə" }
            else if p.base == "ER" && p.stress == "0" { out += "ɚ" }
            else { out += phones[p.base] ?? "" }
        }
        return out.isEmpty ? "" : "/" + out + "/"
    }

    /// Parses the npm cmu-pronouncing-dictionary module (`  "word": "W ER1 D",` lines).
    public static func parseCMUJavaScript(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\""), let colon = t.range(of: "\": \"") else { continue }
            let word = String(t[t.index(after: t.startIndex)..<colon.lowerBound]).lowercased()
            var value = String(t[colon.upperBound...])
            if value.hasSuffix(",") { value.removeLast() }
            if value.hasSuffix("\"") { value.removeLast() }
            if !word.contains("\\"), out[word] == nil { out[word] = value }
        }
        return out
    }

    /// Parses the CMU dictionary text format ("WORD  W ER1 D" or "word(2) …"), keeping the first pronunciation.
    public static func parseCMU(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix(";;;") { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let word = parts[0].lowercased()
            if word.contains("(") { continue }
            if out[word] == nil { out[word] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }
}

public enum WordNetParser {
    public static let partOfSpeech: [Character: String] = ["n": "noun", "v": "verb", "a": "adjective", "s": "adjective", "r": "adverb"]

    public struct Synset: Sendable {
        public var offset: Int
        public var pos: Character
        public var words: [String]
        public var definition: String
        public var examples: [String]
        /// antonym pointers: (source word index 1-based or 0, target synset offset, target pos, target word index)
        public var antonyms: [(source: Int, offset: Int, pos: Character, target: Int)]
    }

    static func cleanLemma(_ raw: Substring) -> String {
        var s = String(raw)
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }        // adjective markers: (a) (p) (ip)
        return s.replacingOccurrences(of: "_", with: " ")
    }

    /// One line of data.noun / data.verb / data.adj / data.adv.
    public static func parseDataLine(_ line: Substring) -> Synset? {
        guard let first = line.first, first.isNumber else { return nil }       // skip licence header
        let halves = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let fields = halves[0].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4, let offset = Int(fields[0]), let pos = fields[2].first,
              let wordCount = Int(fields[3], radix: 16) else { return nil }
        var i = 4
        var words: [String] = []
        for _ in 0..<wordCount {
            guard i + 1 < fields.count else { return nil }
            words.append(cleanLemma(fields[i]))
            i += 2
        }
        var antonyms: [(Int, Int, Character, Int)] = []
        if i < fields.count, let pointerCount = Int(fields[i]) {
            i += 1
            for _ in 0..<pointerCount {
                guard i + 3 < fields.count else { break }
                let symbol = fields[i], targetOffset = Int(fields[i + 1]) ?? 0, targetPos = fields[i + 2].first ?? "n", idx = fields[i + 3]
                if symbol == "!", idx.count == 4 {
                    let src = Int(idx.prefix(2), radix: 16) ?? 0, dst = Int(idx.suffix(2), radix: 16) ?? 0
                    antonyms.append((src, targetOffset, targetPos, dst))
                }
                i += 4
            }
        }
        let gloss = halves.count > 1 ? halves[1].trimmingCharacters(in: .whitespaces) : ""
        let (definition, examples) = splitGloss(gloss)
        return Synset(offset: offset, pos: pos, words: words, definition: definition, examples: examples, antonyms: antonyms)
    }

    /// "a member of the genus Canis; "the dog barked all night"" → ("a member of the genus Canis", ["the dog barked all night"])
    public static func splitGloss(_ gloss: String) -> (String, [String]) {
        var definitionParts: [String] = []
        var examples: [String] = []
        for part in gloss.components(separatedBy: "; ") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\"") {
                let e = t.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                if !e.isEmpty { examples.append(e) }
            } else if examples.isEmpty, !t.isEmpty {
                definitionParts.append(t)
            }
        }
        return (definitionParts.joined(separator: "; "), examples)
    }

    /// One line of index.noun etc.: lemma → synset offsets in frequency order.
    public static func parseIndexLine(_ line: Substring) -> (lemma: String, pos: Character, offsets: [Int])? {
        guard let first = line.first, first != " " else { return nil }
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 6, let pos = f[1].first, let synsetCount = Int(f[2]), let pointerCount = Int(f[3]) else { return nil }
        let start = 4 + pointerCount + 2
        guard start + synsetCount <= f.count else { return nil }
        return (cleanLemma(f[0]), pos, f[start..<(start + synsetCount)].compactMap { Int($0) })
    }

    /// WordNet "morphy": candidate base forms for an inflected word.
    public static func baseForms(_ word: String) -> [String] {
        let w = word.lowercased()
        let rules: [(String, String)] = [
            ("ies", "y"), ("ses", "s"), ("xes", "x"), ("zes", "z"), ("ches", "ch"), ("shes", "sh"), ("men", "man"),
            ("es", "e"), ("es", ""), ("s", ""), ("ed", "e"), ("ed", ""), ("ing", "e"), ("ing", ""),
            ("est", "e"), ("est", ""), ("er", "e"), ("er", "")
        ]
        var out: [String] = []
        for (suffix, replacement) in rules where w.hasSuffix(suffix) && w.count > suffix.count + 1 {
            let base = String(w.dropLast(suffix.count)) + replacement
            if !out.contains(base) { out.append(base) }
        }
        // doubled consonant: running → run, stopped → stop
        for suffix in ["ing", "ed", "er", "est"] where w.hasSuffix(suffix) {
            let stem = w.dropLast(suffix.count)
            if stem.count >= 3, let last = stem.last, stem.dropLast().last == last, !"aeiou".contains(last) {
                let base = String(stem.dropLast())
                if !out.contains(base) { out.append(base) }
            }
        }
        return out
    }
}

public enum OfflineDictionaryBuilder {
    public struct Result: Sendable { public var words: Int; public var senses: Int }

    /// Builds the offline dictionary from a WordNet `dict` folder (data.* and index.*), optional *.exc files and pronunciations.
    @discardableResult
    public static func build(wordNetDict: URL, exceptionsDir: URL?, pronunciations: [String: String], output: URL,
                             progress: ((String) -> Void)? = nil) throws -> Result {
        let posFiles: [(String, Character)] = [("noun", "n"), ("verb", "v"), ("adj", "a"), ("adv", "r")]
        var synsets: [String: WordNetParser.Synset] = [:]      // "pos:offset"
        func key(_ pos: Character, _ offset: Int) -> String { "\(pos == "s" ? "a" : pos):\(offset)" }

        for (name, _) in posFiles {
            progress?("Reading \(name) meanings…")
            let text = try String(contentsOf: wordNetDict.appendingPathComponent("data.\(name)"), encoding: .utf8)
            for line in text.split(separator: "\n") {
                if let s = WordNetParser.parseDataLine(line) { synsets[key(s.pos, s.offset)] = s }
            }
        }

        struct Entry { var display: String; var senses: [[String]] = []; var synonyms: [String] = []; var antonyms: [String] = [] }
        var entries: [String: Entry] = [:]
        var order: [String] = []
        for (name, pos) in posFiles {
            progress?("Indexing \(name) words…")
            let text = try String(contentsOf: wordNetDict.appendingPathComponent("index.\(name)"), encoding: .utf8)
            for line in text.split(separator: "\n") {
                guard let idx = WordNetParser.parseIndexLine(line) else { continue }
                let lemmaKey = idx.lemma.lowercased()
                var e = entries[lemmaKey] ?? Entry(display: idx.lemma)
                if entries[lemmaKey] == nil { order.append(lemmaKey) }
                for off in idx.offsets {
                    guard let s = synsets[key(pos, off)] else { continue }
                    let posName = WordNetParser.partOfSpeech[s.pos] ?? ""
                    if e.senses.count < 24 { e.senses.append([posName, s.definition, s.examples.first ?? ""]) }
                    if e.senses.count == 1, let exact = s.words.first(where: { $0.lowercased() == lemmaKey }), exact != e.display {
                        e.display = exact      // keep capitals as written (Canis familiaris, grace of God)
                    }
                    for w in s.words where w.lowercased() != lemmaKey && !e.synonyms.contains(w) && e.synonyms.count < 24 { e.synonyms.append(w) }
                    let myIndex = (s.words.firstIndex { $0.lowercased() == lemmaKey } ?? -1) + 1
                    for a in s.antonyms where a.source == 0 || a.source == myIndex {
                        guard let t = synsets[key(a.pos, a.offset)] else { continue }
                        let targets = a.target > 0 && a.target <= t.words.count ? [t.words[a.target - 1]] : Array(t.words.prefix(2))
                        for w in targets where !e.antonyms.contains(w) && e.antonyms.count < 12 { e.antonyms.append(w) }
                    }
                }
                entries[lemmaKey] = e
            }
        }

        progress?("Writing the dictionary…")
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDB(path: output.path)
        try db.exec("""
            PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE words (word TEXT PRIMARY KEY, display TEXT, phonetic TEXT, data TEXT) WITHOUT ROWID;
            CREATE TABLE exceptions (form TEXT, base TEXT, pos TEXT, PRIMARY KEY (form, base, pos)) WITHOUT ROWID;
            """)
        var senseCount = 0
        try db.transaction {
            let insert = try db.prepare("INSERT OR REPLACE INTO words (word, display, phonetic, data) VALUES (?, ?, ?, ?)")
            for k in order {
                guard let e = entries[k], !e.senses.isEmpty else { continue }
                var obj: [String: Any] = ["s": e.senses]
                if !e.synonyms.isEmpty { obj["y"] = e.synonyms }
                if !e.antonyms.isEmpty { obj["a"] = e.antonyms }
                guard let json = try? JSONSerialization.data(withJSONObject: obj), let js = String(data: json, encoding: .utf8) else { continue }
                let phon = k.contains(" ") ? "" : (pronunciations[k].map { ARPAbet.ipa($0) } ?? "")
                insert.bind([.text(k), .text(e.display), .text(phon), .text(js)])
                _ = insert.run()
                senseCount += e.senses.count
            }
            if let dir = exceptionsDir {
                let exc = try db.prepare("INSERT OR IGNORE INTO exceptions (form, base, pos) VALUES (?, ?, ?)")
                let posNames = ["noun": "noun", "verb": "verb", "adj": "adjective", "adv": "adverb"]
                for name in ["noun", "verb", "adj", "adv"] {
                    guard let text = try? String(contentsOf: dir.appendingPathComponent("\(name).exc"), encoding: .utf8) else { continue }
                    for line in text.split(whereSeparator: \.isNewline) {
                        let f = line.split(separator: " ")
                        guard f.count >= 2 else { continue }
                        for base in f.dropFirst() {
                            exc.bind([.text(WordNetParser.cleanLemma(f[0]).lowercased()), .text(WordNetParser.cleanLemma(base).lowercased()), .text(posNames[name] ?? "")])
                            _ = exc.run()
                        }
                    }
                }
            }
            let meta = try db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")
            for (k, v) in [("name", "English (WordNet 3.1)"), ("words", String(entries.count)), ("format", "1"),
                           ("licence", "WordNet 3.1 © Princeton University; CMU Pronouncing Dictionary © Carnegie Mellon University")] {
                meta.bind([.text(k), .text(v)]); _ = meta.run()
            }
        }
        try db.exec("VACUUM;")
        db.close()
        return Result(words: entries.count, senses: senseCount)
    }
}

/// Reader for the offline dictionary.
public final class OfflineDictionary {
    private let db: SQLiteDB
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        db = try SQLiteDB(path: url.path, readOnly: true)
    }

    public var name: String {
        var n = "English"
        try? db.query("SELECT value FROM meta WHERE key = 'name'") { n = $0.text(0) }
        return n
    }

    public var wordCount: Int {
        var c = 0
        try? db.query("SELECT COUNT(*) FROM words") { c = $0.int(0) }
        return c
    }

    private func entry(_ key: String) -> WordEntry? {
        var result: WordEntry?
        try? db.query("SELECT display, phonetic, data FROM words WHERE word = ?", [.text(key)]) { row in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(row.text(2).utf8)) as? [String: Any] else { return }
            let senses = (obj["s"] as? [[String]] ?? []).map { s in
                WordSense(partOfSpeech: s.count > 0 ? s[0] : "", definition: s.count > 1 ? s[1] : "", example: s.count > 2 && !s[2].isEmpty ? s[2] : nil)
            }
            result = WordEntry(word: row.text(0), phonetic: row.text(1), senses: senses,
                               synonyms: obj["y"] as? [String] ?? [], antonyms: obj["a"] as? [String] ?? [], source: "Offline English Dictionary")
        }
        return result
    }

    /// Exact word first, then its base forms (went → go, churches → church, running → run). When the word was
    /// found through an inflection, meanings of the matching part of speech come first (went → the verb “go”).
    public func lookup(_ query: String) -> [WordEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var keys: [(String, String?)] = [(q, nil)]
        try? db.query("SELECT base, pos FROM exceptions WHERE form = ?", [.text(q)]) { keys.append(($0.text(0), $0.text(1))) }
        for base in WordNetParser.baseForms(q) {
            let pos: String? = q.hasSuffix("ing") || q.hasSuffix("ed") ? "verb" : (q.hasSuffix("est") || q.hasSuffix("er") ? "adjective" : nil)
            keys.append((base, pos))
        }
        var seen = Set<String>()
        var out: [WordEntry] = []
        for (k, pos) in keys where seen.insert(k).inserted {
            if var e = entry(k) {
                if let pos, e.senses.contains(where: { $0.partOfSpeech == pos }) {
                    e.senses = e.senses.filter { $0.partOfSpeech == pos } + e.senses.filter { $0.partOfSpeech != pos }
                }
                out.append(e)
            }
            if out.count >= 3 { break }
        }
        return out
    }

    public func suggestions(prefix: String, limit: Int = 12) -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard p.count >= 2 else { return [] }
        var out: [String] = []
        let upper = p + "\u{FFFF}"
        try? db.query("SELECT display FROM words WHERE word >= ? AND word < ? ORDER BY word LIMIT ?", [.text(p), .text(upper), .int(limit)]) {
            out.append($0.text(0))
        }
        return out
    }
}
