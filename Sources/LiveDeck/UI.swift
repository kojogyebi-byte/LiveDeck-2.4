import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// vMix-ish palette
private let cBG = Color(red: 0.10, green: 0.10, blue: 0.12)
private let cPanel = Color(red: 0.14, green: 0.14, blue: 0.17)
private let cBar = Color(red: 0.17, green: 0.17, blue: 0.20)
private let cPreview = Color(red: 0.88, green: 0.55, blue: 0.18)
private let cProgram = Color(red: 0.18, green: 0.70, blue: 0.30)
private let cBtn = Color(white: 0.20)

private let pipNoneTag = UUID()

struct MainView: View {
    @EnvironmentObject var engine: Engine
    @State private var showStream = false
    @State private var showOutputs = false
    @State private var dropTargeted = false
    var body: some View {
        VStack(spacing: 0) {
            TopBar(showStream: $showStream)
            HSplitView {
                VSplitView {
                    HStack(spacing: 6) {
                        MonitorPane(title: previewName, accent: cPreview, isProgram: false)
                        TransitionColumn()
                        MonitorPane(title: programName, accent: engine.isRecording ? .red : cProgram, isProgram: true)
                    }
                    .padding(6).frame(maxHeight: .infinity)
                    InputBus().frame(minHeight: 200, idealHeight: 312)
                }
                RightPanel().frame(minWidth: 240, idealWidth: 300, maxWidth: 480)
            }
            StatusBar(showOutputs: $showOutputs)
        }
        .background(cBG).preferredColorScheme(.dark)
        .overlay { if dropTargeted { Rectangle().stroke(cProgram, lineWidth: 3).allowsHitTesting(false) } }
        .overlay(alignment: .topLeading) { HotKeys().frame(width: 0, height: 0) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .sheet(isPresented: $showStream) { StreamSettingsView() }
        .sheet(isPresented: $showOutputs) { OutputsView() }
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

struct HotKeys: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        ZStack {
            ForEach(1...9, id: \.self) { n in
                Button("") { stage(n - 1) }.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
            }
            Button("") { engine.runTransition() }.keyboardShortcut(.return, modifiers: [])
            Button("") { engine.cut() }.keyboardShortcut(.return, modifiers: [.command])
            Button("") { engine.toggleFTB() }.keyboardShortcut("b", modifiers: [])
        }
        .opacity(0).accessibilityHidden(true)
    }
    func stage(_ i: Int) {
        guard engine.sources.indices.contains(i) else { return }
        let s = engine.sources[i]
        if !s.isPlaceholder { engine.setPreview(s.id); engine.selectedSourceID = s.id }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var engine: Engine
    @Binding var showStream: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text("LIVE").font(.system(size: 16, weight: .heavy)) + Text("DECK").font(.system(size: 16, weight: .heavy)).foregroundColor(cPreview)
            Divider().frame(height: 18)
            TBtn("Open") { engine.loadShow() }
            TBtn("Save") { engine.saveShow() }
            Spacer()
            TBtn("Fullscreen", tint: cProgram) { engine.openOutputWindow() }
            TBtn("STREAM", tint: .red) { showStream = true }
            TBtn(engine.isRecording ? "● REC" : "REC", tint: .red, filled: engine.isRecording) { engine.toggleRecording() }
            Spacer()
            Text("\(engine.width)×\(engine.height)").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            Menu {
                Menu("Resolution") {
                    checkButton("720p", engine.height == 720) { engine.setResolution(width: 1280, height: 720) }
                    checkButton("1080p", engine.height == 1080) { engine.setResolution(width: 1920, height: 1080) }
                    checkButton("2160p (4K)", engine.height == 2160) { engine.setResolution(width: 3840, height: 2160) }
                }
                Menu("Frame rate") {
                    checkButton("30 fps", engine.fpsTarget == 30) { engine.setFrameRate(30) }
                    checkButton("60 fps", engine.fpsTarget == 60) { engine.setFrameRate(60) }
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
                Button("Choose recording folder…") { engine.chooseOutputFolder() }
                Button("Reveal last recording") { engine.revealLastRecording() }
            } label: { Image(systemName: "gearshape") }.frame(width: 34)
        }
        .padding(.horizontal, 12).frame(height: 44).background(cBar)
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
            HStack {
                Text(isProgram ? title : title).font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                Spacer()
                Text(isProgram ? (engine.isRecording ? "REC" : "PGM") : "PRV")
                    .font(.system(size: 9, weight: .heavy)).foregroundColor(.white.opacity(0.9))
            }
            .padding(.horizontal, 8).frame(height: 22).background(accent)
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
        .background(cPanel).overlay(Rectangle().stroke(accent, lineWidth: 2))
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
            XBtn("Cut", color: cProgram) { engine.cut() }
            XBtn("Take", color: cPreview) { engine.runTransition() }
            XBtn("Fade", color: engine.transition == .fade ? cPreview : cBtn) { engine.quickTransition(.fade) }
            XBtn("Wipe", color: engine.transition == .wipe ? cPreview : cBtn) { engine.quickTransition(.wipe) }
            XBtn("Slide", color: engine.transition == .slide ? cPreview : cBtn) { engine.quickTransition(.slide) }
            XBtn("Zoom", color: engine.transition == .zoom ? cPreview : cBtn) { engine.quickTransition(.zoom) }
            XBtn("FTB", color: engine.ftbOn ? .red : cBtn) { engine.toggleFTB() }
            Divider()
            VStack(spacing: 4) {
                Text("T-BAR").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
                Slider(value: Binding(get: { engine.tbar }, set: { engine.setTBar($0) }), in: 0...1)
                Text("SPEED \(String(format: "%.1fs", engine.transitionDuration))").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
                Slider(value: $engine.transitionDuration, in: 0.2...2.0)
            }
            VStack(spacing: 1) {
                Text(engine.clockText).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(cProgram)
                Text(String(format: "%02d:%02d:%02d", engine.recordSeconds / 3600, (engine.recordSeconds % 3600) / 60, engine.recordSeconds % 60))
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
            .padding(6).frame(maxWidth: .infinity).background(Color.black).cornerRadius(4)
        }
        .frame(width: 96).padding(.vertical, 22)
    }
    func XBtn(_ t: String, color: Color = cBtn, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(color).foregroundColor(.white).cornerRadius(4)
        }.buttonStyle(.plain)
    }
}

