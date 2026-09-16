import XCTest
@testable import PresentationKit

final class LinkProtocolTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testFrameRoundTripAcrossSplitReads() throws {
        var chat = LinkEnvelope(kind: .chat, from: "A", fromName: "Front of house")
        chat.text = "Go to camera 2 🎥"
        var chunk = LinkEnvelope(kind: .fileChunk, from: "A", fromName: "FOH", to: "B")
        chunk.offset = 524_288
        chunk.file = LinkFileInfo(transferID: "t1", itemID: "i1", fileName: "clip.mp4", title: "Clip", kind: "video", bytes: 900)
        let payload = Data((0..<900).map { UInt8($0 % 251) })
        var stream = try LinkFrame.encode(chat)
        stream.append(try LinkFrame.encode(chunk, binary: payload))

        let dec = LinkFrame.Decoder()
        var got: [(LinkEnvelope, Data)] = []
        // feed in awkward pieces
        var i = 0
        let sizes = [1, 3, 7, 50, 2, 400, 1000, 10_000]
        var s = 0
        while i < stream.count {
            let n = min(sizes[s % sizes.count], stream.count - i)
            got += dec.append(stream.subdata(in: i..<(i + n)))
            i += n; s += 1
        }
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got[0].0.kind, .chat)
        XCTAssertEqual(got[0].0.text, "Go to camera 2 🎥")
        XCTAssertTrue(got[0].1.isEmpty)
        XCTAssertEqual(got[1].0.offset, 524_288)
        XCTAssertEqual(got[1].0.file?.fileName, "clip.mp4")
        XCTAssertEqual(got[1].1, payload)
        XCTAssertFalse(dec.failed)
    }

    func testDecoderRejectsGarbage() {
        let dec = LinkFrame.Decoder()
        _ = dec.append(Data([0xff, 0xff, 0xff, 0xff, 1, 2, 3]))
        XCTAssertTrue(dec.failed)
    }

    func testProofAndHelpers() {
        let n = LinkFrame.newNonce()
        XCTAssertEqual(n.count, 32)
        XCTAssertEqual(LinkFrame.proof(nonce: n, passcode: "1234"), LinkFrame.proof(nonce: n, passcode: "1234"))
        XCTAssertNotEqual(LinkFrame.proof(nonce: n, passcode: "1234"), LinkFrame.proof(nonce: n, passcode: "1235"))
        XCTAssertTrue(LinkFrame.shouldInitiate(myID: "a", peerID: "b"))
        XCTAssertFalse(LinkFrame.shouldInitiate(myID: "b", peerID: "a"))
        XCTAssertEqual(LinkFrame.safeFileName("../../etc/pass wd?.mp4"), "_.._etc_pass wd_.mp4")
        XCTAssertEqual(LinkFrame.safeFileName("..."), "file")
    }

    func testStatusCodable() throws {
        var e = LinkEnvelope(kind: .status, from: "X", fromName: "Stage")
        e.status = LinkStatus(program: "Camera 1", preview: "Slides", recording: true, recordSeconds: 61, keyed: 2)
        let back = try LinkFrame.Decoder().append(LinkFrame.encode(e))
        XCTAssertEqual(back.first?.0.status?.program, "Camera 1")
        XCTAssertEqual(back.first?.0.status?.recordSeconds, 61)
    }
}
