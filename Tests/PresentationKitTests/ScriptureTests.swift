import XCTest
@testable import PresentationKit

final class ScriptureTests: XCTestCase {
    func ref(_ s: String) -> ScriptureReference? { ScriptureReferenceParser.parse(s) }

    func testReferenceParsing() {
        XCTAssertEqual(ref("John 3:16"), ScriptureReference(book: 43, startChapter: 3, startVerse: 16, endVerse: 16))
        XCTAssertEqual(ref("jn 3:16-18")?.endVerse, 18)
        XCTAssertEqual(ref("1 Cor 13:4-7")?.book, 46)
        XCTAssertEqual(ref("1Co13")?.startChapter, 13)
        XCTAssertEqual(ref("Ps 23")?.book, 19)
        XCTAssertEqual(ref("Ps 23")?.startVerse, 0)
        XCTAssertEqual(ref("Song of Solomon 2:1")?.book, 22)
        XCTAssertEqual(ref("First John 1:9")?.book, 62)
        XCTAssertEqual(ref("II Kings 2:11")?.book, 12)
        let g = ref("Gen 1:1-2:3")
        XCTAssertEqual(g?.endChapter, 2); XCTAssertEqual(g?.endVerse, 3)
        XCTAssertEqual(ref("Jude 3")?.startVerse, 3)
        XCTAssertEqual(ref("Rom 8:28–39")?.endVerse, 39)
        XCTAssertEqual(ref("Philippians 4:13")?.book, 50)
        XCTAssertEqual(ref("Philemon 1")?.book, 57)
        XCTAssertNil(ref("Hello world"))
        XCTAssertNil(ref(""))
        XCTAssertEqual(ref("John 3:16")?.display(), "John 3:16")
        XCTAssertEqual(ref("Gen 1:1-2:3")?.display(), "Genesis 1:1–2:3")
    }

    func testExtraBookNames() {
        XCTAssertEqual(ScriptureReferenceParser.parse("Yohane 3:16", extraNames: [43: ["Yohane"]])?.book, 43)
    }

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testWriterStoreQuerySearchSlides() throws {
        let dir = tempDir()
        let w = try BibleWriter(info: BibleVersionInfo(id: "TST", name: "Test Bible", abbreviation: "TST"),
                                destination: BibleLibrary.fileURL("TST", in: dir))
        w.setBookName(43, "John")
        w.add(book: 43, chapter: 3, verse: 16, text: "For God so loved the world,")
        w.add(book: 43, chapter: 3, verse: 17, text: "For God sent not his Son into the world to condemn the world.")
        w.add(book: 43, chapter: 4, verse: 1, text: "When therefore the Lord knew")
        let info = try w.finish()
        XCTAssertEqual(info.verseCount, 3)

        let lib = BibleLibrary(directory: dir)
        XCTAssertEqual(lib.installed().map { $0.id }, ["TST"])
        let store = try XCTUnwrap(lib.store("TST"))
        let r = try XCTUnwrap(store.parseReference("John 3:16-4:1"))
        XCTAssertEqual(store.verses(r).map { $0.verse }, [16, 17, 1])
        XCTAssertEqual(store.verses(ScriptureReference(book: 43, startChapter: 3)).count, 2)
        XCTAssertEqual(store.search("condemn").first?.verse, 17)
        let slides = store.slides(r, theme: .standard, maxChars: 60)
        XCTAssertGreaterThanOrEqual(slides.count, 2)
        XCTAssertTrue(slides[0].label.contains("(TST)"))
        try lib.rename("TST", name: "Renamed", abbreviation: "RN")
        XCTAssertEqual(lib.installed().first?.abbreviation, "RN")
        try lib.remove("TST")
        XCTAssertTrue(lib.installed().isEmpty)
    }

    func testSlideSplittingNeverExceedsLimit() {
        let long = String(repeating: "and the word was with God, ", count: 30)
        let v = [BibleVerse(book: 43, chapter: 1, verse: 1, text: long)]
        let parts = BibleStore.slideTexts(v, maxChars: 120)
        XCTAssertGreaterThan(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { $0.text.count <= 125 })
    }

