import SwiftUI
import PresentationKit
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
    @EnvironmentObject var automation: AutomationModel
    @EnvironmentObject var backgrounds: BackgroundsModel
    @EnvironmentObject var link: LinkManager
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var dict: DictionaryModel
    @State private var showStream = false
    @State private var dropTargeted = false
    @State private var renameText = ""
    @AppStorage("ui.onAirBar") private var showOnAirBar = true
    var body: some View {
        VStack(spacing: 0) {
            TopBar(showStream: $showStream)
            GeometryReader { outer in
            HSplitView {
                GeometryReader { geo in
                    // Monitors keep 16:9; the lower deck (inputs / songs & Bible / dictionary) fills the rest.
                    let monH = min(geo.size.height * 0.5, geo.size.width * 0.265)
                    VStack(spacing: 0) {
                        if showOnAirBar {
                            OnAirStatusBar()
                                .contextMenu { Button("Hide status bar") { showOnAirBar = false } }
                        }
                        HStack(spacing: 8) {
                            MonitorPane(title: previewName, accent: DS.preview, isProgram: false)
                            TransitionColumn()
                            MonitorPane(title: programName, accent: DS.program, isProgram: true)
                        }
                        .padding(8).frame(height: monH)
                        if engine.busStripMode == 1 || (engine.busStripMode == 0 && present.deck != DeckTab.inputs.rawValue) {
                            SwitcherBusStrip().padding(.horizontal, 8).padding(.bottom, 6)
                        }
                        LowerDeck().frame(maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 440)
                RightPanel()
                    .frame(minWidth: panelMin(outer.size.width), idealWidth: 330, maxWidth: panelMax(outer.size.width))
            }
            }
            StatusBar()
        }
        .background(DS.bg0).preferredColorScheme(.dark)
        .background(WindowChrome())
        .overlay { if dropTargeted { Rectangle().stroke(DS.accent, lineWidth: 3).allowsHitTesting(false) } }
        .overlay(alignment: .topLeading) { HotKeys().frame(width: 0, height: 0) }
        .overlay(alignment: .topTrailing) { LinkToast().animation(.easeInOut(duration: 0.25), value: link.toast?.id) }
        .overlay(alignment: .top) { RecoveryBanner() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .sheet(isPresented: $showStream) { StreamSettingsView() }
        .sheet(isPresented: $backgrounds.showFirstRun) {
            StarterPackSheet().environmentObject(backgrounds)
        }
        .alert("Rename input", isPresented: Binding(get: { engine.renamingSourceID != nil }, set: { if !$0 { engine.renamingSourceID = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let n = renameText.trimmingCharacters(in: .whitespaces)
                if let id = engine.renamingSourceID, !n.isEmpty, let s = engine.sources.first(where: { $0.id == id }) { s.name = n }
                engine.renamingSourceID = nil
            }
            Button("Cancel", role: .cancel) { engine.renamingSourceID = nil }
        } message: {
            Text("The name appears on the input tile, the switcher buttons, the mixer and in presets.")
        }
        .onChange(of: engine.renamingSourceID) { id in
            renameText = id.flatMap { i in engine.sources.first { $0.id == i }?.name } ?? ""
        }
        .sheet(isPresented: $engine.showPreflight) {
            PreflightView().environmentObject(engine).environmentObject(present).environmentObject(link).environmentObject(automation)
        }
        .sheet(isPresented: $engine.showZoom) {
            ZoomSetupView().environmentObject(engine)
        }
        .sheet(isPresented: $engine.showHelp) {
            HelpCenter().environmentObject(engine).environmentObject(present)
        }
        .onAppear { present.engine = engine; dict.engine = engine }
    }
    /// Right panel size: 0 free (drag the divider) · 1 narrow · 2 half · 3 wide
    private func panelMin(_ w: CGFloat) -> CGFloat {
        switch engine.rightPanelSize {
        case 1: return 280
        case 2: return max(280, w * 0.5)
        case 3: return max(280, w - 460)
        default: return 280
        }
    }
    private func panelMax(_ w: CGFloat) -> CGFloat {
        switch engine.rightPanelSize {
        case 1: return 340
        case 2: return max(300, w * 0.5)
        case 3: return max(300, w - 440)
        default: return max(320, w - 440)
        }
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
    @EnvironmentObject var link: LinkManager
    @EnvironmentObject var automation: AutomationModel
    @EnvironmentObject var presets: PresetStore
    @EnvironmentObject var ai: AIModel

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        wire(context.coordinator)
        context.coordinator.install()
        return NSView(frame: .zero)
    }
    func updateNSView(_ nsView: NSView, context: Context) { wire(context.coordinator) }
    private func wire(_ c: Coordinator) {
        c.engine = engine; c.present = present; c.link = link; c.automation = automation; c.presets = presets; c.ai = ai
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator {
        weak var engine: Engine?
        weak var present: PresentModel?
        weak var link: LinkManager?
        weak var automation: AutomationModel?
        weak var presets: PresetStore?
        weak var ai: AIModel?
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
            let responder = window.firstResponder
            let typing = responder is NSText || responder is NSTextView

            // Slide arrows on the Songs & Bible and AI Search tabs (not while typing)
            if !typing, ev.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, let present {
                if present.deck == DeckTab.present.rawValue && !(responder is NSTableView) {
                    if ev.keyCode == 124 { present.step(1); return true }
                    if ev.keyCode == 123 { present.step(-1); return true }
                }
                if present.deck == DeckTab.ai.rawValue, let ai {
                    if ev.keyCode == 124 { ai.step(1); return true }
                    if ev.keyCode == 123 { ai.step(-1); return true }
                }
            }

            guard let key = KeyCombo.keyName(keyCode: ev.keyCode, characters: ev.charactersIgnoringModifiers) else { return false }
            let f = ev.modifierFlags
            let combo = KeyCombo(key, command: f.contains(.command), option: f.contains(.option), control: f.contains(.control), shift: f.contains(.shift))
            if combo.isPlain && typing { return false }
            guard let action = ShortcutCatalog.actionID(for: combo, in: engine.shortcuts) else { return false }
            return ShortcutRunner.run(action, engine: engine, present: present, link: link, automation: automation, presets: presets)
        }
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
            Rectangle().fill(DS.line).frame(width: 1, height: 20)
            PresetsMenu()
            LinkTopBarButton()
            Button { engine.showPreflight = true } label: {
                Label("CHECK", systemImage: "checklist").font(.system(size: 11, weight: .semibold)).foregroundColor(DS.text2)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(DS.bg0))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.line, lineWidth: 1))
            }
            .buttonStyle(.plain).help("Pre-service check: inputs, audio, disk, streaming, permissions (⇧⌘P)")
            Spacer()
            Button { engine.openOutputWindow() } label: {
                Label(engine.programWindowActive ? (engine.programOutFullscreen ? "PROGRAM OUT · FULL" : "PROGRAM OUT · WINDOW") : "PROGRAM OUT",
                      systemImage: engine.programOutFullscreen ? "rectangle.inset.filled" : "macwindow")
            }
            .buttonStyle(.ds(.normal, .regular, active: engine.programWindowActive))
            .help("Opens full screen on a second display, or in a window when there is only one screen. Right-click for choices; ⌘⇧F switches window ↔ full screen; Esc returns to a window.")
            .contextMenu { ProgramOutMenuItems() }
            Button { showStream = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(engine.isStreaming ? Color.white : DS.program).frame(width: 7, height: 7)
                    Text(engine.isStreaming ? "LIVE" : "STREAM")
                }
            }
            .buttonStyle(.ds(.program, .regular, active: engine.isStreaming))
            .contextMenu {
                Button("Stream settings…") { showStream = true }
                Button(engine.isStreaming ? "Stop streaming" : "Go live to enabled destinations") { engine.toggleStream(nil) }
                    .disabled(!engine.isStreaming && engine.liveDestinations.isEmpty)
            }
            Button { engine.toggleRecording() } label: {
                HStack(spacing: 6) {
                    Image(systemName: engine.isRecording ? "stop.fill" : "record.circle")
                    Text(engine.isRecording ? String(format: "REC %02d:%02d:%02d", engine.recordSeconds / 3600, (engine.recordSeconds % 3600) / 60, engine.recordSeconds % 60) : "REC")
                        .font(DS.mono(11, .semibold))
                }
            }
            .buttonStyle(.ds(.program, .regular, active: engine.isRecording))
            .contextMenu {
                Button(engine.isRecording ? "Stop recording" : "Start recording") { engine.toggleRecording() }
                Button("Add chapter marker (M)") { engine.addMarker() }.disabled(!engine.isRecording)
                Toggle("Add a marker at every cut", isOn: $engine.markEveryCut)
                Button("Choose recording folder…") { engine.chooseOutputFolder() }
                Button("Reveal last recording") { engine.revealLastRecording() }
                Button("Snapshot") { engine.snapshot() }
            }
            Spacer()
            SystemStatsView()
            Button { engine.showHelp = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                    Text("Find a tool").font(.system(size: 11))
                    Text("⌘K").font(DS.mono(9)).foregroundColor(DS.text3)
                }
                .foregroundColor(DS.text2)
                .padding(.horizontal, 9).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(DS.bg0))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Search tools and instructions")
            DSIconButton(symbol: "questionmark", help: "Help & user guide") { engine.helpQuery = ""; engine.showHelp = true }
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
                Button("Pre-service check…") { engine.showPreflight = true }
                checkButton("Hear microphones in the Mac's speakers", engine.hearLiveInputs) { engine.hearLiveInputs.toggle() }
                checkButton("Show on-air status bar", UserDefaults.standard.object(forKey: "ui.onAirBar") as? Bool ?? true) {
                    let cur = UserDefaults.standard.object(forKey: "ui.onAirBar") as? Bool ?? true
                    UserDefaults.standard.set(!cur, forKey: "ui.onAirBar")
                }
                Button("Choose recording folder…") { engine.chooseOutputFolder() }
                Button("Reveal last recording") { engine.revealLastRecording() }
            } label: { Image(systemName: "gearshape.fill").foregroundColor(DS.text2) }
            .menuStyle(.borderlessButton).fixedSize().frame(width: 30)
        }
        .padding(.horizontal, 12).frame(height: 46)
        .background(DS.bg2)
        .overlay(Rectangle().fill(DS.line).frame(height: 1), alignment: .bottom)
        .sheet(isPresented: Binding(get: { engine.showHotkeys }, set: { engine.showHotkeys = $0 })) { ShortcutsView().environmentObject(engine) }
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
    @AppStorage("programMonitorMeter") private var showMeter = true
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
                let keys = isProgram ? engine.keyedSources.count : engine.previewKeys.count
                if keys > 0 {
                    Text("KEY \(keys)").font(.system(size: 9, weight: .heavy)).foregroundColor(.black)
                        .padding(.horizontal, 5).frame(height: 16)
                        .background(RoundedRectangle(cornerRadius: 3).fill(DS.amber))
                        .help(isProgram ? "Inputs keyed over Program" : "Inputs keyed over Preview — they go live with the next CUT/AUTO")
                }
                if isProgram {
                    Button { showMeter.toggle() } label: {
                        Image(systemName: showMeter ? "chart.bar.fill" : "chart.bar").font(.system(size: 10)).foregroundColor(showMeter ? DS.text : DS.text3)
                    }
                    .buttonStyle(.plain).help("Show or hide the audio meter on this monitor (never on the output)")
                }
            }
            .padding(.horizontal, 8).frame(height: 28).background(DS.bg2)
            .contextMenu { MonitorMenu(isProgram: isProgram, showMeter: $showMeter) }
            ZStack {
                if isProgram { ProgramMonitorView() } else { PreviewMonitorView() }
                Color.clear.contentShape(Rectangle())
                    .contextMenu { MonitorMenu(isProgram: isProgram, showMeter: $showMeter) }
                if isProgram && showMeter {
                    ProgramMonitorMeter().allowsHitTesting(false)
                }
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

/// Stereo meter drawn over the Program monitor in the app only (not part of the rendered output).
struct ProgramMonitorMeter: View {
    @EnvironmentObject var tele: Telemetry
    var body: some View {
        GeometryReader { g in
            let h = max(40, g.size.height - 24)
            HStack(spacing: 3) {
                VStack(spacing: 2) {
                    ForEach([0, -6, -12, -20, -30, -40, -60], id: \.self) { db in
                        Text("\(db)").font(.system(size: 7, design: .monospaced)).foregroundColor(.white.opacity(0.7))
                            .frame(height: h / 7, alignment: .top)
                    }
                }
                .frame(width: 18)
                VStack(spacing: 2) {
                    VerticalMeter(level: tele.masterL).frame(width: 6, height: h - 12)
                    Text("L").font(.system(size: 7, weight: .bold)).foregroundColor(.white.opacity(0.8))
                }
                VStack(spacing: 2) {
                    VerticalMeter(level: tele.masterR).frame(width: 6, height: h - 12)
                    Text("R").font(.system(size: 7, weight: .bold)).foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.55)))
            .frame(width: g.size.width - 8, height: g.size.height, alignment: .trailing)
            .padding(.vertical, 6)
        }
    }
}

