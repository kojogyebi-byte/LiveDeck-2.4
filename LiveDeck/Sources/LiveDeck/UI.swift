import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// vMix-ish palette
private let cBG = DS.bg0
private let cPanel = DS.bg1
private let cBar = DS.bg2
private let cPreview = DS.accent      // selection / active accent
private let cProgram = DS.ok          // "on / OK" green (tally colours are DS.program / DS.preview)
private let cBtn = DS.bg3

private let pipNoneTag = UUID()

struct MainView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var dict: DictionaryModel
    @State private var showStream = false
    @State private var dropTargeted = false
    var body: some View {
        VStack(spacing: 0) {
            TopBar(showStream: $showStream)
            HSplitView {
                GeometryReader { geo in
                    // Monitors keep 16:9; the lower deck (inputs / songs & Bible / dictionary) fills the rest.
                    let monH = min(geo.size.height * 0.5, geo.size.width * 0.265)
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            MonitorPane(title: previewName, accent: DS.preview, isProgram: false)
                            TransitionColumn()
                            MonitorPane(title: programName, accent: DS.program, isProgram: true)
                        }
                        .padding(8).frame(height: monH)
                        LowerDeck().frame(maxHeight: .infinity)
                    }
                }
                RightPanel().frame(minWidth: 280, idealWidth: 320, maxWidth: 480)
            }
            StatusBar()
        }
        .background(DS.bg0).preferredColorScheme(.dark)
        .background(WindowChrome())
        .overlay { if dropTargeted { Rectangle().stroke(DS.accent, lineWidth: 3).allowsHitTesting(false) } }
        .overlay(alignment: .topLeading) { HotKeys().frame(width: 0, height: 0) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .sheet(isPresented: $showStream) { StreamSettingsView() }
        .onAppear { present.engine = engine; dict.engine = engine }
    }
    var previewName: String { engine.sources.first { $0.id == engine.previewID }?.name ?? "Preview" }
    var programName: String { engine.sources.first { $0.id == engine.programID }?.name ?? "Program" }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                if let url { DispatchQueue.main.async { engine.addDroppedFile(url) } }
            }
        }
        return accepted
    }
}

func keyEquivFromName(_ s: String) -> KeyEquivalent? {
    switch s {
    case "Return": return .return
    case "Space": return .space
    case "None", "": return nil
    default: if let c = s.lowercased().first { return KeyEquivalent(c) }; return nil
    }
}

/// Single-key production shortcuts + slide stepping. Implemented with a local key monitor that
/// ignores keys while any text field or editor has focus, so typing lyrics, song searches or
/// references can never trigger a cut, recording or stream.
struct HotKeys: NSViewRepresentable {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        context.coordinator.engine = engine
        context.coordinator.present = present
        context.coordinator.install()
        return NSView(frame: .zero)
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.engine = engine
        context.coordinator.present = present
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator {
        weak var engine: Engine?
        weak var present: PresentModel?
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
                (self?.handle(ev) ?? false) ? nil : ev
            }
        }
        func remove() { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }

        private func matches(_ name: String?, _ ev: NSEvent) -> Bool {
            guard let name, name != "None", !name.isEmpty else { return false }
            switch name {
            case "Return": return ev.keyCode == 36 || ev.keyCode == 76
            case "Space": return ev.keyCode == 49
            default: return (ev.charactersIgnoringModifiers ?? "").uppercased() == name.uppercased()
            }
        }

        func handle(_ ev: NSEvent) -> Bool {
            guard let engine, let window = NSApp.keyWindow, window === NSApp.mainWindow, window.attachedSheet == nil else { return false }
            if !ev.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
            let responder = window.firstResponder
            if responder is NSText || responder is NSTextView { return false }

            // Slide clickers / arrows: Page Up/Down anywhere; ← → when the Songs & Bible tab is open.
            if let present {
                let arrowsOK = present.deck == DeckTab.present.rawValue && !(responder is NSTableView)
                switch ev.keyCode {
                case 121: present.step(1); return true                       // Page Down
                case 116: present.step(-1); return true                      // Page Up
                case 124 where arrowsOK: present.step(1); return true       // →
                case 123 where arrowsOK: present.step(-1); return true      // ←
                default: break
                }
            }
            if let ch = ev.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
                guard engine.sources.indices.contains(n - 1) else { return false }
                let src = engine.sources[n - 1]
                if !src.isPlaceholder { engine.setPreview(src.id); engine.selectedSourceID = src.id }
                return true
            }
            let map: [(String, () -> Void)] = [
                ("take", { engine.runTransition() }), ("cut", { engine.cut() }), ("ftb", { engine.toggleFTB() }),
                ("record", { engine.toggleRecording() }), ("snapshot", { engine.snapshot() }), ("stream", { engine.toggleStream(nil) })
            ]
            for (action, run) in map where matches(engine.hotkeys[action], ev) { run(); return true }
            return false
        }
    }
}

struct HotkeysView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    private let actions: [(String, String)] = [
        ("take", "Take (transition)"), ("cut", "Cut"), ("ftb", "Fade to black"),
        ("record", "Record"), ("snapshot", "Snapshot"), ("stream", "Stream")]
    private let keyOptions = ["None", "Return", "Space", "A", "B", "C", "D", "E", "F", "G",
                              "L", "M", "P", "Q", "R", "S", "T", "V", "W", "X", "Z"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("KEYBOARD SHORTCUTS").font(.system(size: 13, weight: .heavy)).kerning(1)
                Spacer()
                Button("Reset") { engine.hotkeys = Engine.defaultHotkeys }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Number keys 1–9 always stage that input to Preview. Assign a key to each action below.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            ForEach(actions, id: \.0) { act in
                HStack {
                    Text(act.1).font(.system(size: 12)).frame(width: 160, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { engine.hotkeys[act.0] ?? "None" },
                        set: { engine.hotkeys[act.0] = $0 })) {
                        ForEach(keyOptions, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
            }
            Spacer()
        }
        .padding(16).frame(width: 420, height: 380).preferredColorScheme(.dark)
    }
}

// MARK: - Top bar

struct SystemStatsView: View {
    @EnvironmentObject var mon: SystemMonitor
    var body: some View {
        HStack(spacing: 12) {
            stat("CPU", mon.cpu)
            stat("RAM", mon.ram)
            if mon.gpu >= 0 { stat("GPU", mon.gpu) }
        }
    }
    @ViewBuilder func stat(_ label: String, _ v: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
            Text("\(Int(v.rounded()))%").font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(v > 85 ? .red : (v > 65 ? .orange : .primary))
                .frame(width: 34, alignment: .trailing)
            Capsule().fill(v > 85 ? Color.red : (v > 65 ? Color.orange : cProgram))
                .frame(width: max(2, 26 * CGFloat(min(100, v) / 100)), height: 4)
                .frame(width: 26, alignment: .leading)
                .background(Capsule().fill(Color(white: 0.18)))
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var engine: Engine
    @Binding var showStream: Bool
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Text("LIVE").font(.system(size: 15, weight: .black)).foregroundColor(DS.text)
                Text("DECK").font(.system(size: 15, weight: .black)).foregroundColor(DS.program)
            }
            .kerning(0.5)
            Text("STUDIO").font(.system(size: 8, weight: .bold)).kerning(2).foregroundColor(DS.text3)
            Rectangle().fill(DS.line).frame(width: 1, height: 20)
            DSIconButton(symbol: "folder", help: "Open show…") { engine.loadShow() }
            DSIconButton(symbol: "square.and.arrow.down", help: "Save show…") { engine.saveShow() }
            Spacer()
            Button { engine.openOutputWindow() } label: {
                Label(engine.programWindowActive ? "PROGRAM OUT · ON" : "PROGRAM OUT", systemImage: "rectangle.inset.filled")
            }
            .buttonStyle(.ds(.normal, .regular, active: engine.programWindowActive))
            .help("Full-screen Program on the second display (no title bar). Esc or double-click to close.")
            Button { showStream = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(engine.isStreaming ? Color.white : DS.program).frame(width: 7, height: 7)
                    Text(engine.isStreaming ? "LIVE" : "STREAM")
                }
            }
            .buttonStyle(.ds(.program, .regular, active: engine.isStreaming))
            Button { engine.toggleRecording() } label: {
                HStack(spacing: 6) {
                    Image(systemName: engine.isRecording ? "stop.fill" : "record.circle")
                    Text(engine.isRecording ? String(format: "REC %02d:%02d:%02d", engine.recordSeconds / 3600, (engine.recordSeconds % 3600) / 60, engine.recordSeconds % 60) : "REC")
                        .font(DS.mono(11, .semibold))
                }
            }
            .buttonStyle(.ds(.program, .regular, active: engine.isRecording))
            Spacer()
            SystemStatsView()
            Text("\(engine.height)p\(engine.fpsTarget)").font(DS.mono(11)).foregroundColor(DS.text2)
                .padding(.horizontal, 7).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(DS.bg0))
            Menu {
                Menu("Resolution") {
                    checkButton("720p", engine.height == 720) { engine.setResolution(width: 1280, height: 720) }
                    checkButton("1080p (Full HD)", engine.height == 1080) { engine.setResolution(width: 1920, height: 1080) }
                    checkButton("1440p (2K)", engine.height == 1440) { engine.setResolution(width: 2560, height: 1440) }
                    checkButton("2160p (4K UHD)", engine.height == 2160 && engine.width == 3840) { engine.setResolution(width: 3840, height: 2160) }
                    checkButton("4K DCI", engine.width == 4096) { engine.setResolution(width: 4096, height: 2160) }
                }
                Menu("Frame rate") {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { r in
                        checkButton("\(r)p", engine.fpsTarget == r) { engine.setFrameRate(r) }
                    }
                }
                Divider()
                Menu("Recording codec") {
                    ForEach(RecCodec.allCases) { c in checkButton(c.rawValue, engine.recCodec == c) { engine.recCodec = c } }
                }
                Menu("Recording container") {
                    checkButton("MP4", engine.recContainer == "MP4") { engine.recContainer = "MP4" }
                    checkButton("MOV", engine.recContainer == "MOV") { engine.recContainer = "MOV" }
                }
                Menu("Recording bitrate") {
                    ForEach([4, 6, 8, 12, 20, 40], id: \.self) { b in
                        checkButton("\(b) Mbps", engine.recBitrateMbps == b) { engine.recBitrateMbps = b }
                    }
                }
                Divider()
                Button("Keyboard shortcuts…") { engine.showHotkeys = true }
                checkButton("Mix input faders into recording & stream", engine.mixInputsIntoRecording) { engine.mixInputsIntoRecording.toggle() }
                Button("Choose recording folder…") { engine.chooseOutputFolder() }
                Button("Reveal last recording") { engine.revealLastRecording() }
            } label: { Image(systemName: "gearshape.fill").foregroundColor(DS.text2) }
            .menuStyle(.borderlessButton).fixedSize().frame(width: 30)
        }
        .padding(.horizontal, 12).frame(height: 46)
        .background(DS.bg2)
        .overlay(Rectangle().fill(DS.line).frame(height: 1), alignment: .bottom)
        .sheet(isPresented: Binding(get: { engine.showHotkeys }, set: { engine.showHotkeys = $0 })) { HotkeysView() }
    }
}

