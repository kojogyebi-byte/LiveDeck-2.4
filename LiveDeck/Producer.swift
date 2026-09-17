import SwiftUI
import AppKit
import AVFoundation
import PresentationKit

// MARK: - Pre-service checklist

struct PreflightItem: Identifiable {
    enum Level { case ok, warn, fail, info }
    let id = UUID()
    let title: String
    let detail: String
    let level: Level
    var fixTitle: String? = nil
    var fix: (() -> Void)? = nil
}

enum Preflight {
    static func run(engine: Engine, present: PresentModel, link: LinkManager, automation: AutomationModel) -> [PreflightItem] {
        var out: [PreflightItem] = []
        let inputs = engine.sources.filter { !$0.isPlaceholder }

        // Inputs
        if inputs.isEmpty {
            out.append(PreflightItem(title: "No inputs", detail: "Add cameras, videos, slides or a playlist.", level: .fail,
                                     fixTitle: "Show Inputs", fix: { present.deck = DeckTab.inputs.rawValue }))
        } else {
            out.append(PreflightItem(title: "\(inputs.count) input\(inputs.count == 1 ? "" : "s") ready", detail: inputs.map { $0.name }.joined(separator: ", "), level: .ok))
        }
        let missingCams = inputs.compactMap { $0 as? CameraSource }.filter { $0.originLocation.flatMap { AVCaptureDevice(uniqueID: $0) } == nil }
        if !missingCams.isEmpty {
            out.append(PreflightItem(title: "Camera not connected", detail: missingCams.map { $0.name }.joined(separator: ", ") + " — check cables and capture cards.", level: .fail))
        }
        let missingFiles = inputs.filter { s in
            guard s is FileSource || s is ImageSource || s is AudioFileSource, s.sourceURLString == nil, let p = s.originLocation else { return false }
            return !FileManager.default.fileExists(atPath: p)
        }
        if !missingFiles.isEmpty {
            out.append(PreflightItem(title: "Missing media files", detail: missingFiles.map { $0.name }.joined(separator: ", "), level: .fail))
        }
        let brokenPlaylists = inputs.compactMap { $0 as? PlaylistSource }.filter { $0.playlist.items.contains { !$0.exists } || $0.playlist.items.isEmpty }
        if !brokenPlaylists.isEmpty {
            out.append(PreflightItem(title: "Playlist needs attention", detail: brokenPlaylists.map { "\($0.name): \($0.playlist.items.isEmpty ? "empty" : "missing files")" }.joined(separator: " · "),
                                     level: .warn, fixTitle: "Open", fix: { if let p = brokenPlaylists.first { engine.selectedSourceID = p.id; engine.rightTab = 1 } }))
        }
        let slideProblems = inputs.compactMap { $0 as? SlideSource }.compactMap { s in s.backgroundProblem.map { "\(s.name): \($0)" } }
        if !slideProblems.isEmpty {
            out.append(PreflightItem(title: "Slide background missing", detail: slideProblems.joined(separator: " · "), level: .warn))
        }
        if engine.programID == nil || engine.sources.first(where: { $0.id == engine.programID })?.isPlaceholder == true {
            out.append(PreflightItem(title: "Program is empty", detail: "Put your opening input (walk-in playlist, logo, camera) on Program.", level: .warn))
        }

        // Audio
        if !engine.audio.isRunning {
            out.append(PreflightItem(title: "Audio engine stopped", detail: engine.audio.lastError.isEmpty ? "No audio output device." : engine.audio.lastError, level: .fail))
        }
        if engine.masterBus.muted {
            out.append(PreflightItem(title: "Master audio is MUTED", detail: "Nothing will be heard in the recording or stream.", level: .fail,
                                     fixTitle: "Unmute", fix: { engine.masterBus.muted = false }))
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            out.append(PreflightItem(title: "Microphone access is blocked", detail: "System Settings → Privacy & Security → Microphone → LiveDeck.", level: .fail,
                                     fixTitle: "Open Settings", fix: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }))
        }
        let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if camStatus == .denied || camStatus == .restricted {
            out.append(PreflightItem(title: "Camera access is blocked", detail: "System Settings → Privacy & Security → Camera → LiveDeck.", level: .fail,
                                     fixTitle: "Open Settings", fix: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!) }))
        }
        let audioChannels = inputs.filter { $0 is FileSource || $0 is AudioFileSource || $0 is PlaylistSource || $0.audioDeviceID != nil || $0 is LiveAudioSource }
        if audioChannels.isEmpty {
            out.append(PreflightItem(title: "No audio sources", detail: "Assign a microphone or mixer feed to an input (Input panel → Audio) so the recording and stream have sound.", level: .warn,
                                     fixTitle: "Audio Mixer", fix: { present.deck = DeckTab.audio.rawValue }))
        } else if engine.telemetry.master < 0.001 {
            out.append(PreflightItem(title: "No sound on the master meter right now", detail: "Speak into the microphone or play media to confirm levels.", level: .info))
        } else {
            out.append(PreflightItem(title: "Audio is coming through", detail: String(format: "Master peak %.0f dB", meterDB(engine.telemetry.master)), level: .ok))
        }

        // Recording
        let folder = engine.outputFolder
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).map { Double($0) / 1e9 }
        if !FileManager.default.isWritableFile(atPath: folder.path) {
            out.append(PreflightItem(title: "Recording folder is not writable", detail: folder.path, level: .fail,
                                     fixTitle: "Choose folder", fix: { engine.chooseOutputFolder() }))
        } else if let gb = free {
            let hours = gb / max(0.5, Double(engine.recBitrateMbps) * 0.45)
            let lvl: PreflightItem.Level = gb < 5 ? .fail : (gb < 20 ? .warn : .ok)
            out.append(PreflightItem(title: String(format: "%.0f GB free for recording", gb),
                                     detail: String(format: "About %.1f hours at %d Mbps in %@", hours, engine.recBitrateMbps, folder.lastPathComponent), level: lvl,
                                     fixTitle: lvl == .ok ? nil : "Choose folder", fix: lvl == .ok ? nil : { engine.chooseOutputFolder() }))
        }

        // Streaming
        let dests = engine.liveDestinations
        if !dests.isEmpty {
            if !engine.ffmpegAvailable {
                out.append(PreflightItem(title: "Streaming needs ffmpeg", detail: "Install it once in Terminal: brew install ffmpeg", level: .fail))
            }
            let noKey = dests.filter { $0.key.trimmingCharacters(in: .whitespaces).isEmpty && !$0.url.contains("srt://") }
            if !noKey.isEmpty {
                out.append(PreflightItem(title: "Stream key missing", detail: noKey.map { $0.name }.joined(separator: ", "), level: .fail))
            } else if engine.ffmpegAvailable {
                out.append(PreflightItem(title: "Ready to stream to \(dests.count) destination\(dests.count == 1 ? "" : "s")", detail: dests.map { $0.name }.joined(separator: ", "), level: .ok))
            }
        } else {
            out.append(PreflightItem(title: "No stream destinations enabled", detail: "Only needed if you are going live.", level: .info))
        }

        // NDI
        let ndi = engine.ndiOutputs
        if (ndi.programEnabled || ndi.previewEnabled) && !ndi.runtimeAvailable {
            out.append(PreflightItem(title: "NDI output is on but the NDI runtime did not load", detail: NDIBridge.shared.lastError, level: .fail,
                                     fixTitle: "Try again", fix: { ndi.rebuild() }))
        } else if ndi.programEnabled {
            out.append(PreflightItem(title: ndi.programConnections > 0 ? "NDI Program: \(ndi.programConnections) receiver(s)" : "NDI Program is on (no receivers yet)",
                                     detail: "Source name: \(ndi.programName)", level: ndi.programConnections > 0 ? .ok : .info))
        }
        let ndiInputs = inputs.compactMap { $0 as? NDISource }.filter { !$0.status.hasPrefix("Receiving") }
        if !ndiInputs.isEmpty {
            out.append(PreflightItem(title: "NDI input not receiving", detail: ndiInputs.map { "\($0.name): \($0.status)" }.joined(separator: " · "), level: .warn))
        }

        // Performance & outputs
        let fps = engine.telemetry.fps
        let rate = Int(engine.frameFormat.renderRate.rounded())
        if fps > 0 && fps < rate - 3 {
            out.append(PreflightItem(title: "Frame rate is low (\(fps) of \(rate) \(engine.frameFormat.interlaced ? "fields" : "fps"))", detail: "Close other apps, lower the resolution, or remove unused inputs and web pages.", level: .warn))
        }
        if NSScreen.screens.count > 1 && !engine.programWindowActive {
            out.append(PreflightItem(title: "Projector/second display connected", detail: "Program Out is off.", level: .info,
                                     fixTitle: "Open Program Out", fix: { engine.openOutputWindow() }))
        }
        if engine.ftbOn {
            out.append(PreflightItem(title: "Fade to black is ON", detail: "Program output is black.", level: .warn, fixTitle: "Fade up", fix: { engine.toggleFTB() }))
        }
        if !automation.rules.isEmpty && !automation.running {
            out.append(PreflightItem(title: "\(automation.rules.count) automation cue(s) are not running", detail: "Start automation if you want timed lower thirds.", level: .info,
                                     fixTitle: "Start", fix: { automation.start() }))
        }
        if link.enabled {
            out.append(PreflightItem(title: link.connectedPeers.isEmpty ? "No other LiveDeck computers connected" : "\(link.connectedPeers.count) computer(s) linked",
                                     detail: link.connectedPeers.map { $0.name }.joined(separator: ", "), level: link.connectedPeers.isEmpty ? .info : .ok))
        }
        return out
    }
}

