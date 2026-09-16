import XCTest
@testable import PresentationKit

final class HelpImageAudioTests: XCTestCase {
    func testHelpContentIsWellFormed() {
        let ids = HelpIndex.topics.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate help ids")
        for t in HelpIndex.topics {
            XCTAssertFalse(t.steps.isEmpty, t.id)
            XCTAssertTrue(HelpIndex.categories.contains(t.category), t.id)
        }
        for c in HelpIndex.categories { XCTAssertFalse(HelpIndex.topics(in: c).isEmpty, c) }
    }

    func testHelpSearchRanksTools() {
        XCTAssertEqual(HelpIndex.search("blend").first?.id, "backgrounds")
        XCTAssertEqual(HelpIndex.search("projector").first?.id, "program-out")
        XCTAssertEqual(HelpIndex.search("find lyrics").first?.id, "find-lyrics")
        XCTAssertEqual(HelpIndex.search("preset").first?.id, "presets")
        XCTAssertEqual(HelpIndex.search("Équalizer").first?.id, "audio-effects")   // diacritics/case folded
        XCTAssertTrue(HelpIndex.search("zzzz nothing").isEmpty)
        XCTAssertEqual(HelpIndex.search("").count, HelpIndex.topics.count)
    }

    func testLookBlendDecodingDefaults() throws {
        let old = try JSONDecoder().decode(SlideLook.self, from: Data(#"{"name":"Old"}"#.utf8))
        XCTAssertEqual(old.mediaBlend, .normal)
        XCTAssertEqual(old.mediaOpacity, 1)
        var l = SlideLook(); l.mediaBlend = .multiply; l.mediaOpacity = 0.4; l.mediaBase = .gradient
        let back = try JSONDecoder().decode(SlideLook.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back.mediaBlend, .multiply); XCTAssertEqual(back.mediaBase, .gradient); XCTAssertEqual(back.mediaOpacity, 0.4)
    }

    func testOpenverseParse() {
        let json = """
        {"result_count":2,"results":[
         {"id":"abc","title":"Sunrise <b>hills</b>","url":"https://live.staticflickr.com/1/a.jpg","thumbnail":"https://api.openverse.org/v1/images/abc/thumb/",
          "width":1600,"height":900,"creator":"Ama","license":"by","license_version":"4.0","foreign_landing_url":"https://flickr.com/p/1"},
         {"id":"def","title":"Cross","url":"https://upload.wikimedia.org/x.png","width":800,"height":800,"creator":"","license":"cc0"}
        ]}
        """
        let r = ImageSearch.parseOpenverse(Data(json.utf8))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].title, "Sunrise hills")
        XCTAssertEqual(r[0].license, "CC BY 4.0")
        XCTAssertEqual(r[0].attribution, "Sunrise hills — Ama (CC BY 4.0) via Openverse")
        XCTAssertEqual(r[1].license, "CC0")
        XCTAssertEqual(r[1].thumbnailURL, r[1].imageURL)
        XCTAssertEqual(ImageSearch.filter(r, .wide).map { $0.id }, ["ov-abc"])
        XCTAssertEqual(ImageSearch.filter(r, .square).map { $0.id }, ["ov-def"])
    }

    func testWikimediaParse() {
        let json = """
        {"query":{"pages":{
          "22":{"pageid":22,"index":2,"title":"File:Second.jpg","imageinfo":[{"url":"https://upload.wikimedia.org/2.jpg","thumburl":"https://upload.wikimedia.org/t2.jpg","width":400,"height":300,"mime":"image/jpeg","descriptionurl":"https://commons.wikimedia.org/wiki/File:Second.jpg","extmetadata":{"Artist":{"value":"<a href='x'>Kofi</a>"},"LicenseShortName":{"value":"CC BY-SA 4.0"}}}]},
          "11":{"pageid":11,"index":1,"title":"File:First photo.png","imageinfo":[{"url":"https://upload.wikimedia.org/1.png","width":1000,"height":500,"mime":"image/png"}]},
          "33":{"pageid":33,"index":3,"title":"File:Logo.svg","imageinfo":[{"url":"https://upload.wikimedia.org/3.svg","mime":"image/svg+xml"}]}
        }}}
        """
        let r = ImageSearch.parseWikimedia(Data(json.utf8))
        XCTAssertEqual(r.map { $0.title }, ["First photo", "Second"])
        XCTAssertEqual(r[1].creator, "Kofi")
        XCTAssertEqual(r[1].license, "CC BY-SA 4.0")
        XCTAssertTrue(ImageSearch.url(.wikimedia, query: "church")?.absoluteString.contains("gsrsearch=church") == true)
        XCTAssertEqual(ImageSearch.url(.openverse, query: "cross", orientation: .wide)?.absoluteString,
                       "https://api.openverse.org/v1/images/?q=cross&page_size=20&page=1&aspect_ratio=wide")
    }

