import Foundation

// MARK: - Several Bible versions on one slide

public struct ParallelColumn: Hashable, Sendable {
    public var label: String       // version abbreviation
    public var text: String
}

public struct ParallelSlide: Hashable, Sendable {
    public var first: BibleVerse   // primary version's range
    public var last: BibleVerse
    public var columns: [ParallelColumn]
}

public enum ParallelScripture {
    struct Key: Hashable { let chapter: Int; let verse: Int }

    /// Groups the primary passage into slides so that the LONGEST version on each slide stays within `maxChars`.
    /// Every version shows exactly the same verses on a slide (missing verses are simply left out).
    public static func slides(primaryLabel: String, primary: [BibleVerse],
                              others: [(label: String, verses: [BibleVerse])],
                              maxChars: Int = 280, verseNumbers: Bool = true) -> [ParallelSlide] {
        guard !primary.isEmpty else { return [] }
        let maps: [[Key: BibleVerse]] = others.map { o in
            Dictionary(o.verses.map { (Key(chapter: $0.chapter, verse: $0.verse), $0) }, uniquingKeysWith: { a, _ in a })
        }
        func piece(_ v: BibleVerse) -> String {
            (verseNumbers ? BibleStore.superscript(v.verse) + " " : "") + v.text.trimmed
        }
        var slides: [ParallelSlide] = []
        var group: [BibleVerse] = []
        var lengths = [Int](repeating: 0, count: others.count + 1)

        func flush() {
            guard let f = group.first, let l = group.last else { return }
            var cols = [ParallelColumn(label: primaryLabel, text: group.map(piece).joined(separator: " "))]
            for (i, o) in others.enumerated() {
                let text = group.compactMap { maps[i][Key(chapter: $0.chapter, verse: $0.verse)] }.map(piece).joined(separator: " ")
                cols.append(ParallelColumn(label: o.label, text: text))
            }
            slides.append(ParallelSlide(first: f, last: l, columns: cols))
            group = []; lengths = [Int](repeating: 0, count: others.count + 1)
        }

        let limit = max(40, maxChars)
        for v in primary {
            var add = [piece(v).count]
            for m in maps { add.append(m[Key(chapter: v.chapter, verse: v.verse)].map { piece($0).count } ?? 0) }
            let wouldExceed = zip(lengths, add).contains { cur, a in cur > 0 && cur + 1 + a > limit }
            if !group.isEmpty && wouldExceed { flush() }
            group.append(v)
            for i in lengths.indices { lengths[i] += (lengths[i] > 0 ? 1 : 0) + add[i] }
        }
        flush()
        return slides
    }
}
