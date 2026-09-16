import Foundation

// MARK: - Song model

public enum SectionKind: String, Codable, Sendable, CaseIterable {
    case verse, preChorus, chorus, bridge, tag, intro, interlude, ending, other

    public var displayName: String {
        switch self {
        case .verse: return "Verse"
        case .preChorus: return "Pre-Chorus"
        case .chorus: return "Chorus"
        case .bridge: return "Bridge"
        case .tag: return "Tag"
        case .intro: return "Intro"
        case .interlude: return "Interlude"
        case .ending: return "Ending"
        case .other: return "Other"
        }
    }
    /// Short code used in arrangements ("V1 C V2 C B").
    public var code: String {
        switch self {
        case .verse: return "V"
        case .preChorus: return "P"
        case .chorus: return "C"
        case .bridge: return "B"
        case .tag: return "T"
        case .intro: return "I"
        case .interlude: return "IN"
        case .ending: return "E"
        case .other: return "O"
        }
    }
    public var color: RGBAColor {
        switch self {
        case .verse: return RGBAColor(0.20, 0.45, 0.85)
        case .preChorus: return RGBAColor(0.55, 0.35, 0.80)
        case .chorus: return RGBAColor(0.85, 0.25, 0.30)
        case .bridge: return RGBAColor(0.90, 0.55, 0.15)
        case .tag: return RGBAColor(0.15, 0.65, 0.55)
        case .intro, .interlude, .ending: return RGBAColor(0.45, 0.45, 0.50)
        case .other: return RGBAColor(0.35, 0.35, 0.40)
        }
    }

    /// Recognises headers such as "Verse 1", "VERSE", "V1", "[Chorus 2]", "Pre-Chorus:", "Refrain", "Coda".
    public static func parseHeader(_ raw: String) -> (SectionKind, Int?)? {
        var s = raw.trimmed
        if s.hasPrefix("[") && s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        if s.hasSuffix(":") { s.removeLast() }
        s = s.trimmed
        guard !s.isEmpty, s.count <= 24 else { return nil }
        let lower = s.lowercased()

        // split trailing number
        var namePart = lower
        var number: Int?
        if let r = lower.range(of: "\\s*(\\d+)[a-z]?$", options: .regularExpression) {
            let digits = lower[r].filter { $0.isNumber }
            number = Int(digits)
            namePart = String(lower[lower.startIndex..<r.lowerBound]).trimmed
        }
        let words: [(String, SectionKind)] = [
            ("verse", .verse), ("v", .verse), ("vs", .verse), ("stanza", .verse),
            ("pre-chorus", .preChorus), ("prechorus", .preChorus), ("pre chorus", .preChorus), ("pre", .preChorus), ("p", .preChorus), ("lift", .preChorus),
            ("chorus", .chorus), ("c", .chorus), ("ch", .chorus), ("refrain", .chorus), ("r", .chorus),
            ("bridge", .bridge), ("b", .bridge),
            ("tag", .tag), ("t", .tag), ("vamp", .tag),
            ("intro", .intro), ("i", .intro),
            ("interlude", .interlude), ("instrumental", .interlude),
            ("ending", .ending), ("outro", .ending), ("coda", .ending), ("e", .ending), ("o", .other), ("misc", .other)
        ]
        for (w, k) in words where namePart == w {
            // Short codes ("C", "V1", "Ch") must be typed in capitals so ordinary short
            // lyric lines ("c", "b", "I") are never mistaken for headers.
            if w.count <= 2 {
                let letters = s.filter { $0.isLetter }
                if letters != letters.uppercased() { return nil }
                if w == "i" && number == nil { return nil }   // "I" alone is almost always a lyric
            }
            return (k, number)
        }
        return nil
    }
}

