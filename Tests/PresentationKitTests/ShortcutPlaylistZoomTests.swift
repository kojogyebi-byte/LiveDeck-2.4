import XCTest
@testable import PresentationKit

final class ShortcutPlaylistZoomTests: XCTestCase {
    func testShortcutDefaultsHaveNoConflicts() {
        let d = ShortcutCatalog.defaults
        XCTAssertTrue(ShortcutCatalog.conflicts(d).isEmpty, "\(ShortcutCatalog.conflicts(d))")
        XCTAssertFalse(d.values.contains { $0.isReserved }, "defaults must avoid macOS shortcuts")
        XCTAssertEqual(Set(ShortcutCatalog.actions.map { $0.id }).count, ShortcutCatalog.actions.count)
        XCTAssertEqual(ShortcutCatalog.actionID(for: KeyCombo("C"), in: d), "cut")
        XCTAssertEqual(ShortcutCatalog.actionID(for: .opt("3"), in: d), "program.3")
        XCTAssertTrue(ShortcutCatalog.actions.allSatisfy { ShortcutCatalog.categories.contains($0.category) })
    }

    func testComboDisplayAndKeyNames() {
        XCTAssertEqual(KeyCombo("F", command: true, shift: true).display, "⇧⌘F")
        XCTAssertEqual(KeyCombo("1", option: true, control: true).display, "⌃⌥1")
        XCTAssertEqual(KeyCombo("Return").display, "↩")
        XCTAssertTrue(KeyCombo.cmd("Q").isReserved)
        XCTAssertFalse(KeyCombo("Q", command: true, shift: true).isReserved)
        XCTAssertEqual(KeyCombo.keyName(keyCode: 18, characters: "!"), "1", "shifted digits use the key code")
        XCTAssertEqual(KeyCombo.keyName(keyCode: 122, characters: nil), "F1")
        XCTAssertEqual(KeyCombo.keyName(keyCode: 0, characters: "a"), "A")
        let data = try! JSONEncoder().encode(KeyCombo.ctrl("5"))
        XCTAssertEqual(try? JSONDecoder().decode(KeyCombo.self, from: data), KeyCombo.ctrl("5"))
    }

    func testSmartFillKeepsUserChoicesAndFillsGaps() {
        var custom: [String: KeyCombo] = ["cut": KeyCombo("Space")]         // user moved CUT
        custom["record"] = nil
        let filled = ShortcutCatalog.smartFill(custom)
        XCTAssertEqual(filled["cut"], KeyCombo("Space"))
        XCTAssertEqual(filled["record"], KeyCombo("R"))
        XCTAssertEqual(filled.count, ShortcutCatalog.actions.count)
        XCTAssertTrue(ShortcutCatalog.conflicts(filled).isEmpty)
    }

    func testPlaylistOrdering() {
        var p = Playlist(items: [PlaylistItem(path: "/a.mp4", kind: .video), PlaylistItem(path: "/b.jpg", kind: .image, enabled: false),
                                 PlaylistItem(path: "/c.mp3", kind: .audio)])
        XCTAssertEqual(p.nextIndex(after: nil), 0)
        XCTAssertEqual(p.nextIndex(after: 0), 2, "disabled items are skipped")
        XCTAssertEqual(p.nextIndex(after: 2), 0, "loops")
        p.loop = false
        XCTAssertNil(p.nextIndex(after: 2))
        XCTAssertEqual(p.previousIndex(before: 2), 0)
        p.shuffle = true; p.loop = true
        XCTAssertEqual(p.nextIndex(after: 0, random: { 0.0 }), 2)
        XCTAssertEqual(p.seconds(for: p.items[1]), 8)
        var q = Playlist()
        XCTAssertEqual(q.add(paths: ["/x.mov", "/y.txt", "/z.PNG", "/s.m4a"]), 3)
        XCTAssertEqual(q.items.map { $0.kind }, [.video, .image, .audio])
        let old = try! JSONDecoder().decode(Playlist.self, from: Data(#"{"name":"Walk-in"}"#.utf8))
        XCTAssertEqual(old.imageSeconds, 8); XCTAssertTrue(old.startOnProgram)
    }

    func testZoomLinks() {
        let m = ZoomMeeting.parse("https://us02web.zoom.us/j/85012345678?pwd=AbC123")
        XCTAssertEqual(m?.id, "85012345678")
        XCTAssertEqual(m?.passcode, "AbC123")
        XCTAssertEqual(m?.displayID, "850 1234 5678")
        XCTAssertEqual(m?.appURL(displayName: "LiveDeck Media")?.absoluteString,
                       "zoommtg://zoom.us/join?action=join&confno=85012345678&pwd=AbC123&uname=LiveDeck%20Media")
        XCTAssertEqual(ZoomMeeting.parse("850 1234 5678", passcode: "9")?.webURL?.absoluteString, "https://app.zoom.us/wc/join/85012345678?pwd=9")
        XCTAssertNil(ZoomMeeting.parse("hello"))
        XCTAssertNil(ZoomMeeting.parse("12345"))
    }
}