struct TBtn: View {
    var title: String; var tint: Color = cBtn; var filled = false; var action: () -> Void = {}
    init(_ t: String, tint: Color = cBtn, filled: Bool = false, action: @escaping () -> Void = {}) {
        self.title = t; self.tint = tint; self.filled = filled; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(filled ? tint : cBtn)
                .foregroundColor(filled ? .white : (tint == cBtn ? .white : tint))
                .cornerRadius(4)
        }.buttonStyle(.plain)
    }
}

// MARK: - Monitors

struct MonitorPane: View {
    @EnvironmentObject var engine: Engine
    var title: String; var accent: Color; var isProgram: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(isProgram ? "PROGRAM" : "PREVIEW")
                    .font(.system(size: 10, weight: .heavy)).kerning(1.2).foregroundColor(.white)
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 3).fill(accent))
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(DS.text).lineLimit(1)
                Spacer()
                if isProgram && engine.isRecording {
                    HStack(spacing: 4) { Circle().fill(DS.program).frame(width: 6, height: 6); Text("REC").font(DS.caption).foregroundColor(DS.program) }
                }
                if isProgram && engine.isStreaming {
                    HStack(spacing: 4) { Circle().fill(DS.program).frame(width: 6, height: 6); Text("LIVE").font(DS.caption).foregroundColor(DS.program) }
                }
            }
            .padding(.horizontal, 8).frame(height: 28).background(DS.bg2)
            ZStack {
                if isProgram { ProgramMonitorView() } else { PreviewMonitorView() }
                if isProgram && engine.showSafeGuides {
                    GeometryReader { g in
                        Rectangle().stroke(Color.white.opacity(0.3), lineWidth: 1)
                            .frame(width: g.size.width * 0.9, height: g.size.height * 0.9)
                            .position(x: g.size.width / 2, y: g.size.height / 2)
                    }.allowsHitTesting(false)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.black)
        }
        .background(DS.bg1)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(accent.opacity(0.9), lineWidth: 2))
    }
}

struct ProgramMonitorView: NSViewRepresentable {
    @EnvironmentObject var engine: Engine
    func makeNSView(context: Context) -> FrameNSView { let v = FrameNSView(frame: .zero); engine.addConsumer(v); return v }
    func updateNSView(_ v: FrameNSView, context: Context) {}
}
struct PreviewMonitorView: NSViewRepresentable {
    @EnvironmentObject var engine: Engine
    func makeNSView(context: Context) -> FrameNSView { let v = FrameNSView(frame: .zero); engine.addPreviewConsumer(v); return v }
    func updateNSView(_ v: FrameNSView, context: Context) {}
}

// MARK: - Transition column

struct TransitionColumn: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        VStack(spacing: 6) {
            Button("CUT") { engine.cut() }.buttonStyle(.ds(.normal, .large, fullWidth: true))
                .help("Cut Preview to Program")
            Button("AUTO") { engine.runTransition() }.buttonStyle(.ds(.program, .large, active: true, fullWidth: true))
                .help("Run the selected transition")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                trans("Fade", .fade); trans("Wipe", .wipe); trans("Slide", .slide); trans("Zoom", .zoom)
            }
            TBarControl(value: engine.tbar) { engine.setTBar($0) }
                .frame(minHeight: 50, maxHeight: .infinity)
                .help("Drag down to transition manually")
            ParamSlider(label: "Duration", value: $engine.transitionDuration, range: 0.2...2.0, defaultValue: 0.6, format: "%.1fs")
            Button("FTB") { engine.toggleFTB() }.buttonStyle(.ds(.danger, .regular, active: engine.ftbOn, fullWidth: true))
                .help("Fade to black")
            VStack(spacing: 1) {
                ClockText()
                Text(String(format: "%02d:%02d:%02d", engine.recordSeconds / 3600, (engine.recordSeconds % 3600) / 60, engine.recordSeconds % 60))
                    .font(DS.mono(10)).foregroundColor(DS.text3)
            }
            .padding(.vertical, 5).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 4).fill(DS.bg0))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DS.lineSoft, lineWidth: 1))
        }
        .frame(width: 112)
    }
    func trans(_ t: String, _ kind: TransitionType) -> some View {
        Button(t) { engine.quickTransition(kind) }
            .buttonStyle(.ds(.normal, .small, active: engine.transition == kind, fullWidth: true))
    }
}

// MARK: - Input bus

let inputTileChrome: CGFloat = 70   // header 20 + meter 10 + footer 40

// Choose column count + tile width so the input tiles fill the region and reflow on resize.
// Tile screens are ALWAYS 16:9 (4.0-a); the grid picks the column count that makes them
// as large as possible for the current window size.
func bestInputGrid(count: Int, area: CGSize, sizeMul: CGFloat) -> (cols: Int, tileW: CGFloat, screenH: CGFloat) {
    guard count > 0, area.width > 60, area.height > 60 else { return (1, 176, 99) }
    let gap: CGFloat = 8
    let headerH: CGFloat = inputTileChrome
    let minW: CGFloat = 150 * max(0.6, sizeMul)
    var best: (cols: Int, tileW: CGFloat, score: CGFloat) = (1, 150, -1e9)
    for cols in 1...count {
        let tileW = (area.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        if tileW < minW && cols > 1 { continue }
        let rows = Int(ceil(Double(count) / Double(cols)))
        let tileH = tileW * 9.0 / 16.0 + headerH
        let totalH = CGFloat(rows) * (tileH + gap) + gap
        let fits = totalH <= area.height
        let waste = fits ? (area.height - totalH) : (totalH - area.height) * 3
        let score = -waste
        if score > best.score { best = (cols, tileW, score) }
    }
    let tileW = max(120, best.tileW)
    return (best.cols, tileW, tileW * 9.0 / 16.0)
}

/// Lower half of the window: the input bus, the Songs & Bible operator and the Dictionary —
/// all on the same page as Preview / Program.
struct LowerDeck: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                DSTabBar(selection: $present.deck, items: [
                    DSTabItem(id: DeckTab.inputs.rawValue, title: "Inputs", icon: "square.grid.2x2"),
                    DSTabItem(id: DeckTab.present.rawValue, title: "Songs & Bible", icon: "music.note.list"),
                    DSTabItem(id: DeckTab.dictionary.rawValue, title: "Dictionary", icon: "character.book.closed")
                ])
                .frame(width: 420)
                Spacer()
                if present.deck == DeckTab.inputs.rawValue {
                    AddInputMenu()
                    Button("Playlist") { engine.playlistEnabled.toggle() }
                        .buttonStyle(.ds(.normal, .small, active: engine.playlistEnabled))
                        .help("Auto-advance the Program through video/audio inputs as each clip ends")
                    Image(systemName: "rectangle.grid.2x2").font(.system(size: 10)).foregroundColor(DS.text3)
                    Slider(value: $engine.inputTileScale, in: 0.6...1.6).controlSize(.mini).frame(width: 110)
                }
            }
            .padding(.horizontal, 8).frame(height: 40).background(DS.bg2)
            .overlay(Rectangle().fill(DS.lineSoft).frame(height: 1), alignment: .bottom)
            if present.deck == DeckTab.present.rawValue { PresentDeck() }
            else if present.deck == DeckTab.dictionary.rawValue { DictionaryDeck() }
            else { InputBus() }
        }
        .background(DS.bg1)
    }
}

struct InputBus: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let n = max(1, engine.sources.count)
                let g = bestInputGrid(count: n, area: geo.size, sizeMul: CGFloat(engine.inputTileScale))
                let columns = Array(repeating: GridItem(.fixed(g.tileW), spacing: 8), count: g.cols)
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
                        ForEach(Array(engine.sources.enumerated()), id: \.element.id) { idx, src in
                            InputTile(index: idx + 1, source: src, tileW: g.tileW, screenH: g.screenH)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    // Right-click anywhere in the empty part of the input area to add an input.
                    .contentShape(Rectangle())
                    .contextMenu { AddInputMenuItems() }
                }
            }
        }
        .background(cPanel)
        .sheet(isPresented: Binding(get: { engine.streamInputMode != 0 }, set: { if !$0 { engine.streamInputMode = 0 } })) { AddStreamView() }
    }
}

let videoFileTypes = ["public.movie", "public.video", "public.audiovisual-content",
                      "com.apple.quicktime-movie", "public.mpeg-4", "public.avi",
                      "public.mpeg", "public.mpeg-2-transport-stream",
                      "org.matroska.mkv", "com.microsoft.windows-media-wmv"]

/// Items that fill a specific (blank) holder.
struct InputAssignMenuItems: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var dict: DictionaryModel
    var slotID: UUID
    var body: some View {
        Menu("Cameras & Capture Devices") {
            let devices = VideoDevices.all()
            ForEach(devices, id: \.uniqueID) { d in
                Button(d.localizedName) { engine.replaceSource(slotID, with: CameraSource(device: d)) }
            }
            if devices.isEmpty { Text("No devices found") }
        }
        Button("Screen Capture") { engine.replaceSource(slotID, with: ScreenSource()) }
        Button("Video File…") { pickFile(types: videoFileTypes) { engine.replaceSource(slotID, with: FileSource(url: $0)) } }
        Button("Image…") { pickFile(types: ["public.image"]) { engine.replaceSource(slotID, with: ImageSource(url: $0)) } }
        Divider()
        Button("Songs & Bible (Presentation)") {
            let s = PresentationSource(); engine.replaceSource(slotID, with: s)
            present.targetID = s.id; present.deck = DeckTab.present.rawValue
        }
        Button("Dictionary") {
            let s = DictionarySource(); engine.replaceSource(slotID, with: s)
            dict.targetID = s.id; present.deck = DeckTab.dictionary.rawValue
        }
        Divider()
        Button("Network Stream (HLS / URL)…") { engine.openAddStream(1) }
        Button("RTMP / RTSP / SRT (ffmpeg)…") { engine.openAddStream(2) }
        Button("YouTube / Twitch / Facebook link…") { engine.openAddStream(3) }
        Button("Web Page…") { engine.openAddStream(4) }
        Divider()
        Button("Colour") { engine.replaceSource(slotID, with: ColorSource()) }
        Button("Test Pattern (Bars)") { engine.replaceSource(slotID, with: BarsSource()) }
    }
}