// MARK: - Input bus

struct InputBus: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                AddInputMenu()
                Text("INPUTS").font(.system(size: 9, weight: .heavy)).kerning(2).foregroundColor(.secondary)
                Spacer()
                Toggle("Playlist", isOn: $engine.playlistEnabled)
                    .toggleStyle(.button).font(.system(size: 10))
                    .help("Auto-advance the Program through video/audio inputs as each clip ends")
                Text("SIZE").font(.system(size: 9, weight: .heavy)).foregroundColor(.secondary)
                Slider(value: $engine.inputTileScale, in: 0.6...2.0).frame(width: 120)
            }
            .padding(.horizontal, 8).frame(height: 22).background(cBar)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(engine.sources.enumerated()), id: \.element.id) { idx, src in
                        InputTile(index: idx + 1, source: src)
                    }
                }.padding(8)
            }
        }
        .background(cPanel)
        .sheet(isPresented: Binding(get: { engine.showStreamInput }, set: { engine.showStreamInput = $0 })) { AddStreamView() }
    }
}

let videoFileTypes = ["public.movie", "public.video", "public.audiovisual-content",
                      "com.apple.quicktime-movie", "public.mpeg-4", "public.avi",
                      "public.mpeg", "public.mpeg-2-transport-stream",
                      "org.matroska.mkv", "com.microsoft.windows-media-wmv"]