/// Right-click menu for the Preview / Program monitors.
struct MonitorMenu: View {
    @EnvironmentObject var engine: Engine
    let isProgram: Bool
    @Binding var showMeter: Bool
    var body: some View {
        Button("CUT") { engine.cut() }
        Button("AUTO (\(engine.transition.rawValue))") { engine.runTransition() }
        Menu("Transition") {
            ForEach(TransitionType.allCases, id: \.self) { t in
                Button { engine.transition = t } label: {
                    if engine.transition == t { Label(t.rawValue, systemImage: "checkmark") } else { Text(t.rawValue) }
                }
            }
        }
        Button(engine.ftbOn ? "Fade up from black" : "Fade to black") { engine.toggleFTB() }
        Divider()
        let real = engine.sources.filter { !$0.isPlaceholder }
        Menu(isProgram ? "Cut input to Program" : "Put input on Preview") {
            ForEach(real, id: \.id) { s in
                Button(s.name) { engine.setPreview(s.id); if isProgram { engine.cut() } }
            }
        }
        Menu(isProgram ? "Keys over Program" : "Keys over Preview") {
            ForEach(real, id: \.id) { s in
                let on = isProgram ? engine.isKeyed(s.id) : engine.isPreviewKeyed(s.id)
                Button { isProgram ? engine.toggleKey(s.id) : engine.toggleKeyPreview(s.id) } label: {
                    if on { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                }
            }
            Divider()
            Button("Clear all") { if isProgram { engine.clearProgramKeys() } else { engine.previewKeys.removeAll() } }
        }
        if !isProgram {
            Button("Take keys to Program now") { engine.keyedSources.formUnion(engine.previewKeys); engine.previewKeys.removeAll() }
                .disabled(engine.previewKeys.isEmpty)
        }
        if isProgram {
            Menu("Overlays") {
                ForEach(engine.layers) { l in
                    Button { l.isLive.toggle() } label: {
                        if l.isLive { Label(l.name, systemImage: "checkmark") } else { Text(l.name) }
                    }
                }
            }
            if !engine.scenes.isEmpty {
                Menu("Recall scene") { ForEach(engine.scenes) { sc in Button(sc.name) { engine.recallScene(sc) } } }
            }
        }
        Divider()
        if let id = isProgram ? engine.programID : engine.previewID {
            Button("Adjust this input") { engine.selectedSourceID = id; engine.rightTab = 1 }
        }
        if isProgram {
            Toggle("Audio meter on this monitor", isOn: $showMeter)
            Toggle("Safe-area guides", isOn: $engine.showSafeGuides)
            Button("Snapshot") { engine.snapshot() }
            Divider()
            ProgramOutMenuItems()
            Button(engine.isRecording ? "Stop recording" : "Start recording") { engine.toggleRecording() }
        }
    }
}

/// Program Out choices (used in several menus).
struct ProgramOutMenuItems: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        Button(engine.programWindowActive && !engine.programOutFullscreen ? "Program Out: in a window ✓" : "Program Out in a window") {
            engine.showProgramOut(fullscreen: false)
        }
        ForEach(engine.availableScreens(), id: \.index) { sc in
            Button("Program Out full screen on \(sc.name)") { engine.showProgramOut(fullscreen: true, screenIndex: sc.index) }
        }
        if engine.programWindowActive {
            Button(engine.programOutFullscreen ? "Switch Program Out to a window" : "Switch Program Out to full screen") { engine.toggleProgramOutFullscreen() }
            Button("Close Program Out") { engine.closeOutputWindow() }
        }
    }
}