    func testZefaniaImport() throws {
        let dir = tempDir()
        let f = dir.appendingPathComponent("kjv.xml")
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <XMLBIBLE biblename="King James Version"><INFORMATION><title>King James Version</title><language>ENG</language></INFORMATION>
        <BIBLEBOOK bnumber="43" bname="John"><CHAPTER cnumber="3">
        <VERS vnumber="16">For God so loved the world<NOTE>a note</NOTE>, that he gave</VERS>
        <VERS vnumber="17">For God sent not his Son</VERS>
        </CHAPTER></BIBLEBOOK></XMLBIBLE>
        """.write(to: f, atomically: true, encoding: .utf8)
        let info = try BibleImporter.importFiles([f], into: dir.appendingPathComponent("B"), abbreviation: "KJV")
        XCTAssertEqual(info.name, "King James Version")
        let store = try XCTUnwrap(BibleLibrary(directory: dir.appendingPathComponent("B")).store(info.id))
        XCTAssertEqual(store.verses(ScriptureReference(book: 43, startChapter: 3, startVerse: 16, endVerse: 16)).first?.text,
                       "For God so loved the world, that he gave")
    }

    func testOSISMilestoneAndContainer() throws {
        let dir = tempDir()
        let f = dir.appendingPathComponent("web.osis.xml")
        try """
        <osis><osisText><div type="book" osisID="John"><chapter osisID="John.3">
        <title>Heading</title>
        <verse sID="John.3.16" osisID="John.3.16"/>For God so loved<note>n</note> the world.<verse eID="John.3.16"/>
        <verse osisID="John.3.17">For God didn't send</verse>
        </chapter></div></osisText></osis>
        """.write(to: f, atomically: true, encoding: .utf8)
        let info = try BibleImporter.importFiles([f], into: dir)
        let store = try XCTUnwrap(BibleLibrary(directory: dir).store(info.id))
        let v = store.verses(ScriptureReference(book: 43, startChapter: 3))
        XCTAssertEqual(v.map { $0.text }, ["For God so loved the world.", "For God didn't send"])
    }

    func testUSFMImport() throws {
        let dir = tempDir()
        let f = dir.appendingPathComponent("44JHNeng.usfm")
        try """
        \\id JHN
        \\h John
        \\c 3
        \\s1 God's love
        \\p
        \\v 16 For God so loved the world,\\f + \\fr 3:16 \\ft note\\f* that he gave his \\w only|strong="G3439"\\w* Son.
        \\v 17 For God didn't send his Son \\v 18 He who believes
        """.write(to: f, atomically: true, encoding: .utf8)
        let info = try BibleImporter.importFiles([f], into: dir)
        let store = try XCTUnwrap(BibleLibrary(directory: dir).store(info.id))
        let v = store.verses(ScriptureReference(book: 43, startChapter: 3))
        XCTAssertEqual(v.count, 3)
        XCTAssertEqual(v[0].text, "For God so loved the world, that he gave his only Son.")
        XCTAssertEqual(v[2].text, "He who believes")
    }

    func testCSVAndFreeUseJSONImport() throws {
        let dir = tempDir()
        let csv = dir.appendingPathComponent("bible.csv")
        try "book,chapter,verse,text\nJHN,3,16,\"For God so loved, the world\"\nPsalms,23,1,The LORD is my shepherd\n"
            .write(to: csv, atomically: true, encoding: .utf8)
        let a = try BibleImporter.importFiles([csv], into: dir)
        XCTAssertEqual(a.verseCount, 2)
        let s = try XCTUnwrap(BibleLibrary(directory: dir).store(a.id))
        XCTAssertEqual(s.verses(ScriptureReference(book: 43, startChapter: 3, startVerse: 16, endVerse: 16)).first?.text, "For God so loved, the world")

        let json = dir.appendingPathComponent("BSB.json")
        try """
        {"translation":{"id":"BSB","name":"Berean Standard Bible","shortName":"BSB","language":"eng"},
         "books":[{"id":"JHN","name":"John","commonName":"John","chapters":[{"chapter":{"number":3,"content":[
           {"type":"heading","text":"For God So Loved the World"},{"type":"line_break"},
           {"type":"verse","number":16,"text":"For God so loved the world\\nthat He gave","footnotes":[]}]}}]},
           {"id":"TOB","name":"Tobit","chapters":[]}]}
        """.write(to: json, atomically: true, encoding: .utf8)
        let b = try BibleImporter.importFiles([json], into: dir)
        XCTAssertEqual(b.abbreviation, "BSB")
        let s2 = try XCTUnwrap(BibleLibrary(directory: dir).store(b.id))
        XCTAssertEqual(s2.verses(ScriptureReference(book: 43, startChapter: 3)).first?.text, "For God so loved the world that He gave")
    }
}
