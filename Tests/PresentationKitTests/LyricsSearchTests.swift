import XCTest
@testable import PresentationKit

final class LyricsSearchTests: XCTestCase {
    func testURLs() {
        XCTAssertEqual(LyricsSearch.lrclibURL(query: "", title: "Way Maker", artist: "Sinach")?.absoluteString,
                       "https://lrclib.net/api/search?track_name=Way%20Maker&artist_name=Sinach")
        XCTAssertEqual(LyricsSearch.lrclibURL(query: "you are here moving")?.absoluteString,
                       "https://lrclib.net/api/search?q=you%20are%20here%20moving")
        XCTAssertNil(LyricsSearch.lrclibURL(query: "  "))
        XCTAssertEqual(LyricsSearch.lyricsOvhURL(artist: "AC/DC", title: "Back in Black")?.absoluteString,
                       "https://api.lyrics.ovh/v1/AC%2FDC/Back%20in%20Black")
        XCTAssertNil(LyricsSearch.lyricsOvhURL(artist: "", title: "x"))
        XCTAssertEqual(LyricsWebSite.all.first?.url(for: "Amazing grace")?.absoluteString, "https://hymnary.org/search?qu=Amazing%20grace")
    }

    func testParseLRCLIBSkipsEmptyInstrumentalAndDuplicates() {
        let json = """
        [
         {"id":1,"trackName":"Song A","artistName":"Choir","albumName":"Live","duration":200,"instrumental":false,
          "plainLyrics":"Line one  \\r\\nLine two\\n\\n\\n\\nLine three\\n","syncedLyrics":null},
         {"id":2,"trackName":"Song A","artistName":"Choir","albumName":"Studio","duration":201,"instrumental":false,
          "plainLyrics":"Line one\\nLine two\\n\\nLine three","syncedLyrics":null},
         {"id":3,"trackName":"Tune","artistName":"Band","instrumental":true,"plainLyrics":null,"syncedLyrics":null},
         {"id":4,"trackName":"Empty","artistName":"Band","instrumental":false,"plainLyrics":null,"syncedLyrics":null},
         {"id":5,"trackName":"Synced only","artistName":"Band","instrumental":false,"plainLyrics":null,
          "syncedLyrics":"[ar:Band]\\n[00:01.00] Hello\\n[00:02.50][00:10.00] World"}
        ]
        """
        let hits = LyricsSearch.parseLRCLIB(Data(json.utf8))
        XCTAssertEqual(hits.map { $0.id }, ["lrclib-1", "lrclib-5"])
        XCTAssertEqual(hits[0].lyrics, "Line one\nLine two\n\nLine three")
        XCTAssertEqual(hits[1].lyrics, "Hello\nWorld")
        XCTAssertEqual(hits[0].firstLine, "Line one")
    }

    func testParseLyricsOvhStripsHeader() {
        let json = #"{"lyrics":"Paroles de la chanson Hymn par Someone\r\nFirst line\r\nSecond line\n\n\nThird"}"#
        let h = LyricsSearch.parseLyricsOvh(Data(json.utf8), artist: "Someone", title: "Hymn")
        XCTAssertEqual(h?.lyrics, "First line\nSecond line\n\nThird")
        XCTAssertNil(LyricsSearch.parseLyricsOvh(Data(#"{"error":"No lyrics found"}"#.utf8), artist: "a", title: "b"))
    }

    func testSongFromEditedLyrics() {
        let text = "[Verse 1]\nWords of verse one\nSecond line\n\n[Chorus]\nChorus line\n\n[Verse 2]\nVerse two\n\n[Chorus]\nChorus line"
        let s = LyricsSearch.song(title: "My Song", artist: "Writer", lyrics: text, source: "LRCLIB")
        XCTAssertEqual(s.title, "My Song")
        XCTAssertEqual(s.author, "Writer")
        XCTAssertEqual(s.source, "LRCLIB")
        XCTAssertGreaterThanOrEqual(s.sections.count, 3)
        XCTAssertFalse(s.generatedSlides().isEmpty)
    }
}