/// Hardware-style PROGRAM and PREVIEW key rows so inputs can be switched from any tab.
struct SwitcherBusStrip: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel

    var body: some View {
        let inputs = Array(engine.sources.enumerated()).filter { !$0.element.isPlaceholder }
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .trailing, spacing: 6) {
                Text("PROGRAM").font(.system(size: 9, weight: .heavy)).kerning(1).foregroundColor(DS.program).frame(height: 30)
                Text("PREVIEW").font(.system(size: 9, weight: .heavy)).kerning(1).foregroundColor(DS.preview).frame(height: 30)
            }
            .frame(width: 58, alignment: .trailing)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(inputs, id: \.element.id) { i, s in
                            Button(label(i, s)) { engine.setPreview(s.id); engine.cut() }
                                .buttonStyle(SwitcherKeyStyle(color: engine.programID == s.id ? SK.red : SK.amber,
                                                              lit: engine.programID == s.id || engine.isKeyed(s.id), minWidth: 62))
                                .frame(height: 30)
                                .help("Cut \(s.name) to Program" + (engine.isKeyed(s.id) ? " (keyed over Program)" : ""))
                                .contextMenu { busMenu(s) }
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(inputs, id: \.element.id) { i, s in
                            Button(label(i, s)) { engine.setPreview(s.id); engine.selectedSourceID = s.id }
                                .buttonStyle(SwitcherKeyStyle(color: engine.previewID == s.id ? SK.green : SK.amber,
                                                              lit: engine.previewID == s.id || engine.isPreviewKeyed(s.id), minWidth: 62))
                                .frame(height: 30)
                                .help("Put \(s.name) on Preview")
                                .contextMenu { busMenu(s) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            VStack(spacing: 6) {
                Button("CUT") { engine.cut() }.buttonStyle(SwitcherKeyStyle(color: SK.white, lit: false, minWidth: 56)).frame(height: 30)
                Button("AUTO") { engine.runTransition() }.buttonStyle(SwitcherKeyStyle(color: SK.red, lit: true, minWidth: 56)).frame(height: 30)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(rgb: 0x151515)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black, lineWidth: 1))
        .contextMenu {
            Button("Show only when the Inputs tab is hidden") { engine.busStripMode = 0 }
            Button("Always show") { engine.busStripMode = 1 }
            Button("Hide switcher buttons") { engine.busStripMode = 2 }
        }
    }

    private func label(_ i: Int, _ s: Source) -> String {
        let n = s.name.uppercased()
        let short = n.count > 9 ? String(n.prefix(8)) + "…" : n
        return "\(i + 1) \(short)"
    }

    @ViewBuilder private func busMenu(_ s: Source) -> some View {
        Button("Cut to Program") { engine.setPreview(s.id); engine.cut() }
        Button("Put on Preview") { engine.setPreview(s.id) }
        Divider()
        Button(engine.isPreviewKeyed(s.id) ? "Remove key from Preview" : "Key over Preview") { engine.toggleKeyPreview(s.id) }
        Button(engine.isKeyed(s.id) ? "Remove key from Program" : "Key over Program") { engine.toggleKey(s.id) }
        Divider()
        Button("Adjust input") { engine.selectedSourceID = s.id; engine.rightTab = 1 }
        Divider()
        Button("Hide switcher buttons") { engine.busStripMode = 2 }
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
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Text("DURATION").font(.system(size: 8, weight: .bold)).foregroundColor(DS.text3)
                        .lineLimit(1).minimumScaleFactor(0.7).fixedSize()
                    Spacer(minLength: 0)
                    CPValueField(value: $engine.transitionDuration, range: 0.1...5.0, format: "%.1fs")
                        .contextMenu {
                            ForEach([0.3, 0.5, 0.6, 1.0, 1.5, 2.0], id: \.self) { d in Button(String(format: "%.1f s", d)) { engine.transitionDuration = d } }
                        }
                }
                CPFader(value: $engine.transitionDuration, range: 0.1...3.0)
                    .onTapGesture(count: 2) { engine.transitionDuration = 0.6 }
            }
            .help("Transition duration — type a value, drag, double-click the slider for 0.6 s, or right-click for presets")
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
        .contextMenu {
            Button("CUT") { engine.cut() }
            Button("AUTO") { engine.runTransition() }
            Divider()
            ForEach(TransitionType.allCases, id: \.self) { t in
                Button { engine.transition = t } label: {
                    if engine.transition == t { Label(t.rawValue, systemImage: "checkmark") } else { Text(t.rawValue) }
                }
            }
            Menu("Duration") {
                ForEach([0.3, 0.6, 1.0, 1.5, 2.0], id: \.self) { d in
                    Button(String(format: "%.1f s", d)) { engine.transitionDuration = d }
                }
            }
            Divider()
            Button(engine.ftbOn ? "Fade up from black" : "Fade to black") { engine.toggleFTB() }
        }
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
                    DSTabItem(id: DeckTab.dictionary.rawValue, title: "Dictionary", icon: "character.book.closed"),
                    DSTabItem(id: DeckTab.ai.rawValue, title: "AI Search", icon: "sparkle.magnifyingglass"),
                    DSTabItem(id: DeckTab.images.rawValue, title: "Media", icon: "photo.on.rectangle.angled"),
                    DSTabItem(id: DeckTab.audio.rawValue, title: "Audio Mixer", icon: "slider.vertical.3"),
                    DSTabItem(id: DeckTab.automation.rawValue, title: "Automation", icon: "timer")
                ])
                .frame(minWidth: 300, maxWidth: 880)
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
            else if present.deck == DeckTab.images.rawValue { MediaDeck() }
            else if present.deck == DeckTab.audio.rawValue { MixerConsole() }
            else if present.deck == DeckTab.automation.rawValue { AutomationDeck() }
            else if present.deck == DeckTab.ai.rawValue { AIDeck() }
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
    @EnvironmentObject var ai: AIModel
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var link: LinkManager
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var dict: DictionaryModel
    @EnvironmentObject var gen: GeneratorModel
    var index: Int
    @ObservedObject var source: Source
    var tileW: CGFloat = 176
    var screenH: CGFloat? = nil
    var isProgram: Bool { engine.programID == source.id }
    var isPreview: Bool { engine.previewID == source.id }
    var isKeyed: Bool { engine.isKeyed(source.id) }
    var isPreviewKeyed: Bool { engine.isPreviewKeyed(source.id) }
    var tally: Color { isProgram ? DS.program : (isPreview ? DS.preview : (isKeyed || isPreviewKeyed ? DS.amber : DS.line)) }
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
                    .onTapGesture(count: 2) { if !source.isPlaceholder { engine.renamingSourceID = source.id } }
                    .help(source.isPlaceholder ? "" : "Double-click to rename")
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
                ViewThatFits(in: .horizontal) {
                    footer(keys: true, transport: true)
                    footer(keys: false, transport: true)
                    footer(keys: false, transport: false)
                }
                .frame(width: tileW, height: 40).background(DS.bg2)
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
                Button("Rename…") { engine.renamingSourceID = source.id }
                Button("Take to Program") { engine.setPreview(source.id); engine.cut() }
                Button("Set as Preview") { select() }
                Divider()
                Button(isPreviewKeyed ? "Remove key from Preview" : "Key over Preview") { engine.toggleKeyPreview(source.id) }
                Button(isKeyed ? "Remove key from Program" : "Key over Program") { engine.toggleKey(source.id) }
                if source is SlideSource || source is GeneratorSource {
                    Button("Open controls") { openController() }
                }
                Divider()
                Button(source.muted ? "Unmute" : "Mute") { source.muted.toggle() }
                Button(source.solo ? "Unsolo" : "Solo (headphones)") { source.solo.toggle() }
                Button("Audio in mixer") { select(); present.deck = DeckTab.audio.rawValue }
                if let path = source.originLocation, !(source is CameraSource), FileManager.default.fileExists(atPath: path) {
                    Divider()
                    LinkSendMenu(title: "Send file to computer") { pid in link.offerFile(URL(fileURLWithPath: path), title: source.name, to: pid) }
                    LinkSendMenu(title: "Send to computer as an input") { pid in link.offerFile(URL(fileURLWithPath: path), title: source.name, to: pid, addAsInput: true) }
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
    /// Tile control strip; ViewThatFits drops the less important parts on narrow tiles, but the
    /// edit (controls) button and the ⋯ menu are always kept.
    private func footer(keys: Bool, transport: Bool) -> some View {
        HStack(spacing: 6) {
            Button("PVW") { select() }.buttonStyle(SwitcherKeyStyle(color: SK.green, lit: isPreview, minWidth: 36))
            Button("PGM") { engine.setPreview(source.id); engine.cut() }.buttonStyle(SwitcherKeyStyle(color: SK.red, lit: isProgram, minWidth: 36))
            if transport {
                if let f = source as? FileSource { TileTransport(source: f) }
                else if let a = source as? AudioFileSource { TileTransport(source: a) }
                else if let pl = source as? PlaylistSource { PlaylistTransport(source: pl) }
            }
            if keys && !(source is AudioFileSource) {
                HStack(spacing: 5) {
                    Button("K·P") { engine.toggleKeyPreview(source.id) }
                        .buttonStyle(SwitcherKeyStyle(color: SK.amber, lit: isPreviewKeyed, minWidth: 34))
                        .help("Key over PREVIEW (goes on air with the next CUT/AUTO)")
                    Button("K·L") { engine.toggleKey(source.id) }
                        .buttonStyle(SwitcherKeyStyle(color: SK.amber, lit: isKeyed, minWidth: 34))
                        .help("Key over PROGRAM (live)")
                }
            }
            Spacer(minLength: 0)
            Button { openController() } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundColor(DS.text2).help("Edit this input")
            if !keys || !transport {
                Menu {
                    if !transport, let f = source as? FileSource { Button(f.paused ? "Play" : "Pause") { f.togglePlay() }; Button("Restart") { f.restart() } }
                    if !transport, let a = source as? AudioFileSource { Button(a.paused ? "Play" : "Pause") { a.togglePlay() }; Button("Restart") { a.restart() } }
                    if !transport, let pl = source as? PlaylistSource { Button(pl.playing ? "Pause" : "Play") { pl.togglePlay() }; Button("Next item") { pl.next() } }
                    Button(isPreviewKeyed ? "Remove key from Preview" : "Key over Preview") { engine.toggleKeyPreview(source.id) }
                    Button(isKeyed ? "Remove key from Program" : "Key over Program") { engine.toggleKey(source.id) }
                    Divider()
                    Button(source.muted ? "Unmute" : "Mute") { source.muted.toggle() }
                    Button("Edit input") { openController() }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 12)) }
                .menuStyle(.borderlessButton).fixedSize().frame(width: 22)
            }
            Button { source.muted.toggle() } label: {
                Image(systemName: source.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 12))
                    .foregroundColor(source.muted ? DS.program : DS.text2)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 6).frame(height: 40)
    }

    private func openController() {
        if let g = source as? GeneratorSource {
            gen.liveUpdate = false; gen.targetID = g.id; gen.settings = g.settings; gen.liveUpdate = true
            present.mediaSection = 2; present.deck = DeckTab.images.rawValue
        }
        else if source is DictionarySource { dict.targetID = source.id; present.deck = DeckTab.dictionary.rawValue }
        else if source is AISource { ai.targetID = source.id; present.deck = DeckTab.ai.rawValue }
        else if source is PresentationSource { present.targetID = source.id; present.deck = DeckTab.present.rawValue }
        else { engine.selectedSourceID = source.id; engine.rightTab = 1 }
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
        Button("Zoom Meeting / App Window…") { engine.showZoom = true }
        Button("Playlist (videos, audio, images)") {
            let p = PlaylistSource(); engine.placeInput(p); engine.selectedSourceID = p.id; engine.rightTab = 1
        }
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
                    let cols = 3
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
        CPInspector {
            CPCard(title: "Program layout", subtitle: engine.programLayout.label, icon: "rectangle.split.2x2") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                    ForEach(ProgramLayout.allCases) { l in
                        Button { engine.setLayout(l) } label: {
                            LayoutThumb(layout: l)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(engine.programLayout == l ? CP.blue : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain).help(l.label)
                        .contextMenu {
                            Button("Use \(l.label)") { engine.setLayout(l) }
                            Button("Use and save as scene") { engine.setLayout(l); engine.saveScene(l.label) }
                        }
                    }
                }
                .padding(.vertical, 6)
                if engine.programLayout == .grid {
                    CPRow(label: "Cells") {
                        Stepper("\(engine.gridCount)", value: Binding(get: { engine.gridCount }, set: { engine.gridCount = max(2, min(10, $0)) }), in: 2...10)
                            .font(.system(size: 11.5)).foregroundColor(CP.text)
                    }
                }
            }
            if engine.programLayout != .single {
                CPCard(title: "Slots", subtitle: "\(engine.slotCount(engine.programLayout)) inputs", icon: "square.grid.2x2") {
                    ForEach(Array(0..<engine.slotCount(engine.programLayout)), id: \.self) { i in
                        CPRow(label: "Slot \(i + 1)", showDivider: i < engine.slotCount(engine.programLayout) - 1) {
                            Picker("", selection: Binding(
                                get: { (engine.layoutSlots.indices.contains(i) ? engine.layoutSlots[i] : nil) ?? pipNoneTag },
                                set: { engine.setSlot(i, $0 == pipNoneTag ? nil : $0) })) {
                                Text("— none —").tag(pipNoneTag)
                                ForEach(engine.sources.filter { !$0.isPlaceholder }) { s in Text(s.name).tag(s.id) }
                            }
                            .cpPickerChrome().frame(maxWidth: 180)
                        }
                    }
                }
            }
            CPCard(title: "Scenes", subtitle: engine.scenes.isEmpty ? "None saved" : "\(engine.scenes.count) saved", icon: "rectangle.stack") {
                HStack(spacing: 6) {
                    TextField("Scene name", text: $sceneName).dsField().onSubmit { engine.saveScene(sceneName); sceneName = "" }
                    CPButton(icon: "plus", title: "Save", prominent: true) { engine.saveScene(sceneName); sceneName = "" }
                }
                .padding(.vertical, 6)
                if engine.scenes.isEmpty {
                    CPNote("Arrange a layout and its slots, then save it as a scene to recall later.")
                }
                ForEach(engine.scenes) { sc in
                    CPDivider()
                    HStack(spacing: 8) {
                        LayoutThumb(layout: sc.layout)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(sc.name).font(.system(size: 11.5, weight: .medium)).foregroundColor(CP.text).lineLimit(1)
                            Text(sc.layout.label).font(.system(size: 9)).foregroundColor(CP.text2)
                        }
                        Spacer()
                        CPButton(title: "Recall") { engine.recallScene(sc) }
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { engine.recallScene(sc) }
                    .contextMenu {
                        Button("Recall") { engine.recallScene(sc) }
                        Button("Update with current layout") {
                            if let k = engine.scenes.firstIndex(where: { $0.id == sc.id }) {
                                engine.scenes[k].layout = engine.programLayout
                                engine.scenes[k].slots = engine.layoutSlots
                                engine.scenes[k].gridCount = engine.gridCount
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { engine.deleteScene(sc.id) }
                    }
                }
                CPNote("Recalling a scene switches the Program to that layout. Choose Single to return to normal switching.")
            }
        }
    }
}

