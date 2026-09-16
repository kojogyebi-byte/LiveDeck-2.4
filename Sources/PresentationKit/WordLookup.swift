import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Dictionaries

public enum DictionaryKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case macOS = "macOS Dictionary"
    case english = "English Dictionary"
    case wiktionary = "Wiktionary"
    case thesaurus = "Thesaurus"
    case wikipedia = "Wikipedia"
    case custom = "My Dictionaries"
    public var id: String { rawValue }

    public var detail: String {
        switch self {
        case .macOS: return "Offline — the dictionaries enabled in the macOS Dictionary app (English, Oxford Thesaurus, other languages you add there)."
        case .english: return "Free Dictionary API — definitions, pronunciation, parts of speech and examples. Internet."
        case .wiktionary: return "Wiktionary — definitions for words in many languages. Choose the language code. Internet."
        case .thesaurus: return "Synonyms, antonyms and short definitions (Datamuse). Internet."
        case .wikipedia: return "Encyclopedia summary of a person, place or topic in the chosen language. Internet."
        case .custom: return "Dictionaries you import yourself (Bible dictionaries, glossaries…) from CSV, TSV or JSON."
        }
    }
    public var usesLanguage: Bool { self == .wiktionary || self == .wikipedia }
    public var needsInternet: Bool { self != .macOS && self != .custom }
}

public struct WordSense: Codable, Hashable, Sendable {
    public var partOfSpeech: String
    public var definition: String
    public var example: String?
    public init(partOfSpeech: String = "", definition: String, example: String? = nil) {
        self.partOfSpeech = partOfSpeech; self.definition = definition; self.example = example
    }
}