struct InputAssignMenu<Label: View>: View {
    @EnvironmentObject var engine: Engine
    var slotID: UUID
    @ViewBuilder var label: () -> Label
    @State private var devices: [AVCaptureDevice] = []
    var body: some View {
        Menu {
            Menu("Cameras & Capture Devices") {
                ForEach(devices, id: \.uniqueID) { d in
                    Button(d.localizedName) { engine.replaceSource(slotID, with: CameraSource(device: d)) }
                }
                if devices.isEmpty { Text("No devices found") }
                Divider()
                Button("Refresh devices") { devices = VideoDevices.all() }
            }
            Button("Screen Capture") { engine.replaceSource(slotID, with: ScreenSource()) }
            Button("Video File…") { pickFile(types: videoFileTypes) { engine.replaceSource(slotID, with: FileSource(url: $0)) } }
            Button("Image…") { pickFile(types: ["public.image"]) { engine.replaceSource(slotID, with: ImageSource(url: $0)) } }
            Button("Network Stream (HLS / URL)…") { engine.showStreamInput = true }
            Button("Colour") { engine.replaceSource(slotID, with: ColorSource()) }
        } label: { label() }
        .onAppear { if devices.isEmpty { devices = VideoDevices.all() } }
    }
}

struct InputTile: View {
    @EnvironmentObject var engine: Engine
    var index: Int
    @ObservedObject var source: Source
    var isProgram: Bool { engine.programID == source.id }
    var isPreview: Bool { engine.previewID == source.id }
    var border: Color { source.isPlaceholder ? Color(white: 0.22) : (isProgram ? .red : isPreview ? cProgram : Color(white: 0.25)) }
    var tw: CGFloat { 176 * CGFloat(engine.inputTileScale) }
    var th: CGFloat { 99 * CGFloat(engine.inputTileScale) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("\(index)").font(.system(size: 9, weight: .heavy))
                    .frame(width: 16, height: 16).background(border).cornerRadius(2)
                Text(source.isPlaceholder ? "Empty" : source.name).font(.system(size: 10))
                    .foregroundColor(source.isPlaceholder ? .secondary : .primary).lineLimit(1)
                Spacer()
                Button { engine.removeSource(source.id) } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                    .buttonStyle(.plain).foregroundColor(.secondary)
            }
            .frame(width: tw).padding(.horizontal, 5).frame(height: 20).background(cBar)

            if source.isPlaceholder {
                InputAssignMenu(slotID: source.id) {
                    VStack(spacing: 6) {
                        Image(systemName: "plus.circle").font(.system(size: 22)).foregroundColor(Color(white: 0.4))
                        Text("Select input").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .frame(width: tw, height: th).background(Color(white: 0.10))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundColor(Color(white: 0.3)))
                }
                .menuStyle(.borderlessButton)
                Color.clear.frame(width: tw, height: 22)
            } else {
                SourceThumb(source: source)
                    .frame(width: tw, height: th).background(Color.black)
                    .onTapGesture(count: 2) { engine.setPreview(source.id); engine.cut() }
                    .onTapGesture { engine.setPreview(source.id); engine.selectedSourceID = source.id }
                    .contextMenu {
                        Button("Take to Program") { engine.setPreview(source.id); engine.cut() }
                        Button("Set as Preview") { engine.setPreview(source.id); engine.selectedSourceID = source.id }
                        Divider()
                        Button("Remove", role: .destructive) { engine.removeSource(source.id) }
                    }
                HStack(spacing: 4) {
                    Button("PGM") { engine.setPreview(source.id); engine.cut() }
                        .font(.system(size: 9, weight: .bold)).buttonStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color(white: 0.18)).cornerRadius(3)
                    Spacer()
                    Button { source.muted.toggle() } label: {
                        Image(systemName: source.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 9))
                            .foregroundColor(source.muted ? .red : cProgram)
                    }.buttonStyle(.plain)
                }
                .frame(width: tw).padding(.horizontal, 5).frame(height: 22).background(cBar)
            }
        }
        .overlay(Rectangle().stroke(border, lineWidth: 2))
    }
}

struct SourceThumb: NSViewRepresentable {
    @ObservedObject var source: Source
    func makeNSView(context: Context) -> SourceThumbNSView { let v = SourceThumbNSView(frame: .zero); v.source = source; return v }
    func updateNSView(_ v: SourceThumbNSView, context: Context) { v.source = source }
}