struct RightPanel: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var link: LinkManager
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("PANEL").font(.system(size: 8, weight: .bold)).kerning(1).foregroundColor(CP.text2)
                Spacer()
                sizeButton("sidebar.right", 1, "Narrow panel")
                sizeButton("rectangle.split.2x1", 2, "Half the window")
                sizeButton("rectangle.righthalf.inset.filled", 3, "Wide — panel fills most of the window")
                sizeButton("arrow.left.and.right", 0, "Free — drag the divider to any width")
            }
            .padding(.horizontal, 12).padding(.top, 6)
            CPTabBar(selection: $engine.rightTab, items: [
                DSTabItem(id: 1, title: "Input", icon: "rectangle.and.hand.point.up.left"),
                DSTabItem(id: 0, title: "Audio", icon: "slider.vertical.3"),
                DSTabItem(id: 2, title: "Overlays", icon: "square.stack.3d.up"),
                DSTabItem(id: 3, title: "Scenes", icon: "rectangle.split.2x2"),
                DSTabItem(id: 4, title: "Outputs", icon: "display"),
                DSTabItem(id: 5, title: "Presets", icon: "tray.full"),
                DSTabItem(id: 6, title: link.unread > 0 ? "Network •\(link.unread)" : "Network", icon: "network")
            ])
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
            Group {
                if engine.rightTab == 0 { AudioMixerPanel() }
                else if engine.rightTab == 1 { InputSettingsPanel() }
                else if engine.rightTab == 2 { OverlaysPanel() }
                else if engine.rightTab == 3 { ScenesPanel() }
                else if engine.rightTab == 5 { PresetsPanel() }
                else if engine.rightTab == 6 { NetworkPanel() }
                else { OutputsPanel() }
            }
            .frame(maxHeight: .infinity)
        }
        .background(CP.bg).overlay(Rectangle().frame(width: 1).foregroundColor(DS.line), alignment: .leading)
        .contextMenu {
            Button("Narrow panel") { engine.rightPanelSize = 1 }
            Button("Half the window") { engine.rightPanelSize = 2 }
            Button("Wide panel") { engine.rightPanelSize = 3 }
            Button("Free size (drag the divider)") { engine.rightPanelSize = 0 }
        }
    }

    private func sizeButton(_ icon: String, _ mode: Int, _ help: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { engine.rightPanelSize = mode } } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .medium))
                .foregroundColor(engine.rightPanelSize == mode ? .white : CP.text2)
                .frame(width: 26, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(engine.rightPanelSize == mode ? CP.blue : CP.field))
        }
        .buttonStyle(.plain).help(help)
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
                    if let pl = s as? PlaylistSource { PlaylistEditorCard(source: pl).id("pl-" + s.id.uuidString) }
                    CaptureStatusCard(source: s)
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

            CompactChannelConsole(source: source, audioDevices: $audioDevices)
            CompactEffectsConsole(source: source)
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
                Text("Effects change what you hear, record and stream.")
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
    var body: some View { MixerConsole() }
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
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var auto: AutomationModel
    var body: some View {
        CPInspector {
            CPCard(title: "Overlay layers", subtitle: "\(engine.layers.count) layer\(engine.layers.count == 1 ? "" : "s") · \(engine.layers.filter { $0.isLive }.count) on air", icon: "square.stack.3d.up.fill") {
                HStack(spacing: 6) {
                    Menu {
                        Menu("Templates") {
                            ForEach(OverlayTemplate.all) { t in
                                Button { engine.addLayerTemplate(t) } label: { Label(t.name, systemImage: t.icon) }
                            }
                        }
                        Divider()
                        ForEach(Layer.Kind.allCases) { k in Button { engine.addLayer(k) } label: { Label(k.rawValue, systemImage: k.icon) } }
                    } label: { Label("Add layer", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    CPButton(icon: "eye.slash", title: "Hide all") { engine.layers.forEach { $0.isLive = false } }
                }
                .padding(.vertical, 6)
                if engine.layers.isEmpty {
                    CPNote("No overlays yet. Add a lower third, logo, ticker, clock, scoreboard, QR code or picture-in-picture.")
                }
                ForEach(engine.layers) { l in
                    CPDivider()
                    LayerRow(layer: l)
                }
            }
            if let sel = engine.layers.first(where: { $0.id == engine.selectedLayerID }) {
                LayerInspector(layer: sel)
            } else if !engine.layers.isEmpty {
                CPNote("Select a layer to edit it.")
            }
        }
    }
}

struct LayerRow: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var auto: AutomationModel
    @ObservedObject var layer: Layer
    var body: some View {
        let selected = engine.selectedLayerID == layer.id
        HStack(spacing: 8) {
            Image(systemName: layer.kind.icon).font(.system(size: 12)).foregroundColor(selected ? CP.icon : CP.text2).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(layer.name).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).foregroundColor(CP.text).lineLimit(1)
                Text(layer.kind.rawValue).font(.system(size: 9)).foregroundColor(CP.text2)
            }
            Spacer()
            if let idx = engine.layers.firstIndex(where: { $0.id == layer.id }), idx < 4 {
                Text("\(idx + 1)").font(.system(size: 9, weight: .bold)).foregroundColor(CP.text2)
                    .frame(width: 16, height: 16).background(RoundedRectangle(cornerRadius: 4).fill(CP.field))
                    .help("Overlay channel \(idx + 1) in the status bar")
            }
            Toggle("", isOn: $layer.isLive).toggleStyle(.switch).tint(DS.program).labelsHidden().controlSize(.mini)
        }
        .padding(.vertical, 5).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? CP.blueSoft : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { engine.selectedLayerID = layer.id }
        .contextMenu {
            Button(layer.isLive ? "Hide (take off air)" : "Show (put on air)") { layer.isLive.toggle() }
            Button("Edit") { engine.selectedLayerID = layer.id }
            Divider()
            Button("Move up") { engine.moveLayer(layer.id, by: -1) }
            Button("Move down") { engine.moveLayer(layer.id, by: 1) }
            Divider()
            Button("Automate this overlay…") {
                auto.add(0)
                if let i = auto.selectedIndex {
                    auto.rules[i].name = "Show \(layer.name)"
                    auto.rules[i].target = .overlay
                    auto.rules[i].targetID = layer.id.uuidString
                }
                present.deck = DeckTab.automation.rawValue
            }
            Divider()
            Button("Delete", role: .destructive) { engine.removeLayer(layer.id) }
        }
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
                    .help(engine.layers.indices.contains(i) ? "Overlay \(i + 1): \(engine.layers[i].name)" : "Overlay channel \(i + 1) (empty)")
                    .contextMenu {
                        if engine.layers.indices.contains(i) {
                            let l = engine.layers[i]
                            Button(l.isLive ? "Hide \(l.name)" : "Show \(l.name)") { engine.toggleOverlay(i) }
                            Button("Edit \(l.name)") { engine.selectedLayerID = l.id; engine.rightTab = 2 }
                        }
                        Button("Add overlay…") { engine.rightTab = 2 }
                    }
            }
            Rectangle().fill(DS.line).frame(width: 1, height: 16)
            if engine.isRecording {
                Button { engine.addMarker() } label: { Label("MARK \(max(0, engine.markers.count - 1))", systemImage: "bookmark.fill") }
                    .buttonStyle(.ds(.program, .small))
                    .help("Add a chapter marker (M). Markers are saved next to the recording as a chapters file for YouTube.")
                    .contextMenu {
                        ForEach(engine.markers.suffix(12)) { m in Text("\(engine.markerTime(m.seconds))  \(m.label)") }
                        Divider()
                        Toggle("Add a marker at every cut", isOn: $engine.markEveryCut)
                    }
            }
            Button("Snapshot") { engine.snapshot() }.buttonStyle(.ds(.normal, .small))
                .contextMenu {
                    Button("Take snapshot") { engine.snapshot() }
                    Button("Choose folder…") { engine.chooseOutputFolder() }
                }
            Button("Outputs") { engine.rightTab = 4 }.buttonStyle(.ds(.normal, .small, active: !engine.activeScreens.isEmpty))
                .contextMenu { ProgramOutMenuItems() }
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
        CPColorRow(label: "Accent", color: $layer.accent)
        CPColorRow(label: "Text colour", color: $layer.textColor)
        CPColorRow(label: "Background", color: $layer.bgColor)
        adjSlider("BG opacity", $layer.bgOpacity, 0...1)
        adjSlider("Font size", $layer.fontScale, 0.6...2.0)
    }
}

