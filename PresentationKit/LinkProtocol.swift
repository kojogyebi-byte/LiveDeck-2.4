import Foundation

// MARK: - LiveDeck Link: several Macs on the same network
//
// Stations find each other with Bonjour (_livedeck._tcp) and talk over TCP.
// Every frame is:  [UInt32 total length][UInt32 JSON length][JSON envelope][optional binary payload]
// (big-endian). Files travel as binary chunks so large videos are not base64-inflated.

public enum LinkKind: String, Codable, Sendable {
    case hello          // client → server: who I am
    case challenge      // server → client: nonce (when a passcode is set)
    case auth           // client → server: proof
    case welcome        // server → client: accepted (+ server info)
    case reject         // either: refused (reason in text)
    case status         // periodic switcher status
    case chat           // text message
    case attention      // "look at me" flash
    case libraryRequest // ask for someone's media library
    case library        // media library listing
    case fileRequest    // please send me item X
    case fileOffer      // I would like to send you a file
    case fileAccept     // yes / no (accept flag)
    case fileStart      // transfer begins (file info)
    case fileChunk      // binary data at offset
    case fileEnd        // transfer complete
    case fileCancel     // transfer stopped
    case songShare      // a song document (JSON in `json`)
    case presetShare    // a preset (JSON in `json`)
    case ping, pong
}

public struct LinkStatus: Codable, Hashable, Sendable {
    public var program: String
    public var preview: String
    public var recording: Bool
    public var streaming: Bool
    public var recordSeconds: Int
    public var keyed: Int
    public var liveText: String
    public init(program: String = "", preview: String = "", recording: Bool = false, streaming: Bool = false,
                recordSeconds: Int = 0, keyed: Int = 0, liveText: String = "") {
        self.program = program; self.preview = preview; self.recording = recording; self.streaming = streaming
        self.recordSeconds = recordSeconds; self.keyed = keyed; self.liveText = liveText
    }
}

public struct LinkMediaItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var kind: String          // "image" / "video"
    public var bytes: Int64
    public var category: String
    public init(id: String, title: String, kind: String, bytes: Int64, category: String) {
        self.id = id; self.title = title; self.kind = kind; self.bytes = bytes; self.category = category
    }
}

public struct LinkFileInfo: Codable, Hashable, Sendable {
    public var transferID: String
    public var itemID: String
    public var fileName: String
    public var title: String
    public var kind: String
    public var bytes: Int64
    public var addAsInput: Bool
    public init(transferID: String = UUID().uuidString, itemID: String, fileName: String, title: String, kind: String, bytes: Int64, addAsInput: Bool = false) {
        self.transferID = transferID; self.itemID = itemID; self.fileName = fileName; self.title = title
        self.kind = kind; self.bytes = bytes; self.addAsInput = addAsInput
    }
}

public struct LinkEnvelope: Codable, Sendable {
    public var kind: LinkKind
    public var id: String
    public var from: String
    public var fromName: String
    public var to: String?            // nil = everyone
    public var sent: Date
    public var version: Int?
    public var text: String?
    public var nonce: String?
    public var proof: String?
    public var accept: Bool?
    public var status: LinkStatus?
    public var items: [LinkMediaItem]?
    public var file: LinkFileInfo?
    public var offset: Int64?
    public var json: String?

    public init(kind: LinkKind, from: String, fromName: String, to: String? = nil) {
        self.kind = kind; self.id = UUID().uuidString; self.from = from; self.fromName = fromName; self.to = to; self.sent = Date()
    }
}

