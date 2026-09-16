import XCTest
@testable import PresentationKit

final class SongTests: XCTestCase {
    func testHeaderDetection() {
        XCTAssertEqual(SectionKind.parseHeader("Verse 1")?.0, .verse)
        XCTAssertEqual(SectionKind.parseHeader("Verse 1")?.1, 1)
        XCTAssertEqual(SectionKind.parseHeader("[Chorus 2]")?.1, 2)
        XCTAssertEqual(SectionKind.parseHeader("Pre-Chorus:")?.0, .preChorus)
        XCTAssertEqual(SectionKind.parseHeader("V2")?.0, .verse)
        XCTAssertEqual(SectionKind.parseHeader("Refrain")?.0, .chorus)
        XCTAssertNil(SectionKind.parseHeader("Amazing grace how sweet the sound"))
        XCTAssertNil(SectionKind.parseHeader("Verse of my heart"))
    }

    func testTypedLyricsParseAndRoundTrip() {
        let text = """
        Verse 1
        Amazing grace how sweet the sound
        That saved a wretch like me

        I once was lost but now am found
        Was blind but now I see

        Chorus
        My chains are gone
        I've been set free
        """
        let secs = SongText.parse(text)
        XCTAssertEqual(secs.count, 2)
        XCTAssertEqual(secs[0].slides.count, 2)
        XCTAssertEqual(secs[1].kind, .chorus)
        XCTAssertEqual(SongText.parse(SongText.format(secs)).map { $0.lines }, secs.map { $0.lines })
    }

    func testUnheadedParagraphsBecomeVerses() {
        let secs = SongText.parse("Line a\nLine b\n\nLine c\nLine d\n\nLine e")
        XCTAssertEqual(secs.count, 3)
        XCTAssertEqual(secs.map { $0.code }, ["V1", "V2", "V3"])
    }

    func testArrangementAndLinesPerSlide() {
        var song = Song(title: "T")
        song.lyricText = "Verse 1\na\nb\nc\nd\n\nChorus\ne\nf\n\nVerse 2\ng\nh"
        song.arrangement = "V1 C V2 C"
        XCTAssertEqual(song.orderedSections().map { $0.code }, ["V1", "C", "V2", "C"])
        XCTAssertEqual(song.generatedSlides(linesPerSlide: 2).count, 2 + 1 + 1 + 1)
        XCTAssertEqual(song.generatedSlides(linesPerSlide: 0).first?.lines, ["a", "b", "c", "d"])
        let slides = song.slides(theme: .standard)
        XCTAssertEqual(slides.first?.elements.first?.text?.role, .lyrics)
        XCTAssertEqual(slides.count, 4)
    }

    func testRepeatedChorusMergesIntoArrangement() {
        let s = SongImporter.plainText("Verse 1\na\nChorus\nx\ny\nVerse 2\nb\nChorus\nx\ny", fallbackTitle: "S")
        XCTAssertEqual(s.sections.count, 3)
        XCTAssertEqual(s.arrangement, "V1 C V2 C")
    }

    func testSongSelectText() throws {
        let txt = """
        Great Is Thy Faithfulness

        Verse 1
        Great is Thy faithfulness
        O God my Father

        Chorus
        Great is Thy faithfulness
        Great is Thy faithfulness

        CCLI Song # 18723
        Thomas Obediah Chisholm | William Marion Runyan
        © 1923. Ren. 1951 Hope Publishing Company
        For use solely with the SongSelect® Terms of Use.  All rights reserved. www.ccli.com
        CCLI License # 1234567
        """
        let songs = try SongImporter.parse(Data(txt.utf8), filename: "great.txt")
        XCTAssertEqual(songs.count, 1)
        let s = songs[0]
        XCTAssertEqual(s.title, "Great Is Thy Faithfulness")
        XCTAssertEqual(s.ccliNumber, "18723")
        XCTAssertTrue(s.author.contains("Chisholm"))
        XCTAssertTrue(s.copyright.contains("1923"))
        XCTAssertEqual(s.sections.map { $0.code }, ["V1", "C"])
        XCTAssertFalse(s.searchText.contains("terms of use"))
    }

