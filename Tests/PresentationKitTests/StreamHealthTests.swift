import XCTest
@testable import PresentationKit

final class StreamHealthTests: XCTestCase {
    func testProgressParsing() {
        var p = FFmpegProgress()
        p.apply("frame=900\nfps=30.02\nstream_0_0_q=23.0\nbitrate=4512.3kbits/s\ntotal_size=16934000\nout_time_us=30033000\ndup_frames=1\ndrop_frames=4\nspeed=1.01x\nprogress=continue\n")
        XCTAssertEqual(p.frame, 900)
        XCTAssertEqual(p.bitrateKbps, 4512.3, accuracy: 0.01)
        XCTAssertEqual(p.totalBytes, 16_934_000)
        XCTAssertEqual(p.dropFrames, 4)
        XCTAssertEqual(p.speed, 1.01, accuracy: 0.001)
        XCTAssertEqual(p.outTimeSeconds, 30.033, accuracy: 0.001)
        p.apply("bitrate=N/A\nspeed=N/A\nframe=930\n")
        XCTAssertEqual(p.bitrateKbps, 4512.3, accuracy: 0.01, "N/A keeps the last value")
        XCTAssertEqual(p.frame, 930)
    }

    func testHealthLevels() {
        XCTAssertEqual(StreamHealth.evaluate(streaming: false, seconds: 0, speed: 0, backlogSeconds: 0, droppedRecently: 0, fps: 30, receivedProgress: false).level, .off)
        XCTAssertEqual(StreamHealth.evaluate(streaming: true, seconds: 2, speed: 0, backlogSeconds: 0, droppedRecently: 0, fps: 30, receivedProgress: false).level, .connecting)
        XCTAssertEqual(StreamHealth.evaluate(streaming: true, seconds: 60, speed: 1.0, backlogSeconds: 0.05, droppedRecently: 0, fps: 30, receivedProgress: true).bars, 5)
        XCTAssertEqual(StreamHealth.evaluate(streaming: true, seconds: 60, speed: 0.985, backlogSeconds: 0.1, droppedRecently: 0, fps: 30, receivedProgress: true).level, .good)
        XCTAssertEqual(StreamHealth.evaluate(streaming: true, seconds: 60, speed: 1.0, backlogSeconds: 1.5, droppedRecently: 0, fps: 30, receivedProgress: true).level, .fair)
        XCTAssertEqual(StreamHealth.evaluate(streaming: true, seconds: 60, speed: 0.8, backlogSeconds: 0.2, droppedRecently: 0, fps: 30, receivedProgress: true).level, .poor)
        XCTAssertEqual(StreamHealth.evaluate(streaming: true, seconds: 60, speed: 1.0, backlogSeconds: 0.1, droppedRecently: 45, fps: 30, receivedProgress: true).level, .fair)
    }

    func testFormatting() {
        XCTAssertEqual(StatusFormat.duration(3725), "01:02:05")
        XCTAssertEqual(StatusFormat.bytes(1_234_000_000), "1.23 GB")
        XCTAssertEqual(StatusFormat.bitrate(4500), "4.5 Mbps")
        XCTAssertEqual(StatusFormat.hoursLeft(freeBytes: 45_000_000_000, mbps: 10), 10, accuracy: 0.01)
    }
}

final class StreamBitrateTests: XCTestCase {
    func testChoicesAndAdvice() {
        XCTAssertEqual(StreamBitrates.video.first, 128)
        XCTAssertEqual(StreamBitrates.audio.first, 128)
        XCTAssertEqual(StreamBitrates.video, StreamBitrates.video.sorted())
        XCTAssertTrue(StreamBitrates.video.contains(StreamBitrates.defaultVideo))
        XCTAssertTrue(StreamBitrates.audio.contains(StreamBitrates.defaultAudio))
        XCTAssertEqual(StreamBitrates.label(128), "128 kb/s")
        XCTAssertEqual(StreamBitrates.label(4500), "4.5 Mb/s")
        XCTAssertEqual(StreamBitrates.label(6000), "6 Mb/s")
        XCTAssertEqual(StreamBitrates.recommendedVideo(height: 1080, fps: 30), 3000...6000)
        XCTAssertEqual(StreamBitrates.recommendedVideo(height: 1080, fps: 59.94), 4500...9000)
        XCTAssertNil(StreamBitrates.advice(videoKbps: 4500, height: 1080, fps: 30))
        XCTAssertTrue(StreamBitrates.advice(videoKbps: 256, height: 1080, fps: 30)?.hasPrefix("Very low") == true)
        XCTAssertTrue(StreamBitrates.advice(videoKbps: 2000, height: 1080, fps: 30)?.hasPrefix("Below") == true)
        XCTAssertEqual(StreamBitrates.uploadNeeded(videoKbps: 4500, audioKbps: 160, audioOn: true, destinations: 2), 13980)
    }
}

final class StreamResolutionTests: XCTestCase {
    func testResolutionsAndFilters() {
        XCTAssertEqual(Set(StreamResolution.all.map { $0.id }).count, StreamResolution.all.count)
        let same = StreamResolution.sameAsProgram
        XCTAssertNil(same.ffmpegFilter(programWidth: 1920, programHeight: 1080, mode: .fit))
        XCTAssertEqual(same.outputSize(programWidth: 1920, programHeight: 1080).width, 1920)
        let r720 = StreamResolution.byID("720p")
        XCTAssertEqual(r720.ffmpegFilter(programWidth: 1920, programHeight: 1080, mode: .crop), "scale=1280:720:flags=lanczos,setsar=1")
        XCTAssertEqual(r720.scaleDescription(programWidth: 1920, programHeight: 1080), "downscaled 0.67×")
        let v = StreamResolution.byID("v1080")
        XCTAssertEqual(v.ffmpegFilter(programWidth: 1920, programHeight: 1080, mode: .crop),
                       "scale=1080:1920:force_original_aspect_ratio=increase:flags=lanczos,crop=1080:1920,setsar=1")
        XCTAssertTrue(v.ffmpegFilter(programWidth: 1920, programHeight: 1080, mode: .fit)!.contains("pad=1080:1920"))
        XCTAssertEqual(StreamResolution.byID("480p").outputSize(programWidth: 1920, programHeight: 1080).width, 854)
        XCTAssertEqual(StreamResolution.byID("nope").id, "program")
        XCTAssertEqual(StreamResolution.byID("2160p").scaleDescription(programWidth: 1920, programHeight: 1080), "upscaled 2.00×")
    }
}
