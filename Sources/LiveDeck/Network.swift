import Foundation
import Network
import AppKit
import SwiftUI
import PresentationKit

// MARK: - LiveDeck Link (several Macs on the same network)

struct LinkPeerInfo: Identifiable, Hashable {
    enum State: Hashable { case found, connecting, connected, failed(String) }
    let id: String
    var name: String
    var state: State = .found
    var status: LinkStatus?
    var lastSeen = Date()
    var library: [LinkMediaItem]?
    var libraryLoading = false
    var connected: Bool { state == .connected }
}

struct LinkTransfer: Identifiable, Hashable {
    enum State: Hashable { case offered, waiting, sending, receiving, done, declined, failed(String), cancelled }
    let id: String
    var title: String
    var peerID: String
    var peerName: String
    var incoming: Bool
    var bytes: Int64
    var done: Int64 = 0
    var state: State
    var fraction: Double { bytes > 0 ? min(1, Double(done) / Double(bytes)) : 0 }
    var active: Bool { [.offered, .waiting, .sending, .receiving].contains(state) }
}

/// One TCP connection to another station. All methods run on the link queue.
final class LinkConnection {
    let conn: NWConnection
    let outbound: Bool
    var peerID: String?
    var peerName = ""
    var authed = false
    var nonce: String?
    private let decoder = LinkFrame.Decoder()
    weak var manager: LinkManager?

    init(_ conn: NWConnection, outbound: Bool, manager: LinkManager) {
        self.conn = conn; self.outbound = outbound; self.manager = manager
    }

    func start(on q: DispatchQueue) {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self, let m = self.manager else { return }
            switch st {
            case .ready:
                if self.outbound { m.sendHello(self) }
                self.receive()
            case .failed(let e): m.connectionEnded(self, reason: e.localizedDescription)
            case .cancelled: m.connectionEnded(self, reason: nil)
            default: break
            }
        }
        conn.start(queue: q)
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self, let m = self.manager else { return }
            if let data, !data.isEmpty {
                for (env, bin) in self.decoder.append(data) { m.handle(env, binary: bin, from: self) }
                if self.decoder.failed { self.conn.cancel(); return }
            }
            if complete || error != nil { self.conn.cancel(); return }
            self.receive()
        }
    }

    func send(_ env: LinkEnvelope, binary: Data = Data(), completion: ((Bool) -> Void)? = nil) {
        guard let frame = try? LinkFrame.encode(env, binary: binary) else { completion?(false); return }
        conn.send(content: frame, completion: .contentProcessed { err in completion?(err == nil) })
    }

    func close() { conn.cancel() }
}

final class LinkManager: ObservableObject {
    static let serviceType = "_livedeck._tcp"

    weak var engine: Engine?
    weak var backgrounds: BackgroundsModel?
    weak var present: PresentModel?
    weak var presets: PresetStore?

