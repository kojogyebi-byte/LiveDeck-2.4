import Foundation
import Network
import SwiftUI
import AppKit
import Combine
import PresentationKit

// MARK: - Blackmagic ATEM switcher control (UDP 9910, no SDK needed)

final class ATEMSwitcher: NSObject, ObservableObject {
    enum Status: Equatable { case disconnected, connecting, connected, failed(String) }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var state = ATEMState()
    @Published var host: String = UserDefaults.standard.string(forKey: "atem.host") ?? "192.168.10.240" {
        didSet { UserDefaults.standard.set(host, forKey: "atem.host") }
    }
    @Published var autoConnect: Bool = UserDefaults.standard.bool(forKey: "atem.autoConnect") {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "atem.autoConnect") }
    }
    @Published var me = 0
    /// LiveDeck ↔ ATEM link
    @Published var driveATEM: Bool = UserDefaults.standard.bool(forKey: "atem.drive") { didSet { UserDefaults.standard.set(driveATEM, forKey: "atem.drive") } }
    @Published var followATEM: Bool = UserDefaults.standard.bool(forKey: "atem.follow") { didSet { UserDefaults.standard.set(followATEM, forKey: "atem.follow") } }
    /// LiveDeck input name → ATEM source id
    @Published var mapping: [String: UInt16] = (UserDefaults.standard.dictionary(forKey: "atem.mapping") as? [String: Int] ?? [:]).mapValues { UInt16($0) } {
        didSet { UserDefaults.standard.set(mapping.mapValues { Int($0) }, forKey: "atem.mapping") }
    }

    weak var engine: Engine?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "livedeck.atem", qos: .userInitiated)
    // queue-only state
    private var session: UInt16 = 0
    private var established = false
    private var nextPacketID: UInt16 = 1
    private var lastRemoteID: UInt16 = 0
    private var lastReceived = Date.distantPast
    private var inFlight: [UInt16: (data: Data, sent: Date, tries: Int)] = [:]
    private var pendingState = ATEMState()
    private var timer: DispatchSourceTimer?
    private var wantConnected = false
    private var cancellables = Set<AnyCancellable>()
    private var lastEcho = Date.distantPast

    var isConnected: Bool { status == .connected }

    func activate(engine: Engine) {
        self.engine = engine
        // LiveDeck → ATEM
        engine.$programID.removeDuplicates().dropFirst().sink { [weak self] id in
            guard let self, self.driveATEM, self.isConnected, Date().timeIntervalSince(self.lastEcho) > 0.6,
                  let id, let s = engine.sources.first(where: { $0.id == id }), let src = self.mapping[s.name] else { return }
            self.send(ATEMCommand.program(me: self.me, source: src))
        }.store(in: &cancellables)
        engine.$previewID.removeDuplicates().dropFirst().sink { [weak self] id in
            guard let self, self.driveATEM, self.isConnected,
                  let id, let s = engine.sources.first(where: { $0.id == id }), let src = self.mapping[s.name] else { return }
            self.send(ATEMCommand.preview(me: self.me, source: src))
        }.store(in: &cancellables)
        if autoConnect { connect() }
    }

    // MARK: connection

    func connect() {
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        disconnect()
        wantConnected = true
        status = .connecting
        queue.async { [weak self] in self?.open(target) }
    }

    func disconnect() {
        wantConnected = false
        queue.async { [weak self] in
            self?.timer?.cancel(); self?.timer = nil
            self?.connection?.cancel(); self?.connection = nil
            self?.established = false
        }
        status = .disconnected
    }

    private func open(_ target: String) {
        session = 0; established = false; nextPacketID = 1; lastRemoteID = 0; inFlight = [:]; pendingState = ATEMState()
        let c = NWConnection(host: NWEndpoint.Host(target), port: NWEndpoint.Port(rawValue: ATEMPacket.port)!, using: .udp)
        connection = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.lastReceived = Date()
                c.send(content: ATEMPacket.hello, completion: .contentProcessed { _ in })
                self.receive(c)
            case .failed(let e):
                DispatchQueue.main.async { self.status = .failed(e.localizedDescription) }
                self.scheduleReconnect()
            default: break
            }
        }
        c.start(queue: queue)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let packet = ATEMPacket.parse(data) { self.handle(packet) }
            if error == nil && self.connection === c { self.receive(c) }
        }
    }

    private func handle(_ p: ATEMPacket) {
        lastReceived = Date()
        session = p.sessionID
        if p.flags.contains(.newSession) {
            established = true
            lastRemoteID = p.packetID
            sendRaw(ATEMPacket.ack(session: session, remotePacketID: p.packetID))
            return
        }
        guard established else { return }
        if p.flags.contains(.ackRequest) {
            let expected = (lastRemoteID + 1) % ATEMPacket.maxPacketID
            if p.packetID == expected {
                lastRemoteID = p.packetID
                sendRaw(ATEMPacket.ack(session: session, remotePacketID: p.packetID))
                if !p.payload.isEmpty { apply(p.payload) }
            } else {
                // duplicate / old packet: acknowledge what we have
                sendRaw(ATEMPacket.ack(session: session, remotePacketID: lastRemoteID))
            }
        }
        if p.flags.contains(.ackReply) {
            let acked = p.ackID
            inFlight = inFlight.filter { id, _ in !(id <= acked || (acked < 1000 && id > 30000)) }
        }
    }

    private func apply(_ payload: Data) {
        var changed = false
        for c in ATEMCommand.split(payload) { if pendingState.apply(c.name, c.body) { changed = true } }
        guard changed || pendingState.initComplete else { return }
        let snapshot = pendingState
        DispatchQueue.main.async {
            let oldProgram = self.state.program[self.me]
            self.state = snapshot
            if snapshot.initComplete, self.status != .connected { self.status = .connected }
            if self.followATEM, let pgm = snapshot.program[self.me], pgm != oldProgram { self.followProgram(pgm) }
        }
    }

    private func tick() {
        guard wantConnected else { return }
        let now = Date()
        if now.timeIntervalSince(lastReceived) > 5 {
            DispatchQueue.main.async { if self.wantConnected { self.status = .failed("No reply from the switcher — check the IP address and network.") } }
            connection?.cancel(); connection = nil; timer?.cancel(); timer = nil
            scheduleReconnect()
            return
        }
        for (id, item) in inFlight where now.timeIntervalSince(item.sent) > 0.2 {
            if item.tries >= 10 { inFlight[id] = nil; continue }
            var d = item.data
            if d.count >= 1 { d[0] |= (ATEMPacket.Flags.retransmit.rawValue << 3) }
            sendRaw(d)
            inFlight[id] = (item.data, now, item.tries + 1)
        }
    }

    private func scheduleReconnect() {
        let target = host
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.wantConnected, self.connection == nil else { return }
            DispatchQueue.main.async { self.status = .connecting }
            self.open(target)
        }
    }

    private func sendRaw(_ d: Data) { connection?.send(content: d, completion: .contentProcessed { _ in }) }

    /// Sends one or more command blocks reliably.
    func send(_ commands: Data) {
        queue.async { [weak self] in
            guard let self, self.established else { return }
            let id = self.nextPacketID
            self.nextPacketID = (self.nextPacketID + 1) % ATEMPacket.maxPacketID
            let d = ATEMPacket(flags: .ackRequest, sessionID: self.session, packetID: id, payload: commands).encode()
            self.inFlight[id] = (d, Date(), 0)
            self.sendRaw(d)
        }
    }

    // MARK: actions

    func cut() { send(ATEMCommand.cut(me: me)) }
    func auto() { send(ATEMCommand.auto(me: me)) }
    func fadeToBlack() { send(ATEMCommand.fadeToBlack(me: me)) }
    func setProgram(_ src: UInt16) { lastEcho = Date(); send(ATEMCommand.program(me: me, source: src)) }
    func setPreview(_ src: UInt16) { send(ATEMCommand.preview(me: me, source: src)) }
    func setStyle(_ style: UInt8) { send(ATEMCommand.transitionStyle(me: me, style: style)) }
    func setTBar(_ position: Double) { send(ATEMCommand.transitionPosition(me: me, position: UInt16(max(0, min(1, position)) * 10000))) }
    func dsk(_ keyer: Int, onAir: Bool) { send(ATEMCommand.downstreamKeyOnAir(keyer: keyer, onAir: onAir)) }
    func dskAuto(_ keyer: Int) { send(ATEMCommand.downstreamKeyAuto(keyer: keyer)) }
    func upstreamKey(_ keyer: Int, onAir: Bool) { send(ATEMCommand.upstreamKeyOnAir(me: me, keyer: keyer, onAir: onAir)) }
    func runMacro(_ index: Int) { send(ATEMCommand.runMacro(index)) }
    func setAux(_ aux: Int, _ src: UInt16) { send(ATEMCommand.auxSource(aux: aux, source: src)) }

    /// ATEM → LiveDeck: put the mapped input on LiveDeck's Program.
    private func followProgram(_ atemSource: UInt16) {
        guard let engine, let name = mapping.first(where: { $0.value == atemSource })?.key,
              let s = engine.sources.first(where: { $0.name == name && !$0.isPlaceholder }), engine.programID != s.id else { return }
        lastEcho = Date()
        engine.setPreview(s.id)
        engine.cut()
    }

    func name(_ id: UInt16?) -> String {
        guard let id else { return "—" }
        return state.inputs[id]?.longName ?? "Source \(id)"
    }
}

