import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum BibleFileFormat: String, Sendable, CaseIterable {
    case zefania = "Zefania XML"
    case osis = "OSIS XML"
    case usfm = "USFM"
    case csv = "CSV / TSV"
    case freeUseJSON = "Free Use Bible JSON"
    case superSearchJSON = "Bible SuperSearch JSON"
    case ldbible = "LiveDeck Bible"
}

/// Importers for open Bible file formats. All importers stream into a `BibleWriter`
/// so even large files are converted with modest memory use.
public enum BibleImporter {
    public static let fileExtensions = ["xml", "osis", "usfm", "sfm", "usx", "csv", "tsv", "txt", "json", "ldbible"]

    public static func detect(url: URL) -> BibleFileFormat? {
        let ext = url.pathExtension.lowercased()
        if ["usfm", "sfm"].contains(ext) { return .usfm }
        if ext == "csv" || ext == "tsv" { return .csv }
        if ext == BibleLibrary.fileExtension { return .ldbible }
        if ext == "json" {
            // {"metadata":{…},"verses":[{"book_name","book","chapter","verse","text"}]} (Bible SuperSearch export)
            if let h = try? FileHandle(forReadingFrom: url) {
                defer { try? h.close() }
                let head = String(decoding: h.readData(ofLength: 65536), as: UTF8.self)
                if head.contains("\"verses\"") && (head.contains("\"metadata\"") || head.contains("\"book_name\"")) { return .superSearchJSON }
            }
            return .freeUseJSON
        }
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 8192), as: UTF8.self).lowercased()
        if head.contains("<xmlbible") || head.contains("<biblebook") { return .zefania }
        if head.contains("<osis") { return .osis }
        if head.contains("\\id ") || head.contains("\\c 1") { return .usfm }
        if ext == "txt", head.contains("\t") || head.contains(",") { return .csv }
        return nil
    }

    /// Imports one file (or several USFM book files) into `directory`, returning the installed version.
    public static func importFiles(_ urls: [URL], into directory: URL, name: String? = nil, abbreviation: String? = nil,
                                   progress: ((String) -> Void)? = nil) throws -> BibleVersionInfo {
        guard let first = urls.first, let format = detect(url: first) else {
            throw PresentationKitError.badFormat("choose a Zefania XML, OSIS XML, USFM, CSV/TSV or Free Use Bible JSON file")
        }
        let base = first.deletingPathExtension().lastPathComponent
        let abbr = (abbreviation?.trimmed.isEmpty == false ? abbreviation! : base).trimmed
        var info = BibleVersionInfo(id: BibleLibrary.uniqueID(for: "user-" + abbr, in: directory),
                                    name: name?.trimmed.isEmpty == false ? name! : base,
                                    abbreviation: String(abbr.prefix(12)),
                                    license: "Imported by the user — ensure you are licensed to use this translation.",
                                    source: format.rawValue + " file")
        progress?("Reading \(format.rawValue)…")
        switch format {
        case .zefania:
            let meta = try ZefaniaReader.metadata(first)
            if name == nil, let t = meta.title { info.name = t }
            info.language = meta.language ?? ""
            let w = try BibleWriter(info: info, destination: BibleLibrary.fileURL(info.id, in: directory))
            do { try ZefaniaReader.read(first, into: w) } catch { w.cancel(); throw error }
            return try w.finish()
        case .osis:
            let w = try BibleWriter(info: info, destination: BibleLibrary.fileURL(info.id, in: directory))
            do { try OSISReader.read(first, into: w) } catch { w.cancel(); throw error }
            return try w.finish()
        case .usfm:
            let w = try BibleWriter(info: info, destination: BibleLibrary.fileURL(info.id, in: directory))
            for u in urls { USFMReader.read(UsfmText.load(u), into: w) }
            return try w.finish()
        case .csv:
            let w = try BibleWriter(info: info, destination: BibleLibrary.fileURL(info.id, in: directory))
            CSVBibleReader.read(try String(contentsOf: first, encoding: .utf8), into: w)
            return try w.finish()
        case .freeUseJSON:
            return try FreeUseBibleAPI.convertComplete(fileURL: first, into: directory, overrideInfo: info)
        case .superSearchJSON:
            return try SuperSearchJSONReader.importFile(first, into: directory, name: name, abbreviation: abbreviation)
        case .ldbible:
            return try BibleLibrary.installPackage(first, into: directory)
        }
    }

    /// Expands folders (and skips macOS metadata files) into the Bible files they contain.
    public static func bibleFiles(in urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard u.lastPathComponent != "__MACOSX" else { continue }
                let children = ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [])
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                out += bibleFiles(in: children)
            } else {
                let name = u.lastPathComponent
                guard !name.hasPrefix("."), !name.hasPrefix("._"), fileExtensions.contains(u.pathExtension.lowercased()) else { continue }
                out.append(u)
            }
        }
        return out
    }

    public struct BatchResult: Sendable {
        public var imported: [BibleVersionInfo] = []
        public var skipped: [String] = []        // already installed
        public var failed: [String] = []         // "file: reason"
    }

    /// Imports many files: every single-file Bible separately, all USFM books together as one translation.
    /// Versions already installed (same name and abbreviation) are skipped.
    public static func importBatch(_ urls: [URL], into directory: URL, progress: ((String) -> Void)? = nil) -> BatchResult {
        var result = BatchResult()
        let files = bibleFiles(in: urls)
        let usfm = files.filter { detect(url: $0) == .usfm }
        let singles = files.filter { detect(url: $0) != .usfm }
        let existing = BibleLibrary(directory: directory).installed()
        func alreadyInstalled(_ name: String, _ abbr: String) -> Bool {
            existing.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.abbreviation.caseInsensitiveCompare(abbr) == .orderedSame }
        }
        for (i, f) in singles.enumerated() {
            progress?("Importing \(f.lastPathComponent) (\(i + 1) of \(singles.count))…")
            if detect(url: f) == .superSearchJSON, let meta = SuperSearchJSONReader.peekMetadata(f),
               alreadyInstalled(meta.name, meta.abbreviation) {
                result.skipped.append("\(meta.abbreviation) — \(meta.name)")
                continue
            }
            do { result.imported.append(try importFiles([f], into: directory)) }
            catch { result.failed.append("\(f.lastPathComponent): \(error.localizedDescription)") }
        }
        if !usfm.isEmpty {
            progress?("Importing \(usfm.count) USFM book files…")
            do { result.imported.append(try importFiles(usfm, into: directory)) }
            catch { result.failed.append("USFM: \(error.localizedDescription)") }
        }
        return result
    }
}