    // settings
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "link.enabled"); enabled ? start() : stop() } }
    @Published var stationName: String { didSet { UserDefaults.standard.set(stationName, forKey: "link.name"); syncSettings() } }
    @Published var passcode: String { didSet { UserDefaults.standard.set(passcode, forKey: "link.passcode"); syncSettings() } }
    @Published var autoAcceptFiles: Bool { didSet { UserDefaults.standard.set(autoAcceptFiles, forKey: "link.autoAccept") } }
    @Published var shareStatus: Bool { didSet { UserDefaults.standard.set(shareStatus, forKey: "link.shareStatus") } }

    // state
    @Published private(set) var peers: [LinkPeerInfo] = []
    @Published private(set) var messages: [LinkChatMessage] = []
    @Published private(set) var transfers: [LinkTransfer] = []
    @Published var unread = 0
    @Published var toast: LinkChatMessage?
    @Published private(set) var listenerStatus = "Off"
    @Published var chatTarget: String?            // nil = everyone
    @Published var browsingPeerID: String?

    let myID: String
    private let q = DispatchQueue(label: "livedeck.link", qos: .userInitiated)
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [ObjectIdentifier: LinkConnection] = [:]      // q only
    private var byPeer: [String: LinkConnection] = [:]                      // q only
    private var endpoints: [String: NWEndpoint] = [:]                       // q only
    private var outgoingOffers: [String: (url: URL, info: LinkFileInfo, peer: String)] = [:]   // q only
    private var cancelled: Set<String> = []                                 // q only
    private var incomingFiles: [String: (handle: FileHandle, url: URL, info: LinkFileInfo, peer: String, peerName: String)] = [:]  // q only
    private var lastProgress: [String: Date] = [:]
    private var statusTimer: Timer?
    private var toastTimer: Timer?
    private var myPasscode = ""                                             // q copy

    var connectedPeers: [LinkPeerInfo] { peers.filter { $0.connected } }

    init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "link.id") { myID = id } else {
            myID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
            d.set(myID, forKey: "link.id")
        }
        stationName = d.string(forKey: "link.name") ?? (Host.current().localizedName ?? "LiveDeck")
        passcode = d.string(forKey: "link.passcode") ?? ""
        autoAcceptFiles = d.bool(forKey: "link.autoAccept")
        shareStatus = d.object(forKey: "link.shareStatus") as? Bool ?? true
        enabled = d.bool(forKey: "link.enabled")
    }

    /// Call once the other models are wired.
    func activate() { syncSettings(); if enabled { start() } }

    /// Copies the name and passcode to the network queue (the only place they are read there).
    private func syncSettings() {
        let n = stationName, p = passcode
        q.async { [weak self] in self?.nameCache = n; self?.myPasscode = p }
    }

    // MARK: lifecycle

    private var serviceName: String {
        let clean = stationName.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        return String((clean.isEmpty ? "LiveDeck" : clean).prefix(40)) + " #" + myID
    }

    static func parse(serviceName: String) -> (name: String, id: String)? {
        guard let r = serviceName.range(of: " #", options: .backwards) else { return nil }
        let id = String(serviceName[r.upperBound...])
        guard !id.isEmpty else { return nil }
        return (String(serviceName[..<r.lowerBound]), id)
    }

    func start() {
        let name = serviceName
        syncSettings()
        q.async { [weak self] in
            guard let self, self.listener == nil else { return }
            do {
                let l = try NWListener(using: .tcp)
                l.service = NWListener.Service(name: name, type: Self.serviceType)
                l.newConnectionHandler = { [weak self] c in
                    guard let self else { c.cancel(); return }
                    let lc = LinkConnection(c, outbound: false, manager: self)
                    self.connections[ObjectIdentifier(lc)] = lc
                    lc.start(on: self.q)
                }
                l.stateUpdateHandler = { [weak self] st in
                    let text: String
                    switch st {
                    case .ready: text = "Visible on the network"
                    case .failed(let e): text = "Network error: \(e.localizedDescription)"
                    case .waiting(let e): text = "Waiting for network: \(e.localizedDescription)"
                    case .cancelled: text = "Off"
                    default: text = "Starting…"
                    }
                    DispatchQueue.main.async { self?.listenerStatus = text }
                }
                l.start(queue: self.q)
                self.listener = l

                let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
                b.browseResultsChangedHandler = { [weak self] results, _ in self?.browsed(results) }
                b.start(queue: self.q)
                self.browser = b
            } catch {
                DispatchQueue.main.async { self.listenerStatus = "Could not start: \(error.localizedDescription)" }
            }
        }
        startStatusTimer()
    }

    func stop() {
        statusTimer?.invalidate(); statusTimer = nil
        q.async { [weak self] in
            guard let self else { return }
            self.browser?.cancel(); self.browser = nil
            self.listener?.cancel(); self.listener = nil
            for c in self.connections.values { c.close() }
            self.connections.removeAll(); self.byPeer.removeAll(); self.endpoints.removeAll()
            DispatchQueue.main.async { self.peers.removeAll(); self.listenerStatus = "Off" }
        }
    }

    /// Re-advertise after the name or passcode changes.
    func restart() {
        guard enabled else { return }
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.start() }
    }

    // MARK: discovery (q)

    private func browsed(_ results: Set<NWBrowser.Result>) {
        var seen: [String: (String, NWEndpoint)] = [:]
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint, let parsed = Self.parse(serviceName: name), parsed.id != myID else { continue }
            seen[parsed.id] = (parsed.name, r.endpoint)
        }
        for (id, v) in seen {
            endpoints[id] = v.1
            if byPeer[id] == nil && LinkFrame.shouldInitiate(myID: myID, peerID: id) { connect(id: id, endpoint: v.1) }
        }
        // fallback: if the other side has not connected after a while, connect ourselves
        q.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            for (id, v) in seen where self.byPeer[id] == nil && !LinkFrame.shouldInitiate(myID: self.myID, peerID: id) {
                self.connect(id: id, endpoint: v.1)
            }
        }
        let snapshot = seen.mapValues { $0.0 }
        DispatchQueue.main.async {
            for (id, name) in snapshot {
                if let i = self.peers.firstIndex(where: { $0.id == id }) { self.peers[i].name = name; self.peers[i].lastSeen = Date() }
                else { self.peers.append(LinkPeerInfo(id: id, name: name)) }
            }
            // forget stations that disappeared and are not connected
            self.peers.removeAll { snapshot[$0.id] == nil && !$0.connected }
            self.peers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func connect(id: String, endpoint: NWEndpoint) {
        let c = NWConnection(to: endpoint, using: .tcp)
        let lc = LinkConnection(c, outbound: true, manager: self)
        lc.peerID = id
        connections[ObjectIdentifier(lc)] = lc
        byPeer[id] = lc
        setPeerState(id, .connecting)
        lc.start(on: q)
    }

    /// Manual retry (e.g. after typing the passcode).
    func reconnect(_ peerID: String) {
        q.async { [weak self] in
            guard let self, let ep = self.endpoints[peerID] else { return }
            self.byPeer[peerID]?.close(); self.byPeer[peerID] = nil
            self.connect(id: peerID, endpoint: ep)
        }
    }

    // MARK: connection events (q)

    func sendHello(_ c: LinkConnection) {
        var e = envelope(.hello)
        e.version = LinkFrame.protocolVersion
        c.send(e)
    }

    func connectionEnded(_ c: LinkConnection, reason: String?) {
        connections[ObjectIdentifier(c)] = nil
        if let id = c.peerID, byPeer[id] === c {
            byPeer[id] = nil
            let msg = reason
            DispatchQueue.main.async {
                if let i = self.peers.firstIndex(where: { $0.id == id }) {
                    if case .failed = self.peers[i].state { return }
                    self.peers[i].state = msg.map { .failed($0) } ?? .found
                    self.peers[i].status = nil
                }
                for k in self.transfers.indices where self.transfers[k].peerID == id && self.transfers[k].active {
                    self.transfers[k].state = .failed("connection lost")
                }
            }
        }
    }

    private func envelope(_ kind: LinkKind, to: String? = nil) -> LinkEnvelope {
        LinkEnvelope(kind: kind, from: myID, fromName: nameSnapshot, to: to)
    }
    private var nameCache = ""                                              // q only
    private var nameSnapshot: String { nameCache.isEmpty ? "LiveDeck" : nameCache }

    func handle(_ env: LinkEnvelope, binary: Data, from c: LinkConnection) {
        switch env.kind {
        case .hello:
            c.peerID = env.from; c.peerName = env.fromName
            if myPasscode.isEmpty { welcome(c) }
            else {
                let n = LinkFrame.newNonce(); c.nonce = n
                var ch = envelope(.challenge); ch.nonce = n
                c.send(ch)
            }
            return
        case .challenge:
            var a = envelope(.auth)
            a.proof = LinkFrame.proof(nonce: env.nonce ?? "", passcode: myPasscode)
            c.send(a)
            return
        case .auth:
            if let n = c.nonce, env.proof == LinkFrame.proof(nonce: n, passcode: myPasscode) { welcome(c) }
            else {
                var r = envelope(.reject); r.text = "Wrong passcode"
                c.send(r) { _ in c.close() }
            }
            return
        case .welcome:
            c.peerID = env.from; c.peerName = env.fromName
            authenticated(c)
            return
        case .reject:
            let id = env.from
            let text = env.text ?? "Refused"
            DispatchQueue.main.async { self.setPeerState(id, .failed(text + " — set the same passcode on both computers")) }
            c.close()
            return
        default:
            break
        }
        guard c.authed, let peerID = c.peerID else { return }
        if let to = env.to, to != myID { return }
        let peerName = env.fromName

        switch env.kind {
        case .ping:
            c.send(envelope(.pong, to: peerID))
        case .pong:
            break
        case .status:
            let st = env.status
            DispatchQueue.main.async {
                if let i = self.peers.firstIndex(where: { $0.id == peerID }) { self.peers[i].status = st; self.peers[i].name = peerName; self.peers[i].lastSeen = Date() }
            }
        case .chat, .attention:
            let m = LinkChatMessage(id: env.id, from: peerID, fromName: peerName, to: env.to, toName: env.to == nil ? nil : "you",
                                    text: env.text ?? "", date: env.sent, mine: false, attention: env.kind == .attention)
            DispatchQueue.main.async { self.receiveChat(m) }
        case .libraryRequest:
            DispatchQueue.main.async {
                let items = self.localLibraryItems()
                self.q.async {
                    var r = self.envelope(.library, to: peerID); r.items = items
                    c.send(r)
                }
            }
        case .library:
            let items = env.items ?? []
            DispatchQueue.main.async {
                if let i = self.peers.firstIndex(where: { $0.id == peerID }) { self.peers[i].library = items; self.peers[i].libraryLoading = false }
            }
        case .fileRequest:
            guard let info = env.file else { return }
            DispatchQueue.main.async {
                guard let local = self.localFile(itemID: info.itemID) else {
                    self.q.async { var x = self.envelope(.fileCancel, to: peerID); x.file = info; x.text = "not found"; c.send(x) }
                    return
                }
                var out = info
                out.fileName = local.url.lastPathComponent; out.title = local.title; out.kind = local.kind; out.bytes = local.bytes
                self.addTransfer(LinkTransfer(id: out.transferID, title: out.title, peerID: peerID, peerName: peerName, incoming: false, bytes: out.bytes, state: .sending))
                self.q.async { self.stream(local.url, info: out, over: c) }
            }
        case .fileOffer:
            guard let info = env.file else { return }
            DispatchQueue.main.async {
                self.addTransfer(LinkTransfer(id: info.transferID, title: info.title, peerID: peerID, peerName: peerName, incoming: true,
                                              bytes: info.bytes, state: self.autoAcceptFiles ? .waiting : .offered))
                if self.autoAcceptFiles { self.answerOffer(info.transferID, accept: true) }
                else { self.showToast(LinkChatMessage(from: peerID, fromName: peerName, to: nil, toName: nil, text: "wants to send you “\(info.title)” — accept it in Network", mine: false)) }
            }
            pendingIncomingInfo[info.transferID] = (info, peerID)
        case .fileAccept:
            guard let t = env.file?.transferID, let offer = outgoingOffers[t] else { return }
            outgoingOffers[t] = nil
            if env.accept == true {
                updateTransfer(t) { $0.state = .sending }
                stream(offer.url, info: offer.info, over: c)
            } else {
                updateTransfer(t) { $0.state = .declined }
            }
        case .fileStart:
            guard let info = env.file else { return }
            let dir = incomingFolder()
            let url = dir.appendingPathComponent(info.transferID + "-" + LinkFrame.safeFileName(info.fileName))
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            incomingFiles[info.transferID] = (h, url, info, peerID, peerName)
            DispatchQueue.main.async {
                if self.transfers.contains(where: { $0.id == info.transferID }) { self.updateTransferMain(info.transferID) { $0.state = .receiving } }
                else { self.addTransfer(LinkTransfer(id: info.transferID, title: info.title, peerID: peerID, peerName: peerName, incoming: true, bytes: info.bytes, state: .receiving)) }
            }
        case .fileChunk:
            guard let t = env.file?.transferID, let f = incomingFiles[t] else { return }
            if cancelled.contains(t) { return }
            f.handle.seek(toFileOffset: UInt64(max(0, env.offset ?? 0)))
            f.handle.write(binary)
            let done = (env.offset ?? 0) + Int64(binary.count)
            progress(t, done)
        case .fileEnd:
            guard let t = env.file?.transferID, let f = incomingFiles[t] else { return }
            incomingFiles[t] = nil
            f.handle.closeFile()
            let size = (try? FileManager.default.attributesOfItem(atPath: f.url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size == f.info.bytes else {
                try? FileManager.default.removeItem(at: f.url)
                updateTransfer(t) { $0.state = .failed("incomplete file") }
                return
            }
            DispatchQueue.main.async { self.finishIncoming(f.url, info: f.info, peerName: f.peerName) }
        case .fileCancel:
            guard let t = env.file?.transferID else { return }
            cancelled.insert(t)
            outgoingOffers[t] = nil
            if let f = incomingFiles[t] { f.handle.closeFile(); try? FileManager.default.removeItem(at: f.url); incomingFiles[t] = nil }
            updateTransfer(t) { $0.state = .cancelled }
        case .songShare:
            guard let json = env.json, let data = json.data(using: .utf8) else { return }
            DispatchQueue.main.async { self.importSong(data, from: peerName) }
        case .presetShare:
            guard let json = env.json, let data = json.data(using: .utf8) else { return }
            DispatchQueue.main.async { self.importPreset(data, from: peerName) }
        default:
            break
        }
    }
    private var pendingIncomingInfo: [String: (LinkFileInfo, String)] = [:]   // q only

    private func welcome(_ c: LinkConnection) {
        c.send(envelope(.welcome, to: c.peerID))
        authenticated(c)
    }

    private func authenticated(_ c: LinkConnection) {
        guard let id = c.peerID else { return }
        // keep exactly one connection per station: the one opened by the lower id
        if let existing = byPeer[id], existing !== c, existing.authed {
            let keepNew = c.outbound == LinkFrame.shouldInitiate(myID: myID, peerID: id)
            if keepNew { existing.close() } else { c.close(); return }
        }
        c.authed = true
        byPeer[id] = c
        let name = c.peerName
        DispatchQueue.main.async {
            if let i = self.peers.firstIndex(where: { $0.id == id }) { self.peers[i].state = .connected; self.peers[i].name = name }
            else { self.peers.append(LinkPeerInfo(id: id, name: name, state: .connected)) }
            self.sendStatusNow()
        }
    }

    // MARK: status

    private func startStatusTimer() {
        statusTimer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sendStatusNow() }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
    }

    private func sendStatusNow() {
        guard enabled else { return }
        var st: LinkStatus?
        if shareStatus, let e = engine {
            let pgm = e.sources.first { $0.id == e.programID }
            let pvw = e.sources.first { $0.id == e.previewID }
            let live = (pgm as? SlideSource)?.content.body ?? ""
            st = LinkStatus(program: pgm?.name ?? "", preview: pvw?.name ?? "", recording: e.isRecording, streaming: e.isStreaming,
                            recordSeconds: e.recordSeconds, keyed: e.keyedSources.count, liveText: String(live.prefix(160)))
        }
        q.async { [weak self] in
            guard let self else { return }
            for c in self.byPeer.values where c.authed {
                var env = self.envelope(st == nil ? .ping : .status)
                env.status = st
                c.send(env)
            }
        }
    }

    // MARK: chat

    static let quickMessages = ["Standby", "Ready", "Go", "Next slide", "Previous slide", "Camera 1", "Camera 2", "Wide shot",
                                "Mic check", "Wrap up", "Hold", "Thank you"]

    func sendChat(_ text: String, to peerID: String? = nil, attention: Bool = false) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || attention else { return }
        let toName = peerID.flatMap { id in peers.first { $0.id == id }?.name }
        messages.append(LinkChatMessage(from: myID, fromName: stationName, to: peerID, toName: toName ?? (peerID == nil ? "Everyone" : nil),
                                        text: attention ? (t.isEmpty ? "⚠︎ Attention" : "⚠︎ " + t) : t, mine: true, attention: attention))
        trimMessages()
        q.async { [weak self] in
            guard let self else { return }
            let targets = peerID.map { id in self.byPeer[id].map { [$0] } ?? [] } ?? Array(self.byPeer.values)
            for c in targets where c.authed {
                var e = self.envelope(attention ? .attention : .chat, to: peerID)
                e.text = t.isEmpty ? "Attention" : t
                c.send(e)
            }
        }
    }

    private func receiveChat(_ m: LinkChatMessage) {
        messages.append(m)
        trimMessages()
        if engine?.rightTab != 6 { unread += 1 }
        showToast(m)
        if m.attention { NSSound.beep() }
    }

    private func trimMessages() { if messages.count > 300 { messages.removeFirst(messages.count - 300) } }

    func showToast(_ m: LinkChatMessage) {
        toast = m
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: m.attention ? 10 : 6, repeats: false) { [weak self] _ in
            withAnimation { self?.toast = nil }
        }
    }

    func markRead() { unread = 0 }

    // MARK: media sharing (main)

    func requestLibrary(_ peerID: String) {
        browsingPeerID = peerID
        if let i = peers.firstIndex(where: { $0.id == peerID }) { peers[i].libraryLoading = true }
        q.async { [weak self] in
            guard let self, let c = self.byPeer[peerID], c.authed else { return }
            c.send(self.envelope(.libraryRequest, to: peerID))
        }
    }

    func requestFile(_ item: LinkMediaItem, from peerID: String, addAsInput: Bool) {
        let info = LinkFileInfo(itemID: item.id, fileName: item.title, title: item.title, kind: item.kind, bytes: item.bytes, addAsInput: addAsInput)
        let peerName = peers.first { $0.id == peerID }?.name ?? "station"
        addTransfer(LinkTransfer(id: info.transferID, title: item.title, peerID: peerID, peerName: peerName, incoming: true, bytes: item.bytes, state: .waiting))
        q.async { [weak self] in
            guard let self, let c = self.byPeer[peerID], c.authed else { return }
            var e = self.envelope(.fileRequest, to: peerID); e.file = info
            c.send(e)
        }
    }

    /// Offers a file (library item or input file) to one station or everyone.
    func offerFile(_ url: URL, title: String, to peerID: String?, addAsInput: Bool = false) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let ext = url.pathExtension.lowercased()
        let kind = BackgroundsModel.videoExtensions.contains(ext) ? "video" : "image"
        let targets = peerID.map { [$0] } ?? connectedPeers.map { $0.id }
        for pid in targets {
            let info = LinkFileInfo(itemID: url.lastPathComponent, fileName: url.lastPathComponent, title: title, kind: kind, bytes: size, addAsInput: addAsInput)
            let name = peers.first { $0.id == pid }?.name ?? "station"
            addTransfer(LinkTransfer(id: info.transferID, title: title, peerID: pid, peerName: name, incoming: false, bytes: size, state: .offered))
            q.async { [weak self] in
                guard let self, let c = self.byPeer[pid], c.authed else { return }
                self.outgoingOffers[info.transferID] = (url, info, pid)
                var e = self.envelope(.fileOffer, to: pid); e.file = info
                c.send(e)
            }
        }
    }

    func offerLibraryItem(_ item: LocalBackground, to peerID: String?, addAsInput: Bool = false) {
        guard let bg = backgrounds else { return }
        offerFile(bg.catalog.url(item), title: item.title, to: peerID, addAsInput: addAsInput)
    }

    func answerOffer(_ transferID: String, accept: Bool) {
        updateTransferMain(transferID) { $0.state = accept ? .waiting : .declined }
        q.async { [weak self] in
            guard let self, let pending = self.pendingIncomingInfo[transferID], let c = self.byPeer[pending.1] else { return }
            self.pendingIncomingInfo[transferID] = nil
            var e = self.envelope(.fileAccept, to: pending.1); e.file = pending.0; e.accept = accept
            c.send(e)
        }
    }

    func cancelTransfer(_ transferID: String) {
        guard let t = transfers.first(where: { $0.id == transferID }) else { return }
        updateTransferMain(transferID) { $0.state = .cancelled }
        q.async { [weak self] in
            guard let self else { return }
            self.cancelled.insert(transferID)
            self.outgoingOffers[transferID] = nil
            if let f = self.incomingFiles[transferID] { f.handle.closeFile(); try? FileManager.default.removeItem(at: f.url); self.incomingFiles[transferID] = nil }
            if let c = self.byPeer[t.peerID] {
                var e = self.envelope(.fileCancel, to: t.peerID)
                e.file = LinkFileInfo(transferID: transferID, itemID: "", fileName: "", title: t.title, kind: "", bytes: t.bytes)
                c.send(e)
            }
        }
    }

    func clearFinishedTransfers() { transfers.removeAll { !$0.active } }

    func shareSong(_ song: Song, to peerID: String?) {
        guard let data = try? JSONEncoder().encode(song), let json = String(data: data, encoding: .utf8) else { return }
        sendDocument(.songShare, json: json, to: peerID)
        messages.append(LinkChatMessage(from: myID, fromName: stationName, to: peerID, toName: peerName(peerID), text: "🎵 Sent song “\(song.meta.title)”", mine: true))
    }

    func sharePreset(_ preset: AppPreset, to peerID: String?) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(preset), let json = String(data: data, encoding: .utf8) else { return }
        sendDocument(.presetShare, json: json, to: peerID)
        messages.append(LinkChatMessage(from: myID, fromName: stationName, to: peerID, toName: peerName(peerID), text: "🗂 Sent preset “\(preset.name)”", mine: true))
    }

    private func peerName(_ id: String?) -> String { id.flatMap { i in peers.first { $0.id == i }?.name } ?? "Everyone" }

    private func sendDocument(_ kind: LinkKind, json: String, to peerID: String?) {
        q.async { [weak self] in
            guard let self else { return }
            let targets = peerID.map { id in self.byPeer[id].map { [$0] } ?? [] } ?? Array(self.byPeer.values)
            for c in targets where c.authed {
                var e = self.envelope(kind, to: c.peerID); e.json = json
                c.send(e)
            }
        }
    }

    // MARK: transfers (q)

    private func stream(_ url: URL, info: LinkFileInfo, over c: LinkConnection) {
        guard let h = try? FileHandle(forReadingFrom: url) else {
            updateTransfer(info.transferID) { $0.state = .failed("cannot read file") }
            return
        }
        var start = envelope(.fileStart, to: c.peerID); start.file = info
        c.send(start)
        sendChunk(h, info: info, offset: 0, over: c)
    }

    private func sendChunk(_ h: FileHandle, info: LinkFileInfo, offset: Int64, over c: LinkConnection) {
        if cancelled.contains(info.transferID) { h.closeFile(); return }
        let data = h.readData(ofLength: LinkFrame.chunkBytes)
        if data.isEmpty {
            h.closeFile()
            var end = envelope(.fileEnd, to: c.peerID); end.file = info
            c.send(end)
            updateTransfer(info.transferID) { $0.done = $0.bytes; $0.state = .done }
            return
        }
        var e = envelope(.fileChunk, to: c.peerID); e.file = info; e.offset = offset
        let next = offset + Int64(data.count)
        c.send(e, binary: data) { [weak self] ok in
            guard let self else { return }
            guard ok else { h.closeFile(); self.updateTransfer(info.transferID) { $0.state = .failed("send failed") }; return }
            self.progress(info.transferID, next)
            self.sendChunk(h, info: info, offset: next, over: c)
        }
    }

    private func progress(_ id: String, _ done: Int64) {
        let now = Date()
        if let last = lastProgress[id], now.timeIntervalSince(last) < 0.2 { return }
        lastProgress[id] = now
        updateTransfer(id) { $0.done = done }
    }

    private func updateTransfer(_ id: String, _ change: @escaping (inout LinkTransfer) -> Void) {
        DispatchQueue.main.async { self.updateTransferMain(id, change) }
    }

    // MARK: main-thread helpers

    private func updateTransferMain(_ id: String, _ change: (inout LinkTransfer) -> Void) {
        if let i = transfers.firstIndex(where: { $0.id == id }) { change(&transfers[i]) }
    }

    private func addTransfer(_ t: LinkTransfer) {
        transfers.removeAll { $0.id == t.id }
        transfers.insert(t, at: 0)
        if transfers.count > 60 { transfers.removeLast(transfers.count - 60) }
    }

    private func setPeerState(_ id: String, _ s: LinkPeerInfo.State) {
        if Thread.isMainThread {
            if let i = peers.firstIndex(where: { $0.id == id }) { peers[i].state = s }
        } else {
            DispatchQueue.main.async { self.setPeerState(id, s) }
        }
    }

    private func incomingFolder() -> URL {
        let u = PresentationLibrary.defaultRoot.appendingPathComponent("Backgrounds").appendingPathComponent("incoming-link")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func localLibraryItems() -> [LinkMediaItem] {
        guard let bg = backgrounds else { return [] }
        return bg.catalog.items.map { item in
            let size = (try? FileManager.default.attributesOfItem(atPath: bg.catalog.url(item).path)[.size] as? NSNumber)?.int64Value ?? 0
            return LinkMediaItem(id: item.id, title: item.title, kind: item.kind.rawValue, bytes: size, category: item.category)
        }
    }

    private func localFile(itemID: String) -> (url: URL, title: String, kind: String, bytes: Int64)? {
        guard let bg = backgrounds, let item = bg.catalog.items.first(where: { $0.id == itemID }) else { return nil }
        let url = bg.catalog.url(item)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (url, item.title, item.kind.rawValue, size)
    }

    private func finishIncoming(_ url: URL, info: LinkFileInfo, peerName: String) {
        guard let bg = backgrounds else { return }
        let kind: MediaKind = info.kind == "video" || BackgroundsModel.videoExtensions.contains(url.pathExtension.lowercased()) ? .video : .image
        var saved: LocalBackground?
        if let item = try? bg.catalog.add(file: url, id: "link-" + info.transferID, title: info.title, kind: kind, category: "Shared",
                                          credit: "from " + peerName, provider: "LiveDeck Link") {
            saved = item
        }
        try? FileManager.default.removeItem(at: url)
        bg.refresh()
        updateTransferMain(info.transferID) { $0.done = $0.bytes; $0.state = saved == nil ? .failed("could not save") : .done }
        if let s = saved {
            if info.addAsInput { bg.addAsInput(s, .input) }
            showToast(LinkChatMessage(from: "", fromName: peerName, to: nil, toName: nil,
                                      text: "sent “\(s.title)” — it is in Media → Library\(info.addAsInput ? " and added as an input" : "")", mine: false))
        }
    }

    private func importSong(_ data: Data, from peerName: String) {
        guard let present, var song = try? JSONDecoder().decode(Song.self, from: data) else { return }
        if present.library.songs[song.id] != nil {
            song.id = UUID()
            song.meta.title += " (from \(peerName))"
        }
        _ = try? present.library.songs.save(song)
        present.refreshSongs()
        messages.append(LinkChatMessage(from: "", fromName: peerName, to: nil, toName: nil, text: "🎵 Song “\(song.meta.title)” received", mine: false))
        showToast(LinkChatMessage(from: "", fromName: peerName, to: nil, toName: nil, text: "sent the song “\(song.meta.title)” — it is in Songs & Bible", mine: false))
    }

    private func importPreset(_ data: Data, from peerName: String) {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let presets, var p = try? dec.decode(AppPreset.self, from: data) else { return }
        p.name += " (from \(peerName))"
        presets.importPreset(p)
        showToast(LinkChatMessage(from: "", fromName: peerName, to: nil, toName: nil, text: "sent the preset “\(p.name)” — see Presets", mine: false))
    }
}