struct PreflightView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var link: LinkManager
    @EnvironmentObject var automation: AutomationModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PreflightItem] = []

    var body: some View {
        let fails = items.filter { $0.level == .fail }.count, warns = items.filter { $0.level == .warn }.count
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: fails > 0 ? "xmark.octagon.fill" : (warns > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"))
                    .font(.system(size: 22)).foregroundColor(fails > 0 ? DS.program : (warns > 0 ? DS.amber : DS.ok))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Pre-service check").font(.system(size: 14, weight: .semibold)).foregroundColor(CP.text)
                    Text(fails > 0 ? "\(fails) problem\(fails == 1 ? "" : "s") to fix before you go live" : (warns > 0 ? "Ready, with \(warns) thing\(warns == 1 ? "" : "s") to check" : "Everything looks ready"))
                        .font(.system(size: 10.5)).foregroundColor(CP.text2)
                }
                Spacer()
                CPButton(icon: "arrow.clockwise", title: "Check again") { refresh() }
                CPButton(title: "Done", prominent: true) { dismiss() }
            }
            .padding(.horizontal, 14).frame(height: 56).background(CP.cardHeader)
            CPInspector {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(item.level)).font(.system(size: 15)).foregroundColor(color(item.level)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundColor(CP.text)
                            if !item.detail.isEmpty { Text(item.detail).font(.system(size: 10.5)).foregroundColor(CP.text2).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer()
                        if let t = item.fixTitle, let f = item.fix { CPButton(title: t) { f(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { refresh() } } }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CP.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(item.level == .fail ? DS.program.opacity(0.6) : CP.border, lineWidth: 1))
                }
            }
        }
        .frame(width: 560, height: 620)
        .background(CP.bg)
        .preferredColorScheme(.dark)
        .onAppear { refresh() }
    }

    private func refresh() {
        items = Preflight.run(engine: engine, present: present, link: link, automation: automation)
            .sorted { rank($0.level) < rank($1.level) }
    }
    private func rank(_ l: PreflightItem.Level) -> Int { switch l { case .fail: return 0; case .warn: return 1; case .info: return 2; case .ok: return 3 } }
    private func icon(_ l: PreflightItem.Level) -> String {
        switch l { case .ok: return "checkmark.circle.fill"; case .warn: return "exclamationmark.triangle.fill"; case .fail: return "xmark.octagon.fill"; case .info: return "info.circle.fill" }
    }
    private func color(_ l: PreflightItem.Level) -> Color {
        switch l { case .ok: return DS.ok; case .warn: return DS.amber; case .fail: return DS.program; case .info: return CP.icon }
    }
}