// MARK: - Finding ATEMs on the network (Bonjour _blackmagic._tcp)

final class ATEMDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Found: Identifiable, Hashable { let name: String; let host: String; var id: String { name + host } }
    @Published private(set) var found: [Found] = []
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_blackmagic._tcp.", inDomain: "local.")
    }
    func stop() { browser.stop(); services = [] }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        // Only switchers (TXT class=AtemSwitcher); other Blackmagic devices also use this service type
        if let txt = sender.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: txt)
            if let cls = dict["class"].flatMap({ String(data: $0, encoding: .utf8) }), !cls.lowercased().contains("atem") { return }
        }
        guard let ip = sender.addresses?.compactMap(Self.ipv4).first else { return }
        let name = sender.name
        DispatchQueue.main.async {
            if !self.found.contains(where: { $0.host == ip }) { self.found.append(Found(name: name, host: ip)) }
        }
    }

    static func ipv4(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self), sa.pointee.sa_family == UInt8(AF_INET) else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: host)
        }
    }
}

// MARK: - ATEM deck (lower tab)

struct ATEMDeck: View {
    @EnvironmentObject var atem: ATEMSwitcher
    @EnvironmentObject var engine: Engine
    @StateObject private var discovery = ATEMDiscovery()
    @State private var tbar: Double = 0
    @State private var showLink = false