public struct WordEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var word: String
    public var phonetic: String
    public var senses: [WordSense]
    public var synonyms: [String]
    public var antonyms: [String]
    public var source: String

    public init(id: UUID = UUID(), word: String, phonetic: String = "", senses: [WordSense] = [],
                synonyms: [String] = [], antonyms: [String] = [], source: String) {
        self.id = id; self.word = word; self.phonetic = phonetic; self.senses = senses
        self.synonyms = synonyms; self.antonyms = antonyms; self.source = source
    }

    /// Numbered definitions for display (limited to `maxSenses`).
    public func bodyText(maxSenses: Int, examples: Bool) -> String {
        var lines: [String] = []
        let shown = senses.prefix(max(1, maxSenses))
        for (i, s) in shown.enumerated() {
            let pos = s.partOfSpeech.isEmpty ? "" : "(\(s.partOfSpeech.lowercased())) "
            let n = shown.count > 1 ? "\(i + 1). " : ""
            lines.append(n + pos + s.definition)
            if examples, let e = s.example, !e.isEmpty { lines.append("   “\(e)”") }
        }
        if senses.isEmpty && !synonyms.isEmpty { lines.append("Synonyms: " + synonyms.prefix(12).joined(separator: ", ")) }
        if senses.isEmpty && !antonyms.isEmpty { lines.append("Antonyms: " + antonyms.prefix(8).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    public var titleText: String { phonetic.isEmpty ? word : "\(word)  \(phonetic)" }
}

public enum WordLookup {
    public static let userAgent = "LiveDeckStudio/4.1 (macOS; church production app)"

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? s
    }
    static func lang(_ code: String) -> String {
        let c = code.trimmed.lowercased().filter { $0.isLetter || $0 == "-" }
        return c.isEmpty ? "en" : c
    }

    public static func url(_ kind: DictionaryKind, word: String, language: String = "en") -> URL? {
        let w = word.trimmed
        guard !w.isEmpty else { return nil }
        switch kind {
        case .english: return URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/" + enc(w.lowercased()))
        case .wiktionary: return URL(string: "https://en.wiktionary.org/api/rest_v1/page/definition/" + enc(w))
        case .wikipedia: return URL(string: "https://\(lang(language)).wikipedia.org/api/rest_v1/page/summary/" + enc(w.replacingOccurrences(of: " ", with: "_")))
        case .thesaurus:
            let q = w.lowercased().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? w
            return URL(string: "https://api.datamuse.com/words?sp=\(q)&md=d&max=1")
        case .macOS, .custom: return nil
        }
    }

    // MARK: Parsers (pure — unit tested)

    public static func parseFreeDictionary(_ data: Data) -> [WordEntry] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { obj in
            guard let word = obj["word"] as? String else { return nil }
            var phon = obj["phonetic"] as? String ?? ""
            if phon.isEmpty, let ps = obj["phonetics"] as? [[String: Any]] {
                phon = ps.compactMap { $0["text"] as? String }.first { !$0.isEmpty } ?? ""
            }
            var senses: [WordSense] = []
            var syn: [String] = [], ant: [String] = []
            for m in obj["meanings"] as? [[String: Any]] ?? [] {
                let pos = m["partOfSpeech"] as? String ?? ""
                syn += m["synonyms"] as? [String] ?? []
                ant += m["antonyms"] as? [String] ?? []
                for d in m["definitions"] as? [[String: Any]] ?? [] {
                    guard let def = d["definition"] as? String else { continue }
                    senses.append(WordSense(partOfSpeech: pos, definition: def, example: d["example"] as? String))
                }
            }
            return WordEntry(word: word, phonetic: phon, senses: senses, synonyms: unique(syn), antonyms: unique(ant), source: "Free Dictionary API")
        }
    }

    public static func parseWiktionary(_ data: Data, word: String, language: String) -> [WordEntry] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let code = lang(language)
        let key: String? = obj[code] != nil ? code : (obj["en"] != nil ? "en" : obj.keys.sorted().first)
        guard let key, let groups = obj[key] as? [[String: Any]] else { return [] }
        var senses: [WordSense] = []
        var languageName = ""
        for g in groups {
            let pos = g["partOfSpeech"] as? String ?? ""
            if languageName.isEmpty { languageName = g["language"] as? String ?? "" }
            for d in g["definitions"] as? [[String: Any]] ?? [] {
                let def = stripHTML(d["definition"] as? String ?? "")
                guard !def.isEmpty else { continue }
                let ex = (d["examples"] as? [String])?.first.map(stripHTML)
                senses.append(WordSense(partOfSpeech: pos, definition: def, example: ex))
            }
        }
        guard !senses.isEmpty else { return [] }
        return [WordEntry(word: word, senses: senses, source: "Wiktionary" + (languageName.isEmpty ? "" : " — \(languageName)"))]
    }

    public static func parseWikipedia(_ data: Data) -> [WordEntry] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = obj["title"] as? String, let extract = obj["extract"] as? String, !extract.isEmpty else { return [] }
        if (obj["type"] as? String) == "disambiguation" {
            return [WordEntry(word: title, senses: [WordSense(definition: extract)], source: "Wikipedia (several meanings — be more specific)")]
        }
        // split the summary into sentences so "senses" limits length sensibly
        let sentences = splitSentences(extract)
        let desc = obj["description"] as? String ?? ""
        return [WordEntry(word: title, phonetic: "", senses: sentences.map { WordSense(partOfSpeech: "", definition: $0) },
                          source: "Wikipedia" + (desc.isEmpty ? "" : " — \(desc)"))]
    }

    /// Datamuse `sp=word&md=d` (definitions) — synonyms/antonyms are merged in separately.
    public static func parseDatamuseDefinitions(_ data: Data, word: String) -> WordEntry {
        var senses: [WordSense] = []
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let first = arr.first {
            for d in first["defs"] as? [String] ?? [] {
                let parts = d.split(separator: "\t", maxSplits: 1).map(String.init)
                let posMap = ["n": "noun", "v": "verb", "adj": "adjective", "adv": "adverb", "u": ""]
                if parts.count == 2 { senses.append(WordSense(partOfSpeech: posMap[parts[0]] ?? parts[0], definition: parts[1])) }
                else { senses.append(WordSense(definition: d)) }
            }
        }
        return WordEntry(word: word, senses: senses, source: "Thesaurus (Datamuse)")
    }

    public static func parseDatamuseWords(_ data: Data) -> [String] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["word"] as? String }
    }

    /// macOS Dictionary Services text (one long string) → entry.
    public static func entryFromPlainDefinition(word: String, text: String, source: String) -> WordEntry {
        // Dictionary text often numbers senses "1 …  2 …" — split on those markers when present.
        var parts = text.components(separatedBy: CharacterSet(charactersIn: "▶•"))
            .map { $0.trimmed }.filter { !$0.isEmpty }
        if parts.count <= 1 {
            parts = text.replacingOccurrences(of: "\\s([1-9])\\s", with: "\n$1 ", options: .regularExpression)
                .components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty }
        }
        var head = ""
        if let first = parts.first, parts.count > 1, first.count < 80 { head = first; parts.removeFirst() }
        let senses = parts.map { WordSense(definition: $0.replacingOccurrences(of: "^[1-9]\\s", with: "", options: .regularExpression)) }
        return WordEntry(word: word, phonetic: head.hasPrefix(word) ? String(head.dropFirst(word.count)).trimmed : "", senses: senses, source: source)
    }

    public static func stripHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " ", "&#160;": " "]
        for (k, v) in entities { t = t.replacingOccurrences(of: k, with: v) }
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed
    }

    static func splitSentences(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            if ".!?".contains(ch), i + 1 < chars.count, chars[i + 1] == " ", cur.count > 25 {
                out.append(cur.trimmed); cur = ""
            }
        }
        if !cur.trimmed.isEmpty { out.append(cur.trimmed) }
        return out
    }

    static func unique(_ a: [String]) -> [String] {
        var seen = Set<String>(); return a.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: Network

    static func get(_ url: URL, completion: @escaping (Data?, Int, Error?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            completion(data, (resp as? HTTPURLResponse)?.statusCode ?? 0, err)
        }.resume()
    }

    /// Online lookups. `.macOS` and `.custom` are handled by the app / CustomDictionaryStore.
    public static func fetch(_ kind: DictionaryKind, word: String, language: String = "en",
                             completion: @escaping (Result<[WordEntry], Error>) -> Void) {
        let w = word.trimmed
        guard !w.isEmpty else { completion(.success([])); return }
        if kind == .thesaurus {
            let q = w.lowercased().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? w
            guard let defURL = url(.thesaurus, word: w),
                  let synURL = URL(string: "https://api.datamuse.com/words?rel_syn=\(q)&max=24"),
                  let antURL = URL(string: "https://api.datamuse.com/words?rel_ant=\(q)&max=12") else { completion(.success([])); return }
            let group = DispatchGroup()
            var entry = WordEntry(word: w, source: "Thesaurus (Datamuse)")
            var failure: Error?
            let lock = NSLock()
            group.enter(); get(defURL) { d, _, e in lock.lock(); if let d { let p = parseDatamuseDefinitions(d, word: w); entry.senses = p.senses }; if let e { failure = e }; lock.unlock(); group.leave() }
            group.enter(); get(synURL) { d, _, _ in lock.lock(); if let d { entry.synonyms = parseDatamuseWords(d) }; lock.unlock(); group.leave() }
            group.enter(); get(antURL) { d, _, _ in lock.lock(); if let d { entry.antonyms = parseDatamuseWords(d) }; lock.unlock(); group.leave() }
            group.notify(queue: .global()) {
                if entry.senses.isEmpty && entry.synonyms.isEmpty && entry.antonyms.isEmpty {
                    if let failure { completion(.failure(PresentationKitError.network(failure.localizedDescription))) }
                    else { completion(.success([])) }
                } else {
                    if !entry.synonyms.isEmpty {
                        entry.senses.append(WordSense(partOfSpeech: "synonyms", definition: entry.synonyms.prefix(12).joined(separator: ", ")))
                    }
                    if !entry.antonyms.isEmpty {
                        entry.senses.append(WordSense(partOfSpeech: "antonyms", definition: entry.antonyms.prefix(8).joined(separator: ", ")))
                    }
                    completion(.success([entry]))
                }
            }
            return
        }
        guard let u = url(kind, word: w, language: language) else { completion(.success([])); return }
        get(u) { data, status, err in
            if let err { completion(.failure(PresentationKitError.network(err.localizedDescription))); return }
            guard let data else { completion(.success([])); return }
            if status == 404 { completion(.success([])); return }
            switch kind {
            case .english: completion(.success(parseFreeDictionary(data)))
            case .wiktionary: completion(.success(parseWiktionary(data, word: w, language: language)))
            case .wikipedia: completion(.success(parseWikipedia(data)))
            default: completion(.success([]))
            }
        }
    }
}