// MARK: - Session auto-save and recovery

final class SessionGuard: ObservableObject {
    weak var engine: Engine?
    weak var presets: PresetStore?
    @Published var recoveryAvailable = false
    @Published var recoveryDate: Date?
    private var timer: Timer?
    private let folder = PresentationLibrary.defaultRoot.appendingPathComponent("Session")
    private var fileURL: URL { folder.appendingPathComponent("autosave.json") }
    private let cleanKey = "session.cleanExit"

    func activate() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clean = UserDefaults.standard.object(forKey: cleanKey) as? Bool ?? true
        if !clean, FileManager.default.fileExists(atPath: fileURL.path) {
            recoveryDate = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
            recoveryAvailable = true
        }
        UserDefaults.standard.set(false, forKey: cleanKey)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.save()
            UserDefaults.standard.set(true, forKey: self?.cleanKey ?? "session.cleanExit")
        }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.save() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func save() {
        guard let engine, !recoveryAvailable, engine.sources.contains(where: { !$0.isPlaceholder }) else { return }
        let p = PresetStore.capture(engine, name: "Last session", includes: PresetIncludes())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(p) { try? data.write(to: fileURL, options: .atomic) }
    }

    func restore() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let engine, let presets, let data = try? Data(contentsOf: fileURL), let p = try? dec.decode(AppPreset.self, from: data) else { dismiss(); return }
        presets.recall(p, into: engine)
        dismiss()
    }

    func dismiss() { recoveryAvailable = false }
}

