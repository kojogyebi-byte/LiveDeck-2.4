import Foundation
import AVFoundation
import AppKit
import CoreMedia
import Combine
import CoreServices
import UniformTypeIdentifiers
import PresentationKit

enum TransitionType: String, CaseIterable, Identifiable {
    case cut = "Cut", fade = "Fade", wipe = "Wipe", slide = "Slide", zoom = "Zoom"
    var id: String { rawValue }
}

enum RecCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264", hevc = "HEVC (H.265)", prores422 = "ProRes 422", prores4444 = "ProRes 4444"
    var id: String { rawValue }
    var isProRes: Bool { self == .prores422 || self == .prores4444 }
    var avType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        case .prores422: return .proRes422
        case .prores4444: return .proRes4444
        }
    }
}

struct StreamDestination: Identifiable, Codable {
    var id = UUID()
    var name: String
    var platform: String   // YouTube, Facebook Live, Twitch, Custom
    var proto: String      // RTMP, RTMPS, SRT
    var url: String
    var key: String
    var enabled: Bool = true

    static let platforms = ["YouTube", "Facebook Live", "Twitch", "Custom"]
    static let protocols = ["RTMP", "RTMPS", "SRT"]

    static func preset(for platform: String) -> (proto: String, url: String) {
        switch platform {
        case "YouTube":       return ("RTMP",  "rtmp://a.rtmp.youtube.com/live2")
        case "Facebook Live": return ("RTMPS", "rtmps://live-api-s.facebook.com:443/rtmp/")
        case "Twitch":        return ("RTMP",  "rtmp://live.twitch.tv/app")
        default:              return ("RTMP",  "")
        }
    }
    var composedURL: String { key.isEmpty ? url : (url.hasSuffix("/") ? url + key : url + "/" + key) }
}

enum ProgramLayout: Int, CaseIterable, Identifiable {
    case single, sideBySide, topBottom, pip, quad, grid
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .single: return "Single"
        case .sideBySide: return "Side by side"
        case .topBottom: return "Top / bottom"
        case .pip: return "Picture-in-picture"
        case .quad: return "Quad (4-up)"
        case .grid: return "Grid (up to 10)"
        }
    }
    var fixedSlots: Int {
        switch self {
        case .single: return 1
        case .sideBySide, .topBottom, .pip: return 2
        case .quad: return 4
        case .grid: return 0
        }
    }
}

struct ProgramScene: Identifiable {
    let id = UUID()
    var name: String
    var layout: ProgramLayout
    var slots: [UUID?]
    var gridCount: Int = 4
}

final class Telemetry: ObservableObject {
    @Published var fps: Int = 0
    @Published var clock: String = "--:--:--"
    @Published var master: Float = 0
    @Published var masterL: Float = 0
    @Published var masterR: Float = 0
    @Published var levels: [UUID: Float] = [:]
    @Published var levelsL: [UUID: Float] = [:]
    @Published var levelsR: [UUID: Float] = [:]
}

final class Engine: ObservableObject {
    @Published var width = 1280
    @Published var height = 720

    @Published var sources: [Source] = []
    @Published var layers: [Layer] = []
    @Published var selectedLayerID: UUID?
    @Published var selectedSourceID: UUID?

    // vMix-style Preview / Program buses
    @Published var previewID: UUID?
    @Published var programID: UUID?
    @Published var programLayout: ProgramLayout = .single
    @Published var layoutSlots: [UUID?] = Array(repeating: nil, count: 10)
    @Published var gridCount = 4
    @Published var scenes: [ProgramScene] = []

    @Published var transition: TransitionType = .fade
    @Published var transitionDuration: Double = 0.6
    @Published var tbar: Double = 0          // manual T-bar 0...1
    @Published var ftbOn = false

    @Published var isRecording = false
    @Published var recordSeconds = 0
    @Published var lastRecordingURL: URL?

    @Published var audioDevices: [AudioDeviceInfo] = []
    @Published var selectedAudioDeviceID: String?
    @Published var fpsTarget = 30
    @Published var showSafeGuides = false

    // Recording settings
    @Published var recCodec: RecCodec = .h264 { didSet { persistSettings() } }
    @Published var recContainer = "MP4" { didSet { persistSettings() } }
    @Published var recBitrateMbps = 8 { didSet { persistSettings() } }

    // Input bus tile size
    @Published var inputTileScale: Double = 1.0 { didSet { persistSettings() } }
    @Published var mixInputsIntoRecording = false { didSet { persistSettings() } }
    @Published var showHotkeys = false
    @Published var showHelp = false
    @Published var helpQuery = ""
    static let defaultHotkeys: [String: String] = [
        "take": "Return", "cut": "C", "ftb": "B", "record": "R", "snapshot": "S", "stream": "L"
    ]
    @Published var hotkeys: [String: String] = Engine.loadHotkeys() { didSet { UserDefaults.standard.set(hotkeys, forKey: "hotkeys") } }
    static func loadHotkeys() -> [String: String] {
        var m = defaultHotkeys
        if let d = UserDefaults.standard.dictionary(forKey: "hotkeys") as? [String: String] { for (k, v) in d { m[k] = v } }
        return m
    }
    /// The real program audio engine (mixing, monitoring, meters, recording & stream audio).
    let audio = ProgramAudioEngine()
    @Published var monitorLevelDB: Double = 0 { didSet { UserDefaults.standard.set(monitorLevelDB, forKey: "audio.monitorDB") } }
    /// Microphones are kept out of the Mac's speakers unless this is on (prevents feedback). Recording/stream always include them.
    @Published var hearLiveInputs = false { didSet { UserDefaults.standard.set(hearLiveInputs, forKey: "audio.hearLive") } }
    @Published var audioStatus = ""
    private let audioWriterLock = NSLock()
    private var liveAudioWriterInput: AVAssetWriterInput?
    private let audioWriteQueue = DispatchQueue(label: "livedeck.audio.write", qos: .userInitiated)
    private var audioSyncTimer: Timer?
    let masterBus = Source(name: "Master Bus", kindLabel: "MASTER")
    let masterInputID = UUID()

    func effectSnapshot(_ s: Source) -> EffectSnapshot {
        EffectSnapshot(
            enabled: s.fxEnabled,
            hpf: s.eqHPF, lowGain: s.eqLowGain, p1f: s.eqP1Freq, p1g: s.eqP1Gain, p1q: s.eqP1Q,
            p2f: s.eqP2Freq, p2g: s.eqP2Gain, p2q: s.eqP2Q, highGain: s.eqHighGain, lpf: s.eqLPF,
            gThresh: s.gateThreshold, gRange: s.gateRange, gAtt: s.gateAttack, gHold: s.gateHold, gRel: s.gateRelease,
            cThresh: s.compThreshold, cRatio: s.compRatio, cAtt: s.compAttack, cRel: s.compRelease, cMakeup: s.compMakeup)
    }