    func testAudioMath() {
        XCTAssertEqual(AudioMath.dbToGain(0), 1, accuracy: 1e-9)
        XCTAssertEqual(AudioMath.dbToGain(-60), 0)
        XCTAssertEqual(AudioMath.gainToDB(2), 6.0206, accuracy: 1e-3)
        let c = AudioMath.panGains(0)
        XCTAssertEqual(c.left, 1, accuracy: 1e-9); XCTAssertEqual(c.right, 1, accuracy: 1e-9)
        let l = AudioMath.panGains(-100)
        XCTAssertEqual(l.right, 0, accuracy: 1e-9)
        for db in [-60.0, -45, -30, -12, 0, 4, 10] {
            XCTAssertEqual(AudioMath.faderDB(position: AudioMath.faderPosition(db: db)), db, accuracy: 1e-6)
        }
        XCTAssertEqual(AudioMath.dbText(4), "+4.00")
        XCTAssertEqual(AudioMath.dbText(-80), "-∞")
    }
}

final class HelpV44Tests: XCTestCase {
    func testNewTopicsAreFindable() {
        XCTAssertEqual(HelpIndex.search("automate lower third").first?.id, "automation")
        XCTAssertEqual(HelpIndex.search("generate abstract").first?.id, "generator")
        XCTAssertEqual(HelpIndex.search("parallel versions").first?.id, "parallel-bible")
        XCTAssertEqual(HelpIndex.search("royalty free video").first?.id, "backgrounds-library")
        XCTAssertEqual(HelpIndex.search("feedback").first?.id, "monitor")
    }
}

final class HelpV45Tests: XCTestCase {
    func testV45Topics() {
        XCTAssertEqual(HelpIndex.search("preview key").first?.id, "keys")
        XCTAssertEqual(HelpIndex.search("context menu").first?.id, "right-click")
        XCTAssertEqual(HelpIndex.search("projector").first?.id, "program-out")
        XCTAssertTrue(HelpIndex.search("meter").contains { $0.id == "program-meter" })
    }
}

final class HelpV46Tests: XCTestCase {
    func testV46Topics() {
        XCTAssertEqual(HelpIndex.search("chatgpt").first?.id, "ai-search")
        XCTAssertEqual(HelpIndex.search("drag and drop").first?.id, "local-media")
        XCTAssertEqual(HelpIndex.search("stock video").first?.id, "web-videos")
        XCTAssertEqual(HelpIndex.search("resize panel").first?.id, "panel-size")
    }
}

final class HelpV47Tests: XCTestCase {
    func testNetworkTopics() {
        XCTAssertEqual(HelpIndex.search("multiple computers").first?.id, "network")
        XCTAssertEqual(HelpIndex.search("intercom").first?.id, "network-chat")
        XCTAssertEqual(HelpIndex.search("send song").first?.id, "network-share")
    }
}

final class HelpV48Tests: XCTestCase {
    func testV48Topics() {
        XCTAssertEqual(HelpIndex.search("zoom meeting").first?.id, "zoom")
        XCTAssertEqual(HelpIndex.search("walk-in playlist").first?.id, "playlist")
        XCTAssertEqual(HelpIndex.search("switch cameras").first?.id, "bus-keys")
        XCTAssertEqual(HelpIndex.search("assign keys").first?.id, "shortcuts")
    }
}

final class HelpV49Tests: XCTestCase {
    func testV49Topics() {
        XCTAssertEqual(HelpIndex.search("confidence monitor").first?.id, "stage-display")
        XCTAssertEqual(HelpIndex.search("youtube chapters").first?.id, "markers")
        XCTAssertEqual(HelpIndex.search("which verse says").first?.id, "bible-search")
        XCTAssertEqual(HelpIndex.search("before service").first?.id, "preflight")
        XCTAssertEqual(HelpIndex.search("crash").first?.id, "recovery")
    }
}