    func testSongSelectUSR() throws {
        let usr = """
        [File]
        Type=SongSelect Import File
        Version=3.0
        [S A123456]
        Title=Test Song
        Author=Jane Doe|John Doe
        Copyright=Public Domain
        Keys=G
        Fields=Verse 1/tChorus/tVerse 2
        Words=Line one/nLine two/tChorus one/nChorus two/tLine three/nLine four
        """
        let songs = try SongImporter.parse(Data(usr.utf8), filename: "x.usr")
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs[0].ccliNumber, "123456")
        XCTAssertEqual(songs[0].author, "Jane Doe, John Doe")
        XCTAssertEqual(songs[0].sections.map { $0.code }, ["V1", "C", "V2"])
        XCTAssertEqual(songs[0].sections[1].lines, ["Chorus one", "Chorus two"])
    }

    func testChordPro() throws {
        let cho = """
        {title: Blessed Assurance}
        {artist: Fanny Crosby}
        # comment
        {comment: Verse 1}
        [D]Blessed as[G]surance, [D]Jesus is mine
        {start_of_chorus}
        [D]This is my story, [A]this is my song
        {end_of_chorus}
        """
        let s = try SongImporter.parse(Data(cho.utf8), filename: "b.cho")[0]
        XCTAssertEqual(s.title, "Blessed Assurance")
        XCTAssertEqual(s.author, "Fanny Crosby")
        XCTAssertEqual(s.sections.first?.lines.first, "Blessed assurance, Jesus is mine")
        XCTAssertEqual(s.sections.last?.kind, .chorus)
    }

    func testOpenLyrics() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <song xmlns="http://openlyrics.info/namespace/2009/song" version="0.8">
          <properties>
            <titles><title>Amazing Grace</title></titles>
            <authors><author>John Newton</author></authors>
            <verseOrder>v1 c v2 c</verseOrder>
          </properties>
          <lyrics>
            <verse name="v1"><lines>Amazing grace how <chord name="D"/>sweet the sound<br/>That saved a wretch like me</lines></verse>
            <verse name="c"><lines>My chains are gone</lines><lines>I've been set free</lines></verse>
            <verse name="v2"><lines>'Twas grace that taught<br/>my heart to fear</lines></verse>
          </lyrics>
        </song>
        """
        let s = try SongImporter.parse(Data(xml.utf8), filename: "a.xml")[0]
        XCTAssertEqual(s.title, "Amazing Grace")
        XCTAssertEqual(s.sections.count, 3)
        XCTAssertEqual(s.sections[0].lines, ["Amazing grace how sweet the sound", "That saved a wretch like me"])
        XCTAssertEqual(s.sections[1].slides.count, 2)
        XCTAssertEqual(s.arrangement, "V1 C V2 C")
    }

    func testOpenSong() throws {
        let xml = """
        <song><title>How Great</title><author>A</author>
        <presentation>V1 C</presentation>
        <lyrics>[V1]
        .G       C
         O Lord my God
         When I in awesome wonder
        [C]
         Then sings my soul</lyrics></song>
        """
        let s = try SongImporter.parse(Data(xml.utf8), filename: "h")[0]
        XCTAssertEqual(s.title, "How Great")
        XCTAssertEqual(s.sections.map { $0.code }, ["V1", "C"])
        XCTAssertEqual(s.sections[0].lines, ["O Lord my God", "When I in awesome wonder"])
    }

    func testTolerantDecodingOfOldFiles() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","meta":{"title":"Old"},"sections":[{"kind":"verse","slides":[["a"]]}]}"#
        let s = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        XCTAssertEqual(s.title, "Old")
        XCTAssertEqual(s.sections.first?.lines, ["a"])
        XCTAssertEqual(s.linesPerSlide, 0)
    }
}