    private let styleNames = ["Mix", "Dip", "Wipe", "DVE", "Sting"]

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            if atem.isConnected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 10) {
                                busRow("PROGRAM", color: SK.red, selected: atem.state.program[atem.me]) { atem.setProgram($0) }
                                busRow("PREVIEW", color: SK.green, selected: atem.state.preview[atem.me]) { atem.setPreview($0) }
                                transitionRow
                            }
                            Spacer(minLength: 0)
                            tbarView
                        }
                        keysAndMacros
                        linkCard
                    }
                    .padding(12)
                }
            } else {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.3.group").font(.system(size: 34)).foregroundColor(DS.text3)
                    Text(emptyText).font(CPFont.body).foregroundColor(DS.text2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: 520)
                Spacer()
            }
        }
        .background(DS.bg1)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .onChange(of: atem.state.transitionPosition[atem.me] ?? 0) { p in if !(atem.state.inTransition[atem.me] ?? false) { tbar = 0 } else { tbar = Double(p) / 10000 } }
    }

    private var emptyText: String {
        switch atem.status {
        case .connecting: return "Connecting to the ATEM at \(atem.host)…"
        case .failed(let m): return m
        default: return "Connect to an ATEM switcher on this network to control it from LiveDeck: Program/Preview buses, CUT, AUTO, fade to black, T-bar, keys, macros and aux outputs."
        }
    }

    // MARK: connection

    private var connectionBar: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(atem.isConnected ? (atem.state.productName.isEmpty ? "ATEM" : atem.state.productName) : "ATEM")
                .font(.system(size: 12.5, weight: .semibold)).foregroundColor(DS.text)
            if atem.isConnected {
                Text("\(atem.host) · protocol \(atem.state.protocolMajor).\(atem.state.protocolMinor)").font(DS.mono(10)).foregroundColor(DS.text3)
                if atem.state.mixEffects > 1 {
                    Picker("", selection: $atem.me) { ForEach(0..<atem.state.mixEffects, id: \.self) { Text("M/E \($0 + 1)").tag($0) } }
                        .pickerStyle(.segmented).frame(width: 60 * CGFloat(atem.state.mixEffects))
                }
            }
            Spacer()
            if !discovery.found.isEmpty && !atem.isConnected {
                Menu("Found \(discovery.found.count)") {
                    ForEach(discovery.found) { f in Button("\(f.name) — \(f.host)") { atem.host = f.host; atem.connect() } }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            TextField("IP address", text: $atem.host).dsField().frame(width: 130).onSubmit { atem.connect() }
                .disabled(atem.isConnected)
            Toggle("Auto", isOn: $atem.autoConnect).toggleStyle(.checkbox).font(CPFont.caption).help("Connect automatically when LiveDeck starts")
            if canConnect {
                Button("Connect") { atem.connect() }.buttonStyle(.ds(.primary, .small))
            } else {
                Button("Disconnect") { atem.disconnect() }.buttonStyle(.ds(.normal, .small))
            }
        }
        .padding(.horizontal, 12).frame(height: 40).background(DS.bg2)
        .overlay(Rectangle().fill(DS.lineSoft).frame(height: 1), alignment: .bottom)
    }

    private var canConnect: Bool {
        switch atem.status {
        case .disconnected, .failed: return true
        default: return false
        }
    }

    private var statusColor: Color {
        switch atem.status {
        case .connected: return DS.ok
        case .connecting: return DS.amber
        case .failed: return DS.program
        case .disconnected: return DS.text3
        }
    }

    // MARK: buses

    private func busRow(_ label: String, color: Color, selected: UInt16?, action: @escaping (UInt16) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 9, weight: .heavy)).kerning(1).foregroundColor(color).frame(width: 64, alignment: .trailing)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(atem.state.busSources(me: atem.me)) { src in
                        Button(src.shortName.isEmpty ? String(src.id) : src.shortName) { action(src.id) }
                            .buttonStyle(SwitcherKeyStyle(color: color, lit: selected == src.id, minWidth: 58))
                            .frame(height: 34)
                            .help(src.longName)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var transitionRow: some View {
        HStack(spacing: 8) {
            Text("").frame(width: 64)
            Button("CUT") { atem.cut() }.buttonStyle(SwitcherKeyStyle(color: SK.white, lit: false, minWidth: 64)).frame(height: 36)
            Button("AUTO") { atem.auto() }.buttonStyle(SwitcherKeyStyle(color: SK.red, lit: atem.state.inTransition[atem.me] ?? false, minWidth: 64)).frame(height: 36)
            Button("FTB") { atem.fadeToBlack() }.buttonStyle(SwitcherKeyStyle(color: SK.red, lit: atem.state.fadeToBlack[atem.me] ?? false, minWidth: 56)).frame(height: 36)
            Rectangle().fill(DS.line).frame(width: 1, height: 26)
            ForEach(0..<styleNames.count, id: \.self) { i in
                Button(styleNames[i]) { atem.setStyle(UInt8(i)) }
                    .buttonStyle(SwitcherKeyStyle(color: SK.amber, lit: atem.state.transitionStyle[atem.me] == UInt8(i), minWidth: 48)).frame(height: 30)
            }
        }
    }

    private var tbarView: some View {
        VStack(spacing: 6) {
            Text("T-BAR").font(.system(size: 9, weight: .heavy)).kerning(1).foregroundColor(DS.text3)
            Slider(value: Binding(get: { tbar }, set: { v in tbar = v; atem.setTBar(v); if v >= 0.999 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { tbar = 0 } } }), in: 0...1)
                .rotationEffect(.degrees(-90)).frame(width: 150, height: 30).frame(width: 40, height: 150)
            Text("\(Int((atem.state.transitionPosition[atem.me] ?? 0) / 100))%").font(DS.mono(10)).foregroundColor(DS.text2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(DS.bg2))
    }

    // MARK: keys, macros, aux

    private var keysAndMacros: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("DOWNSTREAM KEYS").font(CPFont.section).foregroundColor(DS.text3)
                ForEach(Array(atem.state.downstreamKeys.keys.sorted()), id: \.self) { k in
                    HStack(spacing: 6) {
                        Text("DSK \(k + 1)").font(CPFont.emphasis).foregroundColor(DS.text).frame(width: 52, alignment: .leading)
                        Button("ON AIR") { atem.dsk(k, onAir: !(atem.state.downstreamKeys[k] ?? false)) }
                            .buttonStyle(SwitcherKeyStyle(color: SK.red, lit: atem.state.downstreamKeys[k] ?? false, minWidth: 64)).frame(height: 30)
                        Button("AUTO") { atem.dskAuto(k) }.buttonStyle(SwitcherKeyStyle(color: SK.amber, lit: false, minWidth: 54)).frame(height: 30)
                    }
                }
                let uskKeys = atem.state.upstreamKeys.keys.filter { $0.hasPrefix("\(atem.me):") }.sorted()
                if !uskKeys.isEmpty {
                    Text("UPSTREAM KEYS").font(CPFont.section).foregroundColor(DS.text3).padding(.top, 6)
                    HStack(spacing: 6) {
                        ForEach(uskKeys, id: \.self) { key in
                            let k = Int(key.split(separator: ":").last ?? "0") ?? 0
                            Button("KEY \(k + 1)") { atem.upstreamKey(k, onAir: !(atem.state.upstreamKeys[key] ?? false)) }
                                .buttonStyle(SwitcherKeyStyle(color: SK.amber, lit: atem.state.upstreamKeys[key] ?? false, minWidth: 56)).frame(height: 30)
                        }
                    }
                }
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(DS.bg2))

            VStack(alignment: .leading, spacing: 6) {
                Text("MACROS").font(CPFont.section).foregroundColor(DS.text3)
                if atem.state.macros.isEmpty { Text("No macros on this switcher").font(CPFont.caption).foregroundColor(DS.text3) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                    ForEach(atem.state.macros.keys.sorted(), id: \.self) { i in
                        Button(atem.state.macros[i] ?? "Macro") { atem.runMacro(i) }.buttonStyle(.ds(.normal, .small)).lineLimit(1)
                    }
                }
            }
            .frame(minWidth: 220, maxWidth: 360, alignment: .leading)
            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(DS.bg2))

            if !atem.state.aux.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AUX OUTPUTS").font(CPFont.section).foregroundColor(DS.text3)
                    ForEach(atem.state.aux.keys.sorted(), id: \.self) { a in
                        HStack {
                            Text("Aux \(a + 1)").font(CPFont.emphasis).foregroundColor(DS.text).frame(width: 48, alignment: .leading)
                            Picker("", selection: Binding(get: { atem.state.aux[a] ?? 0 }, set: { atem.setAux(a, $0) })) {
                                ForEach(atem.state.inputs.values.sorted { $0.id < $1.id }) { src in Text(src.longName).tag(src.id) }
                            }
                            .frame(width: 170)
                        }
                    }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(DS.bg2))
            }
        }
    }

    // MARK: link with LiveDeck

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LINK LIVEDECK AND THE ATEM").font(CPFont.section).foregroundColor(DS.text3)
                Spacer()
                Button(showLink ? "Hide" : "Set up") { showLink.toggle() }.buttonStyle(.ds(.ghost, .small))
            }
            HStack(spacing: 16) {
                Toggle("LiveDeck switches the ATEM", isOn: $atem.driveATEM).toggleStyle(.checkbox)
                    .help("When a mapped LiveDeck input goes to Preview or Program, the same ATEM source is selected")
                Toggle("LiveDeck follows the ATEM", isOn: $atem.followATEM).toggleStyle(.checkbox)
                    .help("When the ATEM cuts to a mapped source, LiveDeck puts the matching input on Program")
            }
            .font(CPFont.body).foregroundColor(DS.text)
            if showLink {
                Text("Choose which ATEM source matches each LiveDeck input.").font(CPFont.caption).foregroundColor(DS.text2)
                ForEach(engine.sources.filter { !$0.isPlaceholder }, id: \.id) { s in
                    HStack {
                        Text(s.name).font(CPFont.body).foregroundColor(DS.text).lineLimit(1).frame(width: 200, alignment: .leading)
                        Picker("", selection: Binding(get: { atem.mapping[s.name].map { Int($0) } ?? -1 },
                                                      set: { v in atem.mapping[s.name] = v < 0 ? nil : UInt16(v) })) {
                            Text("Not linked").tag(-1)
                            ForEach(atem.state.busSources(me: atem.me)) { src in Text("\(src.longName) (\(src.id))").tag(Int(src.id)) }
                        }
                        .frame(width: 220)
                        if let src = atem.mapping[s.name] {
                            if atem.state.tallyProgram.contains(src) { tallyBadge("PGM", DS.program) }
                            else if atem.state.tallyPreview.contains(src) { tallyBadge("PVW", DS.preview) }
                        }
                    }
                }
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(DS.bg2))
    }

    private func tallyBadge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 9, weight: .heavy)).foregroundColor(.white).padding(.horizontal, 5).frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 3).fill(c))
    }
}