public enum LinkFrame {
    public static let protocolVersion = 1
    public static let maxFrameBytes = 16 * 1024 * 1024
    public static let chunkBytes = 512 * 1024

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }()

    public static func encode(_ env: LinkEnvelope, binary: Data = Data()) throws -> Data {
        let json = try encoder.encode(env)
        let total = 4 + json.count + binary.count
        guard total + 4 <= maxFrameBytes else { throw PresentationKitError.badFormat("frame too large") }
        var out = Data(capacity: total + 4)
        out.append(be32(UInt32(total)))
        out.append(be32(UInt32(json.count)))
        out.append(json)
        out.append(binary)
        return out
    }

    static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }
    static func readBE32(_ d: Data, _ at: Int) -> UInt32 {
        let i = d.startIndex + at
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    /// Accumulates bytes from the socket and returns complete frames.
    public final class Decoder {
        private var buffer = Data()
        public private(set) var failed = false
        public init() {}

        public func append(_ data: Data) -> [(LinkEnvelope, Data)] {
            guard !failed else { return [] }
            buffer.append(data)
            var out: [(LinkEnvelope, Data)] = []
            while buffer.count >= 4 {
                let total = Int(readBE32(buffer, 0))
                guard total >= 4, total + 4 <= maxFrameBytes else { failed = true; buffer.removeAll(); break }
                guard buffer.count >= 4 + total else { break }
                let jsonLen = Int(readBE32(buffer, 4))
                guard jsonLen <= total - 4 else { failed = true; buffer.removeAll(); break }
                let s = buffer.startIndex
                let json = buffer.subdata(in: (s + 8)..<(s + 8 + jsonLen))
                let binary = buffer.subdata(in: (s + 8 + jsonLen)..<(s + 4 + total))
                buffer.removeSubrange(s..<(s + 4 + total))
                if let env = try? LinkFrame.decoder.decode(LinkEnvelope.self, from: json) { out.append((env, binary)) }
            }
            if buffer.isEmpty { buffer = Data() }      // reset indices
            return out
        }
    }

    // MARK: passcode proof (the passcode itself never crosses the network)

    public static func proof(nonce: String, passcode: String) -> String {
        SHA256.hex(Data(("livedeck-link:" + nonce + ":" + passcode).utf8))
    }

    public static func newNonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Which side opens the connection when both see each other: the lower station id.
    public static func shouldInitiate(myID: String, peerID: String) -> Bool { myID < peerID }

    /// Safe file name for received files.
    public static func safeFileName(_ name: String) -> String {
        let cleaned = name.map { $0.isLetter || $0.isNumber || "-_. ".contains($0) ? $0 : "_" }
        var s = String(cleaned).trimmed
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "file" }
        return String(s.prefix(120))
    }
}

/// Small SHA-256 (Foundation-only so it also runs in the Linux tests).
public enum SHA256 {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

    public static func hash(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8(bitLen >> (UInt64(i) * 8) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 64)
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for t in 0..<16 {
                let b = chunk + t * 4
                w[t] = UInt32(msg[b]) << 24 | UInt32(msg[b + 1]) << 16 | UInt32(msg[b + 2]) << 8 | UInt32(msg[b + 3])
            }
            for t in 16..<64 {
                let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for t in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[t] &+ w[t]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    }

    public static func hex(_ data: Data) -> String { hash(data).map { String(format: "%02x", $0) }.joined() }
}

/// Chat history shown in the Network panel.
public struct LinkChatMessage: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var from: String
    public var fromName: String
    public var to: String?
    public var toName: String?
    public var text: String
    public var date: Date
    public var mine: Bool
    public var attention: Bool
    public init(id: String = UUID().uuidString, from: String, fromName: String, to: String?, toName: String?, text: String,
                date: Date = Date(), mine: Bool, attention: Bool = false) {
        self.id = id; self.from = from; self.fromName = fromName; self.to = to; self.toName = toName; self.text = text
        self.date = date; self.mine = mine; self.attention = attention
    }
}

// MARK: - HMAC-SHA256 and Zoom Meeting SDK token

public enum HMACSHA256 {
    public static func mac(key: Data, message: Data) -> [UInt8] {
        var k = [UInt8](key)
        if k.count > 64 { k = SHA256.hash(Data(k)) }
        k += [UInt8](repeating: 0, count: 64 - k.count)
        let inner = Data(k.map { $0 ^ 0x36 }) + message
        let innerHash = SHA256.hash(inner)
        let outer = Data(k.map { $0 ^ 0x5c }) + Data(innerHash)
        return SHA256.hash(outer)
    }
    public static func hex(key: Data, message: Data) -> String { mac(key: key, message: message).map { String(format: "%02x", $0) }.joined() }
}

/// Builds the JWT the Zoom Meeting SDK needs to authorise (HS256, signed with the SDK Secret).
/// For your own organisation's use. Public distribution should fetch the token from a server instead.
public enum ZoomSDKToken {
    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func make(sdkKey: String, sdkSecret: String, issuedAt: Date = Date(), lifetime: TimeInterval = 7200) -> String {
        let iat = Int(issuedAt.timeIntervalSince1970) - 30          // allow for clock drift
        let exp = iat + Int(max(1800, min(lifetime, 172_800)))       // Zoom accepts 30 min … 48 h
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = "{\"appKey\":\"\(sdkKey)\",\"iat\":\(iat),\"exp\":\(exp),\"tokenExp\":\(exp)}"
        let signingInput = base64url(Data(header.utf8)) + "." + base64url(Data(payload.utf8))
        let sig = HMACSHA256.mac(key: Data(sdkSecret.utf8), message: Data(signingInput.utf8))
        return signingInput + "." + base64url(Data(sig))
    }

    /// Reads the token from a server response: {"token": "…"}, {"signature": "…"} or {"jwt": "…"}, or the raw token text.
    public static func parseServerResponse(_ data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for k in ["token", "signature", "jwt", "jwtToken"] { if let s = obj[k] as? String, s.split(separator: ".").count == 3 { return s } }
            return nil
        }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.split(separator: ".").count == 3 ? s : nil
    }
}