private struct CPPickerRow<Sel: Hashable, Items: View>: View {
    let label: String
    @Binding var selection: Sel
    @ViewBuilder var items: () -> Items
    var body: some View {
        CPRow(label: label) {
            Picker("", selection: $selection) { items() }.cpPickerChrome().frame(maxWidth: 170)
        }
    }
}

struct LayerInspector: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var layer: Layer
    var body: some View {
        VStack(spacing: 8) {
            CPCard(title: layer.name.isEmpty ? layer.kind.rawValue : layer.name, subtitle: layer.kind.rawValue + (layer.isLive ? " · ON AIR" : ""),
                   icon: layer.kind.icon, iconColor: layer.isLive ? DS.program : CP.icon) {
                CPTextRow(label: "Name", text: $layer.name)
                CPToggleRow(label: "On air", isOn: $layer.isLive)
            }
            CPCard(title: "Content", icon: "text.alignleft") { content.padding(.vertical, 2) }
            CPCard(title: "Variants", subtitle: layer.variants.isEmpty ? "Saved states" : "\(layer.variants.count) saved", icon: "square.on.square") {
                VariantsView(layer: layer)
            }
            CPCard(title: "Transform", icon: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", onReset: { layer.resetTransform() }) {
                LayerTransformView(layer: layer)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch layer.kind {
        case .lowerThird:
            CPTextRow(label: "Name line", text: $layer.text1)
            CPTextRow(label: "Title line", text: $layer.text2)
            CPPickerRow(label: "Style", selection: $layer.style) {
                Text("Accent strip").tag(0); Text("Boxed").tag(1); Text("Minimal").tag(2)
                Text("Two-tone").tag(3); Text("Tab header").tag(4); Text("Outline").tag(5); Text("Pill").tag(6)
            }
            CPPickerRow(label: "Align", selection: $layer.align) { Text("Left").tag(0); Text("Centre").tag(1); Text("Right").tag(2) }
            OverlayStyleControls(layer: layer)
        case .ticker:
            CPTextRow(label: "Ticker text", text: $layer.text1)
            adjSlider("Speed", $layer.number1, 20...300)
        case .countdown:
            CPTextRow(label: "Label", text: $layer.text1)
            adjSlider("Minutes", $layer.number1, 1...180)
            HStack(spacing: 6) {
                CPButton(icon: "play.fill", title: "Start", prominent: true) { if layer.remaining <= 0 { layer.remaining = layer.number1 * 60 }; layer.lastTick = 0; layer.isRunning = true }
                CPButton(icon: "pause.fill", title: "Pause") { layer.isRunning = false }
                CPButton(icon: "arrow.counterclockwise", title: "Reset") { layer.isRunning = false; layer.remaining = layer.number1 * 60 }
            }
            .padding(.vertical, 4)
            CPColorRow(label: "Accent", color: $layer.accent)
        case .clock:
            CPToggleRow(label: "24-hour", isOn: $layer.use24h)
        case .scoreboard:
            CPTextRow(label: "Team A", text: $layer.text1)
            CPTextRow(label: "Team B", text: $layer.text2)
            CPColorRow(label: "Team A colour", color: $layer.accent)
            HStack(spacing: 6) {
                CPButton(title: "A +1") { layer.scoreA += 1 }; CPButton(title: "A −1") { layer.scoreA = max(0, layer.scoreA - 1) }
                CPButton(title: "B +1") { layer.scoreB += 1 }; CPButton(title: "B −1") { layer.scoreB = max(0, layer.scoreB - 1) }
            }
            .padding(.vertical, 4)
        case .title:
            CPTextRow(label: "Title", text: $layer.text1)
            CPTextRow(label: "Subtitle", text: $layer.text2, prompt: "optional")
            CPPickerRow(label: "Align", selection: $layer.align) { Text("Left").tag(0); Text("Centre").tag(1); Text("Right").tag(2) }
            adjSlider("Size", $layer.number1, 3...20)
            CPColorRow(label: "Title colour", color: $layer.accent)
            CPColorRow(label: "Subtitle colour", color: $layer.textColor)
            CPToggleRow(label: "Background box", isOn: Binding(get: { layer.bgOpacity > 0.01 }, set: { layer.bgOpacity = $0 ? 0.65 : 0 }))
            if layer.bgOpacity > 0.01 {
                CPColorRow(label: "Box colour", color: $layer.bgColor)
                adjSlider("Box opacity", $layer.bgOpacity, 0.05...1)
            }
        case .logo:
            CPRow(label: "Image") {
                CPButton(icon: "photo", title: "Choose…") {
                    pickFile(types: ["public.image"]) { url in
                        if let nsimg = NSImage(contentsOf: url) {
                            var rect = CGRect(origin: .zero, size: nsimg.size)
                            layer.logoImage = nsimg.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                        }
                    }
                }
            }
            CPPickerRow(label: "Position", selection: $layer.position) { Text("Top left").tag(0); Text("Top right").tag(1); Text("Bottom left").tag(2); Text("Bottom right").tag(3) }
            adjSlider("Scale", $layer.number1, 4...50)
        case .qrcode:
            CPTextRow(label: "URL", text: $layer.text1, prompt: "https://")
            adjSlider("Size", $layer.number1, 80...360)
        case .pip:
            CPPickerRow(label: "Source", selection: Binding(get: { layer.sourceRef ?? pipNoneTag }, set: { layer.sourceRef = ($0 == pipNoneTag ? nil : $0) })) {
                Text("— none —").tag(pipNoneTag)
                ForEach(engine.sources.filter { !$0.isPlaceholder }) { s in Text(s.name).tag(s.id) }
            }
            CPPickerRow(label: "Corner", selection: $layer.position) { Text("Top left").tag(0); Text("Top right").tag(1); Text("Bottom left").tag(2); Text("Bottom right").tag(3) }
            adjSlider("Size", $layer.number1, 8...100)
            CPColorRow(label: "Border", color: $layer.accent)
            SectionLabel("Chroma key")
            CPToggleRow(label: "Enable chroma key", isOn: $layer.keyEnabled)
            if layer.keyEnabled {
                CPColorRow(label: "Key colour", color: $layer.keyColor)
                adjSlider("Similarity", $layer.keySimilarity, 0.02...0.5)
                adjSlider("Smoothness", $layer.keySmoothness, 0.005...0.3)
                CPNote("Tip: set Size ≈ 100 to place keyed talent over the whole Program.")
            }
        case .definition:
            CPTextRow(label: "Word", text: $layer.text1)
            TextField("Definition", text: $layer.text2, axis: .vertical).lineLimit(2...6)
                .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundColor(CP.text)
                .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(CP.field))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CP.border, lineWidth: 1))
                .padding(.vertical, 4)
            adjSlider("Panel height", $layer.number1, 4...12)
            CPColorRow(label: "Word colour", color: $layer.accent)
            CPColorRow(label: "Panel colour", color: $layer.bgColor)
            adjSlider("Panel opacity", $layer.bgOpacity, 0.3...1)
            CPNote("Tip: the Dictionary tab fills this automatically.")
        }
    }
}