// MARK: - Network panel (right panel tab)

struct NetworkPanel: View {
    @EnvironmentObject var link: LinkManager
    @EnvironmentObject var bg: BackgroundsModel
    @State private var draft = ""
    @State private var nameDraft = ""
    @State private var passDraft = ""

    var body: some View {
        CPInspector {
            CPCard(title: "This computer", subtitle: link.enabled ? link.listenerStatus : "Network sharing is off",
                   icon: "desktopcomputer", iconColor: link.enabled ? DS.ok : CP.icon) {
                CPToggleRow(icon: "network", label: "Share on this network", isOn: $link.enabled, showDivider: true)
                CPRow(icon: "character.cursor.ibeam", label: "Station name") {
                    HStack(spacing: 4) {
                        TextField("e.g. Front of house", text: $nameDraft).dsField().frame(maxWidth: 150)
                            .onSubmit { applyName() }
                        if nameDraft != link.stationName { CPButton(title: "Set") { applyName() } }
                    }
                }
                CPRow(icon: "lock", label: "Passcode") {
                    HStack(spacing: 4) {
                        SecureField("optional", text: $passDraft).textFieldStyle(.plain).font(.system(size: 11.5)).foregroundColor(CP.text)
                            .padding(.horizontal, 7).frame(width: 110, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(CP.field))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CP.border, lineWidth: 1))
                            .onSubmit { applyPass() }
                        if passDraft != link.passcode { CPButton(title: "Set") { applyPass() } }
                    }
                }
                CPToggleRow(icon: "tray.and.arrow.down", label: "Accept files without asking", isOn: $link.autoAcceptFiles)
                CPToggleRow(icon: "dot.radiowaves.left.and.right", label: "Share what is on air", isOn: $link.shareStatus)
                CPNote("Every Mac running LiveDeck on the same network appears below. Use the same passcode on all of them to keep others out. macOS may ask to allow local network access — choose Allow.")
            }
            .onAppear { nameDraft = link.stationName; passDraft = link.passcode; link.markRead() }

