import XCTest
@testable import PresentationKit

final class BibleJSONImportTests: XCTestCase {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bj-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    let sample = """
    {"metadata":{"name":"Authorized King James Version w Strong's","shortname":"KJV Strongs","module":"kjv_strongs","lang":"English","lang_short":"en",
     "copyright_statement":"<p>This Bible is in the <b>Public Domain</b>.</p>"},
     "verses":[
      {"book_name":"Genesis","book":1,"chapter":4,"verse":21,"text":"And his brother's{H251} name{H8034} [was] Jubal{H3106}: he was the father{H1} of all such as handle{H8610}{(H8802)} the harp{H3658}"},
      {"book_name":"John","book":43,"chapter":3,"verse":16,"text":"\\u00b6 For God so loved the world , that he gave"}
     ]}
    """

    func testCleanText() {
        XCTAssertEqual(SuperSearchJSONReader.cleanText("And his brother's{H251} name{H8034} [was] Jubal{H3106}: he{(H8802)}"),
                       "And his brother's name was Jubal: he")
        XCTAssertEqual(SuperSearchJSONReader.cleanText("¶ In the <i>beginning</i> , God"), "In the beginning, God")
        XCTAssertEqual(SuperSearchJSONReader.cleanText("said unto him, ‹Suffer› [it to be so] ‹now›"), "said unto him, Suffer it to be so now")
        XCTAssertEqual(SuperSearchJSONReader.cleanText("God said,“Let there be light.”"), "God said, “Let there be light.”")
        XCTAssertEqual(SuperSearchJSONReader.cleanText("no help for him in God. {{Selah"), "no help for him in God. Selah")
    }

    func testImportDetectAndSkipDuplicates() throws {
        let src = tempDir(), lib = tempDir()
        let f = src.appendingPathComponent("kjv_strongs.json")
        try sample.write(to: f, atomically: true, encoding: .utf8)
        try Data("junk".utf8).write(to: src.appendingPathComponent("._kjv_strongs.json"))
        XCTAssertEqual(BibleImporter.detect(url: f), .superSearchJSON)
        XCTAssertEqual(BibleImporter.bibleFiles(in: [src]).count, 1, "macOS ._ files are ignored")
        let meta = SuperSearchJSONReader.peekMetadata(f)
        XCTAssertEqual(meta?.name, "Authorized King James Version w Strong's")
        XCTAssertEqual(meta?.abbreviation, "KJV+")

        let first = BibleImporter.importBatch([src], into: lib)
        XCTAssertEqual(first.imported.count, 1)
        XCTAssertTrue(first.failed.isEmpty, "\(first.failed)")
        let info = try XCTUnwrap(first.imported.first)
        XCTAssertEqual(info.verseCount, 2)
        XCTAssertEqual(info.language, "en")
        XCTAssertEqual(info.license, "This Bible is in the Public Domain.")
        let store = try XCTUnwrap(BibleLibrary(directory: lib).store(info.id))
        XCTAssertEqual(store.verses(ScriptureReference(book: 1, startChapter: 4, startVerse: 21, endVerse: 21)).first?.text,
                       "And his brother's name was Jubal: he was the father of all such as handle the harp")
        XCTAssertEqual(store.bookName(43), "John")

        let again = BibleImporter.importBatch([f], into: lib)
        XCTAssertEqual(again.imported.count, 0)
        XCTAssertEqual(again.skipped.count, 1)

        // ready-made .ldbible package installs into another library
        let other = tempDir()
        let pkg = BibleLibrary.fileURL(info.id, in: lib)
        let installed = try BibleLibrary.installPackage(pkg, into: other)
        XCTAssertEqual(installed.abbreviation, "KJV+")
        XCTAssertNotNil(BibleLibrary(directory: other).store(installed.id))
        XCTAssertThrowsError(try BibleLibrary.installPackage(pkg, into: other))
    }
}