public struct LyricSection: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: SectionKind
    public var number: Int?
    /// Slides within the section, each a list of lines. A typed blank line inside a section starts a new slide.
    public var slides: [[String]]

    public init(id: UUID = UUID(), kind: SectionKind, number: Int? = nil, slides: [[String]]) {
        self.id = id; self.kind = kind; self.number = number; self.slides = slides
    }
    enum CodingKeys: String, CodingKey { case id, kind, number, slides }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); kind = c.value(.kind, .verse); number = c.value(.number, nil); slides = c.value(.slides, [])
    }

    public var label: String { number.map { "\(kind.displayName) \($0)" } ?? kind.displayName }
    public var code: String { kind.code + (number.map(String.init) ?? "") }
    public var lines: [String] { slides.flatMap { $0 } }
}

public struct Song: Codable, Identifiable, Hashable, Sendable {
    public static let schemaVersion = 1
    public var id: UUID
    public var schema: Int
    public var meta: LibraryMeta
    public var author: String
    public var copyright: String
    public var ccliNumber: String
    public var publisher: String
    public var key: String
    public var tempo: String
    public var sections: [LyricSection]
    /// Section codes in performance order, e.g. "V1 C V2 C B C". Empty = sections as written.
    public var arrangement: String
    public var linesPerSlide: Int        // 0 = keep the section's own slide breaks
    public var source: String            // "typed", "SongSelect", "OpenLyrics"… (provenance)

    public init(id: UUID = UUID(), title: String, author: String = "", copyright: String = "", ccliNumber: String = "",
                sections: [LyricSection] = [], arrangement: String = "", linesPerSlide: Int = 0, source: String = "typed") {
        self.id = id; schema = Song.schemaVersion; meta = LibraryMeta(title: title); self.author = author
        self.copyright = copyright; self.ccliNumber = ccliNumber; publisher = ""; key = ""; tempo = ""
        self.sections = sections; self.arrangement = arrangement; self.linesPerSlide = linesPerSlide; self.source = source
    }
    enum CodingKeys: String, CodingKey {
        case id, schema, meta, author, copyright, ccliNumber, publisher, key, tempo, sections, arrangement, linesPerSlide, source
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); schema = c.value(.schema, 1); meta = c.value(.meta, LibraryMeta(title: "Untitled"))
        author = c.value(.author, ""); copyright = c.value(.copyright, ""); ccliNumber = c.value(.ccliNumber, "")
        publisher = c.value(.publisher, ""); key = c.value(.key, ""); tempo = c.value(.tempo, "")
        sections = c.value(.sections, []); arrangement = c.value(.arrangement, ""); linesPerSlide = c.value(.linesPerSlide, 0)
        source = c.value(.source, "typed")
    }

    public var title: String { get { meta.title } set { meta.title = newValue } }

    /// Everything searchable in one folded string.
    public var searchText: String {
        ([meta.title, author, copyright, ccliNumber] + meta.tags + sections.flatMap { $0.lines })
            .joined(separator: " ").searchFolded
    }

    // MARK: Editable lyric text  ⇄  sections

    /// The lyric text as the operator types it: headers on their own line, blank lines = slide breaks.
    public var lyricText: String {
        get { SongText.format(sections) }
        set { sections = SongText.parse(newValue) }
    }

    // MARK: Arrangement

    /// Sections in performance order. Unknown codes are skipped; empty arrangement = as written.
    public func orderedSections(arrangement override: String? = nil) -> [LyricSection] {
        let arr = (override ?? arrangement).trimmed
        guard !arr.isEmpty else { return sections }
        var out: [LyricSection] = []
        for token in arr.uppercased().split(whereSeparator: { $0 == " " || $0 == "," || $0 == "-" }) {
            let t = String(token)
            if let s = sections.first(where: { $0.code.uppercased() == t }) { out.append(s); continue }
            // "C" matches "C1" when the song only has one chorus, and "V" matches verse 1
            if let (kind, num) = SectionKind.parseHeader(t) {
                let same = sections.filter { $0.kind == kind }
                if let n = num, let s = same.first(where: { $0.number == n }) { out.append(s) }
                else if num == nil, let s = same.first { out.append(s) }
            }
        }
        return out.isEmpty ? sections : out
    }

    public var defaultArrangement: String { sections.map { $0.code }.joined(separator: " ") }

    // MARK: Slides

    public struct GeneratedSlide: Hashable, Sendable {
        public var label: String
        public var kind: SectionKind
        public var lines: [String]
        public var sectionID: UUID
    }

    public func generatedSlides(arrangement override: String? = nil, linesPerSlide lps: Int? = nil) -> [GeneratedSlide] {
        let per = lps ?? linesPerSlide
        var out: [GeneratedSlide] = []
        for sec in orderedSections(arrangement: override) {
            var chunks: [[String]] = []
            if per > 0 {
                let all = sec.lines
                var i = 0
                while i < all.count { chunks.append(Array(all[i..<min(all.count, i + per)])); i += per }
            } else {
                chunks = sec.slides.filter { !$0.isEmpty }
            }
            for c in chunks { out.append(GeneratedSlide(label: sec.label, kind: sec.kind, lines: c, sectionID: sec.id)) }
        }
        return out
    }

    public func slides(theme: Theme, arrangement override: String? = nil, showFooter: Bool = false) -> [Slide] {
        generatedSlides(arrangement: override).map { g in
            var els = [SlideElement.textBox(g.lines.joined(separator: "\n"), role: .lyrics, style: theme.body, in: theme.bodyFrame)]
            if showFooter {
                let footer = [meta.title, copyright, ccliNumber.isEmpty ? "" : "CCLI Song #\(ccliNumber)"]
                    .filter { !$0.isEmpty }.joined(separator: "  ·  ")
                els.append(.textBox(footer, role: .subtitle, style: theme.reference, in: theme.referenceFrame))
            }
            return Slide(label: g.label, elements: els, notes: "", groupColor: g.kind.color)
        }
    }
}