struct RecoveryBanner: View {
    @EnvironmentObject var session: SessionGuard
    var body: some View {
        if session.recoveryAvailable {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill").font(.system(size: 20)).foregroundColor(DS.amber)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LiveDeck did not close normally").font(.system(size: 12, weight: .semibold)).foregroundColor(CP.text)
                    Text("Restore your inputs, audio, overlays and settings from \(session.recoveryDate?.formatted(date: .omitted, time: .shortened) ?? "the last session")?")
                        .font(.system(size: 10.5)).foregroundColor(CP.text2)
                }
                Spacer()
                CPButton(title: "Not now") { session.dismiss() }
                CPButton(icon: "arrow.uturn.backward", title: "Restore session", prominent: true) { session.restore() }
            }
            .padding(10)
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 12).fill(CP.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.amber.opacity(0.7), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
            .padding(.top, 56)
        }
    }
}

// MARK: - Stage display (confidence monitor for preacher, singers and band)

final class StageModel: ObservableObject {
    @Published var message = ""
    @Published var flashMessage = false
    @Published var showNext = true
    @Published var showProgramName = false
    @Published var timerMinutes: Double = UserDefaults.standard.object(forKey: "stage.timer") as? Double ?? 30 { didSet { UserDefaults.standard.set(timerMinutes, forKey: "stage.timer") } }
    @Published var timerRemaining: Double = 0
    @Published var timerRunning = false
    @Published private(set) var windowOpen = false
    private var timer: Timer?
    private var window: NSWindow?

    init() {
        NotificationCenter.default.addObserver(forName: .clearStageMessage, object: nil, queue: .main) { [weak self] _ in self?.message = "" }
    }

    func startTimer() {
        if timerRemaining <= 0 { timerRemaining = timerMinutes * 60 }
        timerRunning = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.timerRunning else { return }
            self.timerRemaining -= 1
        }
    }
    func pauseTimer() { timerRunning = false }
    func resetTimer() { timerRunning = false; timerRemaining = timerMinutes * 60 }

    func open(on screenIndex: Int?, engine: Engine, present: PresentModel) {
        close()
        let screens = NSScreen.screens
        let screen = screenIndex.flatMap { screens.indices.contains($0) ? screens[$0] : nil } ?? screens.last ?? NSScreen.main!
        let fullscreen = screens.count > 1 && screen != (NSApp.mainWindow?.screen ?? NSScreen.main)
        let rect = fullscreen ? screen.frame : NSRect(x: screen.visibleFrame.midX - 480, y: screen.visibleFrame.midY - 270, width: 960, height: 540)
        let w = NSWindow(contentRect: rect, styleMask: fullscreen ? [.borderless] : [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false, screen: screen)
        w.title = "LiveDeck — Stage Display"
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = NSHostingView(rootView: StageDisplayView().environmentObject(self).environmentObject(engine).environmentObject(present).environmentObject(engine.telemetry))
        if fullscreen { w.level = .normal; w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]; w.setFrame(screen.frame, display: true) }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.windowOpen = false; self?.window = nil
        }
        w.makeKeyAndOrderFront(nil)
        window = w
        windowOpen = true
    }

    func close() { window?.close(); window = nil; windowOpen = false }
}

