import XCTest
@testable import PresentationKit

final class LookAndDictionaryTests: XCTestCase {
    func testLookRegionsAndMargins() {
        var l = SlideLook()
        l.marginX = 0.05; l.marginY = 0.1
        let full = l.textRegion(width: 1920, height: 1080)
        XCTAssertEqual(full.x, 96, accuracy: 0.01); XCTAssertEqual(full.y, 108, accuracy: 0.01)
        XCTAssertEqual(full.width, 1728, accuracy: 0.01); XCTAssertEqual(full.height, 864, accuracy: 0.01)
        l.region = .lowerThird; l.marginX = 0; l.marginY = 0
        let lt = l.textRegion(width: 1920, height: 1080)
        XCTAssertEqual(lt.y, 1080 * 0.64, accuracy: 0.01)
        l.region = .custom; l.custom = ElementFrame(x: 0.9, y: 0.9, width: 0.5, height: 0.5)   // clamped inside screen
        let c = l.textRegion(width: 1000, height: 1000)
        XCTAssertLessThanOrEqual(c.x + c.width, 1000.01)
    }

    func testLookCodableToleratesOldFilesAndLibrarySaves() throws {
        let json = #"{"name":"Old","region":"Lower third","body":{"size":40}}"#
        let l = try JSONDecoder().decode(SlideLook.self, from: Data(json.utf8))
        XCTAssertEqual(l.region, .lowerThird)
        XCTAssertEqual(l.body.size, 40)
        XCTAssertEqual(l.maxCharsPerSlide, 280)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("looks-\(UUID().uuidString)")
        let lib = LookLibrary(libraryRoot: root)
        try lib.save(SlideLook.lowerThirdKey, as: "Sunday lyrics")
        try lib.save(SlideLook.fullScreen, as: "Sunday lyrics")          // same name → replaced
        let again = LookLibrary(libraryRoot: root)
        XCTAssertEqual(again.looks.count, 1)
        XCTAssertEqual(again.looks.first?.region, .full)
        XCTAssertEqual(again.all.count, SlideLook.builtIn.count + 1)
    }

    func testFreeDictionaryParse() {
        let json = """
        [{"word":"grace","phonetic":"/ɡɹeɪs/","meanings":[
          {"partOfSpeech":"noun","definitions":[{"definition":"Elegant movement.","example":"She moved with grace."},{"definition":"Free and undeserved favour."}],"synonyms":["elegance"],"antonyms":["clumsiness"]},
          {"partOfSpeech":"verb","definitions":[{"definition":"To adorn."}]}]}]
        """
        let e = WordLookup.parseFreeDictionary(Data(json.utf8))
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].phonetic, "/ɡɹeɪs/")
        XCTAssertEqual(e[0].senses.count, 3)
        XCTAssertEqual(e[0].synonyms, ["elegance"])
        let body = e[0].bodyText(maxSenses: 2, examples: true)
        XCTAssertTrue(body.hasPrefix("1. (noun) Elegant movement."))
        XCTAssertTrue(body.contains("She moved with grace."))
        XCTAssertFalse(body.contains("adorn"))
    }

    func testWiktionaryParse() {
        let json = """
        {"en":[{"partOfSpeech":"Noun","language":"English","definitions":[{"definition":"<span>Charming, pleasing <a href=\\"x\\">qualities</a>.</span>","examples":["<i>She has much grace</i>"]}]}],
         "fr":[{"partOfSpeech":"Nom","language":"French","definitions":[{"definition":"grâce &amp; faveur"}]}]}
        """
        let en = WordLookup.parseWiktionary(Data(json.utf8), word: "grace", language: "en")
        XCTAssertEqual(en.first?.senses.first?.definition, "Charming, pleasing qualities.")
        XCTAssertEqual(en.first?.senses.first?.example, "She has much grace")
        let fr = WordLookup.parseWiktionary(Data(json.utf8), word: "grâce", language: "fr")
        XCTAssertEqual(fr.first?.senses.first?.definition, "grâce & faveur")
        XCTAssertTrue(fr.first?.source.contains("French") == true)
    }

    func testWikipediaAndDatamuseParse() {
        let wiki = #"{"type":"standard","title":"Kumasi","description":"City in Ghana","extract":"Kumasi is a city in the Ashanti Region. It is among the largest metropolitan areas in Ghana."}"#
        let w = WordLookup.parseWikipedia(Data(wiki.utf8))
        XCTAssertEqual(w.first?.word, "Kumasi")
        XCTAssertEqual(w.first?.senses.count, 2)
        XCTAssertTrue(w.first?.source.contains("City in Ghana") == true)

        let defs = #"[{"word":"hope","score":1,"defs":["n\tExpectation of good.","v\tTo want something to happen."]}]"#
        let d = WordLookup.parseDatamuseDefinitions(Data(defs.utf8), word: "hope")
        XCTAssertEqual(d.senses.map { $0.partOfSpeech }, ["noun", "verb"])
        XCTAssertEqual(WordLookup.parseDatamuseWords(Data(#"[{"word":"faith"},{"word":"trust"}]"#.utf8)), ["faith", "trust"])
    }

    func testPlainDefinitionSplitting() {
        let e = WordLookup.entryFromPlainDefinition(word: "grace", text: "grace | ɡreɪs | noun 1 simple elegance 2 courteous goodwill", source: "macOS")
        XCTAssertGreaterThanOrEqual(e.senses.count, 2)
    }

    func testURLs() {
        XCTAssertEqual(WordLookup.url(.english, word: "Grace")?.absoluteString, "https://api.dictionaryapi.dev/api/v2/entries/en/grace")
        XCTAssertEqual(WordLookup.url(.wikipedia, word: "Holy Spirit", language: "fr")?.absoluteString, "https://fr.wikipedia.org/api/rest_v1/page/summary/Holy_Spirit")
        XCTAssertNil(WordLookup.url(.macOS, word: "x"))
    }

    func testCustomDictionaryImportAndLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dict-\(UUID().uuidString)")
        let store = CustomDictionaryStore(libraryRoot: root)
        let csv = root.appendingPathComponent("eastons.csv")
        try "word,definition\nAbba,\"Father, a Chaldee word\"\nAbel,Breath; the second son of Adam\nAbraham,Father of a multitude\n"
            .write(to: csv, atomically: true, encoding: .utf8)
        let d = try store.importFile(csv, name: "Bible Dictionary")
        XCTAssertEqual(d.entries.count, 3)
        XCTAssertEqual(store.lookup("abba").first?.senses.first?.definition, "Father, a Chaldee word")
        XCTAssertEqual(store.lookup("ab").count, 3)
        store.setEnabled(d.id, false)
        XCTAssertTrue(store.lookup("abba").isEmpty)
        let json = root.appendingPathComponent("glossary.json")
        try #"[{"term":"Selah","meaning":"A pause"}]"#.write(to: json, atomically: true, encoding: .utf8)
        try store.importFile(json)
        XCTAssertEqual(CustomDictionaryStore(libraryRoot: root).lookup("selah").first?.source, "glossary")
    }
}