            CPCard(title: "Stations", subtitle: link.enabled ? "\(link.connectedPeers.count) connected · \(link.peers.count) found" : "Turn on sharing to find other computers",
                   icon: "rectangle.connected.to.line.below") {
                if link.enabled && link.peers.isEmpty {
                    CPNote("Looking for other LiveDeck computers… Open LiveDeck on another Mac on this network and turn on Share on this network.")
                }
                ForEach(link.peers) { p in
                    CPDivider()
                    PeerRow(peer: p)
                }
            }

            CPCard(title: "Messages", subtitle: link.unread > 0 ? "\(link.unread) unread" : "\(link.messages.count) messages", icon: "bubble.left.and.bubble.right") {
                CPRow(label: "To") {
                    Picker("", selection: $link.chatTarget) {
                        Text("Everyone").tag(String?.none)
                        ForEach(link.connectedPeers) { p in Text(p.name).tag(String?.some(p.id)) }
                    }
                    .cpPickerChrome().frame(maxWidth: 170)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(link.messages) { m in ChatBubble(message: m).id(m.id) }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 200)
                    .background(RoundedRectangle(cornerRadius: 6).fill(CP.field))
                    .onChange(of: link.messages.count) { _ in if let last = link.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
                    .onAppear { if let last = link.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(LinkManager.quickMessages, id: \.self) { q in
                            Button(q) { link.sendChat(q, to: link.chatTarget) }.buttonStyle(.ds(.normal, .small))
                        }
                    }
                    .padding(.vertical, 5)
                }
                HStack(spacing: 6) {
                    TextField("Type a message", text: $draft).dsField().onSubmit { send() }
                    CPButton(icon: "paperplane.fill", title: "Send", prominent: true) { send() }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || link.connectedPeers.isEmpty)
                    Button { link.sendChat(draft, to: link.chatTarget, attention: true); draft = "" } label: { Image(systemName: "exclamationmark.triangle.fill") }
                        .buttonStyle(.ds(.amber, .small)).help("Attention: flashes and beeps on the other computer")
                        .disabled(link.connectedPeers.isEmpty)
                }
                .padding(.vertical, 6)
            }

            if let pid = link.browsingPeerID, let p = link.peers.first(where: { $0.id == pid }) {
                CPCard(title: "Media on \(p.name)", subtitle: p.libraryLoading ? "Loading…" : "\(p.library?.count ?? 0) items", icon: "photo.stack", onReset: { link.browsingPeerID = nil }) {
                    if let items = p.library, !items.isEmpty {
                        ForEach(items) { item in
                            CPDivider()
                            HStack(spacing: 8) {
                                Image(systemName: item.kind == "video" ? "film" : "photo").foregroundColor(CP.text2).frame(width: 16)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.title).font(.system(size: 11.5)).foregroundColor(CP.text).lineLimit(1)
                                    Text("\(item.category) · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))")
                                        .font(.system(size: 9)).foregroundColor(CP.text2)
                                }
                                Spacer()
                                CPButton(icon: "arrow.down.circle", title: "Get") { link.requestFile(item, from: p.id, addAsInput: false) }
                            }
                            .padding(.vertical, 4)
                            .contextMenu {
                                Button("Download to my library") { link.requestFile(item, from: p.id, addAsInput: false) }
                                Button("Download and add as input") { link.requestFile(item, from: p.id, addAsInput: true) }
                            }
                        }
                    } else if !p.libraryLoading {
                        CPNote("No media in their library yet.")
                    }
                }
            }

            CPCard(title: "Transfers", subtitle: link.transfers.filter { $0.active }.isEmpty ? "\(link.transfers.count) recent" : "\(link.transfers.filter { $0.active }.count) in progress",
                   icon: "arrow.up.arrow.down.circle") {
                if link.transfers.isEmpty {
                    CPNote("Right-click an item in Media → Library, a song, a preset or an input to send it to another computer.")
                }
                ForEach(link.transfers) { t in
                    CPDivider()
                    TransferRow(transfer: t)
                }
                if link.transfers.contains(where: { !$0.active }) {
                    HStack { Spacer(); Button("Clear finished") { link.clearFinishedTransfers() }.buttonStyle(.ds(.ghost, .small)) }.padding(.vertical, 4)
                }
            }
        }
        .onAppear { link.markRead() }
    }

    private func send() {
        link.sendChat(draft, to: link.chatTarget)
        draft = ""
    }
    private func applyName() {
        let n = nameDraft.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        link.stationName = n
        link.restart()
    }
    private func applyPass() {
        link.passcode = passDraft
        link.restart()
    }
}