struct InputAssignMenu<Label: View>: View {
    var slotID: UUID
    @ViewBuilder var label: () -> Label
    var body: some View {
        Menu { InputAssignMenuItems(slotID: slotID) } label: { label() }
    }
}

struct TileTransport<S: MediaPlayback>: View {
    @ObservedObject var source: S
    var body: some View {
        HStack(spacing: 9) {
            Button { source.restart() } label: { Image(systemName: "backward.end.fill").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundColor(DS.text2)
            Button { source.togglePlay() } label: {
                Image(systemName: source.paused ? "play.fill" : "pause.fill").font(.system(size: 15))
            }.buttonStyle(.plain).foregroundColor(DS.text)
            Button { source.loop.toggle() } label: {
                Image(systemName: "repeat").font(.system(size: 12)).foregroundColor(source.loop ? DS.accent : DS.text3)
            }.buttonStyle(.plain)
        }
    }
}

struct InputTile: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var dict: DictionaryModel
    var index: Int
    @ObservedObject var source: Source
    var tileW: CGFloat = 176
    var screenH: CGFloat? = nil
    var isProgram: Bool { engine.programID == source.id }
    var isPreview: Bool { engine.previewID == source.id }
    var isKeyed: Bool { engine.isKeyed(source.id) }
    var tally: Color { isProgram ? DS.program : (isPreview ? DS.preview : (isKeyed ? DS.amber : DS.line)) }
    var th: CGFloat { tileW * 9.0 / 16.0 }   // always 16:9, whatever the window size

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text("\(index)").font(DS.mono(9, .bold))
                    .foregroundColor(isProgram || isPreview || isKeyed ? .white : DS.text2)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(RoundedRectangle(cornerRadius: 3).fill(isProgram || isPreview || isKeyed ? tally : DS.bg4))
                Text(source.isPlaceholder ? "Empty" : source.name).font(.system(size: 10, weight: .medium))
                    .foregroundColor(source.isPlaceholder ? DS.text3 : DS.text).lineLimit(1)
                Spacer()
                if !source.isPlaceholder {
                    Text(source.kindLabel).font(.system(size: 8, weight: .bold)).kerning(0.6).foregroundColor(DS.text3)
                }
                if source.sourceURLString != nil {
                    Button { engine.openEditStream(source.id) } label: { Image(systemName: "pencil").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundColor(DS.text3)
                }
                Button { engine.removeSource(source.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).foregroundColor(DS.text3)
            }
            .padding(.horizontal, 5).frame(width: tileW, height: 20).background(DS.bg2)

            if source.isPlaceholder {
                // Blank holder = a switched-off TV: a black 16:9 screen, with a discreet assign
                // button in the middle; the strip below matches a live tile's control bar.
                ZStack {
                    Color.black
                    InputAssignMenu(slotID: source.id) {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .opacity(0.35)
                    .help("Assign an input to this slot (or drop a file on the window)")
                }
                .frame(width: tileW, height: th)
                DS.bg2.frame(width: tileW, height: inputTileChrome - 20)
            }
            if !source.isPlaceholder {
                SourceThumb(source: source)
                    .frame(width: tileW, height: th).background(Color.black)
                    .onTapGesture(count: 2) { engine.setPreview(source.id); engine.cut() }
                    .onTapGesture { select() }
                ChannelMeterBar(id: source.id, muted: source.muted, segments: 14)
                    .frame(width: tileW, height: 6).padding(.vertical, 2).background(DS.bg1)
                HStack(spacing: 6) {
                    Button("PVW") { select() }.buttonStyle(.ds(.preview, .small, active: isPreview))
                    Button("PGM") { engine.setPreview(source.id); engine.cut() }.buttonStyle(.ds(.program, .small, active: isProgram))
                    if let f = source as? FileSource { TileTransport(source: f) }
                    else if let a = source as? AudioFileSource { TileTransport(source: a) }
                    else if source is SlideSource {
                        Button("KEY") { engine.toggleKey(source.id) }.buttonStyle(.ds(.amber, .small, active: isKeyed))
                            .help("Overlay on Program")
                        Button { openController() } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.ds(.normal, .small)).help("Open its controls")
                    }
                    Spacer(minLength: 0)
                    Button { source.muted.toggle() } label: {
                        Image(systemName: source.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 12))
                            .foregroundColor(source.muted ? DS.program : DS.text2)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 6).frame(width: tileW, height: 40).background(DS.bg2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tally, lineWidth: isProgram || isPreview || isKeyed ? 2 : 1))
        .contentShape(Rectangle())
        .contextMenu {
            if source.isPlaceholder {
                Menu("Assign input") { InputAssignMenuItems(slotID: source.id) }
                Divider()
                Button("Remove holder", role: .destructive) { engine.removeSource(source.id) }
            } else {
                Button("Take to Program") { engine.setPreview(source.id); engine.cut() }
                Button("Set as Preview") { select() }
                if source is SlideSource {
                    Button(isKeyed ? "Remove key from Program" : "Key over Program") { engine.toggleKey(source.id) }
                    Button("Open controls") { openController() }
                }
                if source.sourceURLString != nil {
                    Button("Edit address…") { engine.openEditStream(source.id) }
                }
                if let w = source as? WebSource { Button("Reload page") { w.reload() } }
                Divider()
                Button("Adjust in Input panel") { select(); engine.rightTab = 1 }
                Divider()
                Button("Remove", role: .destructive) { engine.removeSource(source.id) }
            }
        }
    }

    private func select() {
        engine.setPreview(source.id); engine.selectedSourceID = source.id
        if source is PresentationSource { present.targetID = source.id }
        if source is DictionarySource { dict.targetID = source.id }
    }
    private func openController() {
        if source is DictionarySource { dict.targetID = source.id; present.deck = DeckTab.dictionary.rawValue }
        else { present.targetID = source.id; present.deck = DeckTab.present.rawValue }
    }
}

struct SourceThumb: NSViewRepresentable {
    @ObservedObject var source: Source
    func makeNSView(context: Context) -> SourceThumbNSView { let v = SourceThumbNSView(frame: .zero); v.source = source; return v }
    func updateNSView(_ v: SourceThumbNSView, context: Context) { v.source = source }
}

/// Items shared by the "Add Input" button menu and the right-click menu of the input area.
struct AddInputMenuItems: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var dict: DictionaryModel
    var body: some View {
        Menu("Cameras & Capture Devices") {
            let devices = VideoDevices.all()
            ForEach(devices, id: \.uniqueID) { d in Button(d.localizedName) { engine.addCamera(d) } }
            if devices.isEmpty { Text("No devices found") }
        }
        Button("Screen Capture") { engine.addScreen() }
        Button("Video File…") { pickFile(types: videoFileTypes) { engine.addFile(url: $0) } }
        Button("Image…") { pickFile(types: ["public.image"]) { engine.addImage(url: $0) } }
        Divider()
        Button("Songs & Bible (Presentation)") {
            let s = engine.addPresentationInput(); present.targetID = s.id; present.deck = DeckTab.present.rawValue
        }
        Button("Dictionary") {
            let s = engine.addDictionaryInput(); dict.targetID = s.id; present.deck = DeckTab.dictionary.rawValue
        }
        Divider()
        Button("Network Stream (HLS / URL)…") { engine.openAddStream(1) }
        Button("RTMP / RTSP / SRT (ffmpeg)…") { engine.openAddStream(2) }
        Button("YouTube / Twitch / Facebook link…") { engine.openAddStream(3) }
        Button("Web Page…") { engine.openAddStream(4) }
        Divider()
        Button("Colour") { engine.addColor() }
        Button("Test Pattern (Bars)") { engine.addBars() }
        Divider()
        Button("Blank Input") { engine.addBlankInput() }
    }
}

struct AddInputMenu: View {
    var body: some View {
        Menu {
            AddInputMenuItems()
        } label: {
            Label("Add Input", systemImage: "plus").font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(DS.accent))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }
}

// MARK: - Right panel (Audio Mixer / Overlays)

struct LayoutThumb: View {
    var layout: ProgramLayout
    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let rects: [CGRect] = {
                switch layout {
                case .single: return [CGRect(x: 0, y: 0, width: W, height: H)]
                case .sideBySide: return [CGRect(x: 0, y: 0, width: W / 2, height: H), CGRect(x: W / 2, y: 0, width: W / 2, height: H)]
                case .topBottom: return [CGRect(x: 0, y: 0, width: W, height: H / 2), CGRect(x: 0, y: H / 2, width: W, height: H / 2)]
                case .pip: return [CGRect(x: 0, y: 0, width: W, height: H), CGRect(x: W * 0.62, y: H * 0.60, width: W * 0.33, height: H * 0.33)]
                case .quad: return [CGRect(x: 0, y: 0, width: W / 2, height: H / 2), CGRect(x: W / 2, y: 0, width: W / 2, height: H / 2),
                                    CGRect(x: 0, y: H / 2, width: W / 2, height: H / 2), CGRect(x: W / 2, y: H / 2, width: W / 2, height: H / 2)]
                case .grid:
                    var rs: [CGRect] = []
                    let cols = 3, rows = 2
                    for i in 0..<6 { let r = i / cols, c = i % cols
                        rs.append(CGRect(x: CGFloat(c) * W / 3, y: CGFloat(r) * H / 2, width: W / 3, height: H / 2)) }
                    return rs
                }
            }()
            ZStack {
                ForEach(Array(rects.enumerated()), id: \.offset) { _, r in
                    Rectangle().fill(Color(white: 0.28)).overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                        .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                }
            }
        }
        .frame(width: 54, height: 30).background(Color.black).cornerRadius(3)
    }
}

