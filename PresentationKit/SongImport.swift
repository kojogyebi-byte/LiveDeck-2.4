import Foundation

public enum SongFormat: String, Sendable, CaseIterable {
    case plainText = "Plain text"
    case songSelectText = "SongSelect (.txt)"
    case songSelectUSR = "SongSelect (.usr)"
    case chordPro = "ChordPro"
    case openLyrics = "OpenLyrics XML"
    case openSong = "OpenSong"
}

/// Imports songs from open / exportable formats. Proprietary library formats of other
/// presentation products are intentionally not supported.
public enum SongImporter {
    public static let fileExtensions = ["txt", "text", "usr", "cho", "chordpro", "chopro", "crd", "pro", "xml", "song", ""]

    public static func importFile(_ url: URL) throws -> [Song] {
        let data = try Data(contentsOf: url)
        return try parse(data, filename: url.lastPathComponent)
    }

    public static func detect(_ data: Data, filename: String) -> SongFormat {
        let ext = (filename as NSString).pathExtension.lowercased()
        let head = decode(data).prefix(4000).lowercased()
        if ext == "usr" || head.contains("[file]") && head.contains("words=") { return .songSelectUSR }
        if head.contains("<song") && (head.contains("openlyrics") || head.contains("<lyrics>") && head.contains("<verse")) { return .openLyrics }
        if head.contains("<song") && head.contains("<lyrics") { return .openSong }
        if ["cho", "chordpro", "chopro", "crd", "pro"].contains(ext) || head.contains("{title") || head.contains("{t:")
            || head.contains("{start_of_chorus") || head.contains("{soc}") { return .chordPro }
        if head.contains("ccli song #") || head.contains("ccli license #") { return .songSelectText }
        return .plainText
    }

    public static func parse(_ data: Data, filename: String) throws -> [Song] {
        let title = ((filename as NSString).deletingPathExtension as String).trimmed
        switch detect(data, filename: filename) {
        case .plainText: return [plainText(decode(data), fallbackTitle: title)]
        case .songSelectText: return [songSelectText(decode(data), fallbackTitle: title)]
        case .songSelectUSR: return songSelectUSR(decode(data))
        case .chordPro: return [chordPro(decode(data), fallbackTitle: title)]
        case .openLyrics: return [try openLyrics(data, fallbackTitle: title)]
        case .openSong: return [try openSong(data, fallbackTitle: title)]
        }
    }

    static func decode(_ data: Data) -> String {
        var d = data
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        if let s = String(data: d, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        return String(data: d, encoding: .windowsCP1252) ?? String(decoding: d, as: UTF8.self)
    }

    // MARK: Plain text  ("Title:" optional, section headers optional)

    public static func plainText(_ text: String, fallbackTitle: String) -> Song {
        var body: [String] = []
        var song = Song(title: fallbackTitle)
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmed, l = t.lowercased()
            if l.hasPrefix("title:") { song.title = String(t.dropFirst(6)).trimmed; continue }
            if l.hasPrefix("author:") { song.author = String(t.dropFirst(7)).trimmed; continue }
            if l.hasPrefix("copyright:") { song.copyright = String(t.dropFirst(10)).trimmed; continue }
            if l.hasPrefix("ccli:") { song.ccliNumber = String(t.dropFirst(5)).filter { $0.isNumber }; continue }
            body.append(line)
        }
        let (secs, arr) = mergeRepeats(SongText.parse(body.joined(separator: "\n")))
        song.sections = secs; song.arrangement = arr; song.source = "Plain text"
        if song.title.isEmpty { song.title = secs.first?.lines.first ?? "Untitled" }
        return song
    }

    // MARK: SongSelect text export

    public static func songSelectText(_ text: String, fallbackTitle: String) -> Song {
        var lines = text.components(separatedBy: .newlines).map { $0.trimmed }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        var song = Song(title: lines.first ?? fallbackTitle)
        if !lines.isEmpty { lines.removeFirst() }
        var body: [String] = []
        var i = 0
        while i < lines.count {
            let l = lines[i], low = l.lowercased()
            if low.hasPrefix("ccli song #") || low.hasPrefix("ccli song number") {
                song.ccliNumber = l.filter { $0.isNumber }
                if i + 1 < lines.count, !lines[i + 1].isEmpty, !lines[i + 1].hasPrefix("©") { song.author = lines[i + 1]; i += 1 }
            } else if l.hasPrefix("©") || low.hasPrefix("copyright") {
                song.copyright = song.copyright.isEmpty ? l : song.copyright + "; " + l
            } else if low.hasPrefix("for use solely with the songselect") || low.hasPrefix("ccli license #")
                        || low.hasPrefix("note: reproduction") || low.contains("terms of use") {
                // licence boilerplate — dropped
            } else {
                body.append(l)
            }
            i += 1
        }
        let (secs, arr) = mergeRepeats(SongText.parse(body.joined(separator: "\n")))
        song.sections = secs; song.arrangement = arr; song.source = "SongSelect"
        return song
    }