struct AddInputMenu: View {
    @EnvironmentObject var engine: Engine
    @State private var devices: [AVCaptureDevice] = []
    var body: some View {
        Menu {
            Menu("Cameras & Capture Devices") {
                ForEach(devices, id: \.uniqueID) { d in Button(d.localizedName) { engine.addCamera(d) } }
                if devices.isEmpty { Text("No devices found") }
                Divider()
                Button("Refresh devices") { devices = VideoDevices.all() }
            }
            Button("Screen Capture") { engine.addScreen() }
            Button("Video File…") { pickFile(types: videoFileTypes) { engine.addFile(url: $0) } }
            Button("Image…") { pickFile(types: ["public.image"]) { engine.addImage(url: $0) } }
            Button("Network Stream (HLS / URL)…") { engine.showStreamInput = true }
            Button("Colour") { engine.addColor() }
            Divider()
            Button("Blank Input") { engine.addBlankInput() }
        } label: {
            Text("Add Input").font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 8).padding(.vertical, 3).background(cProgram).foregroundColor(.white).cornerRadius(3)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .onAppear { if devices.isEmpty { devices = VideoDevices.all() } }
    }
}

// MARK: - Right panel (Audio Mixer / Overlays)

struct RightPanel: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $engine.rightTab) {
                Text("Audio").tag(0); Text("Input").tag(1); Text("Overlays").tag(2)
            }.pickerStyle(.segmented).padding(8)
            Divider()
            if engine.rightTab == 0 { AudioMixerPanel() }
            else if engine.rightTab == 1 { InputSettingsPanel() }
            else { OverlaysPanel() }
        }
        .background(cPanel).overlay(Rectangle().frame(width: 1).foregroundColor(Color(white: 0.2)), alignment: .leading)
    }
}

@ViewBuilder
func checkButton(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack { Text(title); if on { Image(systemName: "checkmark") } }
    }
}

// Shared labelled slider for adjustments
@ViewBuilder
func adjSlider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        HStack {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            Spacer()
            Text(String(format: "%.2f", value.wrappedValue)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
        }
        Slider(value: value, in: range)
    }
}

struct InputSettingsPanel: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        ScrollView {
            if let s = engine.sources.first(where: { $0.id == engine.selectedSourceID }) {
                InputAdjust(source: s)
            } else {
                Text("Tap an input's thumbnail to adjust its zoom, pan, rotation, crop, colour and audio here.")
                    .font(.system(size: 11)).foregroundColor(.secondary).padding(12)
            }
        }
    }
}

struct InputAdjust: View {
    @ObservedObject var source: Source
    @State private var audioDevices: [AudioDeviceInfo] = []
    @State private var showFX = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("INPUT NAME").font(.system(size: 9, weight: .heavy)).kerning(1.5).foregroundColor(.secondary)
                Spacer()
                Button("Reset") { source.resetAdjustments() }.font(.system(size: 10))
            }
            TextField("Name", text: $source.name)

            if let f = source as? FileSource { PlaybackTransport(source: f) }
            if let a = source as? AudioFileSource { PlaybackTransport(source: a) }

            Text("GEOMETRY").font(.system(size: 9, weight: .heavy)).kerning(1.5).foregroundColor(.secondary)
            adjSlider("Zoom", $source.zoom, 0.2...4)
            adjSlider("Pan X", $source.panX, -1...1)
            adjSlider("Pan Y", $source.panY, -1...1)
            adjSlider("Rotate", $source.rotation, -180...180)
            Divider()
            Text("CROP").font(.system(size: 9, weight: .heavy)).kerning(1.5).foregroundColor(.secondary)
            adjSlider("Left", $source.cropL, 0...0.45)
            adjSlider("Right", $source.cropR, 0...0.45)
            adjSlider("Top", $source.cropT, 0...0.45)
            adjSlider("Bottom", $source.cropB, 0...0.45)
            Divider()
            Text("COLOUR").font(.system(size: 9, weight: .heavy)).kerning(1.5).foregroundColor(.secondary)
            adjSlider("Brightness", $source.brightness, -0.5...0.5)
            adjSlider("Contrast", $source.contrast, 0...2)
            adjSlider("Saturation", $source.saturation, 0...2)
            Divider()
            Text("AUDIO").font(.system(size: 9, weight: .heavy)).kerning(1.5).foregroundColor(.secondary)
            Picker("Audio device", selection: Binding(
                get: { source.audioDeviceID ?? "" },
                set: { source.audioDeviceID = $0.isEmpty ? nil : $0 })) {
                Text("None").tag("")
                ForEach(audioDevices) { d in Text(d.name).tag(d.id) }
            }
            AudioMeter(level: source.muted ? 0 : source.level).frame(height: 10)
            adjSlider("Gain", $source.gain, 0...1.5)
            Toggle("Mute", isOn: $source.muted).font(.system(size: 11))
            Button(showFX ? "Hide Effects" : "Audio Effects (EQ · Comp · Gate)") { showFX.toggle() }
                .font(.system(size: 11))
            if showFX { AudioEffects(source: source) }
        }
        .padding(12)
        .onAppear { audioDevices = AudioCapture.availableDevices() }
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
        .padding(8).background(Color(white: 0.10)).cornerRadius(6)
    }
}