struct PeerRow: View {
    @EnvironmentObject var link: LinkManager
    let peer: LinkPeerInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(peer.name).font(.system(size: 12, weight: .semibold)).foregroundColor(CP.text).lineLimit(1)
                    Text(stateText).font(.system(size: 9.5)).foregroundColor(stateColor).lineLimit(2)
                }
                Spacer()
                if peer.connected {
                    if let s = peer.status {
                        if s.recording { badge("REC", DS.program) }
                        if s.streaming { badge("LIVE", DS.program) }
                    }
                    Menu {
                        Button("Message \(peer.name)") { link.chatTarget = peer.id }
                        Button("Attention!") { link.sendChat("", to: peer.id, attention: true) }
                        Divider()
                        Button("Browse their media") { link.requestLibrary(peer.id) }
                    } label: { Image(systemName: "ellipsis.circle").foregroundColor(CP.text) }
                    .menuStyle(.borderlessButton).fixedSize()
                } else {
                    CPButton(title: "Connect") { link.reconnect(peer.id) }
                }
            }
            if let s = peer.status, peer.connected {
                HStack(spacing: 6) {
                    tally("PGM", s.program, DS.program)
                    tally("PVW", s.preview, DS.preview)
                    if s.keyed > 0 { tally("KEY", "\(s.keyed)", DS.amber) }
                    if s.recording {
                        Text(String(format: "%02d:%02d:%02d", s.recordSeconds / 3600, s.recordSeconds / 60 % 60, s.recordSeconds % 60))
                            .font(DS.mono(9)).foregroundColor(CP.text2)
                    }
                }
                if !s.liveText.isEmpty {
                    Text(s.liveText).font(.system(size: 9.5)).foregroundColor(CP.text2).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            if peer.connected {
                Button("Message \(peer.name)") { link.chatTarget = peer.id }
                Button("Attention!") { link.sendChat("", to: peer.id, attention: true) }
                Button("Browse their media") { link.requestLibrary(peer.id) }
            } else {
                Button("Connect") { link.reconnect(peer.id) }
            }
        }
    }

    private var dotColor: Color {
        switch peer.state {
        case .connected: return DS.ok
        case .connecting: return DS.amber
        case .failed: return DS.program
        case .found: return CP.text2
        }
    }
    private var stateColor: Color { if case .failed = peer.state { return DS.program }; return CP.text2 }
    private var stateText: String {
        switch peer.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .failed(let r): return r
        case .found: return "Found on the network"
        }
    }
    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 8, weight: .heavy)).foregroundColor(.white)
            .padding(.horizontal, 4).frame(height: 14).background(RoundedRectangle(cornerRadius: 3).fill(c))
    }
    private func tally(_ label: String, _ value: String, _ c: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 8, weight: .heavy)).foregroundColor(.white)
                .padding(.horizontal, 3).frame(height: 13).background(RoundedRectangle(cornerRadius: 2).fill(c))
            Text(value.isEmpty ? "—" : value).font(.system(size: 10)).foregroundColor(CP.text).lineLimit(1)
        }
    }
}