    // Output folder
    @Published var outputFolderPath: String? { didSet { UserDefaults.standard.set(outputFolderPath, forKey: "outputFolder") } }
    var outputFolder: URL {
        if let p = outputFolderPath { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { [weak self] resp in if resp == .OK, let url = panel.url { self?.outputFolderPath = url.path } }
    }
    func revealLastRecording() { if let u = lastRecordingURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    let telemetry = Telemetry()
    let sysMon = SystemMonitor()
    let streamer = StreamOutput()
    @Published var isStreaming = false
    @Published var streamError = ""
    /// 3.17: send the mixed program audio to the stream (off = silent track, the 3.12–3.16 behaviour).
    @Published var streamAudio = true { didSet { persistSettings() } }
    @Published var streamBitrateKbps = 4500 { didSet { persistSettings() } }
    static let streamBitrates = [2500, 3500, 4500, 6000, 8000, 12000]
    @Published var fileOutputActive = false
    @Published var programWindowActive = false
    /// Program Out is currently full screen (false = in a normal window).
    @Published var programOutFullscreen = false
    /// Right control panel size: 0 free · 1 narrow · 2 half · 3 wide
    @Published var rightPanelSize: Int = UserDefaults.standard.integer(forKey: "ui.rightPanelSize") {
        didSet { UserDefaults.standard.set(rightPanelSize, forKey: "ui.rightPanelSize") }
    }
    /// Inputs keyed over the PREVIEW monitor (they join Program keys on the next CUT/AUTO).
    @Published var previewKeys: Set<UUID> = []
    @Published var rightTab = 0   // 0 Audio · 1 Input · 2 Overlays · 3 Scenes · 4 Outputs
    /// Slide / dictionary inputs keyed (transparent overlay) over Program, independent of the switcher.
    @Published var keyedSources: Set<UUID> = []
    private var keyAlpha: [UUID: Double] = [:]

    @Published var streamDestinations: [StreamDestination] = [] { didSet { persistStreams() } }

    func loadStreams() {
        if let data = UserDefaults.standard.data(forKey: "streamDestinations"),
           let list = try? JSONDecoder().decode([StreamDestination].self, from: data) {
            streamDestinations = list
        }
    }
    private func persistStreams() {
        if let data = try? JSONEncoder().encode(streamDestinations) {
            UserDefaults.standard.set(data, forKey: "streamDestinations")
        }
    }
    func addStreamDestination() {
        let p = StreamDestination.preset(for: "Custom")
        streamDestinations.append(StreamDestination(name: "New destination", platform: "Custom",
                                                    proto: p.proto, url: p.url, key: ""))
    }
    func removeStreamDestination(_ id: UUID) { streamDestinations.removeAll { $0.id == id } }

    var ffmpegAvailable: Bool { streamer.available }
    var ytdlpAvailable: Bool { StreamOutput.ytdlpPath() != nil }

    /// Destinations "Go Live" sends to: the given one, else every enabled one (simulcast).
    var liveDestinations: [StreamDestination] {
        streamDestinations.filter { $0.enabled && !$0.composedURL.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func toggleStream(_ dest: StreamDestination?) {
        if isStreaming { stopStream(); return }
        let targets: [StreamDestination] = dest.map { [$0] } ?? liveDestinations
        guard !targets.isEmpty else { streamError = "Add (and enable) a stream destination first."; return }
        guard streamer.available else { streamError = "ffmpeg not found. Install it (brew install ffmpeg)."; return }
        streamer.onUnexpectedExit = { [weak self] msg in
            guard let self else { return }
            self.streamError = msg
            self.isStreaming = false
        }
        let ok = streamer.start(urls: targets.map { $0.composedURL }, width: width, height: height,
                                fps: fpsTarget, bitrateKbps: streamBitrateKbps, audio: streamAudio)
        streamError = ok ? "" : streamer.lastError
        isStreaming = streamer.isStreaming
    }
    func stopStream() { streamer.stop(); isStreaming = false }

    private var transFrom: UUID?
    private var transitioning = false
    private var manualActive = false
    private var transT: Double = 1

    private var fade: Double = 1
    private var timer: Timer?
    private var lastFrameTime: CFTimeInterval = 0
    private var frameCount = 0
    private var fpsClock: CFTimeInterval = 0
    private var ftbT: Double = 0

    private var consumers = NSHashTable<FrameNSView>.weakObjects()
    private var previewConsumers = NSHashTable<FrameNSView>.weakObjects()
    private var multiviewConsumer: FrameNSView?
    private var multiviewWindow: NSWindow?
    private var screenWindows: [Int: OutputWindow] = [:]
    @Published var screenFullscreen: [Int: Bool] = [:]
    @Published var activeScreens: Set<Int> = []
    @Published var screenSource: [Int: UUID] = [:]
    private var screenViews: [Int: FrameNSView] = [:]

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordTimer: Timer?
    private var meterTimer: Timer?
    private var outputWindow: OutputWindow?

    // MARK: lifecycle

    func start() {
        guard timer == nil else { return }
        loadSettings()
        sysMon.start()
        audioDevices = AudioCapture.availableDevices()
        lastFrameTime = CACurrentMediaTime(); fpsClock = lastFrameTime
        let t = Timer(timeInterval: 1.0 / Double(fpsTarget), repeats: true) { [weak self] _ in self?.renderFrame() }
        t.tolerance = 0.005
        RunLoop.main.add(t, forMode: .common)
        timer = t
        startAudio()
        // Publish meter levels at a steady ~12 Hz (NOT per audio buffer) to keep the UI responsive.
        let mt = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.publishMeters() }
        mt.tolerance = 0.02
        RunLoop.main.add(mt, forMode: .common)
        meterTimer = mt
        if sources.isEmpty { for _ in 0..<8 { sources.append(EmptySource()) } }
        loadStreams()
    }

    // MARK: program audio

    private func startAudio() {
        if let v = UserDefaults.standard.object(forKey: "audio.monitorDB") as? Double { monitorLevelDB = v }
        hearLiveInputs = UserDefaults.standard.bool(forKey: "audio.hearLive")
        audio.programSink = { [weak self] l, r, n, time in self?.consumeProgramAudio(l, r, n, time) }
        audio.start()
        audioStatus = audio.lastError
        syncAudio()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.syncAudio() }
        t.tolerance = 0.03
        RunLoop.main.add(t, forMode: .common)
        audioSyncTimer = t
    }

    /// Keeps the mixer's channels in step with the inputs (devices, media taps, faders, mute, AFV, pan, solo, FX).
    private func syncAudio() {
        var keep = Set<UUID>()
        let anyOnAir = { (id: UUID) -> Bool in self.isOnAir(id) }
        for s in sources where !s.isPlaceholder {
            let file = s as? FileSource
            let audioFile = s as? AudioFileSource
            guard file != nil || audioFile != nil || s.audioDeviceID != nil else { continue }
            keep.insert(s.id)
            let c = audio.channel(s.id)
            audio.setDevice(s.audioDeviceID, for: c)
            if let f = file, let item = f.audioItem {
                audio.attachMedia(item, to: c) { [weak f] ok in f?.audioRouted = ok }
            }
            if let a = audioFile, let item = a.audioItem {
                audio.attachMedia(item, to: c) { [weak a] ok in a?.audioRouted = ok }
            }
            var p = ChannelParams()
            p.fader = Float(min(4, s.channelGain))
            let off = s.muted || !s.sendToMain || (s.audioFollowsVideo && !anyOnAir(s.id))
            p.on = off ? 0 : 1
            let pg = AudioMath.panGains(s.pan)
            p.panL = Float(pg.left); p.panR = Float(pg.right)
            p.solo = s.solo
            p.fx = effectSnapshot(s)
            audio.update(c, p)
        }
        if let md = selectedAudioDeviceID {
            keep.insert(masterInputID)
            let c = audio.channel(masterInputID)
            audio.setDevice(md, for: c)
            audio.update(c, ChannelParams())
        }
        audio.removeChannels(notIn: keep)
        audio.masterGain = masterBus.muted ? 0 : Float(min(4, masterBus.channelGain))
        audio.masterFX = effectSnapshot(masterBus)
        audio.monitorGain = Float(AudioMath.dbToGain(monitorLevelDB))
        audio.hearLiveInputs = hearLiveInputs
        if audioStatus != audio.lastError { audioStatus = audio.lastError }
    }

    /// Render thread: program mix → stream FIFO and recording file.
    private func consumeProgramAudio(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int, _ time: CMTime) {
        streamer.pushStereo(l, r, n)
        audioWriterLock.lock()
        let input = liveAudioWriterInput
        audioWriterLock.unlock()
        guard let input else { return }
        var data = Data(count: n * 2 * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<n { p[i * 2] = l[i]; p[i * 2 + 1] = r[i] }
        }
        audioWriteQueue.async {
            guard input.isReadyForMoreMediaData, let sb = PCMSampleBuffer.make(interleaved: data, frames: n, time: time) else { return }
            input.append(sb)
        }
    }

    private var meterL: [UUID: Float] = [:]
    private var meterR: [UUID: Float] = [:]
    private var meterML: Float = 0
    private var meterMR: Float = 0

    private func publishMeters() {
        if isStreaming != streamer.isStreaming { isStreaming = streamer.isStreaming }
        let m = audio.takeMeters()
        let decay: Float = 0.82
        var newL: [UUID: Float] = [:], newR: [UUID: Float] = [:], newMax: [UUID: Float] = [:]
        for s in sources {
            let peak = m.channels[s.id] ?? (0, 0)
            let l = max(min(1, peak.0), (meterL[s.id] ?? 0) * decay)
            let r = max(min(1, peak.1), (meterR[s.id] ?? 0) * decay)
            newL[s.id] = l < 0.0005 ? 0 : l
            newR[s.id] = r < 0.0005 ? 0 : r
            newMax[s.id] = max(newL[s.id] ?? 0, newR[s.id] ?? 0)
        }
        meterL = newL; meterR = newR
        meterML = max(min(1, m.master.0), meterML * decay)
        meterMR = max(min(1, m.master.1), meterMR * decay)
        if meterML < 0.0005 { meterML = 0 }
        if meterMR < 0.0005 { meterMR = 0 }
        let mm = max(meterML, meterMR)
        if abs(mm - telemetry.master) > 0.002 || (mm == 0 && telemetry.master != 0) {
            telemetry.master = mm; telemetry.masterL = meterML; telemetry.masterR = meterMR
        }
        func differs(_ a: [UUID: Float], _ b: [UUID: Float]) -> Bool {
            if a.count != b.count { return true }
            for (k, v) in a where abs(v - (b[k] ?? -1)) > 0.002 { return true }
            return false
        }
        if differs(newMax, telemetry.levels) { telemetry.levels = newMax; telemetry.levelsL = newL; telemetry.levelsR = newR }
    }

    @Published var playlistEnabled = false { didSet { applyPlaylistMode() } }
    // Stream input dialog: 0 = closed, 1 = HLS/URL, 2 = RTMP/RTSP/SRT (ffmpeg), 3 = social link
    @Published var streamInputMode = 0
    @Published var editStreamID: UUID?
    @Published var editStreamURL = ""

    func openAddStream(_ mode: Int) { editStreamID = nil; editStreamURL = ""; streamInputMode = mode }
    func openEditStream(_ id: UUID) {
        guard let s = sources.first(where: { $0.id == id }) else { return }
        editStreamID = id; editStreamURL = s.sourceURLString ?? ""
        streamInputMode = (s is WebSource) ? 4 : ((s is FFmpegStreamSource) ? 2 : 1)
    }

    /// Create/replace a network input from the dialog.
    func commitStream(url: String, mode: Int, peakMbps: Double) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let src: Source
        if mode == 4 {
            src = WebSource(url: trimmed)
        } else if mode == 2 || mode == 3 {
            src = FFmpegStreamSource(url: trimmed)
        } else {
            guard let u = URL(string: trimmed), let sc = u.scheme,
                  ["http", "https"].contains(sc.lowercased()) else { return }
            let f = FileSource(url: u, displayName: u.host ?? "Stream", label: "STREAM", startLooping: false, autoplay: true)
            if peakMbps > 0 { f.setPeakBitrate(peakMbps * 1_000_000) }
            src = f
        }
        if let eid = editStreamID, sources.contains(where: { $0.id == eid }) {
            replaceSource(eid, with: src)
        } else {
            placeSource(src)
        }
        editStreamID = nil; streamInputMode = 0
    }

    /// Add an HLS/HTTP network stream as an input (AVFoundation-supported URLs).
    func addNetworkStream(_ urlString: String) { commitStream(url: urlString, mode: 1, peakMbps: 0) }

    /// Replace a slot (e.g. a blank placeholder) with a real source in place.
    func replaceSource(_ oldID: UUID, with new: Source) {
        guard let idx = sources.firstIndex(where: { $0.id == oldID }) else { return }
        sources[idx].stop()
        sources[idx] = new
        if programID == oldID { programID = new.id }
        if previewID == oldID { previewID = new.id }
        if transFrom == oldID { transFrom = new.id }
        if selectedSourceID == oldID { selectedSourceID = new.id }
        if programID == nil { programID = new.id }
        else if previewID == nil { previewID = new.id }
        selectedSourceID = new.id
        wireMedia(new)
    }

    func addBlankInput() { sources.append(EmptySource()) }

    // MARK: slide inputs (presentation / dictionary)

    /// Places a source in the first empty holder (or appends) — public entry for panels.
    func placeInput(_ src: Source) { placeSource(src) }

    @discardableResult
    func addPresentationInput(name: String = "Presentation") -> PresentationSource {
        let n = sources.filter { $0 is PresentationSource }.count
        let s = PresentationSource(name: n == 0 ? name : "\(name) \(n + 1)")
        placeSource(s)
        return s
    }

    @discardableResult
    func addAIInput() -> AISource {
        let n = sources.filter { $0 is AISource }.count
        let s = AISource(name: n == 0 ? "AI Search" : "AI Search \(n + 1)")
        placeSource(s)
        return s
    }

    func addDictionaryInput() -> DictionarySource {
        let n = sources.filter { $0 is DictionarySource }.count
        let s = DictionarySource(name: n == 0 ? "Dictionary" : "Dictionary \(n + 1)")
        placeSource(s)
        return s
    }

    /// Replaces every input at once (preset recall). Old inputs are stopped; Program/Preview are cleared.
    func replaceAllSources(_ new: [Source]) {
        for s in sources { s.stop() }
        keyedSources.removeAll(); keyAlpha.removeAll(); previewKeys.removeAll()
        transitioning = false; manualActive = false; transFrom = nil; tbar = 0
        programID = nil; previewID = nil; selectedSourceID = nil
        layoutSlots = Array(repeating: nil, count: 10)
        sources = new
        if let first = new.first(where: { !$0.isPlaceholder }) { previewID = first.id }
    }

    func isKeyed(_ id: UUID) -> Bool { keyedSources.contains(id) }

    /// True when the input is visible on Program (directly, in a layout slot, or keyed).
    func isOnAir(_ id: UUID) -> Bool {
        if programID == id || keyedSources.contains(id) { return true }
        if programLayout != .single && layoutSlots.contains(where: { $0 == id }) { return true }
        return false
    }

    /// Whether a channel is currently audible in the mix (drives the mixer tally).
    func isChannelLive(_ s: Source) -> Bool {
        if s.isPlaceholder || s.muted || !s.sendToMain { return false }
        if s.audioFollowsVideo && !isOnAir(s.id) { return false }
        if sources.contains(where: { $0.solo }) && !s.solo { return false }
        return true
    }
    func toggleKey(_ id: UUID) {
        if keyedSources.contains(id) { keyedSources.remove(id) } else { keyedSources.insert(id); previewKeys.remove(id) }
    }
    func toggleKeyPreview(_ id: UUID) {
        if previewKeys.contains(id) { previewKeys.remove(id) } else { previewKeys.insert(id) }
    }
    func isPreviewKeyed(_ id: UUID) -> Bool { previewKeys.contains(id) }
    func clearProgramKeys() { keyedSources.removeAll() }
    /// CUT/AUTO take whatever is keyed on Preview to Program too.
    private func takePreviewKeys() {
        guard !previewKeys.isEmpty else { return }
        keyedSources.formUnion(previewKeys)
        previewKeys.removeAll()
    }

    func setAudioDevice(_ id: String?) { selectedAudioDeviceID = id }
    func addConsumer(_ v: FrameNSView) { consumers.add(v) }
    func addPreviewConsumer(_ v: FrameNSView) { previewConsumers.add(v) }

    private var loadingSettings = false
    private func persistSettings() {
        guard !loadingSettings else { return }   // didSet during load must not overwrite unloaded keys
        let d = UserDefaults.standard
        d.set(recCodec.rawValue, forKey: "recCodec")
        d.set(recContainer, forKey: "recContainer")
        d.set(recBitrateMbps, forKey: "recBitrate")
        d.set(fpsTarget, forKey: "fpsTarget")
        d.set(width, forKey: "rwidth"); d.set(height, forKey: "rheight")
        d.set(inputTileScale, forKey: "tileScale")
        d.set(mixInputsIntoRecording, forKey: "mixInputs")
        d.set(streamAudio, forKey: "streamAudio")
        d.set(streamBitrateKbps, forKey: "streamBitrate")
    }
    private func loadSettings() {
        loadingSettings = true
        defer { loadingSettings = false }
        let d = UserDefaults.standard
        if let c = d.string(forKey: "recCodec"), let rc = RecCodec(rawValue: c) { recCodec = rc }
        if let cont = d.string(forKey: "recContainer") { recContainer = cont }
        let br = d.integer(forKey: "recBitrate"); if br > 0 { recBitrateMbps = br }
        let f = d.integer(forKey: "fpsTarget"); if f > 0 { fpsTarget = f }
        let w = d.integer(forKey: "rwidth"), h = d.integer(forKey: "rheight"); if w > 0 && h > 0 { width = w; height = h }
        let ts = d.double(forKey: "tileScale"); if ts > 0 { inputTileScale = ts }
        mixInputsIntoRecording = d.bool(forKey: "mixInputs")
        if d.object(forKey: "streamAudio") != nil { streamAudio = d.bool(forKey: "streamAudio") }
        let sbr = d.integer(forKey: "streamBitrate"); if sbr > 0 { streamBitrateKbps = sbr }
        outputFolderPath = d.string(forKey: "outputFolder")
    }

    /// Create the right kind of source for a dropped file and place it.
    func addDroppedFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let image = ["png", "jpg", "jpeg", "heic", "heif", "gif", "bmp", "tiff", "tif", "webp"]
        let audio = ["mp3", "wav", "aac", "m4a", "aiff", "aif", "flac", "caf"]
        let src: Source
        if image.contains(ext) { src = ImageSource(url: url) }
        else if audio.contains(ext) { src = AudioFileSource(url: url) }
        else { src = FileSource(url: url) }  // video + fallback
        placeSource(src)
    }