// MARK: - Bible SuperSearch JSON ({"metadata":{…},"verses":[…]})

public enum SuperSearchJSONReader {
    struct File: Decodable {
        struct Meta: Decodable {
            var name: String?
            var shortname: String?
            var module: String?
            var year: String?
            var lang: String?
            var lang_short: String?
            var copyright_statement: String?
            var rtl: Int?
        }
        struct Verse: Decodable {
            var book_name: String?
            var book: Int
            var chapter: Int
            var verse: Int
            var text: String
        }
        var metadata: Meta?
        var verses: [Verse]
    }

    /// Name and abbreviation without reading the whole file.
    public static func peekMetadata(_ url: URL) -> (name: String, abbreviation: String)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 65536), as: UTF8.self)
        func field(_ key: String) -> String? {
            guard let r = head.range(of: "\"\(key)\":\"((?:[^\"\\\\]|\\\\.)*)\"", options: .regularExpression) else { return nil }
            let raw = String(head[r]).dropFirst(key.count + 4).dropLast()
            return (try? JSONDecoder().decode(String.self, from: Data(("\"" + raw + "\"").utf8))) ?? String(raw)
        }
        guard let name = field("name") else { return nil }
        return (cleanName(name), abbreviation(field("shortname") ?? field("module") ?? name))
    }

    static func cleanName(_ s: String) -> String { s.replacingOccurrences(of: "®", with: "").trimmed }
    static func abbreviation(_ s: String) -> String {
        let t = s.replacingOccurrences(of: " Strongs", with: "+").replacingOccurrences(of: "Strongs", with: "+").trimmed
        return String(t.prefix(12))
    }

    /// Screen-ready verse text: removes Strong's numbers {H1234} {(H8804)}, HTML/markup, pilcrows and
    /// the square brackets some editions use for supplied words.
    public static func cleanText(_ raw: String) -> String {
        var t = raw
        t = t.replacingOccurrences(of: "\\{\\(?[HGhg][0-9]+[a-zA-Z]?\\)?\\}", with: "", options: .regularExpression)   // Strong's / TVM codes
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for mark in ["¶", "[", "]", "{", "}", "‹", "›"] { t = t.replacingOccurrences(of: mark, with: "") }   // pilcrows, supplied words, red-letter marks
        t = t.replacingOccurrences(of: "([,;:!?.])([“‘])", with: "$1 $2", options: .regularExpression)                // "said,“Let" → "said, “Let"
        t = t.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " ([,.;:!?])", with: "$1", options: .regularExpression)
        return t.trimmed
    }

    public static func importFile(_ url: URL, into directory: URL, name: String? = nil, abbreviation abbr: String? = nil) throws -> BibleVersionInfo {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) }
        catch { throw PresentationKitError.badFormat("Bible JSON: \(error.localizedDescription)") }
        let meta = file.metadata
        let displayName = name?.trimmed.isEmpty == false ? name! : cleanName(meta?.name ?? url.deletingPathExtension().lastPathComponent)
        let short = abbr?.trimmed.isEmpty == false ? abbr!.trimmed : abbreviation(meta?.shortname ?? meta?.module ?? url.deletingPathExtension().lastPathComponent)
        let module = meta?.module ?? url.deletingPathExtension().lastPathComponent
        var license = meta?.copyright_statement.map { WordLookup.stripHTML($0).trimmed } ?? ""
        if license.isEmpty { license = "Imported by the user — ensure you are licensed to use this translation." }
        let info = BibleVersionInfo(id: BibleLibrary.uniqueID(for: "user-" + module, in: directory), name: displayName, abbreviation: short,
                                    language: meta?.lang_short ?? "", languageName: meta?.lang ?? "", license: license,
                                    source: BibleFileFormat.superSearchJSON.rawValue + " file", rightToLeft: (meta?.rtl ?? 0) == 1)
        let w = try BibleWriter(info: info, destination: BibleLibrary.fileURL(info.id, in: directory))
        var named = Set<Int>()
        for v in file.verses {
            if !named.contains(v.book), let n = v.book_name { w.setBookName(v.book, n); named.insert(v.book) }
            w.add(book: v.book, chapter: v.chapter, verse: v.verse, text: cleanText(v.text))
        }
        return try w.finish()
    }
}