struct ChatBubble: View {
    let message: LinkChatMessage
    var body: some View {
        HStack {
            if message.mine { Spacer(minLength: 30) }
            VStack(alignment: message.mine ? .trailing : .leading, spacing: 1) {
                Text(message.mine ? "You → \(message.toName ?? "Everyone")" : message.fromName + (message.to == nil ? "" : " (to you)"))
                    .font(.system(size: 8.5, weight: .semibold)).foregroundColor(CP.text2)
                Text(message.text).font(.system(size: 11.5)).foregroundColor(message.attention ? .black : CP.text)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(message.attention ? DS.amber : (message.mine ? CP.blue.opacity(0.55) : CP.cardHeader)))
                    .textSelection(.enabled)
                Text(message.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 8)).foregroundColor(CP.text2)
            }
            if !message.mine { Spacer(minLength: 30) }
        }
        .padding(.horizontal, 6)
    }
}

struct TransferRow: View {
    @EnvironmentObject var link: LinkManager
    let transfer: LinkTransfer
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: transfer.incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .foregroundColor(transfer.incoming ? DS.preview : CP.icon)
                VStack(alignment: .leading, spacing: 0) {
                    Text(transfer.title).font(.system(size: 11.5)).foregroundColor(CP.text).lineLimit(1)
                    Text("\(transfer.incoming ? "from" : "to") \(transfer.peerName) · \(stateText)")
                        .font(.system(size: 9)).foregroundColor(isFailure ? DS.program : CP.text2).lineLimit(1)
                }
                Spacer()
                if transfer.state == .offered && transfer.incoming {
                    CPButton(title: "Accept", prominent: true) { link.answerOffer(transfer.id, accept: true) }
                    CPButton(title: "Decline") { link.answerOffer(transfer.id, accept: false) }
                } else if transfer.active {
                    Button { link.cancelTransfer(transfer.id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundColor(CP.text2).help("Cancel")
                }
            }
            if transfer.state == .sending || transfer.state == .receiving {
                ProgressView(value: transfer.fraction).tint(CP.blue)
            }
        }
        .padding(.vertical, 5)
    }
    private var isFailure: Bool { if case .failed = transfer.state { return true }; return false }
    private var stateText: String {
        let size = ByteCountFormatter.string(fromByteCount: transfer.bytes, countStyle: .file)
        switch transfer.state {
        case .offered: return transfer.incoming ? "wants to send \(size)" : "waiting for them to accept"
        case .waiting: return "starting…"
        case .sending, .receiving: return "\(Int(transfer.fraction * 100))% of \(size)"
        case .done: return "done · \(size)"
        case .declined: return "declined"
        case .failed(let r): return "failed: \(r)"
        case .cancelled: return "cancelled"
        }
    }
}