struct ScenesPanel: View {
    @EnvironmentObject var engine: Engine
    @State private var sceneName = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("PROGRAM LAYOUT")
                HStack(spacing: 6) {
                    ForEach(ProgramLayout.allCases) { l in
                        Button { engine.setLayout(l) } label: {
                            LayoutThumb(layout: l)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(engine.programLayout == l ? cPreview : .clear, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                }
                Text(engine.programLayout.label).font(.system(size: 11, weight: .semibold))

                if engine.programLayout == .grid {
                    Stepper("Cells: \(engine.gridCount)", value: Binding(
                        get: { engine.gridCount },
                        set: { engine.gridCount = max(2, min(10, $0)) }), in: 2...10)
                        .font(.system(size: 11))
                }

                if engine.programLayout != .single {
                    SectionLabel("SLOTS")
                    ForEach(Array(0..<engine.slotCount(engine.programLayout)), id: \.self) { i in
                        HStack {
                            Text("Slot \(i + 1)").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 48, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { (engine.layoutSlots.indices.contains(i) ? engine.layoutSlots[i] : nil) ?? pipNoneTag },
                                set: { engine.setSlot(i, $0 == pipNoneTag ? nil : $0) })) {
                                Text("— none —").tag(pipNoneTag)
                                ForEach(engine.sources.filter { !$0.isPlaceholder }) { s in Text(s.name).tag(s.id) }
                            }.labelsHidden()
                        }
                    }
                }

                Divider()
                SectionLabel("SCENES")
                HStack {
                    TextField("Scene name", text: $sceneName).textFieldStyle(.roundedBorder)
                    Button("Save") { engine.saveScene(sceneName); sceneName = "" }
                }
                if engine.scenes.isEmpty {
                    Text("Arrange a layout and its slots above, then Save it as a scene to recall later.")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
                ForEach(engine.scenes) { sc in
                    HStack(spacing: 8) {
                        LayoutThumb(layout: sc.layout)
                        Button(sc.name) { engine.recallScene(sc) }
                            .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                        Button { engine.deleteScene(sc.id) } label: { Image(systemName: "trash").font(.system(size: 10)) }
                            .buttonStyle(.plain).foregroundColor(.secondary)
                    }
                    .padding(6).background(Color(white: 0.1)).cornerRadius(5)
                }
                Text("Recalling a scene cuts the Program to that layout. Choose “Single” to return to the normal switcher.")
                    .font(.system(size: 9)).foregroundColor(.secondary).padding(.top, 4)
            }.padding(10)
        }
    }
}

struct RightPanel: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        VStack(spacing: 0) {
            CPTabBar(selection: $engine.rightTab, items: [
                DSTabItem(id: 1, title: "Input", icon: "rectangle.and.hand.point.up.left"),
                DSTabItem(id: 0, title: "Audio", icon: "slider.vertical.3"),
                DSTabItem(id: 2, title: "Overlays", icon: "square.stack.3d.up"),
                DSTabItem(id: 3, title: "Scenes", icon: "rectangle.split.2x2"),
                DSTabItem(id: 4, title: "Outputs", icon: "display")
            ])
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
            Group {
                if engine.rightTab == 0 { AudioMixerPanel() }
                else if engine.rightTab == 1 { InputSettingsPanel() }
                else if engine.rightTab == 2 { OverlaysPanel() }
                else if engine.rightTab == 3 { ScenesPanel() }
                else { OutputsPanel() }
            }
            .frame(maxHeight: .infinity)
        }
        .background(CP.bg).overlay(Rectangle().frame(width: 1).foregroundColor(DS.line), alignment: .leading)
    }
}

@ViewBuilder
func checkButton(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack { Text(title); if on { Image(systemName: "checkmark") } }
    }
}

// Shared labelled slider for adjustments (professional compact slider; double-click resets)
func adjSlider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ def: Double? = nil) -> some View {
    let fallback: Double? = def ?? (range.contains(0) && range.lowerBound < 0 ? 0 : nil)
    let fmt = (range.upperBound - range.lowerBound) >= 100 ? "%.0f" : "%.2f"
    return CPSliderRow(label: label, value: value, range: range, defaultValue: fallback, format: fmt)
}

struct InputSettingsPanel: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                InputChannelCard()
                if let s = engine.sources.first(where: { $0.id == engine.selectedSourceID }), !s.isPlaceholder {
                    InputAdjust(source: s).id(s.id)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.tap").font(.system(size: 26)).foregroundColor(CP.text2)
                        Text("Choose an input above, or click an input's picture, to adjust its geometry, crop, colour and audio.")
                            .font(.system(size: 11.5)).foregroundColor(CP.text2).multilineTextAlignment(.center)
                    }
                    .padding(24).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 11).fill(CP.card))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(CP.border, lineWidth: 1))
                }
            }
            .padding(10)
        }
        .background(CP.bg)
    }
}

/// "Input Channel" card: which input is being edited + reset all.
struct InputChannelCard: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        let selected = engine.sources.first(where: { $0.id == engine.selectedSourceID && !$0.isPlaceholder })
        HStack(spacing: 10) {
            Image(systemName: "rectangle.and.hand.point.up.left.filled")
                .font(.system(size: 18, weight: .semibold)).foregroundColor(CP.icon).frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text("Input Channel").font(.system(size: 13, weight: .semibold)).foregroundColor(CP.text)
                Picker("", selection: Binding(
                    get: { engine.selectedSourceID ?? pipNoneTag },
                    set: { id in
                        guard id != pipNoneTag else { engine.selectedSourceID = nil; return }
                        engine.selectedSourceID = id
                        engine.setPreview(id)
                    })) {
                    Text("None").tag(pipNoneTag)
                    ForEach(Array(engine.sources.enumerated()).filter { !$0.element.isPlaceholder }, id: \.element.id) { idx, src in
                        Text("\(idx + 1)  ·  \(src.name)").tag(src.id)
                    }
                }
                .cpPickerChrome()
            }
            CPButton(icon: "arrow.counterclockwise", title: "Reset") { selected?.resetAdjustments(); selected?.gain = 1 }
                .disabled(selected == nil)
                .padding(.top, 18)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(CP.card))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(CP.border, lineWidth: 1))
    }
}

struct InputAdjust: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var dict: DictionaryModel
    @ObservedObject var source: Source
    @State private var audioDevices: [AudioDeviceInfo] = []
    @State private var showFX = false

    var body: some View {
        VStack(spacing: 12) {
            CPCard(title: "Name & Playback", subtitle: source.kindLabel.capitalized + " input", icon: "tv") {
                CPRow(icon: "character.cursor.ibeam", label: "Name", showDivider: source is FileSource || source is AudioFileSource) {
                    TextField("Name", text: $source.name)
                        .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(CP.text)
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(CP.field))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(CP.border, lineWidth: 1))
                }
                if let f = source as? FileSource { PlaybackTransport(source: f).padding(.vertical, 8) }
                if let a = source as? AudioFileSource { PlaybackTransport(source: a).padding(.vertical, 8) }
            }

            if let slide = source as? SlideSource {
                CPCard(title: "Display", subtitle: "Songs, scripture or dictionary", icon: "text.below.photo") {
                    CPRow(icon: "square.2.layers.3d.top.filled", label: "Key over Program") {
                        Toggle("", isOn: Binding(get: { engine.isKeyed(slide.id) }, set: { _ in engine.toggleKey(slide.id) }))
                            .toggleStyle(.switch).tint(CP.blue).labelsHidden()
                    }
                    CPRow(icon: "textformat", label: "Hide text") {
                        SlideVisibilityToggles(source: slide)
                    }
                    HStack {
                        CPButton(icon: "paintbrush.pointed", title: "Formatting & slides", prominent: true) {
                            if slide is DictionarySource { dict.targetID = slide.id; present.deck = DeckTab.dictionary.rawValue }
                            else { present.targetID = slide.id; present.deck = DeckTab.present.rawValue }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
            } else {
                CPCard(title: "Geometry", subtitle: "Position and rotation of the input", icon: "scope",
                       onReset: { source.zoom = 1; source.panX = 0; source.panY = 0; source.rotation = 0 }) {
                    CPSliderRow(icon: "magnifyingglass", label: "Zoom", value: $source.zoom, range: 0.2...4, defaultValue: 1)
                    CPSliderRow(icon: "arrow.left.and.right", label: "Pan X", value: $source.panX, range: -1...1, defaultValue: 0)
                    CPSliderRow(icon: "arrow.up.and.down", label: "Pan Y", value: $source.panY, range: -1...1, defaultValue: 0)
                    CPSliderRow(icon: "arrow.clockwise", label: "Rotate", value: $source.rotation, range: -180...180, defaultValue: 0, format: "%.0f", showDivider: false)
                }

                CPCard(title: "Crop", subtitle: "Trim the input frame", icon: "crop",
                       onReset: { source.cropL = 0; source.cropR = 0; source.cropT = 0; source.cropB = 0 }) {
                    CPSliderRow(icon: "arrow.left", label: "Left", value: $source.cropL, range: 0...0.45, defaultValue: 0)
                    CPSliderRow(icon: "arrow.right", label: "Right", value: $source.cropR, range: 0...0.45, defaultValue: 0)
                    CPSliderRow(icon: "arrow.up", label: "Top", value: $source.cropT, range: 0...0.45, defaultValue: 0)
                    CPSliderRow(icon: "arrow.down", label: "Bottom", value: $source.cropB, range: 0...0.45, defaultValue: 0, showDivider: false)
                }

                CPCard(title: "Colour", subtitle: "Adjust colour properties", icon: "circle.hexagongrid.fill",
                       onReset: { source.brightness = 0; source.contrast = 1; source.saturation = 1 }) {
                    CPSliderRow(icon: "sun.max", label: "Brightness", value: $source.brightness, range: -0.5...0.5, defaultValue: 0)
                    CPSliderRow(icon: "circle.lefthalf.filled", label: "Contrast", value: $source.contrast, range: 0...2, defaultValue: 1)
                    CPSliderRow(icon: "drop", label: "Saturation", value: $source.saturation, range: 0...2, defaultValue: 1, showDivider: false)
                }
            }

            CPCard(title: "Audio", subtitle: "Audio monitoring and control", icon: "speaker.wave.2.fill",
                   onReset: { source.gain = 1; source.muted = false }) {
                CPRow(icon: "headphones", label: "Device") {
                    Picker("", selection: Binding(
                        get: { source.audioDeviceID ?? "" },
                        set: { source.audioDeviceID = $0.isEmpty ? nil : $0 })) {
                        Text("None").tag("")
                        ForEach(audioDevices) { d in Text(d.name).tag(d.id) }
                    }
                    .cpPickerChrome()
                    .frame(maxWidth: 170)
                    Button { audioDevices = AudioCapture.availableDevices() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).foregroundColor(CP.text)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(CP.field))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(CP.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain).help("Refresh audio devices")
                }
                VStack(spacing: 2) {
                    CPSliderRow(icon: "dial.medium", label: "Gain", value: $source.gain, range: 0...1.5, defaultValue: 1, showDivider: false)
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 18 + 64 + 8, height: 1)
                        ChannelMeterBar(id: source.id, muted: source.muted, segments: 24).frame(height: 11)
                        Color.clear.frame(width: 52 + 22 + 8, height: 1)
                    }
                    .padding(.bottom, 8)
                    CPDivider()
                }
                CPRow(icon: source.muted ? "speaker.slash.fill" : "speaker.wave.1", label: "Mute") {
                    Toggle("", isOn: $source.muted).toggleStyle(.switch).tint(DS.program).labelsHidden()
                }
                HStack {
                    CPPillButton(icon: "slider.vertical.3", title: "Audio Effects (EQ · Compressor · Gate)", expanded: showFX) {
                        withAnimation(.easeInOut(duration: 0.18)) { showFX.toggle() }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
            }

            if showFX {
                CPCard(title: "Audio Effects", subtitle: "EQ · Noise gate · Compressor", icon: "waveform") {
                    AudioEffectsBody(source: source).padding(.vertical, 6)
                }
            }
        }
        .onAppear { audioDevices = AudioCapture.availableDevices() }
    }
}

