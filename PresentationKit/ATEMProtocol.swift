import Foundation

// MARK: - Blackmagic ATEM switcher control protocol (UDP port 9910)
//
// Packet: 12-byte header + optional command blocks.
//   bytes 0-1  flags (5 bits) << 11 | total length (11 bits)
//   bytes 2-3  session id
//   bytes 4-5  id of the remote packet being acknowledged (AckReply)
//   bytes 10-11 this packet's id (AckRequest)
// Command block: length (UInt16, includes the 8-byte block header) · 2 zero bytes · 4-letter name · body.

public struct ATEMPacket: Equatable, Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let ackRequest = Flags(rawValue: 0x01)
        public static let newSession = Flags(rawValue: 0x02)
        public static let retransmit = Flags(rawValue: 0x04)
        public static let retransmitRequest = Flags(rawValue: 0x08)
        public static let ackReply = Flags(rawValue: 0x10)
    }

    public var flags: Flags
    public var sessionID: UInt16
    public var ackID: UInt16
    public var packetID: UInt16
    public var payload: Data

    public init(flags: Flags, sessionID: UInt16, ackID: UInt16 = 0, packetID: UInt16 = 0, payload: Data = Data()) {
        self.flags = flags; self.sessionID = sessionID; self.ackID = ackID; self.packetID = packetID; self.payload = payload
    }

    public static let port: UInt16 = 9910
    public static let maxPacketID: UInt16 = 32768

    /// First packet a client sends.
    public static let hello = Data([0x10, 0x14, 0x53, 0xAB, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3A, 0x00, 0x00,
                                    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

    public func encode() -> Data {
        let length = UInt16(12 + payload.count)
        var d = Data(count: 12)
        let word0 = (UInt16(flags.rawValue) << 11) | (length & 0x07FF)
        d[0] = UInt8(word0 >> 8); d[1] = UInt8(word0 & 0xFF)
        d[2] = UInt8(sessionID >> 8); d[3] = UInt8(sessionID & 0xFF)
        d[4] = UInt8(ackID >> 8); d[5] = UInt8(ackID & 0xFF)
        d[10] = UInt8(packetID >> 8); d[11] = UInt8(packetID & 0xFF)
        d.append(payload)
        return d
    }

    public static func parse(_ data: Data) -> ATEMPacket? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data)
        let word0 = UInt16(b[0]) << 8 | UInt16(b[1])
        let length = Int(word0 & 0x07FF)
        guard length >= 12, length <= b.count else { return nil }
        return ATEMPacket(flags: Flags(rawValue: UInt8(word0 >> 11)),
                          sessionID: UInt16(b[2]) << 8 | UInt16(b[3]),
                          ackID: UInt16(b[4]) << 8 | UInt16(b[5]),
                          packetID: UInt16(b[10]) << 8 | UInt16(b[11]),
                          payload: Data(b[12..<length]))
    }

    public static func ack(session: UInt16, remotePacketID: UInt16) -> Data {
        ATEMPacket(flags: .ackReply, sessionID: session, ackID: remotePacketID).encode()
    }
}

public enum ATEMCommand {
    public static func block(_ name: String, _ body: [UInt8]) -> Data {
        precondition(name.utf8.count == 4)
        let len = UInt16(8 + body.count)
        var d = Data([UInt8(len >> 8), UInt8(len & 0xFF), 0, 0])
        d.append(contentsOf: Array(name.utf8))
        d.append(contentsOf: body)
        return d
    }

    /// Splits a packet payload into (name, body) command blocks.
    public static func split(_ payload: Data) -> [(name: String, body: Data)] {
        var out: [(String, Data)] = []
        let b = [UInt8](payload)
        var i = 0
        while i + 8 <= b.count {
            let len = Int(UInt16(b[i]) << 8 | UInt16(b[i + 1]))
            guard len >= 8, i + len <= b.count else { break }
            let name = String(bytes: b[(i + 4)..<(i + 8)], encoding: .ascii) ?? "????"
            out.append((name, Data(b[(i + 8)..<(i + len)])))
            i += len
        }
        return out
    }

    private static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