    // MARK: SongSelect .usr

    public static func songSelectUSR(_ text: String) -> [Song] {
        var songs: [Song] = []
        var fields: [String: String] = [:]
        var inSong = false
        var ccli = ""

        func flush() {
            guard inSong else { return }
            var song = Song(title: fields["title"] ?? "Untitled")
            song.author = (fields["author"] ?? "").replacingOccurrences(of: "|", with: ", ")
            song.copyright = (fields["copyright"] ?? "").replacingOccurrences(of: "|", with: "; ")
            song.publisher = fields["admin"] ?? ""
            song.ccliNumber = ccli
            song.key = (fields["keys"] ?? "").components(separatedBy: "/t").first ?? ""
            let names = (fields["fields"] ?? "").components(separatedBy: "/t")
            let words = (fields["words"] ?? "").components(separatedBy: "/t")
            var secs: [LyricSection] = []
            for (idx, w) in words.enumerated() {
                let lines = w.components(separatedBy: "/n").map { $0.trimmed }.filter { !$0.isEmpty }
                guard !lines.isEmpty else { continue }
                let header = idx < names.count ? names[idx] : "Verse \(idx + 1)"
                let (kind, num) = SectionKind.parseHeader(header) ?? (.verse, idx + 1)
                secs.append(LyricSection(kind: kind, number: num, slides: [lines]))
            }
            song.sections = SongText.numberDuplicates(secs)
            song.source = "SongSelect"
            songs.append(song)
            fields = [:]
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmed
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                let inner = String(line.dropFirst().dropLast())
                inSong = inner.uppercased().hasPrefix("S ")
                ccli = inSong ? inner.filter { $0.isNumber } : ""
                continue
            }
            guard inSong, let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq]).lowercased()] = String(line[line.index(after: eq)...])
        }
        flush()
        return songs
    }

    // MARK: ChordPro

    public static func chordPro(_ text: String, fallbackTitle: String) -> Song {
        var song = Song(title: fallbackTitle)
        var out: [String] = []
        var envSection: String?
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmed
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("{") && line.hasSuffix("}") {
                let inner = String(line.dropFirst().dropLast())
                let parts = inner.split(separator: ":", maxSplits: 1).map { String($0).trimmed }
                let dir = parts.first?.lowercased() ?? ""
                let val = parts.count > 1 ? parts[1] : ""
                switch dir {
                case "title", "t": song.title = val
                case "subtitle", "st", "artist", "composer", "lyricist":
                    if song.author.isEmpty { song.author = val }
                case "copyright": song.copyright = val
                case "ccli": song.ccliNumber = val.filter { $0.isNumber }
                case "key": song.key = val
                case "tempo": song.tempo = val
                case "start_of_chorus", "soc": envSection = val.isEmpty ? "Chorus" : val; out.append(""); out.append(envSection ?? "Chorus")
                case "start_of_verse", "sov": envSection = val.isEmpty ? "Verse" : val; out.append(""); out.append(envSection ?? "Verse")
                case "start_of_bridge", "sob": envSection = val.isEmpty ? "Bridge" : val; out.append(""); out.append(envSection ?? "Bridge")
                case "end_of_chorus", "eoc", "end_of_verse", "eov", "end_of_bridge", "eob": envSection = nil; out.append("")
                case "comment", "c", "ci", "comment_italic", "cb", "comment_box":
                    if SectionKind.parseHeader(val) != nil { out.append(""); out.append(val) }
                case "chorus": out.append(""); out.append("Chorus")   // {chorus} = repeat chorus
                default: break
                }
                continue
            }
            // strip chords [G], [Am7/C]
            line = line.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression).trimmed
            out.append(line)
        }
        let (secs, arr) = mergeRepeats(SongText.parse(out.joined(separator: "\n")))
        song.sections = secs; song.arrangement = arr; song.source = "ChordPro"
        return song
    }

    // MARK: OpenLyrics

    public static func openLyrics(_ data: Data, fallbackTitle: String) throws -> Song {
        let root = try XNode.parse(data)
        guard root.name == "song" else { throw PresentationKitError.badFormat("OpenLyrics root is not <song>") }
        let props = root.child("properties")
        var song = Song(title: props?.child("titles")?.all("title").first?.deepText.trimmed ?? fallbackTitle)
        song.author = props?.child("authors")?.all("author").map { $0.deepText.trimmed }.joined(separator: ", ") ?? ""
        song.copyright = props?.child("copyright")?.deepText.trimmed ?? ""
        song.ccliNumber = props?.child("cclino")?.deepText.trimmed ?? ""
        song.publisher = props?.child("publisher")?.deepText.trimmed ?? ""
        song.key = props?.child("key")?.deepText.trimmed ?? ""

        var codeMap: [String: String] = [:]   // "v1" → "V1"
        var secs: [LyricSection] = []
        for v in root.child("lyrics")?.all("verse") ?? [] {
            let name = (v["name"] ?? "v").lowercased()
            let letters = String(name.prefix { $0.isLetter })
            let num = Int(name.drop { $0.isLetter }.prefix { $0.isNumber })
            let kind: SectionKind
            switch letters {
            case "c": kind = .chorus
            case "p": kind = .preChorus
            case "b": kind = .bridge
            case "e": kind = .ending
            case "i": kind = .intro
            case "o": kind = .other
            default: kind = .verse
            }
            var slides: [[String]] = []
            for l in v.all("lines") {
                let lines = linesText(l).components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty }
                if !lines.isEmpty { slides.append(lines) }
            }
            guard !slides.isEmpty else { continue }
            let sec = LyricSection(kind: kind, number: num, slides: slides)
            codeMap[name] = sec.code
            secs.append(sec)
        }
        song.sections = SongText.numberDuplicates(secs)
        if let order = props?.child("verseorder")?.deepText.trimmed, !order.isEmpty {
            song.arrangement = order.split(separator: " ").map { codeMap[String($0).lowercased()] ?? String($0).uppercased() }
                .joined(separator: " ")
        }
        song.source = "OpenLyrics"
        return song
    }

    /// <lines> text with <br/> → newline, chord markup and <comment> removed.
    private static func linesText(_ n: XNode) -> String {
        var s = ""
        for item in n.items {
            switch item {
            case .text(let t): s += t.replacingOccurrences(of: "\n", with: " ")
            case .node(let c):
                if c.name == "br" { s += "\n" }
                else if c.name == "comment" { continue }
                else { s += linesText(c) }
            }
        }
        return s
    }

    // MARK: OpenSong

    public static func openSong(_ data: Data, fallbackTitle: String) throws -> Song {
        let root = try XNode.parse(data)
        var song = Song(title: root.child("title")?.deepText.trimmed ?? fallbackTitle)
        song.author = root.child("author")?.deepText.trimmed ?? ""
        song.copyright = root.child("copyright")?.deepText.trimmed ?? ""
        song.ccliNumber = root.child("ccli")?.deepText.trimmed ?? ""
        song.key = root.child("key")?.deepText.trimmed ?? ""
        let lyrics = root.child("lyrics")?.deepText ?? ""
        var out: [String] = []
        for raw in lyrics.components(separatedBy: .newlines) {
            if raw.hasPrefix(".") || raw.hasPrefix(";") { continue }        // chords / comments
            let t = raw.trimmed
            if t.hasPrefix("[") && t.hasSuffix("]") {
                let code = String(t.dropFirst().dropLast())
                out.append("")
                if let (k, n) = SectionKind.parseHeader(code.uppercased()) { out.append(n.map { "\(k.displayName) \($0)" } ?? k.displayName) }
                else { out.append("Verse") }
                continue
            }
            if t == "||" || t == "|" { out.append(""); continue }
            out.append(t.replacingOccurrences(of: "|", with: "").replacingOccurrences(of: "_", with: ""))
        }
        song.sections = SongText.parse(out.joined(separator: "\n"))
        if let pres = root.child("presentation")?.deepText.trimmed, !pres.isEmpty { song.arrangement = pres.uppercased() }
        song.source = "OpenSong"
        return song
    }

    // MARK: Helpers

    /// Merges repeated identical sections (a chorus typed out twice) and returns the implied arrangement.
    public static func mergeRepeats(_ sections: [LyricSection]) -> ([LyricSection], String) {
        var unique: [LyricSection] = []
        var order: [String] = []
        var repeated = false
        for s in sections {
            if let u = unique.first(where: { $0.kind == s.kind && $0.lines == s.lines }) {
                order.append(u.code); repeated = true
            } else {
                var copy = s
                if s.kind != .verse, unique.contains(where: { $0.kind == s.kind }) == false, s.number != nil,
                   sections.filter({ $0.kind == s.kind }).allSatisfy({ $0.lines == s.lines }) {
                    copy.number = nil   // "Chorus 1" & "Chorus 2" identical → just "Chorus"
                }
                unique.append(copy); order.append(copy.code)
            }
        }
        return (unique, repeated ? order.joined(separator: " ") : "")
    }
}