/// Clear-text / hide-background switches for a slide input.
struct SlideVisibilityToggles: View {
    @ObservedObject var source: SlideSource
    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $source.textCleared).toggleStyle(.switch).tint(DS.amber).labelsHidden().help("Hide text")
            Text("BG").font(.system(size: 10, weight: .semibold)).foregroundColor(CP.text2)
            Toggle("", isOn: Binding(get: { !source.backgroundCleared }, set: { source.backgroundCleared = !$0 }))
                .toggleStyle(.switch).tint(CP.blue).labelsHidden().help("Show background")
        }
    }
}

struct PlaybackTransport<S: MediaPlayback>: View {
    @ObservedObject var source: S
    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    private func tc(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s); return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(
                get: { scrubbing ? scrubValue : source.currentTime },
                set: { scrubValue = $0 }),
                in: 0...max(0.1, source.duration),
                onEditingChanged: { editing in
                    if editing { scrubValue = source.currentTime; scrubbing = true }
                    else { source.seek(to: scrubValue); scrubbing = false }
                })
            HStack {
                Text(tc(scrubbing ? scrubValue : source.currentTime)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                Spacer()
                Text(tc(source.duration)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Button { source.skip(-10) } label: { Image(systemName: "gobackward.10") }.buttonStyle(.borderless)
                Button { source.restart() } label: { Image(systemName: "backward.end.fill") }.buttonStyle(.borderless)
                Button { source.togglePlay() } label: {
                    Image(systemName: source.paused ? "play.fill" : "pause.fill").font(.system(size: 16))
                }.buttonStyle(.borderless)
                Button { source.skip(10) } label: { Image(systemName: "goforward.10") }.buttonStyle(.borderless)
                Spacer()
                Toggle("Loop", isOn: Binding(get: { source.loop }, set: { source.loop = $0 })).font(.system(size: 11))
            }
            Divider()
            HStack(spacing: 8) {
                Button("Set In") { source.setIn() }.font(.system(size: 10))
                Button("Set Out") { source.setOut() }.font(.system(size: 10))
                Button("Clear") { source.clearTrim() }.font(.system(size: 10))
                Spacer()
                Text("IN \(tc(source.inPoint))  •  OUT \(source.outPoint > 0 ? tc(source.outPoint) : "end")")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(CP.field))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(CP.border, lineWidth: 1))
    }
}

// Total EQ magnitude (dB) at frequency f, for the response curve.
func eqTotalDB(_ f: Double, _ s: Source) -> Double {
    let sr = 48000.0
    var db = 0.0
    if s.eqHPF >= 20 { db += Biquad.highpass(s.eqHPF, sr: sr).magnitudeDB(f, sr: sr) }
    if s.eqLPF >= 1000 && s.eqLPF < 20000 { db += Biquad.lowpass(s.eqLPF, sr: sr).magnitudeDB(f, sr: sr) }
    if abs(s.eqLowGain) > 0.1 { db += Biquad.lowShelf(120, gainDB: s.eqLowGain, sr: sr).magnitudeDB(f, sr: sr) }
    if abs(s.eqP1Gain) > 0.1 { db += Biquad.peaking(s.eqP1Freq, q: s.eqP1Q, gainDB: s.eqP1Gain, sr: sr).magnitudeDB(f, sr: sr) }
    if abs(s.eqP2Gain) > 0.1 { db += Biquad.peaking(s.eqP2Freq, q: s.eqP2Q, gainDB: s.eqP2Gain, sr: sr).magnitudeDB(f, sr: sr) }
    if abs(s.eqHighGain) > 0.1 { db += Biquad.highShelf(8000, gainDB: s.eqHighGain, sr: sr).magnitudeDB(f, sr: sr) }
    return db
}

struct EQCurve: View {
    @ObservedObject var source: Source
    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            ZStack {
                Path { p in p.move(to: CGPoint(x: 0, y: H / 2)); p.addLine(to: CGPoint(x: W, y: H / 2)) }
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
                Path { p in
                    let n = 110
                    for i in 0...n {
                        let frac = Double(i) / Double(n)
                        let f = 20 * pow(1000, frac)
                        let db = eqTotalDB(f, source)
                        let x = CGFloat(frac) * W
                        let y = min(max(0, H / 2 - CGFloat(db / 18) * (H / 2)), H)
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }.stroke(cPreview, lineWidth: 2)
            }
            .background(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 84)
    }
}

struct GateCurve: View {
    @ObservedObject var source: Source
    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            Path { p in
                for i in 0...60 {
                    let inDb = -60.0 + Double(i)
                    let outDb = inDb < source.gateThreshold ? max(-60, inDb + source.gateRange) : inDb
                    let x = CGFloat((inDb + 60) / 60) * W
                    let y = H - CGFloat((min(0, max(-60, outDb)) + 60) / 60) * H
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }.stroke(vmGreen, lineWidth: 2)
                .background(Color(white: 0.06)).clipShape(RoundedRectangle(cornerRadius: 4))
        }.frame(height: 70)
    }
}

struct CompCurve: View {
    @ObservedObject var source: Source
    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            ZStack {
                Path { p in p.move(to: CGPoint(x: 0, y: H)); p.addLine(to: CGPoint(x: W, y: 0)) }
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                Path { p in
                    for i in 0...60 {
                        let inDb = -60.0 + Double(i)
                        var outDb = inDb
                        if inDb > source.compThreshold { outDb = source.compThreshold + (inDb - source.compThreshold) / max(1, source.compRatio) }
                        outDb += source.compMakeup
                        let x = CGFloat((inDb + 60) / 60) * W
                        let y = H - CGFloat((min(0, max(-60, outDb)) + 60) / 60) * H
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }.stroke(cProgram, lineWidth: 2)
            }
            .background(Color(white: 0.06)).clipShape(RoundedRectangle(cornerRadius: 4))
        }.frame(height: 70)
    }
}

struct AudioEffects: View {
    @ObservedObject var source: Source
    var body: some View {
        ScrollView { AudioEffectsBody(source: source).padding(12) }
            .frame(width: 380, height: 560)
            .background(CP.bg)
    }
}

struct AudioEffectsBody: View {
    @ObservedObject var source: Source
    var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Effects", isOn: $source.fxEnabled).font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Menu("Preset") { ForEach(FXPreset.all) { p in Button(p.name) { source.applyFXPreset(p) } } }
                        .frame(width: 110)
                }
                Text("Effects process the recorded & streamed mix when “Mix input faders into recording & stream” is on.")
                    .font(.system(size: 9)).foregroundColor(.secondary)
                Divider()
                Text("PARAMETRIC EQ").font(.system(size: 9, weight: .heavy)).kerning(1).foregroundColor(.secondary)
                EQCurve(source: source)
                adjSlider("High-pass Hz", $source.eqHPF, 0...400)
                adjSlider("Low shelf dB", $source.eqLowGain, -18...18)
                Text("Peak 1").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                adjSlider("Freq Hz", $source.eqP1Freq, 40...1200)
                adjSlider("Gain dB", $source.eqP1Gain, -18...18)
                adjSlider("Q", $source.eqP1Q, 0.3...10)
                Text("Peak 2").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                adjSlider("Freq Hz", $source.eqP2Freq, 500...12000)
                adjSlider("Gain dB", $source.eqP2Gain, -18...18)
                adjSlider("Q", $source.eqP2Q, 0.3...10)
                adjSlider("High shelf dB", $source.eqHighGain, -18...18)
                adjSlider("Low-pass Hz", $source.eqLPF, 0...20000)
                Divider()
                Text("NOISE GATE").font(.system(size: 9, weight: .heavy)).kerning(1).foregroundColor(.secondary)
                GateCurve(source: source)
                adjSlider("Threshold dB", $source.gateThreshold, -80...0)
                adjSlider("Range dB", $source.gateRange, -80...0)
                adjSlider("Attack ms", $source.gateAttack, 0...50)
                adjSlider("Hold ms", $source.gateHold, 0...500)
                adjSlider("Release ms", $source.gateRelease, 5...1000)
                Divider()
                Text("COMPRESSOR / LIMITER").font(.system(size: 9, weight: .heavy)).kerning(1).foregroundColor(.secondary)
                CompCurve(source: source)
                adjSlider("Threshold dB", $source.compThreshold, -40...0)
                adjSlider("Ratio :1", $source.compRatio, 1...20)
                adjSlider("Attack ms", $source.compAttack, 0...100)
                adjSlider("Release ms", $source.compRelease, 10...500)
                adjSlider("Makeup dB", $source.compMakeup, 0...18)
            }
    }
}

struct AudioMixerPanel: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("AUDIO MIXER").font(.system(size: 10, weight: .heavy)).kerning(2).foregroundColor(.secondary)
                MasterStrip(label: "MASTER", active: true, showFXButton: true)
                MasterStrip(label: "RECORDING", active: engine.isRecording)
                DBScale().padding(.horizontal, 4)
                Divider()
                ForEach(engine.sources) { s in
                    ChannelStrip(source: s)
                }
                Text("Each input has its own fader, mute (M) and solo (S). Assign an audio device per input (Input tab) for live metering. To record the summed mix (faders, mutes and solos applied), enable “Mix input faders into recording & stream” in the gear menu; otherwise recording and stream carry the single master device.")
                    .font(.system(size: 9)).foregroundColor(.secondary).padding(.top, 4)
            }.padding(10)
        }
    }
}

struct ClockText: View {
    @EnvironmentObject var tele: Telemetry
    var body: some View {
        Text(tele.clock).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(cProgram)
    }
}