struct AudioEffects: View {
    @ObservedObject var source: Source
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Enable effects", isOn: $source.fxEnabled).font(.system(size: 11))
            Text("EQUALISER (dB)").font(.system(size: 9, weight: .heavy)).foregroundColor(.secondary)
            adjSlider("Low", $source.eqLow, -24...24)
            adjSlider("Mid", $source.eqMid, -24...24)
            adjSlider("High", $source.eqHigh, -24...24)
            Text("COMPRESSOR").font(.system(size: 9, weight: .heavy)).foregroundColor(.secondary)
            adjSlider("Threshold", $source.compThreshold, -40...0)
            adjSlider("Ratio", $source.compRatio, 1...20)
            Text("GATE").font(.system(size: 9, weight: .heavy)).foregroundColor(.secondary)
            adjSlider("Threshold", $source.gateThreshold, -80...0)
        }
        .padding(8).background(Color(white: 0.10)).cornerRadius(6)
    }
}

struct AudioMixerPanel: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("AUDIO MIXER").font(.system(size: 10, weight: .heavy)).kerning(2).foregroundColor(.secondary)
                MasterStrip(label: "MASTER", level: engine.audioLevel)
                MasterStrip(label: "RECORDING", level: engine.isRecording ? engine.audioLevel : 0)
                DBScale().padding(.horizontal, 4)
                Divider()
                ForEach(engine.sources) { s in
                    ChannelStrip(source: s)
                }
                Text("Each input has its own fader, mute (M) and solo (S). Mute silences that input's live output immediately. Assign an audio device in the Input tab for live metering.")
                    .font(.system(size: 9)).foregroundColor(.secondary).padding(.top, 4)
            }.padding(10)
        }
    }
}

struct MasterStrip: View {
    var label: String; var level: Float
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(label).font(.system(size: 10, weight: .heavy)).kerning(1).foregroundColor(.white)
                Spacer()
                Text(dbReadout(level)).font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(meterDB(level) >= -2 ? vmRed : .secondary)
            }
            AudioMeter(level: level, segments: 28).frame(height: 16)
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
            let lvl = source.muted ? 0 : source.level
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(source.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(dbReadout(lvl)).font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(meterDB(lvl) >= -2 ? vmRed : .secondary)
                }
                AudioMeter(level: lvl).frame(height: 13)
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 9)).foregroundColor(.secondary)
                    Slider(value: $source.gain, in: 0...1.5)
                    Text(gainDBText(source.gain)).font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary).frame(width: 42, alignment: .trailing)
                }
                HStack(spacing: 6) {
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
                    .popover(isPresented: $showFX) { AudioEffects(source: source).frame(width: 240).padding(10) }
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

struct StatusBar: View {
    @EnvironmentObject var engine: Engine
    @Binding var showOutputs: Bool
    var body: some View {
        HStack(spacing: 12) {
            Text("\(engine.height)p\(engine.fpsTarget)").font(.system(size: 10, design: .monospaced))
            Text("FPS \(engine.fps)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            Text("Render —").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            Spacer()
            ForEach(0..<4) { i in
                Button { engine.toggleOverlay(i) } label: {
                    Text("\(i + 1)").font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 18)
                        .background(engine.layers.indices.contains(i) && engine.layers[i].isLive ? cPreview : Color(white: 0.18))
                        .cornerRadius(3)
                }.buttonStyle(.plain).help("Toggle overlay channel \(i + 1)")
            }
            SBtn("Record", color: engine.isRecording ? .red : cBtn) { engine.toggleRecording() }
            SBtn("Stream", color: cBtn).opacity(0.5)
            SBtn("Snapshot") { engine.snapshot() }
            SBtn("Outputs", color: engine.activeScreens.isEmpty ? cBtn : cProgram) { showOutputs = true }
            SBtn("Multiview") { engine.openMultiviewWindow() }
            Toggle("Guides", isOn: $engine.showSafeGuides).toggleStyle(.button).font(.system(size: 10))
        }
        .padding(.horizontal, 12).frame(height: 30).background(cBar)
    }
    func SBtn(_ t: String, color: Color = cBtn, _ action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 3)
                .background(color).foregroundColor(.white).cornerRadius(3)
        }.buttonStyle(.plain)
    }
}

