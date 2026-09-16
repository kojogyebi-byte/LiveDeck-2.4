import XCTest
@testable import PresentationKit

final class VideoFormatTests: XCTestCase {
    func testFrameRates() {
        let i5994 = FrameRateFormat.byID("59.94i")!
        XCTAssertTrue(i5994.interlaced)
        XCTAssertEqual(i5994.framesPerSecond, 29.97, accuracy: 0.001)
        XCTAssertEqual(i5994.fieldsPerSecond, 59.94, accuracy: 0.001)
        XCTAssertEqual(i5994.ffmpegRate, "30000/1001")
        XCTAssertEqual(i5994.name(height: 1080), "1080i59.94")
        XCTAssertEqual(i5994.frameDuration.value, 1001); XCTAssertEqual(i5994.frameDuration.timescale, 30000)
        let i50 = FrameRateFormat.byID("50i")!
        XCTAssertEqual(i50.framesPerSecond, 25); XCTAssertEqual(i50.renderRate, 50)
        XCTAssertEqual(i50.name(height: 1080), "1080i50")
        XCTAssertEqual(FrameRateFormat.byID("23.976p")!.name(height: 1080), "1080p23.98")
        XCTAssertEqual(FrameRateFormat.byID("29.97p")!.nominalFPS, 30)
        XCTAssertEqual(FrameRateFormat.fromLegacy(25).id, "25p")
        XCTAssertEqual(FrameRateFormat.fromLegacy(33).id, "30p")
        XCTAssertEqual(Set(FrameRateFormat.all.map { $0.id }).count, FrameRateFormat.all.count)
    }

    func testCropAndPlacement() {
        var s = ScreenOutputSettings(cropLeft: 0.1, cropRight: 0.1)
        let c = OutputGeometry.cropRect(sourceWidth: 1920, sourceHeight: 1080, s)
        XCTAssertEqual(c, PixelRect(x: 192, y: 0, width: 1536, height: 1080))
        // 16:9 into a 4:3 region
        let lb = OutputGeometry.placement(contentWidth: 1920, contentHeight: 1080, targetWidth: 1024, targetHeight: 768, scaling: .letterbox)
        XCTAssertEqual(lb.width, 1024, accuracy: 0.01); XCTAssertEqual(lb.height, 576, accuracy: 0.01); XCTAssertEqual(lb.y, 96, accuracy: 0.01)
        let cr = OutputGeometry.placement(contentWidth: 1920, contentHeight: 1080, targetWidth: 1024, targetHeight: 768, scaling: .crop)
        XCTAssertEqual(cr.height, 768, accuracy: 0.01); XCTAssertEqual(cr.x, -170.67, accuracy: 0.01)
        let sq = OutputGeometry.placement(contentWidth: 1920, contentHeight: 1080, targetWidth: 1024, targetHeight: 768, scaling: .squeeze)
        XCTAssertEqual(sq, PixelRect(x: 0, y: 0, width: 1024, height: 768))
        let na = OutputGeometry.placement(contentWidth: 1280, contentHeight: 720, targetWidth: 1920, targetHeight: 1080, scaling: .native)
        XCTAssertEqual(na, PixelRect(x: 320, y: 180, width: 1280, height: 720))
        XCTAssertEqual(OutputGeometry.scaleFactor(contentWidth: 1920, contentHeight: 1080, targetWidth: 3840, targetHeight: 2160, scaling: .letterbox), 2, accuracy: 0.0001)
        s.customRegion = true; s.regionX = 3000; s.regionWidth = 1920; s.regionHeight = 5000
        let cl = OutputGeometry.clampRegion(s, displayWidth: 3840, displayHeight: 2160)
        XCTAssertEqual(cl.regionHeight, 2160); XCTAssertEqual(cl.regionX, 1920)
        let old = try! JSONDecoder().decode(ScreenOutputSettings.self, from: Data(#"{"scaling":"Squeeze"}"#.utf8))
        XCTAssertEqual(old.scaling, .squeeze); XCTAssertFalse(old.customRegion)
    }
}