// MARK: - Typed lyric text format

public enum SongText {
    public static func parse(_ text: String) -> [LyricSection] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var sections: [LyricSection] = []
        var current: LyricSection?
        var slide: [String] = []
        var autoVerse = 0

        func closeSlide() {
            if !slide.isEmpty { current?.slides.append(slide); slide = [] }
        }
        func closeSection() {
            closeSlide()
            if let c = current, !c.slides.isEmpty { sections.append(c) }
            current = nil
        }

        for raw in lines {
            let line = raw.trimmed
            if line.isEmpty {
                // blank line: slide break inside a headed section; paragraph = new verse when un-headed
                if current != nil { closeSlide() }
                continue
            }
            if let (kind, num) = SectionKind.parseHeader(line) {
                closeSection()
                current = LyricSection(kind: kind, number: num, slides: [])
                continue
            }
            if current == nil {
                autoVerse += 1
                current = LyricSection(kind: .verse, number: autoVerse, slides: [])
            }
            slide.append(line)
        }
        closeSection()

        // Un-headed text: each blank-line paragraph becomes its own verse.
        if sections.count == 1, sections[0].kind == .verse, sections[0].number == 1, sections[0].slides.count > 1,
           !lines.contains(where: { SectionKind.parseHeader($0) != nil }) {
            return sections[0].slides.enumerated().map { LyricSection(kind: .verse, number: $0.offset + 1, slides: [$0.element]) }
        }
        return numberDuplicates(sections)
    }

    /// If a kind appears more than once without numbers (e.g. two "Verse" headers), number them 1, 2…
    static func numberDuplicates(_ secs: [LyricSection]) -> [LyricSection] {
        var out = secs
        for kind in SectionKind.allCases {
            let idx = out.indices.filter { out[$0].kind == kind }
            if idx.count > 1 && idx.allSatisfy({ out[$0].number == nil }) {
                for (n, i) in idx.enumerated() { out[i].number = n + 1 }
            }
        }
        return out
    }

    public static func format(_ sections: [LyricSection]) -> String {
        sections.map { sec in
            sec.label + "\n" + sec.slides.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
        }.joined(separator: "\n\n\n")
    }
}