// MARK: - Inspector + variants

struct OverlayStyleControls: View {
    @ObservedObject var layer: Layer
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("STYLING").font(.system(size: 9, weight: .heavy)).kerning(1.5).foregroundColor(.secondary)
            ColorPicker("Accent", selection: $layer.accent)
            ColorPicker("Text colour", selection: $layer.textColor)
            ColorPicker("Background", selection: $layer.bgColor)
            HStack { Text("BG opacity").font(.system(size: 11)).foregroundColor(.secondary); Slider(value: $layer.bgOpacity, in: 0...1) }
            HStack { Text("Font size").font(.system(size: 11)).foregroundColor(.secondary); Slider(value: $layer.fontScale, in: 0.6...2.0) }
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
                HStack { Text("Speed").font(.system(size: 11)).foregroundColor(.secondary); Slider(value: $layer.number1, in: 20...300) }
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
                TextField("Text", text: $layer.text1)
                Picker("Align", selection: $layer.align) { Text("Left").tag(0); Text("Centre").tag(1); Text("Right").tag(2) }
                HStack { Text("Size").font(.system(size: 11)).foregroundColor(.secondary); Slider(value: $layer.number1, in: 3...20) }
                ColorPicker("Color", selection: $layer.accent)
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
                HStack { Text("Scale").font(.system(size: 11)).foregroundColor(.secondary); Slider(value: $layer.number1, in: 4...50) }
            case .qrcode:
                TextField("URL", text: $layer.text1)
                HStack { Text("Size").font(.system(size: 11)).foregroundColor(.secondary); Slider(value: $layer.number1, in: 80...360) }
            case .pip:
                Picker("Source", selection: Binding(get: { layer.sourceRef ?? pipNoneTag }, set: { layer.sourceRef = ($0 == pipNoneTag ? nil : $0) })) {
                    Text("— none —").tag(pipNoneTag)
                    ForEach(engine.sources) { s in Text(s.name).tag(s.id) }
                }
                Picker("Corner", selection: $layer.position) { Text("Top left").tag(0); Text("Top right").tag(1); Text("Bottom left").tag(2); Text("Bottom right").tag(3) }
                HStack { Text("Size").font(.system(size: 11)).foregroundColor(.secondary); Slider(value: $layer.number1, in: 8...50) }
                ColorPicker("Border", selection: $layer.accent)
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
                Text("VARIANTS").font(.system(size: 9, weight: .heavy)).kerning(1.5).foregroundColor(.secondary)
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
                Text("TRANSFORM").font(.system(size: 9, weight: .heavy)).kerning(1.5).foregroundColor(.secondary)
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
            Text("LiveDeck stores these destinations (RTMP/RTMPS/SRT URL + key). Actually going live needs a streaming encoder, which isn't bundled yet — for now capture the Program window in OBS or YouTube's browser encoder. These saved settings are ready for when the encoder lands.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(16).frame(width: 540, height: 480)
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
        .padding(10).background(Color(white: 0.12)).cornerRadius(6)
    }
}

