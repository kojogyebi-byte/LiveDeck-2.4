import XCTest
@testable import PresentationKit

final class CountdownTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(CountdownClock.display(231, format: .auto), "03:51")
        XCTAssertEqual(CountdownClock.display(230.2, format: .mmss), "03:51", "rounds up while counting down")
        XCTAssertEqual(CountdownClock.display(3725, format: .auto), "1:02:05")
        XCTAssertEqual(CountdownClock.display(3725, format: .mmss), "62:05")
        XCTAssertEqual(CountdownClock.display(65, format: .hhmmss), "00:01:05")
        XCTAssertEqual(CountdownClock.display(65, format: .mss), "1:05")
        XCTAssertEqual(CountdownClock.display(90, format: .seconds), "90")
        XCTAssertEqual(CountdownClock.display(65.47, format: .tenths), "01:05.4")
        XCTAssertEqual(CountdownClock.display(-5, format: .mmss), "00:00")
    }

    func testTargetTime() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 9, minute: 30))!
        XCTAssertEqual(CountdownClock.secondsUntil(hour: 10, minute: 0, from: now, calendar: cal), 1800)
        XCTAssertEqual(CountdownClock.secondsUntil(hour: 9, minute: 25, from: now, calendar: cal), -300, "just passed → overtime")
        XCTAssertEqual(CountdownClock.secondsUntil(hour: 8, minute: 0, from: cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 22))!, calendar: cal), 36000, "tomorrow morning")
    }

    func testStates() {
        var s = CountdownStyle()
        XCTAssertEqual(CountdownClock.state(seconds: 120, style: s), .running("02:00"))
        XCTAssertEqual(CountdownClock.state(seconds: 30, style: s), .warning("00:30"))
        XCTAssertEqual(CountdownClock.state(seconds: 0, style: s), .ended("00:00"))
        s.endBehavior = .endText; s.endText = "WE ARE LIVE"
        XCTAssertEqual(CountdownClock.state(seconds: -3, style: s), .ended("WE ARE LIVE"))
        s.endBehavior = .overtime
        XCTAssertEqual(CountdownClock.state(seconds: -75, style: s), .overtime("+01:15"))
        s.mode = .countUp; s.warnSeconds = 60
        XCTAssertEqual(CountdownClock.state(seconds: 30, style: s), .running("00:30"))
        let old = try! JSONDecoder().decode(CountdownStyle.self, from: Data(#"{"box":"Pill","format":"M:SS"}"#.utf8))
        XCTAssertEqual(old.box, .pill); XCTAssertEqual(old.format, .mss); XCTAssertEqual(old.labelPosition, .above)
    }
}
