import XCTest
@testable import PresentationKit

final class BibleAssistTests: XCTestCase {
    func testBookAndReferenceSuggestions() {
        let jo = BibleAssist.referenceSuggestions("jo")
        XCTAssertTrue(jo.contains { $0.title == "John" && $0.kind == .book })
        XCTAssertTrue(jo.contains { $0.title == "Joshua" })
        let one = BibleAssist.referenceSuggestions("1 jo")
        XCTAssertEqual(one.first?.title, "1 John")
        XCTAssertEqual(BibleAssist.referenceSuggestions("1jo").first?.title, "1 John")
        XCTAssertEqual(BibleAssist.referenceSuggestions("ii cor").first?.title, "2 Corinthians")
        let ref = BibleAssist.referenceSuggestions("john 3:16")
        XCTAssertEqual(ref.first?.kind, .reference)
        XCTAssertEqual(ref.first?.text, "John 3:16")
        XCTAssertTrue(BibleAssist.referenceSuggestions("psalm 23").contains { $0.kind == .popular && $0.text == "Psalm 23" })
        XCTAssertEqual(BibleAssist.referenceSuggestions("jude 5").first?.kind, .book, "Jude has 1 chapter")
        XCTAssertTrue(BibleAssist.referenceSuggestions("zzz").isEmpty)
        XCTAssertTrue(BibleAssist.looksLikeReference("Rom 8:28"))
        XCTAssertFalse(BibleAssist.looksLikeReference("the lord is my shepherd"))
    }

    func testThemeAndFTSQuery() {
        XCTAssertTrue(BibleAssist.themeSuggestions("healing").contains { $0.text == "Isaiah 53:5" })
        XCTAssertEqual(BibleAssist.ftsQuery("grace fai"), "\"grace\" \"fai\"*")
        XCTAssertEqual(BibleAssist.ftsQuery("\"the lord is\""), "\"the lord is\"")
        XCTAssertNil(BibleAssist.ftsQuery("   "))
    }

    func testPhraseCompletionAndCounts() {
        let verses = [
            BibleVerse(book: 19, chapter: 23, verse: 1, text: "The LORD is my shepherd; I shall not want."),
            BibleVerse(book: 19, chapter: 27, verse: 1, text: "The LORD is my light and my salvation"),
            BibleVerse(book: 19, chapter: 28, verse: 7, text: "The LORD is my strength and my shield"),
            BibleVerse(book: 2, chapter: 15, verse: 2, text: "The LORD is my strength and song")
        ]
        let c = BibleAssist.phraseCompletions(query: "the lord is my", in: verses)
        XCTAssertEqual(c.first?.title, "the lord is my strength and")
        XCTAssertEqual(c.first?.detail, "2 verses")
        XCTAssertTrue(c.contains { $0.title.hasPrefix("the lord is my shepherd") })
        let partial = BibleAssist.phraseCompletions(query: "lord is my sh", in: verses)
        XCTAssertEqual(partial.first?.title, "lord is my shepherd i shall")
        XCTAssertEqual(BibleAssist.bookCounts(verses).map { $0.book }, [2, 19])
        XCTAssertEqual(BibleAssist.bookCounts(verses).last?.count, 3)
    }

    func testLiveSearchInStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ba-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("kjv.xml")
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <XMLBIBLE biblename="Test"><BIBLEBOOK bnumber="49" bname="Ephesians"><CHAPTER cnumber="2">
        <VERS vnumber="8">For by grace are ye saved through faith</VERS>
        <VERS vnumber="9">Not of works, lest any man should boast</VERS>
        </CHAPTER></BIBLEBOOK></XMLBIBLE>
        """.write(to: f, atomically: true, encoding: .utf8)
        let info = try BibleImporter.importFiles([f], into: dir.appendingPathComponent("B"), abbreviation: "TST")
        let store = try XCTUnwrap(BibleLibrary(directory: dir.appendingPathComponent("B")).store(info.id))
        XCTAssertEqual(store.liveSearch("grace fai").first?.verse, 8, "last word may be unfinished")
        XCTAssertEqual(store.liveSearch("\"lest any man\"").first?.verse, 9)
        XCTAssertTrue(store.liveSearch("x").isEmpty)
    }
}