struct VariantsView: View {
    @ObservedObject var layer: Layer
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CPButton(icon: "plus", title: "Save current") { layer.captureVariant() }
                Spacer()
                CPButton(icon: "chevron.left", title: "") { layer.cycleVariant(-1) }
                CPButton(icon: "chevron.right", title: "") { layer.cycleVariant(1) }
            }
            if layer.variants.isEmpty {
                CPNote("Save reusable states (e.g. each speaker's name) and switch between them live.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(layer.variants.enumerated()), id: \.element.id) { idx, v in
                            Button { layer.applyVariant(idx) } label: {
                                Text(v.text1.isEmpty ? v.name : v.text1).font(.system(size: 10.5)).lineLimit(1)
                                    .foregroundColor(CP.text)
                                    .padding(.horizontal, 8).frame(height: 24)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(layer.activeVariant == idx ? CP.blueSoft : CP.field))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(layer.activeVariant == idx ? CP.blue : CP.border, lineWidth: 1))
                            }.buttonStyle(.plain)
                            .contextMenu {
                                Button("Apply") { layer.applyVariant(idx) }
                                Button("Delete", role: .destructive) { if layer.variants.indices.contains(idx) { layer.variants.remove(at: idx) } }
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct LayerTransformView: View {
    @ObservedObject var layer: Layer
    var body: some View {
        adjSlider("Opacity", $layer.opacity, 0...1, 1)
        adjSlider("Position X", $layer.offsetX, -0.5...0.5)
        adjSlider("Position Y", $layer.offsetY, -0.5...0.5)
        adjSlider("Scale", $layer.scaleAdj, 0.2...3, 1)
        adjSlider("Rotate", $layer.rotationAdj, -180...180)
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
        return "Audio: the Program mix from the Audio Mixer — video/audio files and microphones with their faders, ON/AFV, mute, pan, effects and the Master fader (stereo)."
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 14, weight: .semibold)).foregroundColor(DS.program)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Stream").font(.system(size: 13, weight: .semibold)).foregroundColor(CP.text)
                    Text(engine.isStreaming ? "LIVE to \(engine.liveDestinations.count) destination(s)" : "Destinations and quality")
                        .font(.system(size: 10)).foregroundColor(engine.isStreaming ? DS.program : CP.text2)
                }
                Spacer()
                CPButton(icon: "plus", title: "Add destination") { engine.addStreamDestination() }
                CPButton(title: "Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12).frame(height: 48).background(CP.cardHeader)

            CPInspector {
                if engine.streamDestinations.isEmpty {
                    CPNote("No destinations yet. Add one and choose YouTube, Facebook Live, Twitch or a custom RTMP/RTMPS/SRT server.")
                }
                ForEach($engine.streamDestinations) { $d in StreamRow(dest: $d) }
                CPCard(title: "Quality & audio", icon: "slider.horizontal.3") {
                    CPToggleRow(label: "Send program audio", isOn: $engine.streamAudio, showDivider: true)
                        .disabled(engine.isStreaming)
                    CPRow(label: "Video bitrate", showDivider: false) {
                        Picker("", selection: $engine.streamBitrateKbps) {
                            ForEach(Engine.streamBitrates, id: \.self) { b in Text(String(format: "%.1f Mbps", Double(b) / 1000)).tag(b) }
                        }
                        .cpPickerChrome().frame(maxWidth: 150).disabled(engine.isStreaming)
                    }
                    CPNote(streamAudioNote)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: engine.ffmpegAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(engine.ffmpegAvailable ? DS.ok : DS.amber)
                    Text(engine.ffmpegAvailable ? liveSummary : "ffmpeg not found. Install it once (Terminal: brew install ffmpeg), then reopen.")
                        .font(.system(size: 11)).foregroundColor(CP.text)
                    Spacer()
                    if engine.isStreaming {
                        HStack(spacing: 4) {
                            Circle().fill(DS.program).frame(width: 7, height: 7)
                            Text("LIVE").font(.system(size: 10, weight: .heavy)).foregroundColor(DS.program)
                        }
                    }
                    Button(engine.isStreaming ? "Stop streaming" : "Go live") { engine.toggleStream(nil) }
                        .buttonStyle(.ds(.program, .regular, active: engine.isStreaming))
                        .disabled(!engine.ffmpegAvailable || (!engine.isStreaming && engine.liveDestinations.isEmpty))
                }
                if !engine.streamError.isEmpty {
                    Text(engine.streamError).font(.system(size: 10)).foregroundColor(DS.amber).textSelection(.enabled).lineLimit(6)
                }
                Text("Go live sends Program to every enabled destination at once. RTMP/RTMPS use FLV; SRT uses MPEG-TS. Resolution and frame rate are locked while live.")
                    .font(.system(size: 9.5)).foregroundColor(CP.text2)
            }
            .padding(12).background(CP.card)
        }
        .frame(width: 560, height: 620)
        .background(CP.bg)
        .preferredColorScheme(.dark)
    }
}