    private func placeSource(_ src: Source) {
        if let slot = sources.first(where: { $0.isPlaceholder }) {
            replaceSource(slot.id, with: src)
        } else {
            sources.append(src)
            if programID == nil { programID = src.id } else if previewID == nil { previewID = src.id } else { previewID = src.id }
            selectedSourceID = src.id
            wireMedia(src)
        }
    }

    // MARK: playlist (auto-advance through media clips)

    private func wireMedia(_ src: Source) {
        guard src is FileSource || src is AudioFileSource else { return }
        let sid = src.id
        src.onReachedEnd = { [weak self] in
            guard let self else { return }
            if self.playlistEnabled && self.programID == sid { self.advancePlaylistFrom(sid) }
        }
        (src as? FileSource)?.loop = !playlistEnabled
        (src as? AudioFileSource)?.loop = !playlistEnabled
    }

    private func applyPlaylistMode() {
        for s in sources {
            (s as? FileSource)?.loop = !playlistEnabled
            (s as? AudioFileSource)?.loop = !playlistEnabled
        }
        if playlistEnabled, let pid = programID, let s = sources.first(where: { $0.id == pid }) {
            (s as? FileSource)?.playFromIn(); (s as? AudioFileSource)?.playFromIn()
        }
    }

    private func mediaSourcesInOrder() -> [Source] {
        sources.filter { $0 is FileSource || $0 is AudioFileSource }
    }