// MARK: - Add network stream

struct AddStreamView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ADD NETWORK STREAM").font(.system(size: 13, weight: .heavy)).kerning(1)
            Text("Enter a stream URL. Supported natively: HLS (.m3u8) live streams and direct HTTP(S) video URLs (MP4, MOV, etc.). These run through the same engine as file inputs — with transport, trim, and audio.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            TextField("https://example.com/live/stream.m3u8", text: $urlString)
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            VStack(alignment: .leading, spacing: 4) {
                Text("Not directly supported:").font(.system(size: 11, weight: .bold))
                Text("• RTMP / RTSP pull — needs an external demuxer (FFmpeg). Restream it to HLS and paste that URL.\n• YouTube / Twitch / Facebook page links — these don't expose a playable URL; pull the source feed or restream to HLS instead.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            .padding(10).background(Color(white: 0.12)).cornerRadius(6)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add Stream") { engine.addNetworkStream(urlString); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).frame(width: 540, height: 320).preferredColorScheme(.dark)
    }
}

// MARK: - Outputs (simultaneous / external displays)

struct OutputsView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var screens: [(index: Int, name: String)] = []
    @State private var ndiAvailable = false
    @State private var ndiVersion = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SIMULTANEOUS OUTPUTS").font(.system(size: 13, weight: .heavy)).kerning(1)
                Spacer()
                Button("Refresh") { screens = engine.availableScreens(); NDIBridge.shared.detect(); ndiAvailable = NDIBridge.shared.isAvailable; ndiVersion = NDIBridge.shared.versionString }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Every output below runs at the same time — and alongside Record and Stream. Send the clean Program feed to a projector or LED wall by enabling its display.")
                .font(.system(size: 11)).foregroundColor(.secondary)

            Text("EXTERNAL DISPLAYS").font(.system(size: 10, weight: .heavy)).kerning(1.5).foregroundColor(.secondary)
            if screens.count <= 1 {
                Text("No additional displays detected. Connect a projector, monitor or LED processor and click Refresh.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            ForEach(screens, id: \.index) { s in
                HStack {
                    Image(systemName: "display").foregroundColor(.secondary)
                    Text(s.name + (s.index == 0 ? "  (main)" : "")).font(.system(size: 12))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { engine.activeScreens.contains(s.index) },
                        set: { _ in engine.toggleScreenOutput(s.index) })).labelsHidden()
                }
                .padding(10).background(Color(white: 0.12)).cornerRadius(6)
            }

            Divider()
            Text("WINDOWS").font(.system(size: 10, weight: .heavy)).kerning(1.5).foregroundColor(.secondary)
            HStack {
                Button("Open Program Window") { engine.openOutputWindow() }
                Button("Open Multiview") { engine.openMultiviewWindow() }
            }

            Divider()
            Text("NDI OUTPUT (NETWORK)").font(.system(size: 10, weight: .heavy)).kerning(1.5).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Image(systemName: ndiAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(ndiAvailable ? cProgram : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    if ndiAvailable {
                        Text("NDI runtime detected\(ndiVersion.isEmpty ? "" : " — \(ndiVersion)")").font(.system(size: 11))
                        Text("Frame-sending will be enabled once the NDI SDK headers are wired into the build.")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    } else {
                        Text("NDI runtime not found.").font(.system(size: 11))
                        Text("Run the libNDI for Mac installer, then click Refresh.")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(10).background(Color(white: 0.12)).cornerRadius(6)
            Toggle("Enable NDI output", isOn: .constant(false)).disabled(true)
                .font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
        }
        .padding(16).frame(width: 480, height: 460)
        .preferredColorScheme(.dark)
        .onAppear { screens = engine.availableScreens(); ndiAvailable = NDIBridge.shared.isAvailable; ndiVersion = NDIBridge.shared.versionString }
    }
}

// MARK: - File picker

func pickFile(types: [String], completion: @escaping (URL) -> Void) {
    let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
    panel.allowedContentTypes = types.compactMap { UTType($0) }
    panel.begin { resp in if resp == .OK, let url = panel.url { completion(url) } }
}
