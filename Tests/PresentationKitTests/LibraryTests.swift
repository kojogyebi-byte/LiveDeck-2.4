import XCTest
@testable import PresentationKit

final class LibraryTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)") }

    func testSaveReloadSearchDuplicateDeleteRestore() throws {
        let r = root()
        let lib = PresentationLibrary(root: r)
        var s = Song(title: "Amazing Grace", author: "John Newton")
        s.lyricText = "Verse 1\nAmazing grace how sweet the sound"
        s.meta.folder = "Hymns"
        try lib.songs.save(s)
        try lib.songs.save(Song(title: "Blessed Assurance"))

        let again = PresentationLibrary(root: r)
        XCTAssertEqual(again.songs.all.map { $0.title }, ["Amazing Grace", "Blessed Assurance"])
        XCTAssertEqual(again.songs.search("sweet sound").map { $0.title }, ["Amazing Grace"])
        XCTAssertEqual(again.songs.search("newton").count, 1)
        XCTAssertEqual(again.songs.search("", folder: "Hymns").count, 1)
        XCTAssertEqual(again.songs.folders, ["Hymns"])

        let dup = try XCTUnwrap(again.songs.duplicate(s.id))
        XCTAssertNotEqual(dup.id, s.id)
        XCTAssertEqual(dup.title, "Amazing Grace copy")
        try again.songs.setFavorite(dup.id, true)
        XCTAssertEqual(again.songs.search("", favoritesOnly: true).map { $0.id }, [dup.id])

        try again.songs.delete(s.id)
        XCTAssertNil(again.songs[s.id])
        XCTAssertEqual(again.songs.trashed.map { $0.id }, [s.id])
        try again.songs.restoreFromTrash(s.id)
        XCTAssertNotNil(PresentationLibrary(root: r).songs[s.id])
    }

    func testVersionsAndRestore() throws {
        let lib = PresentationLibrary(root: root())
        lib.songs.versionInterval = 0
        var s = Song(title: "V1")
        try lib.songs.save(s)
        s.title = "V2"; try lib.songs.save(s)
        s.title = "V3"; try lib.songs.save(s)
        let versions = lib.songs.versions(of: s.id)
        XCTAssertEqual(versions.count, 2)
        let restored = try lib.songs.restoreVersion(versions.last!.url)
        XCTAssertEqual(restored.title, "V1")
        XCTAssertEqual(lib.songs.versions(of: s.id).count, 3)
    }

    func testDamagedFileIsQuarantinedNotFatal() throws {
        let r = root()
        let lib = PresentationLibrary(root: r)
        try lib.songs.save(Song(title: "Good"))
        try Data("{not json".utf8).write(to: r.appendingPathComponent("Songs/broken.json"))
        let again = PresentationLibrary(root: r)
        XCTAssertEqual(again.songs.all.count, 1)
        XCTAssertEqual(again.songs.damaged, ["broken.json"])
    }

    func testPresentationAndServiceRoundTrip() throws {
        let lib = PresentationLibrary(root: root())
        var p = Presentation(title: "Announcements", kind: .announcement)
        p.slides = [Slide(label: "Welcome", elements: [.textBox("Welcome", role: .title, style: TextStyle(), in: ElementFrame(x: 0, y: 0, width: 100, height: 100))])]
        try lib.presentations.save(p)
        let plan = ServicePlan(title: "Sunday", items: [ServiceItem(title: "Opening Song", kind: .song), ServiceItem(title: "Scripture", kind: .scripture, scripture: "John 3:16")])
        try lib.services.save(plan)
        let again = PresentationLibrary(root: lib.root)
        XCTAssertEqual(again.presentations.all.first?.slides.first?.plainText, "Welcome")
        XCTAssertEqual(again.services.all.first?.items.count, 2)
        XCTAssertEqual(again.presentations.search("welcome").count, 1)
    }

    func testColorHex() {
        XCTAssertEqual(RGBAColor(hex: "#FF8000")?.hex, "#FF8000")
        XCTAssertEqual(RGBAColor(hex: "00000080")?.a ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertNil(RGBAColor(hex: "xyz"))
    }
}