struct StageDisplayView: View {
    @EnvironmentObject var stage: StageModel
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var tele: Telemetry
    @EnvironmentObject var present: PresentModel
    @State private var now = Date()
    @State private var blink = false
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { g in
            let s = max(0.5, g.size.height / 1080)
            let target = present.currentTarget()
            let current = target?.textCleared == true ? "" : (target?.content.body ?? "")
            let next: String = {
                let i = present.liveSlideIndex + 1
                return present.liveSlides.indices.contains(i) ? present.liveSlides[i].body : ""
            }()
            VStack(spacing: 18 * s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(now.formatted(date: .omitted, time: .shortened)).font(.system(size: 70 * s, weight: .bold)).foregroundColor(.white)
                    Spacer()
                    if engine.isRecording || engine.isStreaming {
                        HStack(spacing: 10 * s) {
                            Circle().fill(Color.red).frame(width: 22 * s, height: 22 * s).opacity(blink ? 1 : 0.35)
                            Text(engine.isStreaming ? "LIVE" : "REC").font(.system(size: 44 * s, weight: .heavy)).foregroundColor(.red)
                            Text(String(format: "%02d:%02d:%02d", tele.recordSeconds / 3600, tele.recordSeconds / 60 % 60, tele.recordSeconds % 60))
                                .font(.system(size: 44 * s, weight: .semibold).monospacedDigit()).foregroundColor(.white.opacity(0.85))
                        }
                    }
                    Spacer()
                    if stage.timerRunning || stage.timerRemaining > 0 {
                        let r = Int(stage.timerRemaining)
                        Text((r < 0 ? "-" : "") + String(format: "%d:%02d", abs(r) / 60, abs(r) % 60))
                            .font(.system(size: 70 * s, weight: .bold).monospacedDigit())
                            .foregroundColor(r < 0 ? .red : (r < 300 ? .orange : .green))
                    }
                }
                if !stage.message.isEmpty {
                    Text(stage.message).font(.system(size: 62 * s, weight: .bold)).foregroundColor(.black)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(18 * s)
                        .background(RoundedRectangle(cornerRadius: 16 * s).fill(Color.yellow.opacity(stage.flashMessage && blink ? 0.55 : 1)))
                }
                Text(current.isEmpty ? " " : current)
                    .font(.system(size: 76 * s, weight: .semibold)).foregroundColor(.white)
                    .multilineTextAlignment(.center).minimumScaleFactor(0.3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if stage.showNext && !next.isEmpty {
                    VStack(spacing: 4 * s) {
                        Text("NEXT").font(.system(size: 26 * s, weight: .heavy)).kerning(3).foregroundColor(.gray)
                        Text(next).font(.system(size: 42 * s)).foregroundColor(Color(white: 0.65)).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.4)
                    }
                    .frame(maxWidth: .infinity).padding(14 * s)
                    .background(RoundedRectangle(cornerRadius: 12 * s).fill(Color(white: 0.1)))
                }
                if stage.showProgramName {
                    Text("ON SCREEN: " + (engine.sources.first { $0.id == engine.programID }?.name ?? "—"))
                        .font(.system(size: 30 * s, weight: .semibold)).foregroundColor(.gray)
                }
            }
            .padding(40 * s)
            .frame(width: g.size.width, height: g.size.height)
            .background(Color.black)
        }
        .onReceive(tick) { d in now = d; blink.toggle() }
    }
}

/// Outputs-panel card that controls the stage display.
struct StageDisplayCard: View {
    @EnvironmentObject var stage: StageModel
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @State private var draft = ""

    var body: some View {
        CPCard(title: "Stage display", subtitle: stage.windowOpen ? "Open" : "Confidence monitor for speakers and singers", icon: "person.wave.2",
               iconColor: stage.windowOpen ? DS.ok : CP.icon) {
            CPRow(icon: "display", label: "Show on") {
                Menu(stage.windowOpen ? "Move / reopen" : "Open") {
                    ForEach(engine.availableScreens(), id: \.index) { sc in
                        Button(sc.name) { stage.open(on: sc.index, engine: engine, present: present) }
                    }
                    if stage.windowOpen { Divider(); Button("Close") { stage.close() } }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            CPToggleRow(label: "Show next slide", isOn: $stage.showNext)
            CPToggleRow(label: "Show what is on Program", isOn: $stage.showProgramName, showDivider: true)
            HStack(spacing: 6) {
                TextField("Message to stage — e.g. 5 minutes left", text: $draft).dsField().onSubmit { stage.message = draft }
                CPButton(title: "Send", prominent: true) { stage.message = draft }
                CPButton(title: "Clear") { stage.message = ""; draft = "" }
            }
            .padding(.vertical, 6)
            CPToggleRow(label: "Flash the message", isOn: $stage.flashMessage, showDivider: true)
            ParamSlider(label: "Timer minutes", value: $stage.timerMinutes, range: 1...120, defaultValue: 30, format: "%.0f")
            HStack(spacing: 6) {
                CPButton(icon: stage.timerRunning ? "pause.fill" : "play.fill", title: stage.timerRunning ? "Pause" : "Start", prominent: true) {
                    stage.timerRunning ? stage.pauseTimer() : stage.startTimer()
                }
                CPButton(icon: "arrow.counterclockwise", title: "Reset") { stage.resetTimer() }
                Spacer()
                let r = Int(stage.timerRemaining)
                Text((r < 0 ? "-" : "") + String(format: "%d:%02d", abs(r) / 60, abs(r) % 60)).font(DS.mono(12)).foregroundColor(r < 0 ? DS.program : CP.text)
            }
            .padding(.vertical, 6)
            CPNote("Shows the clock, the words on screen, the next slide, REC/LIVE time, your message and a countdown. With one screen it opens in a window.")
        }
    }
}
