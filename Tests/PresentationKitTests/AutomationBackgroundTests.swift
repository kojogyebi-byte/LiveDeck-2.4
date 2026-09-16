import XCTest
@testable import PresentationKit

final class AutomationBackgroundTests: XCTestCase {
    func ctx(_ t: Double, sod: Int = 0, pgm: String? = nil, rec: Bool = false, stream: Bool = false) -> AutomationContext {
        AutomationContext(time: t, secondsOfDay: sod, programInputID: pgm, recording: rec, streaming: stream)
    }

    func testAfterStartWithHold() {
        let s = AutomationScheduler()
        let r = AutomationRule(trigger: .afterStart, delay: 5, action: .show, target: .overlay, targetID: "L1", holdSeconds: 3)
        s.start(at: 100)
        XCTAssertTrue(s.tick([r], ctx(104)).isEmpty)
        let fire = s.tick([r], ctx(105))
        XCTAssertEqual(fire.map { $0.action }, [.show])
        XCTAssertTrue(s.tick([r], ctx(107)).isEmpty)
        let undo = s.tick([r], ctx(108.1))
        XCTAssertEqual(undo.first?.action, .hide)
        XCTAssertEqual(undo.first?.isUndo, true)
        XCTAssertTrue(s.tick([r], ctx(200)).isEmpty, "afterStart fires once")
    }

    func testRepeatingAndMaxRuns() {
        let s = AutomationScheduler()
        let r = AutomationRule(trigger: .repeating, delay: 0, interval: 10, action: .toggle, target: .keyInput, targetID: "K", holdSeconds: 0, maxRuns: 2)
        s.start(at: 0)
        XCTAssertEqual(s.tick([r], ctx(0)).count, 1)
        XCTAssertEqual(s.tick([r], ctx(5)).count, 0)
        XCTAssertEqual(s.tick([r], ctx(10)).count, 1)
        XCTAssertEqual(s.tick([r], ctx(20)).count, 0, "max runs reached")
        XCTAssertEqual(s.runs(r.id), 2)
    }

    func testClockTimeCrossingIncludingMidnight() {
        let s = AutomationScheduler()
        let r = AutomationRule(trigger: .clockTime, timeOfDay: 30, action: .show, holdSeconds: 0)
        s.start(at: 0)
        _ = s.tick([r], ctx(0, sod: 86390))
        XCTAssertTrue(s.tick([r], ctx(10, sod: 20)).isEmpty)
        XCTAssertEqual(s.tick([r], ctx(11, sod: 30)).count, 1)
        let m = AutomationRule(trigger: .clockTime, timeOfDay: 5, action: .show, holdSeconds: 0)
        let s2 = AutomationScheduler(); s2.start(at: 0)
        _ = s2.tick([m], ctx(0, sod: 86398))
        XCTAssertEqual(s2.tick([m], ctx(8, sod: 6)).count, 1, "crossed midnight")
        XCTAssertEqual(s2.secondsUntilNext(m, ctx(9, sod: 7)), 86398)
    }

    func testOnProgramDelayRevertAndCancel() {
        let s = AutomationScheduler()
        let r = AutomationRule(trigger: .onProgram, delay: 2, watchInputID: "CAM2", action: .show, target: .overlay, targetID: "LT",
                               holdSeconds: 0, revertWhenEnds: true)
        s.start(at: 0)
        _ = s.tick([r], ctx(0, pgm: "CAM1"))
        XCTAssertTrue(s.tick([r], ctx(1, pgm: "CAM2")).isEmpty)
        XCTAssertEqual(s.tick([r], ctx(3, pgm: "CAM2")).map { $0.action }, [.show])
        XCTAssertEqual(s.tick([r], ctx(4, pgm: "CAM1")).map { $0.action }, [.hide])
        // leaving before the delay cancels
        _ = s.tick([r], ctx(5, pgm: "CAM2"))
        XCTAssertTrue(s.tick([r], ctx(6, pgm: "CAM1")).isEmpty)
        XCTAssertTrue(s.tick([r], ctx(8, pgm: "CAM1")).isEmpty)
    }