struct StreamRow: View {
    @EnvironmentObject var engine: Engine
    @Binding var dest: StreamDestination
    var body: some View {
        CPCard(title: dest.name.isEmpty ? "Destination" : dest.name, subtitle: dest.enabled ? "\(dest.platform) · enabled" : "\(dest.platform) · off",
               icon: "antenna.radiowaves.left.and.right", iconColor: dest.enabled ? DS.program : CP.text2) {
            CPToggleRow(label: "Enabled", isOn: $dest.enabled, showDivider: true)
            CPTextRow(label: "Name", text: $dest.name, showDivider: true)
            CPRow(label: "Platform") {
                Picker("", selection: $dest.platform) {
                    ForEach(StreamDestination.platforms, id: \.self) { Text($0).tag($0) }
                }
                .cpPickerChrome().frame(maxWidth: 170)
                .onChange(of: dest.platform) { newValue in
                    let p = StreamDestination.preset(for: newValue)
                    dest.proto = p.proto
                    if !p.url.isEmpty { dest.url = p.url }
                }
            }
            CPRow(label: "Protocol") {
                Picker("", selection: $dest.proto) {
                    ForEach(StreamDestination.protocols, id: \.self) { Text($0).tag($0) }
                }
                .cpPickerChrome().frame(maxWidth: 170)
            }
            CPTextRow(label: "Server URL", text: $dest.url, prompt: "rtmp://…", showDivider: true)
            CPTextRow(label: "Stream key", text: $dest.key, secure: true)
            HStack {
                Text(dest.composedURL).font(.system(size: 9, design: .monospaced)).foregroundColor(CP.text2).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { engine.removeStreamDestination(dest.id) } label: { Label("Remove", systemImage: "trash") }
                    .buttonStyle(.ds(.danger, .small))
            }
            .padding(.vertical, 6)
        }
        .contextMenu {
            Button(dest.enabled ? "Disable" : "Enable") { dest.enabled.toggle() }
            Button("Go live to this destination only") { engine.toggleStream(dest) }.disabled(engine.isStreaming)
            Divider()
            Button("Remove", role: .destructive) { engine.removeStreamDestination(dest.id) }
        }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: mode == 4 ? "globe" : "antenna.radiowaves.left.and.right").font(.system(size: 14, weight: .semibold)).foregroundColor(CP.icon)
                Text(title.capitalized).font(.system(size: 13, weight: .semibold)).foregroundColor(CP.text)
            }

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
        .padding(16).frame(width: 560, height: mode == 3 ? 340 : 300)
        .background(CP.bg)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .preferredColorScheme(.dark)
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
                CPCard(title: "Program Out", subtitle: engine.programWindowActive ? (engine.programOutFullscreen ? "Full screen" : "In a window") : "Off",
                       icon: "rectangle.inset.filled", iconColor: engine.programWindowActive ? DS.program : CP.icon) {
                    CPRow(icon: "power", label: "Program Out") {
                        Toggle("", isOn: Binding(get: { engine.programWindowActive }, set: { _ in engine.openOutputWindow() }))
                            .toggleStyle(.switch).tint(CP.blue).labelsHidden()
                    }
                    CPRow(icon: "macwindow", label: "Mode") {
                        DSSegmented(selection: Binding(get: { engine.programOutFullscreen }, set: { engine.showProgramOut(fullscreen: $0) }),
                                    options: [(false, "Window"), (true, "Full screen")])
                            .frame(width: 170)
                    }
                    if screens.count > 1 {
                        CPRow(icon: "display.2", label: "Full screen on") {
                            Menu(engine.programOutFullscreen ? "Choose display" : "Choose display") {
                                ForEach(screens, id: \.index) { sc in
                                    Button(sc.name + (sc.index == 0 ? " (main)" : "")) { engine.showProgramOut(fullscreen: true, screenIndex: sc.index) }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                    CPRow(icon: "square.grid.3x3", label: "Multiview window", showDivider: false) {
                        CPButton(title: "Open") { engine.openMultiviewWindow() }
                    }
                    CPNote(screens.count > 1
                           ? "With a second display Program Out opens full screen there. Esc or double-click returns to a window; F or ⌘⇧F switches."
                           : "Only one display: Program Out opens in a window so your controls stay visible. F, double-click or ⌘⇧F switches to full screen; Esc comes back.")
                }

                StageDisplayCard()

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