struct FPSText: View {
    @EnvironmentObject var tele: Telemetry
    var body: some View {
        Text("FPS \(tele.fps)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
    }
}

// Leaf meters observe Telemetry only, so their parent strips don't re-render each tick.
struct ChannelMeterBar: View {
    @EnvironmentObject var tele: Telemetry
    let id: UUID; var muted: Bool; var segments: Int = 20
    var body: some View { AudioMeter(level: muted ? 0 : (tele.levels[id] ?? 0), segments: segments) }
}
struct ChannelDBLabel: View {
    @EnvironmentObject var tele: Telemetry
    let id: UUID; var muted: Bool
    var body: some View {
        let lvl = muted ? 0 : (tele.levels[id] ?? 0)
        Text(dbReadout(lvl)).font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(meterDB(lvl) >= -2 ? vmRed : .secondary)
    }
}
struct BusMeterBar: View {
    @EnvironmentObject var tele: Telemetry
    var active: Bool; var segments: Int = 28
    var body: some View { AudioMeter(level: active ? tele.master : 0, segments: segments) }
}
struct BusDBLabel: View {
    @EnvironmentObject var tele: Telemetry
    var active: Bool
    var body: some View {
        let lvl = active ? tele.master : 0
        Text(dbReadout(lvl)).font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(meterDB(lvl) >= -2 ? vmRed : .secondary)
    }
}

struct MasterStrip: View {
    @EnvironmentObject var engine: Engine
    var label: String; var active: Bool
    var showFXButton: Bool = false
    @State private var showFX = false
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(label).font(.system(size: 10, weight: .heavy)).kerning(1).foregroundColor(.white)
                Spacer()
                if showFXButton {
                    Button { showFX.toggle() } label: {
                        Text("FX").font(.system(size: 9, weight: .heavy))
                            .frame(width: 30, height: 18)
                            .background(engine.masterBus.fxEnabled ? cProgram : Color(white: 0.17))
                            .foregroundColor(.white).cornerRadius(3)
                    }.buttonStyle(.plain)
                    .popover(isPresented: $showFX) { AudioEffects(source: engine.masterBus) }
                }
                BusDBLabel(active: active)
            }
            BusMeterBar(active: active, segments: 28).frame(height: 16)
        }
        .padding(8).background(vmStripBG).cornerRadius(5)
    }
}

struct ChannelStrip: View {
    @ObservedObject var source: Source
    @State private var showFX = false
    var body: some View {
        if source.isPlaceholder {
            HStack {
                Text(source.name).font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Text("no input").font(.system(size: 9)).foregroundColor(Color(white: 0.35))
            }
            .padding(8).background(Color(white: 0.07)).cornerRadius(5)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(source.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer()
                    ChannelDBLabel(id: source.id, muted: source.muted)
                }
                ChannelMeterBar(id: source.id, muted: source.muted).frame(height: 13)
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 9)).foregroundColor(.secondary)
                    Slider(value: $source.gain, in: 0...1.5)
                    Text(gainDBText(source.gain)).font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary).frame(width: 42, alignment: .trailing)
                }
                HStack(spacing: 6) {
                    Button { source.sendToMain.toggle() } label: {
                        Text("MAIN").font(.system(size: 9, weight: .heavy))
                            .frame(maxWidth: .infinity).frame(height: 20)
                            .background(source.sendToMain ? cProgram : Color(white: 0.17))
                            .foregroundColor(source.sendToMain ? .black : Color(white: 0.6)).cornerRadius(3)
                    }.buttonStyle(.plain)
                    Button { source.solo.toggle() } label: {
                        Text("SOLO").font(.system(size: 9, weight: .heavy))
                            .frame(maxWidth: .infinity).frame(height: 20)
                            .background(source.solo ? vmAmber : Color(white: 0.17))
                            .foregroundColor(source.solo ? .black : .white).cornerRadius(3)
                    }.buttonStyle(.plain)
                    Button { source.muted.toggle() } label: {
                        Text("M").font(.system(size: 10, weight: .heavy))
                            .frame(width: 30, height: 20)
                            .background(source.muted ? vmRed : Color(white: 0.17))
                            .foregroundColor(.white).cornerRadius(3)
                    }.buttonStyle(.plain)
                    Button { showFX.toggle() } label: {
                        Text("FX").font(.system(size: 9, weight: .heavy))
                            .frame(width: 30, height: 20)
                            .background(source.fxEnabled ? cProgram : Color(white: 0.17))
                            .foregroundColor(.white).cornerRadius(3)
                    }.buttonStyle(.plain)
                    .popover(isPresented: $showFX) { AudioEffects(source: source) }
                }
                if source.audioDeviceID == nil {
                    Text("no audio device — assign one in the Input tab for metering")
                        .font(.system(size: 8)).foregroundColor(Color(white: 0.4))
                }
            }
            .padding(8).background(vmStripBG).cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(source.muted ? vmRed.opacity(0.5) : Color.white.opacity(0.05), lineWidth: 1))
        }
    }
}

// vMix-style colours
let vmGreen = Color(red: 0.26, green: 0.76, blue: 0.29)
let vmAmber = Color(red: 0.92, green: 0.74, blue: 0.05)
let vmRed = Color(red: 0.89, green: 0.23, blue: 0.18)
let vmStripBG = Color(red: 0.10, green: 0.10, blue: 0.11)

func meterDB(_ level: Float) -> Double { level > 0.0001 ? Double(20 * log10(level)) : -60 }
func dbReadout(_ level: Float) -> String { level > 0.0009 ? String(format: "%.0f", meterDB(level)) : "-∞" }
func gainDBText(_ gain: Double) -> String {
    let d = gain > 0.0001 ? 20 * log10(gain) : -60
    return d <= -60 ? "-∞ dB" : String(format: "%+.0f dB", d)
}

/// Segmented LED meter mapped to a -60…0 dB scale (vMix look).
struct AudioMeter: View {
    var level: Float
    var segments: Int = 20
    private func segColor(_ frac: Double) -> Color {
        let d = -60 + frac * 60
        if d >= -2 { return vmRed }
        if d >= -9 { return vmAmber }
        return vmGreen
    }
    var body: some View {
        let pos = (meterDB(level) + 60) / 60
        HStack(spacing: 1.5) {
            ForEach(0..<segments, id: \.self) { i in
                let frac = segments <= 1 ? 0 : Double(i) / Double(segments - 1)
                let lit = frac <= pos
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit ? segColor(frac) : segColor(frac).opacity(0.14))
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Tiny dB scale ruler under the master meters.
struct DBScale: View {
    let marks: [Int] = [-60, -40, -20, -12, -6, 0]
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                ForEach(marks, id: \.self) { m in
                    let x = CGFloat((Double(m) + 60) / 60) * geo.size.width
                    Text("\(m)").font(.system(size: 7, design: .monospaced)).foregroundColor(.secondary)
                        .position(x: min(max(8, x), geo.size.width - 8), y: 6)
                }
            }
        }.frame(height: 12)
    }
}

struct DictionaryLookup: View {
    @EnvironmentObject var engine: Engine
    @State private var word = ""
    @State private var definition = ""
    @State private var notFound = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("DICTIONARY")
            HStack {
                TextField("Search a word", text: $word, onCommit: lookup).textFieldStyle(.roundedBorder)
                Button("Look up", action: lookup)
            }
            if notFound {
                Text("No definition found in the installed dictionaries.").font(.system(size: 10)).foregroundColor(.orange)
            }
            if !definition.isEmpty {
                ScrollView { Text(definition).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 90).padding(6).background(Color(white: 0.1)).cornerRadius(5)
                Button("Show on Program / Video Wall") { engine.showDefinition(word: word, definition: definition) }
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(10).background(Color(white: 0.07))
    }
    func lookup() {
        notFound = false; definition = ""
        if let d = engine.defineWord(word) { definition = d } else { notFound = true }
    }
}

struct OverlaysPanel: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("OVERLAY CHANNELS / LAYERS").font(.system(size: 9, weight: .heavy)).kerning(1).foregroundColor(.secondary)
                Spacer()
                Menu {
                    Menu("Templates") {
                        ForEach(OverlayTemplate.all) { t in
                            Button { engine.addLayerTemplate(t) } label: { Label(t.name, systemImage: t.icon) }
                        }
                    }
                    Divider()
                    ForEach(Layer.Kind.allCases) { k in Button { engine.addLayer(k) } label: { Label(k.rawValue, systemImage: k.icon) } }
                } label: { Image(systemName: "plus.circle.fill").foregroundColor(cPreview) }
                .menuStyle(.borderlessButton).frame(width: 28)
            }.padding(.horizontal, 10).padding(.vertical, 6)
            List { ForEach(engine.layers) { l in LayerRow(layer: l) } }.listStyle(.plain).frame(maxHeight: 220)
            Divider()
            ScrollView {
                if let sel = engine.layers.first(where: { $0.id == engine.selectedLayerID }) { LayerInspector(layer: sel) }
                else { Text("Select a layer to edit it.").font(.system(size: 11)).foregroundColor(.secondary).padding(12) }
            }
        }
    }
}

struct LayerRow: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var layer: Layer
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: layer.kind.icon).frame(width: 18)
            Text(layer.name).font(.system(size: 12)).lineLimit(1)
            Spacer()
            VStack(spacing: 0) {
                Button { engine.moveLayer(layer.id, by: -1) } label: { Image(systemName: "chevron.up").font(.system(size: 7)) }.buttonStyle(.borderless)
                Button { engine.moveLayer(layer.id, by: 1) } label: { Image(systemName: "chevron.down").font(.system(size: 7)) }.buttonStyle(.borderless)
            }
            Toggle("", isOn: $layer.isLive).toggleStyle(.switch).tint(.red).labelsHidden()
            Button { engine.removeLayer(layer.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.borderless).foregroundColor(.secondary)
        }
        .padding(.vertical, 2).contentShape(Rectangle())
        .onTapGesture { engine.selectedLayerID = layer.id }
        .background(engine.selectedLayerID == layer.id ? cPreview.opacity(0.12) : Color.clear)
    }
}

// MARK: - Status bar

struct DiskReadout: View {
    @EnvironmentObject var engine: Engine
    @State private var freeGB: Double? = nil
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    var body: some View {
        Group {
            if let g = freeGB {
                HStack(spacing: 4) {
                    Image(systemName: g < 5 ? "externaldrive.badge.exclamationmark" : "externaldrive")
                        .font(.system(size: 9))
                    Text(String(format: "%.0f GB free", g)).font(.system(size: 10, design: .monospaced))
                }
                .foregroundColor(g < 5 ? .red : .secondary)
                .help(g < 5 ? "Low disk space on the recording volume" : "Free space on the recording volume")
            } else {
                Text("Disk —").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            }
        }
        .onAppear { freeGB = engine.freeDiskGB() }
        .onReceive(timer) { _ in freeGB = engine.freeDiskGB() }
    }
}