    func testRecordingEdgeAndRunNowAndCodable() throws {
        let s = AutomationScheduler()
        let r = AutomationRule(trigger: .onRecording, delay: 0, action: .show, holdSeconds: 0)
        s.start(at: 0)
        _ = s.tick([r], ctx(0, rec: false))
        XCTAssertEqual(s.tick([r], ctx(1, rec: true)).count, 1)
        XCTAssertEqual(s.runNow(r, at: 2).first?.action, .show)
        let old = try JSONDecoder().decode(AutomationRule.self, from: Data(#"{"name":"LT","trigger":"When recording starts"}"#.utf8))
        XCTAssertEqual(old.trigger, .onRecording)
        XCTAssertEqual(old.holdSeconds, 8)
        XCTAssertEqual(AutomationRule.timeText(3725), "01:02:05")
    }

    func testParallelScriptureKeepsVersionsAligned() {
        func v(_ n: Int, _ t: String) -> BibleVerse { BibleVerse(book: 43, chapter: 3, verse: n, text: t) }
        let primary = [v(16, String(repeating: "a", count: 100)), v(17, String(repeating: "b", count: 100)), v(18, "short")]
        let other = [v(16, String(repeating: "x", count: 150)), v(17, String(repeating: "y", count: 150)), v(18, "tiny")]
        let slides = ParallelScripture.slides(primaryLabel: "KJV", primary: primary, others: [(label: "ASA", verses: other)], maxChars: 260, verseNumbers: false)
        XCTAssertEqual(slides.count, 2, "the longer version decides the split")
        XCTAssertEqual(slides[0].first.verse, 16); XCTAssertEqual(slides[0].last.verse, 16)
        XCTAssertEqual(slides[1].first.verse, 17); XCTAssertEqual(slides[1].last.verse, 18)
        XCTAssertEqual(slides[1].columns.map { $0.label }, ["KJV", "ASA"])
        XCTAssertTrue(slides[1].columns[1].text.hasSuffix("tiny"))
        let missing = ParallelScripture.slides(primaryLabel: "A", primary: [v(1, "one")], others: [(label: "B", verses: [])])
        XCTAssertEqual(missing.first?.columns[1].text, "")
    }

    func testLookParallelDefaults() throws {
        let l = try JSONDecoder().decode(SlideLook.self, from: Data(#"{"name":"Old"}"#.utf8))
        XCTAssertEqual(l.parallelLayout, .sideBySide)
        XCTAssertTrue(l.showVersionLabels)
    }

    func testBackgroundParsers() {
        let nasa = """
        {"collection":{"items":[{"data":[{"nasa_id":"GSFC_2016","title":"Earth rotating","media_type":"video","center":"GSFC"}],
          "links":[{"href":"https://images-assets.nasa.gov/video/GSFC_2016/GSFC_2016~thumb.jpg"},{"href":"https://x/captions.srt"}]}]}}
        """
        let items = BackgroundSearch.parseNASASearch(Data(nasa.utf8))
        XCTAssertEqual(items.first?.assetManifestID, "GSFC_2016")
        XCTAssertEqual(items.first?.kind, .video)
        XCTAssertEqual(items.first?.credit, "NASA GSFC")
        let asset = #"{"collection":{"items":[{"href":"http://images-assets.nasa.gov/video/A/A~orig.mp4"},{"href":"http://images-assets.nasa.gov/video/A/A~medium.mp4"},{"href":"http://images-assets.nasa.gov/video/A/A~thumb.jpg"}]}}"#
        XCTAssertEqual(BackgroundSearch.parseNASAAsset(Data(asset.utf8), kind: .video)?.absoluteString, "https://images-assets.nasa.gov/video/A/A~medium.mp4")

        let pixabay = """
        {"hits":[{"id":125,"pageURL":"https://pixabay.com/videos/id-125/","tags":"flowers, yellow","duration":12,"user":"Ama",
          "videos":{"large":{"url":"https://cdn.pixabay.com/125_large.mp4","width":3840,"height":2160,"size":9,"thumbnail":"https://cdn.pixabay.com/125_large.jpg"},
                    "medium":{"url":"https://cdn.pixabay.com/125_medium.mp4","width":1920,"height":1080,"size":6,"thumbnail":"https://cdn.pixabay.com/125_medium.jpg"}}}]}
        """
        let px = BackgroundSearch.parsePixabay(Data(pixabay.utf8), videos: true)
        XCTAssertEqual(px.first?.downloadURL?.absoluteString, "https://cdn.pixabay.com/125_medium.mp4", "skips 4K for smooth playback")
        XCTAssertEqual(px.first?.title, "Flowers, Yellow")

        let pexels = """
        {"videos":[{"id":9,"url":"https://www.pexels.com/video/9/","image":"https://images.pexels.com/9.jpg","duration":20,"user":{"name":"Kofi"},
          "video_files":[{"link":"https://v.pexels.com/9-uhd.mp4","file_type":"video/mp4","width":3840,"height":2160},
                         {"link":"https://v.pexels.com/9-hd.mp4","file_type":"video/mp4","width":1920,"height":1080},
                         {"link":"https://v.pexels.com/9-sd.mp4","file_type":"video/mp4","width":960,"height":540}]}]}
        """
        let pe = BackgroundSearch.parsePexels(Data(pexels.utf8), videos: true)
        XCTAssertEqual(pe.first?.downloadURL?.absoluteString, "https://v.pexels.com/9-hd.mp4")
        XCTAssertEqual(pe.first?.credit, "Kofi")
        XCTAssertNil(BackgroundSearch.searchURL(.pixabay, query: "sky", key: ""))
        XCTAssertEqual(BackgroundSearch.searchURL(.nasa, query: "earth from space")?.absoluteString,
                       "https://images-api.nasa.gov/search?q=earth%20from%20space&media_type=video&page=1")
    }

    func testBackgroundCatalogPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString)")
        let cat = BackgroundCatalog(libraryRoot: root)
        let tmp = root.appendingPathComponent("clip.mp4")
        try Data([1, 2, 3]).write(to: tmp)
        try cat.add(file: tmp, id: "nasa-1", title: "Earth", kind: .video, category: "Downloaded", provider: "NASA")
        cat.setFavorite("nasa-1", true)
        let again = BackgroundCatalog(libraryRoot: root)
        XCTAssertEqual(again.items.count, 1)
        XCTAssertTrue(again.items[0].favorite)
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.url(again.items[0]).path))
        again.remove("nasa-1")
        XCTAssertTrue(BackgroundCatalog(libraryRoot: root).items.isEmpty)
    }

    func testGeneratorSettings() throws {
        XCTAssertEqual(GeneratorSettings.hash(3, 1, 7), GeneratorSettings.hash(3, 1, 7))
        XCTAssertNotEqual(GeneratorSettings.hash(3, 1, 7), GeneratorSettings.hash(4, 1, 7))
        for i in 0..<200 { let h = GeneratorSettings.hash(i, 2, 9); XCTAssertTrue(h >= 0 && h < 1) }
        let g = try JSONDecoder().decode(GeneratorSettings.self, from: Data(#"{"style":"Snow","colors":[{"r":1,"g":1,"b":1,"a":1}]}"#.utf8))
        XCTAssertEqual(g.style, .snow)
        XCTAssertEqual(g.colors.count, 3)
        XCTAssertTrue(GeneratorStyle.snow.isEffect)
        XCTAssertFalse(GeneratorSettings.presets.isEmpty)
    }
}