/// Floating notification for incoming messages and files.
struct LinkToast: View {
    @EnvironmentObject var link: LinkManager
    @EnvironmentObject var engine: Engine
    var body: some View {
        if let m = link.toast {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: m.attention ? "exclamationmark.triangle.fill" : "bubble.left.fill")
                    .font(.system(size: 18)).foregroundColor(m.attention ? .black : CP.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.fromName).font(.system(size: 11, weight: .bold)).foregroundColor(m.attention ? .black : CP.text)
                    Text(m.text).font(.system(size: 13, weight: .medium)).foregroundColor(m.attention ? .black : CP.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button { withAnimation { link.toast = nil } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundColor(m.attention ? .black : CP.text2)
            }
            .padding(12)
            .frame(width: 340, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(m.attention ? DS.amber : CP.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(m.attention ? Color.white.opacity(0.6) : CP.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
            .onTapGesture { engine.rightTab = 6; link.markRead(); withAnimation { link.toast = nil } }
            .transition(.move(edge: .top).combined(with: .opacity))
            .padding(.top, 56).padding(.trailing, 16)
        }
    }
}

/// "Send to" submenu used in right-click menus.
struct LinkSendMenu: View {
    @EnvironmentObject var link: LinkManager
    let title: String
    let send: (_ peerID: String?) -> Void
    var body: some View {
        if link.enabled && !link.connectedPeers.isEmpty {
            Menu(title) {
                ForEach(link.connectedPeers) { p in Button(p.name) { send(p.id) } }
                if link.connectedPeers.count > 1 {
                    Divider()
                    Button("All connected computers") { send(nil) }
                }
            }
        }
    }
}


/// Top-bar indicator: connected computers + unread messages.
struct LinkTopBarButton: View {
    @EnvironmentObject var link: LinkManager
    @EnvironmentObject var engine: Engine
    var body: some View {
        Button { engine.rightTab = 6; link.markRead() } label: {
            HStack(spacing: 5) {
                Image(systemName: link.enabled ? "network" : "network.slash")
                Text(link.enabled ? "LINK \(link.connectedPeers.count)" : "LINK").font(.system(size: 11, weight: .semibold))
                if link.unread > 0 {
                    Text("\(link.unread)").font(.system(size: 9, weight: .heavy)).foregroundColor(.white)
                        .padding(.horizontal, 5).frame(height: 15).background(Capsule().fill(DS.program))
                }
            }
            .foregroundColor(link.enabled && !link.connectedPeers.isEmpty ? DS.ok : DS.text2)
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(DS.bg0))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Other LiveDeck computers on this network: messages, status and media sharing")
        .contextMenu {
            Toggle("Share on this network", isOn: $link.enabled)
            Button("Open Network panel") { engine.rightTab = 6; link.markRead() }
            if !link.connectedPeers.isEmpty {
                Divider()
                Menu("Quick message to everyone") {
                    ForEach(LinkManager.quickMessages, id: \.self) { m in Button(m) { link.sendChat(m) } }
                }
                Button("Attention to everyone") { link.sendChat("", attention: true) }
            }
        }
    }
}