    private func advancePlaylistFrom(_ id: UUID) {
        let list = mediaSourcesInOrder()
        guard list.count > 1, let idx = list.firstIndex(where: { $0.id == id }) else {
            if let s = sources.first(where: { $0.id == id }) {
                (s as? FileSource)?.playFromIn(); (s as? AudioFileSource)?.playFromIn()
            }
            return
        }
        let next = list[(idx + 1) % list.count]
        previewID = next.id
        cut()
        (next as? FileSource)?.playFromIn()
        (next as? AudioFileSource)?.playFromIn()
    }
    func setResolution(width: Int, height: Int) { guard !isRecording, !isStreaming else { return }; self.width = width; self.height = height; persistSettings() }

    func setFrameRate(_ f: Int) {
        guard !isRecording, !isStreaming, f != fpsTarget else { return }
        fpsTarget = f
        persistSettings()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / Double(f), repeats: true) { [weak self] _ in self?.renderFrame() }
        t.tolerance = 0.005
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: sources

    func addCamera(_ device: AVCaptureDevice) { let s = CameraSource(device: device); sources.append(s); stageFirst(s.id) }
    func addScreen() { let s = ScreenSource(); sources.append(s); stageFirst(s.id) }
    func addFile(url: URL) { let s = FileSource(url: url); sources.append(s); stageFirst(s.id) }
    func addImage(url: URL) { let s = ImageSource(url: url); sources.append(s); stageFirst(s.id) }
    func addColor() { let s = ColorSource(); sources.append(s); stageFirst(s.id) }
    func addBars() { let s = BarsSource(); placeOrAppend(s) }