struct StatusBar: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        HStack(spacing: 10) {
            Text("\(engine.width)×\(engine.height) · \(engine.fpsTarget)p").font(DS.mono(10)).foregroundColor(DS.text2)
            FPSText()
            DiskReadout()
            Spacer()
            Text("OVERLAYS").font(DS.caption).kerning(1).foregroundColor(DS.text3)
            ForEach(0..<4) { i in
                Button("\(i + 1)") { engine.toggleOverlay(i) }
                    .buttonStyle(.ds(.amber, .small, active: engine.layers.indices.contains(i) && engine.layers[i].isLive))
                    .help("Toggle overlay channel \(i + 1)")
            }
            Rectangle().fill(DS.line).frame(width: 1, height: 16)
            Button("Snapshot") { engine.snapshot() }.buttonStyle(.ds(.normal, .small))
            Button("Outputs") { engine.rightTab = 4 }.buttonStyle(.ds(.normal, .small, active: !engine.activeScreens.isEmpty))
            Button("Multiview") { engine.openMultiviewWindow() }.buttonStyle(.ds(.normal, .small))
            Button("Guides") { engine.showSafeGuides.toggle() }.buttonStyle(.ds(.normal, .small, active: engine.showSafeGuides))
        }
        .padding(.horizontal, 12).frame(height: 32).background(DS.bg2)
        .overlay(Rectangle().fill(DS.line).frame(height: 1), alignment: .top)
    }
}

// MARK: - Inspector + variants

struct OverlayStyleControls: View {
    @ObservedObject var layer: Layer
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            SectionLabel("STYLING")
            ColorPicker("Accent", selection: $layer.accent)
            ColorPicker("Text colour", selection: $layer.textColor)
            ColorPicker("Background", selection: $layer.bgColor)
            adjSlider("BG opacity", $layer.bgOpacity, 0...1)
            adjSlider("Font size", $layer.fontScale, 0.6...2.0)
        }
    }
}

struct LayerInspector: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var layer: Layer
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(layer.kind.rawValue.uppercased()).font(.system(size: 11, weight: .heavy)).kerning(1.5).foregroundColor(cPreview)
                Spacer()
                Circle().fill(layer.isLive ? Color.red : Color(white: 0.3)).frame(width: 9, height: 9)
            }
            TextField("Layer name", text: $layer.name)
            VariantsView(layer: layer)
            LayerTransformView(layer: layer)
            Divider()
            switch layer.kind {
            case .lowerThird:
                TextField("Name line", text: $layer.text1); TextField("Title line", text: $layer.text2)
                Picker("Style", selection: $layer.style) {
                    Text("Accent strip").tag(0); Text("Boxed").tag(1); Text("Minimal").tag(2)
                    Text("Two-tone").tag(3); Text("Tab header").tag(4); Text("Outline").tag(5); Text("Pill").tag(6)
                }
                Picker("Align", selection: $layer.align) { Text("Left").tag(0); Text("Centre").tag(1); Text("Right").tag(2) }
                OverlayStyleControls(layer: layer)
            case .ticker:
                TextField("Ticker text", text: $layer.text1)
                adjSlider("Speed", $layer.number1, 20...300)
            case .countdown:
                TextField("Label", text: $layer.text1)
                HStack { Text("Minutes").font(.system(size: 11)).foregroundColor(.secondary); TextField("", value: $layer.number1, formatter: NumberFormatter()).frame(width: 60) }
                HStack(spacing: 8) {
                    Button("Start") { if layer.remaining <= 0 { layer.remaining = layer.number1 * 60 }; layer.lastTick = 0; layer.isRunning = true }
                    Button("Pause") { layer.isRunning = false }
                    Button("Reset") { layer.isRunning = false; layer.remaining = layer.number1 * 60 }
                }
                ColorPicker("Accent", selection: $layer.accent)
            case .clock:
                Toggle("24-hour", isOn: $layer.use24h)
            case .scoreboard:
                TextField("Team A", text: $layer.text1); TextField("Team B", text: $layer.text2)
                ColorPicker("Team A color", selection: $layer.accent)
                HStack(spacing: 8) {
                    Button("A +1") { layer.scoreA += 1 }; Button("A −1") { layer.scoreA = max(0, layer.scoreA - 1) }
                    Button("B +1") { layer.scoreB += 1 }; Button("B −1") { layer.scoreB = max(0, layer.scoreB - 1) }
                }
            case .title:
                TextField("Title text", text: $layer.text1)
                TextField("Subtitle (optional)", text: $layer.text2)
                Picker("Align", selection: $layer.align) { Text("Left").tag(0); Text("Centre").tag(1); Text("Right").tag(2) }
                adjSlider("Size", $layer.number1, 3...20)
                ColorPicker("Title colour", selection: $layer.accent)
                ColorPicker("Subtitle colour", selection: $layer.textColor)
                Divider()
                Toggle("Background box", isOn: Binding(get: { layer.bgOpacity > 0.01 }, set: { layer.bgOpacity = $0 ? 0.65 : 0 }))
                    .font(.system(size: 11))
                if layer.bgOpacity > 0.01 {
                    ColorPicker("Box colour", selection: $layer.bgColor)
                    adjSlider("Box opacity", $layer.bgOpacity, 0.05...1)
                }
            case .logo:
                Button("Choose image…") {
                    pickFile(types: ["public.image"]) { url in
                        if let nsimg = NSImage(contentsOf: url) {
                            var rect = CGRect(origin: .zero, size: nsimg.size)
                            layer.logoImage = nsimg.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                        }
                    }
                }
                Picker("Position", selection: $layer.position) { Text("Top left").tag(0); Text("Top right").tag(1); Text("Bottom left").tag(2); Text("Bottom right").tag(3) }
                adjSlider("Scale", $layer.number1, 4...50)
            case .qrcode:
                TextField("URL", text: $layer.text1)
                adjSlider("Size", $layer.number1, 80...360)
            case .pip:
                Picker("Source", selection: Binding(get: { layer.sourceRef ?? pipNoneTag }, set: { layer.sourceRef = ($0 == pipNoneTag ? nil : $0) })) {
                    Text("— none —").tag(pipNoneTag)
                    ForEach(engine.sources) { s in Text(s.name).tag(s.id) }
                }
                Picker("Corner", selection: $layer.position) { Text("Top left").tag(0); Text("Top right").tag(1); Text("Bottom left").tag(2); Text("Bottom right").tag(3) }
                adjSlider("Size", $layer.number1, 8...100)
                ColorPicker("Border", selection: $layer.accent)
                Divider()
                SectionLabel("CHROMA KEY")
                Toggle("Enable chroma key", isOn: $layer.keyEnabled)
                if layer.keyEnabled {
                    ColorPicker("Key colour", selection: $layer.keyColor)
                    adjSlider("Similarity", $layer.keySimilarity, 0.02...0.5)
                    adjSlider("Smoothness", $layer.keySmoothness, 0.005...0.3)
                    Text("Tip: set the source full-size (Size ≈ 100) to place keyed talent over the whole program.")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
            case .definition:
                TextField("Word", text: $layer.text1)
                Text("Definition").font(.system(size: 10)).foregroundColor(.secondary)
                TextField("Definition", text: $layer.text2, axis: .vertical).lineLimit(2...6)
                adjSlider("Panel height", $layer.number1, 4...12)
                ColorPicker("Word colour", selection: $layer.accent)
                ColorPicker("Panel colour", selection: $layer.bgColor)
                adjSlider("Panel opacity", $layer.bgOpacity, 0.3...1)
                Text("Tip: use the Dictionary search at the top of this tab to fill this automatically.")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder).padding(12)
    }
}

struct VariantsView: View {
    @ObservedObject var layer: Layer
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("VARIANTS")
                Spacer()
                Button { layer.captureVariant() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Save current as variant")
                Button { layer.cycleVariant(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Button { layer.cycleVariant(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
            }
            if layer.variants.isEmpty {
                Text("Save reusable states (e.g. each speaker) and switch live.").font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(layer.variants.enumerated()), id: \.element.id) { idx, v in
                            Button { layer.applyVariant(idx) } label: {
                                Text(v.text1.isEmpty ? v.name : v.text1).font(.system(size: 10)).lineLimit(1)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(layer.activeVariant == idx ? cPreview.opacity(0.3) : Color(white: 0.14))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(layer.activeVariant == idx ? cPreview : Color(white: 0.25), lineWidth: 1))
                                    .cornerRadius(5)
                            }.buttonStyle(.plain)
                            .contextMenu { Button("Delete", role: .destructive) { if layer.variants.indices.contains(idx) { layer.variants.remove(at: idx) } } }
                        }
                    }
                }
            }
        }
    }
}

struct LayerTransformView: View {
    @ObservedObject var layer: Layer
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("TRANSFORM")
                Spacer()
                Button("Reset") { layer.resetTransform() }.font(.system(size: 10))
            }
            adjSlider("Opacity", $layer.opacity, 0...1)
            adjSlider("Pos X", $layer.offsetX, -0.5...0.5)
            adjSlider("Pos Y", $layer.offsetY, -0.5...0.5)
            adjSlider("Scale", $layer.scaleAdj, 0.2...3)
            adjSlider("Rotate", $layer.rotationAdj, -180...180)
        }
    }
}

// MARK: - Stream settings