    public static func cut(me: Int = 0) -> Data { block("DCut", [UInt8(me), 0, 0, 0]) }
    public static func auto(me: Int = 0) -> Data { block("DAut", [UInt8(me), 0, 0, 0]) }
    public static func fadeToBlack(me: Int = 0) -> Data { block("FtbA", [UInt8(me), 0, 0, 0]) }
    public static func program(me: Int = 0, source: UInt16) -> Data { block("CPgI", [UInt8(me), 0] + u16(source)) }
    public static func preview(me: Int = 0, source: UInt16) -> Data { block("CPvI", [UInt8(me), 0] + u16(source)) }
    /// style: 0 mix · 1 dip · 2 wipe · 3 DVE · 4 stinger
    public static func transitionStyle(me: Int = 0, style: UInt8) -> Data { block("CTTp", [0x01, UInt8(me), style, 0]) }
    /// position 0 … 10000 (T-bar)
    public static func transitionPosition(me: Int = 0, position: UInt16) -> Data { block("CTPs", [UInt8(me), 0] + u16(min(10000, position))) }
    public static func downstreamKeyOnAir(keyer: Int, onAir: Bool) -> Data { block("CDsL", [UInt8(keyer), onAir ? 1 : 0, 0, 0]) }
    public static func downstreamKeyAuto(keyer: Int) -> Data { block("DDsA", [UInt8(keyer), 0, 0, 0]) }
    public static func downstreamKeyTie(keyer: Int, tie: Bool) -> Data { block("CDsT", [UInt8(keyer), tie ? 1 : 0, 0, 0]) }
    public static func upstreamKeyOnAir(me: Int = 0, keyer: Int, onAir: Bool) -> Data { block("CKOn", [UInt8(me), UInt8(keyer), onAir ? 1 : 0, 0]) }
    public static func runMacro(_ index: Int) -> Data { block("MAct", u16(UInt16(index)) + [0, 0]) }
    public static func stopMacro() -> Data { block("MAct", u16(0xFFFF) + [1, 0]) }
    public static func auxSource(aux: Int, source: UInt16) -> Data { block("CAuS", [1, UInt8(aux)] + u16(source)) }
}

public struct ATEMInput: Hashable, Identifiable, Sendable {
    public var id: UInt16
    public var longName: String
    public var shortName: String
    public var portType: UInt8          // 0 external · 1 black · 2 bars · 3 colour · 4/5 media player · 6 super source · 128 ME output · 129 aux …
    public var meAvailability: UInt8    // bit 0 = ME 1, bit 1 = ME 2
    public init(id: UInt16, longName: String, shortName: String, portType: UInt8, meAvailability: UInt8) {
        self.id = id; self.longName = longName; self.shortName = shortName; self.portType = portType; self.meAvailability = meAvailability
    }
    /// Sources that can be selected on a mix/effect bus.
    public func availableOn(me: Int) -> Bool { meAvailability & (1 << UInt8(me)) != 0 }
}

public struct ATEMState: Equatable, Sendable {
    public var productName = ""
    public var protocolMajor: UInt16 = 0
    public var protocolMinor: UInt16 = 0
    public var mixEffects = 1
    public var inputs: [UInt16: ATEMInput] = [:]
    public var program: [Int: UInt16] = [:]
    public var preview: [Int: UInt16] = [:]
    public var transitionStyle: [Int: UInt8] = [:]
    public var inTransition: [Int: Bool] = [:]
    public var transitionPosition: [Int: UInt16] = [:]
    public var fadeToBlack: [Int: Bool] = [:]
    public var fadeToBlackInTransition: [Int: Bool] = [:]
    public var downstreamKeys: [Int: Bool] = [:]
    public var downstreamTie: [Int: Bool] = [:]
    public var upstreamKeys: [String: Bool] = [:]       // "me:keyer"
    public var tallyProgram: Set<UInt16> = []
    public var tallyPreview: Set<UInt16> = []
    public var macros: [Int: String] = [:]
    public var aux: [Int: UInt16] = [:]
    public var initComplete = false
    public init() {}

    /// Protocol 2.28 (firmware 8.0) changed the input-properties layout.
    public var isV8OrLater: Bool { protocolMajor > 2 || (protocolMajor == 2 && protocolMinor >= 28) }