    private func placeOrAppend(_ s: Source) {
        if let slot = sources.first(where: { $0.isPlaceholder }) { replaceSource(slot.id, with: s) }
        else { sources.append(s); stageFirst(s.id) }
    }

    /// Free space (GB) on the recording volume; nil if unknown.
    func freeDiskGB() -> Double? {
        let url = outputFolder
        if let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = vals.volumeAvailableCapacityForImportantUsage {
            return Double(bytes) / 1_000_000_000
        }
        return nil
    }

    private func stageFirst(_ id: UUID) {
        if programID == nil { programID = id }
        else if previewID == nil { previewID = id }
        else { previewID = id }
    }

    func removeSource(_ id: UUID) {
        keyedSources.remove(id); keyAlpha[id] = nil; previewKeys.remove(id)
        if let s = sources.first(where: { $0.id == id }) { s.stop() }
        sources.removeAll { $0.id == id }
        if programID == id { programID = nil }
        if previewID == id { previewID = nil }
        if transFrom == id { transFrom = nil; transitioning = false }
    }

    func setPreview(_ id: UUID) { previewID = id }

    // MARK: switching / transitions

    func cut() {
        guard let p = previewID else { return }
        let old = programID; programID = p; previewID = old
        transitioning = false; manualActive = false; transT = 1; transFrom = nil
        takePreviewKeys()
    }

    // MARK: scene layouts

    func setLayout(_ l: ProgramLayout) {
        programLayout = l
        if l != .single && layoutSlots.allSatisfy({ $0 == nil }) { layoutSlots[0] = programID }
    }
    func setSlot(_ i: Int, _ id: UUID?) { if i < layoutSlots.count { layoutSlots[i] = id } }
    func slotCount(_ l: ProgramLayout) -> Int { l == .grid ? max(2, min(10, gridCount)) : l.fixedSlots }

    func layoutRects(_ l: ProgramLayout, _ f: CGRect) -> [CGRect] {
        let W = f.width, H = f.height
        switch l {
        case .single: return [f]
        case .sideBySide: return [CGRect(x: 0, y: 0, width: W / 2, height: H), CGRect(x: W / 2, y: 0, width: W / 2, height: H)]
        case .topBottom: return [CGRect(x: 0, y: H / 2, width: W, height: H / 2), CGRect(x: 0, y: 0, width: W, height: H / 2)]
        case .pip: return [f, CGRect(x: W * 0.655, y: H * 0.06, width: W * 0.30, height: H * 0.30)]
        case .quad: return [CGRect(x: 0, y: H / 2, width: W / 2, height: H / 2), CGRect(x: W / 2, y: H / 2, width: W / 2, height: H / 2),
                            CGRect(x: 0, y: 0, width: W / 2, height: H / 2), CGRect(x: W / 2, y: 0, width: W / 2, height: H / 2)]
        case .grid:
            let count = max(2, min(10, gridCount))
            let cols = Int(ceil(Double(count).squareRoot()))
            let rows = Int(ceil(Double(count) / Double(cols)))
            let cw = W / CGFloat(cols), ch = H / CGFloat(rows)
            var rects: [CGRect] = []
            for i in 0..<count {
                let r = i / cols, c = i % cols
                rects.append(CGRect(x: CGFloat(c) * cw, y: H - CGFloat(r + 1) * ch, width: cw, height: ch))
            }
            return rects
        }
    }

    private func drawProgramBase(_ ctx: CGContext, rect full: CGRect) {
        let rects = layoutRects(programLayout, full)
        for (i, r) in rects.enumerated() {
            let sid = i < layoutSlots.count ? layoutSlots[i] : nil
            if let sid, let s = sources.first(where: { $0.id == sid }) {
                ctx.saveGState(); ctx.clip(to: r); s.draw(in: ctx, rect: r); ctx.restoreGState()
            } else {
                ctx.setFillColor(NSColor(white: 0.07, alpha: 1).cgColor); ctx.fill(r)
            }
        }
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(2)
        for r in rects { ctx.stroke(r) }
    }

    func saveScene(_ name: String) {
        let nm = name.trimmingCharacters(in: .whitespaces)
        scenes.append(ProgramScene(name: nm.isEmpty ? "Scene \(scenes.count + 1)" : nm, layout: programLayout, slots: layoutSlots, gridCount: gridCount))
    }
    func recallScene(_ s: ProgramScene) { programLayout = s.layout; layoutSlots = s.slots; gridCount = s.gridCount }
    func deleteScene(_ id: UUID) { scenes.removeAll { $0.id == id } }

    func runTransition() {
        if transition == .cut { cut(); return }
        guard previewID != nil, !transitioning else { return }
        transFrom = programID; transitioning = true; manualActive = false; transT = 0
    }

    func quickTransition(_ type: TransitionType) { transition = type; runTransition() }

    func setTBar(_ v: Double) {
        if !manualActive {
            guard previewID != nil else { return }
            manualActive = true; transitioning = true; transFrom = programID
        }
        transT = v; tbar = v
        if v >= 0.999 { commitTransition(); tbar = 0 }
        else if v <= 0.001 { transitioning = false; manualActive = false; transFrom = nil }
    }

    func toggleFTB() { ftbOn.toggle() }

    private func commitTransition() {
        let incoming = previewID
        previewID = transFrom
        programID = incoming
        transFrom = nil; transitioning = false; manualActive = false; transT = 1
        takePreviewKeys()
    }

    // MARK: layers

    func addLayer(_ kind: Layer.Kind) { let l = Layer(kind: kind); layers.insert(l, at: 0); selectedLayerID = l.id; rightTab = 2 }