struct StreamSettingsView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    private var liveSummary: String {
        let n = engine.liveDestinations.count
        if n == 0 { return "ffmpeg detected — enable at least one destination." }
        return n == 1 ? "ffmpeg detected — ready to stream to 1 destination."
                      : "ffmpeg detected — ready to simulcast to \(n) destinations."
    }
    private var streamAudioNote: String {
        guard engine.streamAudio else { return "Audio: silent track." }
        let mixing = engine.mixInputsIntoRecording && engine.sources.contains { $0.audioDeviceID != nil }
        return mixing
            ? "Audio: the input-fader mix (MAIN / mute / solo / FX apply). Video/audio-file inputs play to speakers only and are not in the mix yet."
            : "Audio: the master audio device (+ master FX). Turn on \u{201C}Mix input faders into recording & stream\u{201D} (gear menu) to stream the per-input mix instead."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("STREAM DESTINATIONS").font(.system(size: 13, weight: .heavy)).kerning(1)
                Spacer()
                Button("Add Destination") { engine.addStreamDestination() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if engine.streamDestinations.isEmpty {
                Text("No destinations yet. Add one and choose a platform (YouTube, Facebook Live, Twitch) or a custom RTMP/RTMPS/SRT server.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($engine.streamDestinations) { $d in StreamRow(dest: $d) }
                }
            }
            Divider()
            HStack(spacing: 14) {
                Toggle("Send program audio", isOn: $engine.streamAudio)
                    .disabled(engine.isStreaming)
                    .help("On: the mixed program audio goes to the stream. Off: a silent audio track (older behaviour).")
                Picker("Video bitrate", selection: $engine.streamBitrateKbps) {
                    ForEach(Engine.streamBitrates, id: \.self) { b in
                        Text(String(format: "%.1f Mbps", Double(b) / 1000)).tag(b)
                    }
                }
                .frame(width: 210)
                .disabled(engine.isStreaming)
            }
            .font(.system(size: 11))
            Text(streamAudioNote).font(.system(size: 10)).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Image(systemName: engine.ffmpegAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(engine.ffmpegAvailable ? cProgram : .orange)
                if engine.ffmpegAvailable {
                    Text(liveSummary).font(.system(size: 11))
                } else {
                    Text("ffmpeg not found. Install it once (Terminal: brew install ffmpeg), then reopen.").font(.system(size: 11))
                }
                Spacer()
                if engine.isStreaming {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("LIVE").font(.system(size: 10, weight: .heavy)).foregroundColor(.red)
                    }
                }
                Button(engine.isStreaming ? "Stop Streaming" : "Go Live") { engine.toggleStream(nil) }
                    .disabled(!engine.ffmpegAvailable || (!engine.isStreaming && engine.liveDestinations.isEmpty))
                    .foregroundColor(engine.isStreaming ? .red : cProgram)
            }
            if !engine.streamError.isEmpty {
                Text(engine.streamError).font(.system(size: 10)).foregroundColor(.orange)
                    .textSelection(.enabled).lineLimit(6)
            }
            Text("Go Live sends the Program to every enabled destination at once (simulcast). RTMP/RTMPS use FLV; SRT uses MPEG-TS automatically. Resolution and frame rate are locked while live.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(16).frame(width: 560, height: 600)
        .preferredColorScheme(.dark)
    }
}

struct StreamRow: View {
    @EnvironmentObject var engine: Engine
    @Binding var dest: StreamDestination
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: $dest.enabled).labelsHidden()
                TextField("Name", text: $dest.name)
                Button { engine.removeStreamDestination(dest.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundColor(.red)
            }
            HStack {
                Picker("Platform", selection: $dest.platform) {
                    ForEach(StreamDestination.platforms, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: dest.platform) { newValue in
                    let p = StreamDestination.preset(for: newValue)
                    dest.proto = p.proto
                    if !p.url.isEmpty { dest.url = p.url }
                }
                Picker("Protocol", selection: $dest.proto) {
                    ForEach(StreamDestination.protocols, id: \.self) { Text($0).tag($0) }
                }
            }
            TextField("Server URL", text: $dest.url)
            SecureField("Stream key", text: $dest.key)
            Text(dest.composedURL).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
        }
        .textFieldStyle(.roundedBorder)
        .padding(10).background(DS.bg2).cornerRadius(6)
    }
}

// MARK: - Add network stream

struct AddStreamView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    @State private var peakMbps: Double = 0
    private var mode: Int { engine.streamInputMode }
    private var editing: Bool { engine.editStreamID != nil }

    private var title: String {
        switch mode {
        case 2: return editing ? "EDIT RTMP / RTSP / SRT" : "ADD RTMP / RTSP / SRT (FFMPEG)"
        case 3: return "YOUTUBE / TWITCH / FACEBOOK LINK"
        case 4: return editing ? "EDIT WEB PAGE" : "ADD WEB PAGE"
        default: return editing ? "EDIT NETWORK STREAM" : "ADD NETWORK STREAM (HLS / URL)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .heavy)).kerning(1)

            if mode == 4 {
                Text("Displays any website as an input — great for online lyrics, Bible sites, countdowns, dashboards or web-based graphics. It renders at 1280×720 and refreshes continuously.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                TextField("https://…", text: $urlString)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            } else if mode == 2 {
                Text("Pulls and decodes an RTMP / RTSP / SRT (or HTTP) stream using your installed ffmpeg, and shows it as an input. Requires ffmpeg (brew install ffmpeg).")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                if !engine.ffmpegAvailable {
                    Text("⚠︎ ffmpeg not found — install it first, then reopen.").font(.system(size: 11)).foregroundColor(.orange)
                }
                TextField("rtmp://…  •  rtsp://…  •  srt://…", text: $urlString)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            } else if mode == 3 {
                Text("Plays a YouTube / Twitch / Facebook link by extracting the real stream with yt-dlp and decoding it with ffmpeg. Best for live streams; both tools must be installed.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                HStack(spacing: 12) {
                    Label(engine.ffmpegAvailable ? "ffmpeg ✓" : "ffmpeg missing", systemImage: engine.ffmpegAvailable ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(engine.ffmpegAvailable ? cProgram : .orange)
                    Label(engine.ytdlpAvailable ? "yt-dlp ✓" : "yt-dlp missing", systemImage: engine.ytdlpAvailable ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(engine.ytdlpAvailable ? cProgram : .orange)
                }.font(.system(size: 10))
                if !engine.ytdlpAvailable {
                    Text("Install once in Terminal: brew install yt-dlp ffmpeg").font(.system(size: 10)).foregroundColor(.secondary)
                }
                TextField("https://www.youtube.com/watch?v=…", text: $urlString)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            } else {
                Text("HLS (.m3u8) live streams and direct HTTP(S) video URLs — full input with transport, trim and audio.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                TextField("https://example.com/live/stream.m3u8", text: $urlString)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                HStack {
                    Text("Max bitrate").font(.system(size: 11)).foregroundColor(.secondary)
                    Slider(value: $peakMbps, in: 0...20)
                    Text(peakMbps < 0.1 ? "Auto" : String(format: "%.0f Mbps", peakMbps))
                        .font(.system(size: 10, design: .monospaced)).frame(width: 60, alignment: .trailing)
                }
                Text("Caps the adaptive (ABR) bitrate for HLS. Auto lets the player choose.")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { engine.streamInputMode = 0; dismiss() }
                Button(editing ? "Save" : "Add") {
                    engine.commitStream(url: urlString, mode: mode, peakMbps: peakMbps)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty
                          || (mode == 2 && !engine.ffmpegAvailable)
                          || (mode == 3 && (!engine.ffmpegAvailable || !engine.ytdlpAvailable)))
            }
        }
        .padding(16).frame(width: 560, height: mode == 3 ? 340 : 300).preferredColorScheme(.dark)
        .onAppear { urlString = engine.editStreamURL }
    }
}

// MARK: - Outputs (simultaneous / external displays)

struct OutputsPanel: View {
    @EnvironmentObject var engine: Engine
    @State private var screens: [(index: Int, name: String)] = []
    @State private var ndiAvailable = false
    @State private var ndiVersion = ""

    private func refresh() {
        screens = engine.availableScreens(); NDIBridge.shared.detect()
        ndiAvailable = NDIBridge.shared.isAvailable; ndiVersion = NDIBridge.shared.versionString
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                CPCard(title: "Program Out", subtitle: "Full screen, no title bar", icon: "rectangle.inset.filled") {
                    CPRow(icon: "display", label: "Full-screen Program") {
                        Toggle("", isOn: Binding(get: { engine.programWindowActive }, set: { _ in engine.openOutputWindow() }))
                            .toggleStyle(.switch).tint(CP.blue).labelsHidden()
                    }
                    CPRow(icon: "square.grid.3x3", label: "Multiview window", showDivider: false) {
                        CPButton(title: "Open") { engine.openMultiviewWindow() }
                    }
                    Text("Program Out uses the second display when one is connected. Press Esc or double-click it to close.")
                        .font(.system(size: 10.5)).foregroundColor(CP.text2).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)
                }

                CPCard(title: "External Displays", subtitle: "Projectors, monitors and LED walls", icon: "display.2") {
                    HStack {
                        Text("All outputs run at the same time as Record and Stream.")
                            .font(.system(size: 10.5)).foregroundColor(CP.text2)
                        Spacer()
                        CPButton(icon: "arrow.clockwise", title: "Refresh") { refresh() }
                    }
                    .padding(.vertical, 8)
                    CPDivider()
                    if screens.count <= 1 {
                        Text("No additional displays detected. Connect a projector, monitor or LED processor and click Refresh.")
                            .font(.system(size: 11)).foregroundColor(CP.text2).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(screens, id: \.index) { sc in
                        CPRow(icon: "display", label: sc.name + (sc.index == 0 ? " (main)" : ""), showDivider: !engine.activeScreens.contains(sc.index)) {
                            Toggle("", isOn: Binding(
                                get: { engine.activeScreens.contains(sc.index) },
                                set: { _ in engine.toggleScreenOutput(sc.index) }))
                                .toggleStyle(.switch).tint(CP.blue).labelsHidden()
                        }
                        if engine.activeScreens.contains(sc.index) {
                            CPRow(icon: "arrow.turn.down.right", label: "Send") {
                                Picker("", selection: Binding(
                                    get: { engine.screenSource[sc.index] ?? pipNoneTag },
                                    set: { engine.setScreenSource(sc.index, $0 == pipNoneTag ? nil : $0) })) {
                                    Text("Program").tag(pipNoneTag)
                                    ForEach(engine.sources.filter { !$0.isPlaceholder }) { src in Text(src.name).tag(src.id) }
                                }
                                .cpPickerChrome().frame(maxWidth: 170)
                            }
                        }
                    }
                }

                CPCard(title: "NDI Output", subtitle: "Network video", icon: "network") {
                    HStack(spacing: 10) {
                        Image(systemName: ndiAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(ndiAvailable ? DS.ok : DS.amber)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ndiAvailable ? "NDI runtime detected\(ndiVersion.isEmpty ? "" : " — \(ndiVersion)")" : "NDI runtime not found")
                                .font(.system(size: 12)).foregroundColor(CP.text)
                            Text(ndiAvailable ? "Frame sending arrives once the NDI SDK headers are added to the build."
                                              : "Install libNDI for Mac, then click Refresh.")
                                .font(.system(size: 10.5)).foregroundColor(CP.text2)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
            }
            .padding(10)
        }
        .background(CP.bg)
        .onAppear { refresh() }
    }
}

// MARK: - File picker

func pickFile(types: [String], completion: @escaping (URL) -> Void) {
    let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
    panel.allowedContentTypes = types.compactMap { UTType($0) }
    panel.begin { resp in if resp == .OK, let url = panel.url { completion(url) } }
}