enum UsfmText {
    static func load(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
    }
}

// MARK: - Zefania XML (streaming)

final class ZefaniaReader: NSObject, XMLParserDelegate {
    private let w: BibleWriter
    private var book = 0, chapter = 0, verse = 0
    private var inVerse = false
    private var skipDepth = 0
    private var buf = ""
    private var bookName = ""

    init(_ w: BibleWriter) { self.w = w }

    static func read(_ url: URL, into w: BibleWriter) throws {
        guard let p = XMLParser(contentsOf: url) else { throw PresentationKitError.badFormat("cannot open file") }
        let r = ZefaniaReader(w)
        p.delegate = r
        if !p.parse() { throw PresentationKitError.badFormat(p.parserError?.localizedDescription ?? "invalid Zefania XML") }
    }

    struct Meta { var title: String?; var language: String? }
    static func metadata(_ url: URL) throws -> Meta {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Meta() }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 16384), as: UTF8.self)
        func grab(_ pattern: String) -> String? {
            guard let r = head.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let s = String(head[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "biblename=\"", with: "", options: .caseInsensitive).replacingOccurrences(of: "\"", with: "")
            return s.trimmed.isEmpty ? nil : s.trimmed
        }
        return Meta(title: grab("<title>[^<]*</title>") ?? grab("biblename=\"[^\"]*\""), language: grab("<language>[^<]*</language>"))
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        let n = name.uppercased()
        func attr(_ k: String) -> String? { a.first { $0.key.lowercased() == k }?.value }
        switch n {
        case "BIBLEBOOK":
            book = Int(attr("bnumber") ?? "") ?? (book + 1)
            bookName = attr("bname") ?? ""
            w.setBookName(book, bookName)
        case "CHAPTER": chapter = Int(attr("cnumber") ?? "") ?? (chapter + 1)
        case "VERS":
            verse = Int((attr("vnumber") ?? "").prefix { $0.isNumber }) ?? (verse + 1)
            inVerse = true; buf = ""
        case "NOTE", "XREF", "DIV", "REMARK": if inVerse { skipDepth += 1 }
        case "BR": if inVerse { buf += " " }
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name.uppercased() {
        case "VERS":
            if inVerse { w.add(book: book, chapter: chapter, verse: verse, text: buf) }
            inVerse = false; skipDepth = 0
        case "NOTE", "XREF", "DIV", "REMARK": if inVerse && skipDepth > 0 { skipDepth -= 1 }
        case "CHAPTER": verse = 0
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if inVerse && skipDepth == 0 { buf += s } }
}

// MARK: - OSIS XML (streaming; container and milestone verses)

final class OSISReader: NSObject, XMLParserDelegate {
    private let w: BibleWriter
    private var current: (Int, Int, Int)?
    private var buf = ""
    private var skipDepth = 0

    init(_ w: BibleWriter) { self.w = w }

    static func read(_ url: URL, into w: BibleWriter) throws {
        guard let p = XMLParser(contentsOf: url) else { throw PresentationKitError.badFormat("cannot open file") }
        let r = OSISReader(w)
        p.delegate = r
        if !p.parse() { throw PresentationKitError.badFormat(p.parserError?.localizedDescription ?? "invalid OSIS XML") }
        r.flush()
    }

    static func ref(_ osisID: String) -> (Int, Int, Int)? {
        let first = osisID.split(separator: " ").first.map(String.init) ?? osisID
        let bare = first.split(separator: ":").last.map(String.init) ?? first   // "KJV:Gen.1.1"
        let parts = bare.split(separator: ".").map(String.init)
        guard parts.count >= 3, let b = BibleBookInfo.byCode(parts[0]),
              let c = Int(parts[1]), let v = Int(parts[2].prefix { $0.isNumber }) else { return nil }
        return (b.number, c, v)
    }

    func flush() {
        if let (b, c, v) = current { w.add(book: b, chapter: c, verse: v, text: buf) }
        current = nil; buf = ""
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        let local = (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
        switch local {
        case "verse":
            if a["eID"] != nil { flush(); return }
            flush()
            if let id = a["osisID"] ?? a["sID"], let r = OSISReader.ref(id) { current = r }
        case "note", "title":
            skipDepth += 1
        case "chapter":
            if a["eID"] != nil { flush() }
        case "lb", "l":
            if current != nil { buf += " " }
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
        switch local {
        case "note", "title": if skipDepth > 0 { skipDepth -= 1 }
        case "div": if skipDepth == 0 { flush() }
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if current != nil && skipDepth == 0 { buf += s } }
}

// MARK: - USFM

enum USFMReader {
    static func read(_ text: String, into w: BibleWriter) {
        var book = 0, chapter = 0, verse = 0
        var buf = ""
        func flush() { if book > 0 && chapter > 0 && verse > 0 { w.add(book: book, chapter: chapter, verse: verse, text: clean(buf)) }; buf = "" }

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmed
            guard !line.isEmpty else { continue }
            if line.hasPrefix("\\id ") {
                flush(); verse = 0; chapter = 0
                book = BibleBookInfo.byCode(String(line.dropFirst(4).prefix(3)))?.number ?? 0
                continue
            }
            if line.hasPrefix("\\toc2 ") || line.hasPrefix("\\h ") {
                let name = line.hasPrefix("\\h ") ? String(line.dropFirst(3)) : String(line.dropFirst(6))
                if book > 0 { w.setBookName(book, name) }
                continue
            }
            if line.hasPrefix("\\c ") {
                flush(); verse = 0
                chapter = Int(line.dropFirst(3).prefix { $0.isNumber }) ?? chapter
                continue
            }
            // headings / titles / references lines are not verse text
            let skipMarkers = ["\\s", "\\ms", "\\mt", "\\r ", "\\d ", "\\toc", "\\ide", "\\rem", "\\sp", "\\cl", "\\mr", "\\sr", "\\is", "\\ip", "\\imt"]
            if skipMarkers.contains(where: { line.hasPrefix($0) }) && !line.hasPrefix("\\sc") { continue }

            // a line can hold several verses: split at \v markers
            while let r = line.range(of: "\\v ") {
                buf += " " + String(line[line.startIndex..<r.lowerBound])
                flush()
                let after = line[r.upperBound...]
                let numStr = after.prefix { $0.isNumber || $0 == "-" }
                verse = Int(numStr.prefix { $0.isNumber }) ?? (verse + 1)
                line = String(after.dropFirst(numStr.count))
            }
            buf += " " + line
        }
        flush()
    }

    static func clean(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "\\\\f .*?\\\\f\\*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\\\fe .*?\\\\fe\\*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\\\x .*?\\\\x\\*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\|[^\\\\]*?(\\\\\\+?w\\*)", with: "$1", options: .regularExpression)  // \w word|strong="H1"\w*
        t = t.replacingOccurrences(of: "\\\\\\+?[a-z]+[0-9]*\\*?", with: "", options: .regularExpression)       // remaining markers
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed
    }
}

// MARK: - CSV / TSV   (book,chapter,verse,text — book as number, USFM code or name)

enum CSVBibleReader {
    static func read(_ text: String, into w: BibleWriter) {
        let lines = text.components(separatedBy: .newlines)
        let tab = lines.prefix(5).contains { $0.contains("\t") }
        for line in lines where !line.trimmed.isEmpty {
            let f = tab ? line.components(separatedBy: "\t") : fields(line)
            guard f.count >= 4, let c = Int(f[1].trimmed), let v = Int(f[2].trimmed) else { continue }   // header rows skipped
            let b = f[0].trimmed
            let book = Int(b) ?? BibleBookInfo.byCode(b)?.number ?? ScriptureReferenceParser.matchBook(b)
            guard let book else { continue }
            w.add(book: book, chapter: c, verse: v, text: f[3...].joined(separator: tab ? "\t" : ","))
        }
    }
    static func fields(_ line: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false
        var it = Array(line), i = 0
        while i < it.count {
            let ch = it[i]
            if ch == "\"" {
                if quoted && i + 1 < it.count && it[i + 1] == "\"" { cur.append("\""); i += 1 } else { quoted.toggle() }
            } else if ch == "," && !quoted { out.append(cur); cur = "" } else { cur.append(ch) }
            i += 1
        }
        out.append(cur)
        it.removeAll()
        return out
    }
}