    static func string(_ d: Data, _ from: Int, _ len: Int) -> String {
        let b = [UInt8](d)
        guard from < b.count else { return "" }
        let slice = b[from..<min(b.count, from + len)]
        let bytes = slice.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
    static func u8(_ d: Data, _ i: Int) -> UInt8 { i < d.count ? d[d.startIndex + i] : 0 }
    static func u16(_ d: Data, _ i: Int) -> UInt16 { UInt16(u8(d, i)) << 8 | UInt16(u8(d, i + 1)) }

    /// Applies one state command; returns true when something changed.
    @discardableResult
    public mutating func apply(_ name: String, _ body: Data) -> Bool {
        let before = self
        switch name {
        case "_ver":
            protocolMajor = Self.u16(body, 0); protocolMinor = Self.u16(body, 2)
        case "_pin":
            productName = Self.string(body, 0, 44)
        case "_top":
            if body.count >= 1 { mixEffects = max(1, Int(Self.u8(body, 0))) }
        case "InPr":
            guard body.count >= 32 else { break }
            let id = Self.u16(body, 0)
            let port = isV8OrLater ? Self.u8(body, 32) : Self.u8(body, 30)
            let meAvail = isV8OrLater ? Self.u8(body, 35) : Self.u8(body, 33)
            inputs[id] = ATEMInput(id: id, longName: Self.string(body, 2, 20), shortName: Self.string(body, 22, 4), portType: port, meAvailability: meAvail)
        case "PrgI":
            program[Int(Self.u8(body, 0))] = Self.u16(body, 2)
        case "PrvI":
            preview[Int(Self.u8(body, 0))] = Self.u16(body, 2)
        case "TrSS":
            transitionStyle[Int(Self.u8(body, 0))] = Self.u8(body, 1)
        case "TrPs":
            let me = Int(Self.u8(body, 0))
            inTransition[me] = Self.u8(body, 1) == 1
            transitionPosition[me] = Self.u16(body, 4)
        case "FtbS":
            let me = Int(Self.u8(body, 0))
            fadeToBlack[me] = Self.u8(body, 1) == 1
            fadeToBlackInTransition[me] = Self.u8(body, 2) == 1
        case "DskS":
            downstreamKeys[Int(Self.u8(body, 0))] = Self.u8(body, 1) == 1
        case "DskP":
            downstreamTie[Int(Self.u8(body, 0))] = Self.u8(body, 1) == 1
        case "KeOn":
            upstreamKeys["\(Self.u8(body, 0)):\(Self.u8(body, 1))"] = Self.u8(body, 2) == 1
        case "TlSr":
            let count = Int(Self.u16(body, 0))
            var pgm = Set<UInt16>(), pvw = Set<UInt16>()
            for i in 0..<count {
                let src = Self.u16(body, 2 + i * 3)
                let flags = Self.u8(body, 4 + i * 3)
                if flags & 1 != 0 { pgm.insert(src) }
                if flags & 2 != 0 { pvw.insert(src) }
            }
            tallyProgram = pgm; tallyPreview = pvw
        case "MPrp":
            let index = Int(Self.u16(body, 0))
            let used = Self.u8(body, 2) != 0
            let nameLen = Int(Self.u16(body, 4))
            if used { macros[index] = Self.string(body, 8, nameLen).isEmpty ? "Macro \(index + 1)" : Self.string(body, 8, nameLen) }
            else { macros[index] = nil }
        case "AuxS":
            aux[Int(Self.u8(body, 0))] = Self.u16(body, 2)
        case "InCm":
            initComplete = true
        default:
            return false
        }
        return self != before
    }

    /// Bus buttons for a mix/effect: cameras first, then other sources, in id order.
    public func busSources(me: Int = 0) -> [ATEMInput] {
        inputs.values
            .filter { $0.availableOn(me: me) && $0.portType != 128 && $0.portType != 129 }
            .sorted { a, b in
                let ae = a.portType == 0, be = b.portType == 0
                return ae != be ? ae : a.id < b.id
            }
    }
}