    /// Offline dictionary lookup via macOS Dictionary Services.
    func defineWord(_ word: String) -> String? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = CFRangeMake(0, (trimmed as NSString).length)
        guard let def = DCSCopyTextDefinition(nil, trimmed as CFString, range) else { return nil }
        let text = def.takeRetainedValue() as String
        return text.isEmpty ? nil : text
    }

    /// Create or update the dictionary overlay and put it on the wall.
    func showDefinition(word: String, definition: String) {
        let clipped = definition.count > 420 ? String(definition.prefix(420)) + "…" : definition
        if let existing = layers.first(where: { $0.kind == .definition }) {
            existing.text1 = word; existing.text2 = clipped; existing.isLive = true; selectedLayerID = existing.id
        } else {
            let l = Layer(kind: .definition); l.text1 = word; l.text2 = clipped; l.isLive = true
            layers.insert(l, at: 0); selectedLayerID = l.id
        }
        rightTab = 2
    }
    func addLayerTemplate(_ t: OverlayTemplate) { let l = t.make(); layers.insert(l, at: 0); selectedLayerID = l.id; rightTab = 2 }
    func removeLayer(_ id: UUID) { layers.removeAll { $0.id == id }; if selectedLayerID == id { selectedLayerID = nil } }
    func moveLayer(_ id: UUID, by delta: Int) {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta; guard j >= 0, j < layers.count else { return }
        layers.swapAt(i, j)
    }
    func toggleOverlay(_ index: Int) { guard layers.indices.contains(index) else { return }; layers[index].isLive.toggle() }

    // MARK: frame loop

    private func renderFrame() {
        let now = CACurrentMediaTime()
        let dt = now - lastFrameTime
        lastFrameTime = now

        // advance auto transition
        if transitioning && !manualActive {
            transT += dt / max(0.1, transitionDuration)
            if transT >= 1 { commitTransition() }
        }
        // FTB
        if ftbOn { ftbT = min(1, ftbT + dt / 0.4) } else { ftbT = max(0, ftbT - dt / 0.4) }

        // ---- PROGRAM ----
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        var pbOut: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pbOut)
        guard let pb = pbOut else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(NSColor.black.cgColor); ctx.fill(full)

        if programLayout != .single {
            drawProgramBase(ctx, rect: full)
        } else if transitioning, let from = transFrom {
            drawTransition(ctx, from: from, to: previewID, t: transT, rect: full)
        } else if let p = programID, let s = sources.first(where: { $0.id == p }) {
            s.draw(in: ctx, rect: full)
        }

        // downstream keys: slide inputs over Program (fade 0.3 s)
        if !keyedSources.isEmpty || !keyAlpha.isEmpty {
            for s in sources where keyedSources.contains(s.id) || (keyAlpha[s.id] ?? 0) > 0 {
                var a = (keyAlpha[s.id] ?? 0) + (keyedSources.contains(s.id) ? 1 : -1) * dt / 0.3
                a = max(0, min(1, a))
                if a <= 0 { keyAlpha[s.id] = nil; continue }
                keyAlpha[s.id] = a
                ctx.saveGState()
                ctx.setAlpha(CGFloat(a))
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                s.draw(in: ctx, rect: full)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }

        // overlays / layers on top of program
        for layer in layers.reversed() {
            layer.liveT += (layer.isLive ? 1 : -1) * dt / 0.45
            layer.liveT = max(0, min(1, layer.liveT))
            if layer.liveT > 0 {
                ctx.saveGState()
                // transform: offset, then scale+rotate about centre
                ctx.translateBy(x: CGFloat(layer.offsetX) * CGFloat(width),
                                y: CGFloat(layer.offsetY) * CGFloat(height))
                if layer.scaleAdj != 1 || layer.rotationAdj != 0 {
                    ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
                    if layer.rotationAdj != 0 { ctx.rotate(by: CGFloat(layer.rotationAdj) * .pi / 180) }
                    ctx.scaleBy(x: CGFloat(layer.scaleAdj), y: CGFloat(layer.scaleAdj))
                    ctx.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
                }
                let useGroup = layer.opacity < 0.999
                if useGroup { ctx.setAlpha(CGFloat(layer.opacity)); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
                LayerRenderer.render(layer, in: ctx, width: width, height: height, time: now,
                                     sourceImage: { [weak self] id in self?.sources.first(where: { $0.id == id })?.currentImage() })
                if useGroup { ctx.endTransparencyLayer() }
                ctx.restoreGState()
            }
        }
        if ftbT > 0 { ctx.setFillColor(NSColor.black.withAlphaComponent(CGFloat(ftbT)).cgColor); ctx.fill(full) }

        if let img = ctx.makeImage() {
            for v in consumers.allObjects { v.show(img) }
            // Per-display source override: send a chosen input (instead of Program) to a screen.
            if !screenSource.isEmpty {
                for (idx, sid) in screenSource {
                    guard let v = screenViews[idx], let s = sources.first(where: { $0.id == sid }),
                          let simg = imageForSource(s) else { continue }
                    v.show(simg)
                }
            }
        }
        if isRecording, let input = videoInput, input.isReadyForMoreMediaData, let adaptor = adaptor {
            adaptor.append(pb, withPresentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        if streamer.isStreaming { streamer.writeFrame(pb) }

        // ---- PREVIEW MONITOR ----
        if !previewConsumers.allObjects.isEmpty && (previewID != nil || !previewKeys.isEmpty) {
            if let ctx2 = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                ctx2.setFillColor(NSColor.black.cgColor); ctx2.fill(full)
                if let pv = previewID, let s = sources.first(where: { $0.id == pv }) { s.draw(in: ctx2, rect: full) }
                // what Program will look like after the take: Program keys stay, Preview keys join them
                for k in sources where k.id != previewID && (keyedSources.contains(k.id) || previewKeys.contains(k.id)) {
                    ctx2.saveGState()
                    ctx2.beginTransparencyLayer(auxiliaryInfo: nil)
                    k.draw(in: ctx2, rect: full)
                    ctx2.endTransparencyLayer()
                    ctx2.restoreGState()
                }
                if let img = ctx2.makeImage() { for v in previewConsumers.allObjects { v.show(img) } }
            }
        }

        if let mv = multiviewConsumer, multiviewWindow?.isVisible == true,
           let grid = composeMultiview() { mv.show(grid) }

        frameCount += 1
        if now - fpsClock >= 1.0 {
            if frameCount != telemetry.fps { telemetry.fps = frameCount }
            frameCount = 0; fpsClock = now
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            let c = f.string(from: Date())
            if c != telemetry.clock { telemetry.clock = c }
        }
    }

    private func drawTransition(_ ctx: CGContext, from: UUID?, to: UUID?, t: Double, rect: CGRect) {
        let fromS = from.flatMap { id in sources.first { $0.id == id } }
        let toS = to.flatMap { id in sources.first { $0.id == id } }
        let W = rect.width, H = rect.height
        switch transition {
        case .cut:
            (toS ?? fromS)?.draw(in: ctx, rect: rect)
        case .fade:
            fromS?.draw(in: ctx, rect: rect)
            ctx.saveGState(); ctx.setAlpha(CGFloat(t)); toS?.draw(in: ctx, rect: rect); ctx.restoreGState()
        case .wipe:
            fromS?.draw(in: ctx, rect: rect)
            toS?.draw(in: ctx, rect: CGRect(x: 0, y: 0, width: W * CGFloat(t), height: H))
        case .slide:
            fromS?.draw(in: ctx, rect: rect)
            toS?.draw(in: ctx, rect: CGRect(x: W * CGFloat(1 - t), y: 0, width: W, height: H))
        case .zoom:
            fromS?.draw(in: ctx, rect: rect)
            ctx.saveGState(); ctx.setAlpha(CGFloat(t))
            let w = W * CGFloat(t), h = H * CGFloat(t)
            toS?.draw(in: ctx, rect: CGRect(x: (W - w) / 2, y: (H - h) / 2, width: w, height: h))
            ctx.restoreGState()
        }
    }

    private func composeMultiview() -> CGImage? {
        let cells = sources; let n = max(1, cells.count)
        let cols = Int(ceil(sqrt(Double(n)))); let rows = Int(ceil(Double(n) / Double(cols)))
        let cw = 320, ch = 180; let gw = cols * cw, gh = rows * ch
        guard let ctx = CGContext(data: nil, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: gw, height: gh))
        for (i, src) in cells.enumerated() {
            let cx = (i % cols) * cw; let cy = gh - ((i / cols) + 1) * ch
            let rect = CGRect(x: cx + 4, y: cy + 4, width: cw - 8, height: ch - 8)
            src.draw(in: ctx, rect: rect)
            let onAir = programID == src.id, prev = previewID == src.id
            ctx.setStrokeColor((onAir ? NSColor.red : prev ? NSColor.systemGreen : NSColor(white: 0.25, alpha: 1)).cgColor)
            ctx.setLineWidth(onAir || prev ? 4 : 2); ctx.stroke(rect)
        }
        return ctx.makeImage()
    }

    // MARK: recording

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    private func startRecording() {
        let folder = outputFolder
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let useMOV = recCodec.isProRes || recContainer == "MOV"
        let ext = useMOV ? "mov" : "mp4"
        let fileType: AVFileType = useMOV ? .mov : .mp4
        let url = folder.appendingPathComponent("LiveDeck_\(fmt.string(from: Date())).\(ext)")
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: fileType)
            var vSettings: [String: Any] = [
                AVVideoCodecKey: recCodec.avType, AVVideoWidthKey: width, AVVideoHeightKey: height]
            if !recCodec.isProRes {
                vSettings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: recBitrateMbps * 1_000_000]
            }
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
            vIn.expectsMediaDataInRealTime = true
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            if w.canAdd(vIn) { w.add(vIn) }
            let aSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            aIn.expectsMediaDataInRealTime = true
            if w.canAdd(aIn) { w.add(aIn) }
            w.startWriting(); w.startSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
            writer = w; videoInput = vIn; audioInput = aIn; adaptor = ad
            recordSeconds = 0; isRecording = true; fileOutputActive = true
            // The program mix from the audio engine is written as it is rendered.
            audioWriterLock.lock(); liveAudioWriterInput = aIn; audioWriterLock.unlock()
            recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.recordSeconds += 1 }
        } catch { NSLog("Recording failed: \(error.localizedDescription)") }
    }

    private func stopRecording() {
        isRecording = false; fileOutputActive = false
        audioWriterLock.lock(); liveAudioWriterInput = nil; audioWriterLock.unlock()
        recordTimer?.invalidate(); recordTimer = nil
        guard let w = writer else { return }
        videoInput?.markAsFinished(); audioInput?.markAsFinished()
        let url = w.outputURL
        w.finishWriting { [weak self] in DispatchQueue.main.async {
            self?.lastRecordingURL = url; NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        writer = nil; videoInput = nil; audioInput = nil; adaptor = nil
    }

    func snapshot() {
        guard let c = consumers.allObjects.first?.layer?.contents else { return }
        let img = c as! CGImage
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = outputFolder.appendingPathComponent("LiveDeck_\(fmt.string(from: Date())).png")
        try? data.write(to: url); NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: save / load

    func saveShow() {
        func idxOf(_ slots: [UUID?]) -> [Int] {
            slots.map { id in id.flatMap { uid in sources.firstIndex(where: { $0.id == uid }) } ?? -1 }
        }
        let show = ShowFile(width: width, height: height, layers: layers.map { $0.toShowLayer() },
                            layout: programLayout.rawValue, slots: idxOf(layoutSlots), gridCount: gridCount,
                            scenes: scenes.map { ShowScene(name: $0.name, layout: $0.layout.rawValue, slots: idxOf($0.slots), gridCount: $0.gridCount) })
        guard let data = try? JSONEncoder().encode(show) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Untitled.livedeck"
        if let t = UTType(filenameExtension: "livedeck") { panel.allowedContentTypes = [t] }
        panel.begin { resp in if resp == .OK, let url = panel.url { try? data.write(to: url) } }
    }

    func loadShow() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if let t = UTType(filenameExtension: "livedeck") { panel.allowedContentTypes = [t] }
        panel.begin { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
                  let show = try? JSONDecoder().decode(ShowFile.self, from: data) else { return }
            self.setResolution(width: show.width, height: show.height)
            self.layers = show.layers.compactMap { Layer.from($0) }
            self.selectedLayerID = self.layers.first?.id
            func slotsFrom(_ idx: [Int]) -> [UUID?] {
                var s = idx.map { $0 >= 0 && $0 < self.sources.count ? self.sources[$0].id : nil }
                while s.count < 10 { s.append(nil) }
                return Array(s.prefix(10))
            }
            self.programLayout = ProgramLayout(rawValue: show.layout) ?? .single
            self.gridCount = max(2, min(10, show.gridCount))
            self.layoutSlots = slotsFrom(show.slots)
            self.scenes = show.scenes.map { ProgramScene(name: $0.name, layout: ProgramLayout(rawValue: $0.layout) ?? .single, slots: slotsFrom($0.slots), gridCount: max(2, min(10, $0.gridCount))) }
        }
    }

    // MARK: windows

    /// The display the LiveDeck controls are on.
    private var controlsScreen: NSScreen? { NSApp.mainWindow?.screen ?? NSScreen.main }
    var hasExternalDisplay: Bool { NSScreen.screens.count > 1 }

    /// PROGRAM OUT button: opens full screen on an external display when one is connected, otherwise in a
    /// normal window (so the controls never disappear). Pressing it again closes Program Out.
    func openOutputWindow() {
        if outputWindow != nil { closeOutputWindow(); return }
        showProgramOut(fullscreen: hasExternalDisplay)
    }

    func toggleProgramOutFullscreen() {
        showProgramOut(fullscreen: outputWindow == nil ? true : !programOutFullscreen)
    }

    func closeOutputWindow() {
        guard let w = outputWindow else { return }
        w.close()
    }

    /// Opens (or switches) Program Out. `screenIndex` picks the display for full screen.
    func showProgramOut(fullscreen: Bool, screenIndex: Int? = nil) {
        if let old = outputWindow {
            old.onClose = nil
            old.close()
            outputWindow = nil
            NSApp.presentationOptions = []
        }
        let screens = NSScreen.screens
        let controls = controlsScreen
        var screen: NSScreen? = nil
        if let i = screenIndex, screens.indices.contains(i) { screen = screens[i] }
        if screen == nil { screen = fullscreen ? (screens.first(where: { $0 != controls }) ?? controls) : controls }
        guard let target = screen ?? screens.first else { return }
        let win = makeOutputWindow(fullscreen: fullscreen, screen: target, title: "LiveDeck — Program Out") { [weak self] v in
            self?.addConsumer(v)
        }
        win.onEscape = { [weak self] in
            guard let self else { return }
            if self.programOutFullscreen { self.showProgramOut(fullscreen: false) } else { self.closeOutputWindow() }
        }
        win.onToggleFullscreen = { [weak self] in self?.toggleProgramOutFullscreen() }
        win.onClose = { [weak self] in
            NSApp.presentationOptions = []
            self?.outputWindow = nil
            self?.programWindowActive = false
            self?.programOutFullscreen = false
        }
        outputWindow = win
        programWindowActive = true
        programOutFullscreen = fullscreen
        win.makeKeyAndOrderFront(nil)
    }

    /// Builds an output window — borderless full screen, or a normal resizable 16:9 window.
    private func makeOutputWindow(fullscreen: Bool, screen: NSScreen, title: String, attach: (FrameNSView) -> Void) -> OutputWindow {
        let sameAsControls = screen == controlsScreen
        let win: OutputWindow
        let view: FrameNSView
        if fullscreen {
            view = FrameNSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            win = OutputWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            win.level = sameAsControls ? NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1) : .normal
            win.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
            win.setFrame(screen.frame, display: true)
            if sameAsControls { NSApp.presentationOptions = [.hideDock, .hideMenuBar] }
        } else {
            let vf = screen.visibleFrame
            let w = min(960, vf.width * 0.6), h = w * 9 / 16
            let rect = NSRect(x: vf.maxX - w - 24, y: vf.minY + 24, width: w, height: h)
            view = FrameNSView(frame: NSRect(origin: .zero, size: rect.size))
            win = OutputWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false, screen: screen)
            win.title = title
            win.contentAspectRatio = NSSize(width: 16, height: 9)
            win.minSize = NSSize(width: 320, height: 200)
            win.level = .floating
            win.collectionBehavior = [.fullScreenAuxiliary]
        }
        attach(view)
        let container = NSView(frame: view.frame)
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        if fullscreen && sameAsControls {
            let hint = NSTextField(labelWithString: "Full screen  ·  Esc or double-click: back to a window  ·  F: switch")
            hint.font = .systemFont(ofSize: 13, weight: .medium)
            hint.textColor = .white
            hint.alignment = .center
            hint.wantsLayer = true
            hint.drawsBackground = true
            hint.backgroundColor = NSColor.black.withAlphaComponent(0.65)
            hint.sizeToFit()
            hint.frame = NSRect(x: (container.bounds.width - hint.frame.width - 28) / 2, y: 40, width: hint.frame.width + 28, height: 30)
            hint.autoresizingMask = [.minXMargin, .maxXMargin]
            hint.layer?.cornerRadius = 8
            container.addSubview(hint)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.6; hint.animator().alphaValue = 0 },
                                                     completionHandler: { hint.removeFromSuperview() })
            }
        }
        win.contentView = container
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        return win
    }

    func openMultiviewWindow() {
        if let w = multiviewWindow { w.makeKeyAndOrderFront(nil); return }
        let view = FrameNSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540)); multiviewConsumer = view
        let win = NSWindow(contentRect: NSRect(x: 260, y: 160, width: 960, height: 540),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "LiveDeck — Multiview"; win.contentView = view
        win.isReleasedWhenClosed = false; win.makeKeyAndOrderFront(nil); multiviewWindow = win
    }

    // MARK: external display outputs (projectors / LED walls) — run simultaneously

    func setScreenSource(_ index: Int, _ id: UUID?) {
        if let id { screenSource[index] = id } else { screenSource.removeValue(forKey: index) }
    }

    private func imageForSource(_ s: Source) -> CGImage? {
        if let img = s.currentImage() { return img }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        s.draw(in: ctx, rect: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    func availableScreens() -> [(index: Int, name: String)] {
        NSScreen.screens.enumerated().map { (idx, s) in
            (idx, s.localizedName.isEmpty ? "Display \(idx + 1)" : s.localizedName)
        }
    }

    func toggleScreenOutput(_ index: Int) {
        if let w = screenWindows[index] { w.close(); return }
        openScreenOutput(index, fullscreen: !(NSScreen.screens.count == 1 || NSScreen.screens.indices.contains(index) && NSScreen.screens[index] == controlsScreen))
    }

    /// Display outputs on the controls' own screen open in a window; F / double-click switches to full screen,
    /// Esc returns to the window (or closes it).
    func openScreenOutput(_ index: Int, fullscreen: Bool) {
        let screens = NSScreen.screens
        guard screens.indices.contains(index) else { return }
        if let old = screenWindows[index] { old.onClose = nil; old.close(); NSApp.presentationOptions = [] }
        var viewRef: FrameNSView?
        let win = makeOutputWindow(fullscreen: fullscreen, screen: screens[index], title: "LiveDeck — \(screens[index].localizedName)") { [weak self] v in
            self?.addConsumer(v); viewRef = v
        }
        screenViews[index] = viewRef
        screenFullscreen[index] = fullscreen
        win.onToggleFullscreen = { [weak self] in
            guard let self else { return }
            self.openScreenOutput(index, fullscreen: !(self.screenFullscreen[index] ?? false))
        }
        win.onEscape = { [weak self] in
            guard let self else { return }
            if self.screenFullscreen[index] == true { self.openScreenOutput(index, fullscreen: false) } else { self.screenWindows[index]?.close() }
        }
        win.onClose = { [weak self] in
            NSApp.presentationOptions = []
            self?.screenWindows[index] = nil; self?.screenViews[index] = nil; self?.screenFullscreen[index] = nil
            self?.screenSource.removeValue(forKey: index); self?.activeScreens.remove(index)
        }
        win.makeKeyAndOrderFront(nil)
        screenWindows[index] = win
        activeScreens.insert(index)
    }
}

// MARK: - Output window (full screen or windowed)

final class OutputWindow: NSWindow {
    var onClose: (() -> Void)?
    var onEscape: (() -> Void)?
    var onToggleFullscreen: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        let ch = (event.charactersIgnoringModifiers ?? "").lowercased()
        if event.keyCode == 53 { onEscape?(); return }                                    // Esc
        if ch == "f" && event.modifierFlags.intersection([.command, .control, .option]).isEmpty { onToggleFullscreen?(); return }
        if event.modifierFlags.contains(.command) && ch == "f" { onToggleFullscreen?(); return }
        if event.modifierFlags.contains(.command) && ch == "w" { close(); return }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onToggleFullscreen?() } else { super.mouseDown(with: event) }
    }
    override func close() {
        let cb = onClose
        onClose = nil
        super.close()
        cb?()
    }
}

// MARK: - Frame display view

final class FrameNSView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor; layer?.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    func show(_ image: CGImage) { layer?.contents = image }
}

// MARK: - Per-source live thumbnail view

final class SourceThumbNSView: NSView {
    weak var source: Source?
    private var t: Timer?
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor; layer?.contentsGravity = .resizeAspect
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self, let s = self.source else { return }
            if let img = s.currentImage() {
                self.layer?.contents = img
            } else if !s.isPlaceholder {
                // Draw-only sources (colour bars, solid colour) have no currentImage — render via draw().
                let w = 320, h = 180
                if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                    s.draw(in: ctx, rect: CGRect(x: 0, y: 0, width: w, height: h))
                    self.layer?.contents = ctx.makeImage()
                }
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common); t = timer
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { t?.invalidate() }
}