// MARK: - Custom (imported) dictionaries

public struct CustomDictionary: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// headword → definition (as imported)
    public var entries: [String: String]
    public init(id: UUID = UUID(), name: String, enabled: Bool = true, entries: [String: String]) {
        self.id = id; self.name = name; self.enabled = enabled; self.entries = entries
    }
}

public final class CustomDictionaryStore {
    public let directory: URL
    public private(set) var dictionaries: [CustomDictionary] = []
    private var index: [UUID: [String: String]] = [:]   // folded headword → original headword

    public init(libraryRoot: URL) {
        directory = libraryRoot.appendingPathComponent("Dictionaries")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    public func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        dictionaries = files.filter { $0.pathExtension == "json" }.compactMap { try? JSONFile.read(CustomDictionary.self, from: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        index = [:]
        for d in dictionaries {
            var m: [String: String] = [:]
            for k in d.entries.keys { m[k.searchFolded] = k }
            index[d.id] = m
        }
    }

    /// Imports CSV/TSV ("word,definition") or JSON ({"word": "definition"} or [{"word":…,"definition":…}]).
    @discardableResult
    public func importFile(_ url: URL, name: String? = nil) throws -> CustomDictionary {
        let data = try Data(contentsOf: url)
        var entries: [String: String] = [:]
        if url.pathExtension.lowercased() == "json" {
            let obj = try JSONSerialization.jsonObject(with: data)
            if let dict = obj as? [String: String] { entries = dict }
            else if let arr = obj as? [[String: Any]] {
                for o in arr {
                    let w = (o["word"] ?? o["term"] ?? o["headword"] ?? o["title"]) as? String
                    let d = (o["definition"] ?? o["meaning"] ?? o["text"] ?? o["description"]) as? String
                    if let w, let d, !w.trimmed.isEmpty { entries[w.trimmed] = d.trimmed }
                }
            }
        } else {
            let text = SongImporter.decode(data)
            let lines = text.components(separatedBy: .newlines)
            let tab = lines.prefix(5).contains { $0.contains("\t") }
            for line in lines where !line.trimmed.isEmpty {
                let f = tab ? line.components(separatedBy: "\t") : CSVBibleReader.fields(line)
                guard f.count >= 2 else { continue }
                let w = f[0].trimmed, d = f[1...].joined(separator: tab ? " " : ",").trimmed
                if !w.isEmpty, !d.isEmpty, w.lowercased() != "word" && w.lowercased() != "term" { entries[w] = d }
            }
        }
        guard !entries.isEmpty else { throw PresentationKitError.badFormat("no word/definition pairs found") }
        let dict = CustomDictionary(name: name ?? url.deletingPathExtension().lastPathComponent, entries: entries)
        try JSONFile.write(dict, to: directory.appendingPathComponent(dict.id.uuidString + ".json"))
        reload()
        return dict
    }

    public func setEnabled(_ id: UUID, _ on: Bool) {
        guard var d = dictionaries.first(where: { $0.id == id }) else { return }
        d.enabled = on
        try? JSONFile.write(d, to: directory.appendingPathComponent(d.id.uuidString + ".json"))
        reload()
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
        reload()
    }

    /// Exact (folded) matches first, then headwords starting with the query.
    public func lookup(_ word: String, limit: Int = 20) -> [WordEntry] {
        let q = word.trimmed.searchFolded
        guard !q.isEmpty else { return [] }
        var exact: [WordEntry] = [], prefix: [WordEntry] = []
        for d in dictionaries where d.enabled {
            guard let idx = index[d.id] else { continue }
            if let orig = idx[q], let def = d.entries[orig] {
                exact.append(WordEntry(word: orig, senses: [WordSense(definition: def)], source: d.name))
            }
            for (folded, orig) in idx where folded != q && folded.hasPrefix(q) {
                if prefix.count >= limit { break }
                if let def = d.entries[orig] { prefix.append(WordEntry(word: orig, senses: [WordSense(definition: def)], source: d.name)) }
            }
        }
        return Array((exact + prefix.sorted { $0.word < $1.word }).prefix(limit))
    }
}
