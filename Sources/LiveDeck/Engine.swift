import Foundation
import AVFoundation
import AppKit
import CoreMedia
import Combine
import UniformTypeIdentifiers

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

    @Published var transition: TransitionType = .fade
    @Published var transitionDuration: Double = 0.6
    @Published var tbar: Double = 0          // manual T-bar 0...1
    @Published var ftbOn = false

    @Published var isRecording = false
    @Published var recordSeconds = 0
    @Published var lastRecordingURL: URL?

    @Published var audioDevices: [AudioDeviceInfo] = []
    @Published var selectedAudioDeviceID: String?
    @Published var audioLevel: Float = 0
    @Published var fps: Int = 0
    @Published var fpsTarget = 30
    @Published var showSafeGuides = false

    // Recording settings
    @Published var recCodec: RecCodec = .h264 { didSet { persistSettings() } }
    @Published var recContainer = "MP4" { didSet { persistSettings() } }
    @Published var recBitrateMbps = 8 { didSet { persistSettings() } }

    // Input bus tile size
    @Published var inputTileScale: Double = 1.0 { didSet { persistSettings() } }

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
    @Published var clockText = "--:--:--"
    @Published var fileOutputActive = false
    @Published var programWindowActive = false
    @Published var rightTab = 0   // 0 = Audio Mixer, 1 = Overlays

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
    private var screenWindows: [Int: NSWindow] = [:]
    @Published var activeScreens: Set<Int> = []

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let audioCapture = AudioCapture()
    private var recordTimer: Timer?
    private var meterTimer: Timer?
    private var outputWindow: NSWindow?

    // MARK: lifecycle

    func start() {
        guard timer == nil else { return }
        loadSettings()
        audioDevices = AudioCapture.availableDevices()
        lastFrameTime = CACurrentMediaTime(); fpsClock = lastFrameTime
        let t = Timer(timeInterval: 1.0 / Double(fpsTarget), repeats: true) { [weak self] _ in self?.renderFrame() }
        t.tolerance = 0.005
        RunLoop.main.add(t, forMode: .common)
        timer = t
        audioCapture.onSampleBuffer = { [weak self] sb in
            guard let self, self.isRecording, let input = self.audioInput, input.isReadyForMoreMediaData else { return }
            input.append(sb)
        }
        audioCapture.start(deviceID: selectedAudioDeviceID)
        // Publish meter levels at a steady ~12 Hz (NOT per audio buffer) to keep the UI responsive.
        let mt = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in self?.publishMeters() }
        mt.tolerance = 0.02
        RunLoop.main.add(mt, forMode: .common)
        meterTimer = mt
        if sources.isEmpty { for _ in 0..<5 { sources.append(EmptySource()) } }
        loadStreams()
    }

    private func publishMeters() {
        let m = audioCapture.currentLevel
        if abs(m - audioLevel) > 0.01 { audioLevel = m }
        for s in sources {
            let lvl = s.meter.currentLevel
            if abs(lvl - s.level) > 0.01 { s.level = lvl }
        }
    }

    @Published var playlistEnabled = false { didSet { applyPlaylistMode() } }

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

    func setAudioDevice(_ id: String?) { selectedAudioDeviceID = id; audioCapture.start(deviceID: id) }
    func addConsumer(_ v: FrameNSView) { consumers.add(v) }
    func addPreviewConsumer(_ v: FrameNSView) { previewConsumers.add(v) }

    private func persistSettings() {
        let d = UserDefaults.standard
        d.set(recCodec.rawValue, forKey: "recCodec")
        d.set(recContainer, forKey: "recContainer")
        d.set(recBitrateMbps, forKey: "recBitrate")
        d.set(fpsTarget, forKey: "fpsTarget")
        d.set(width, forKey: "rwidth"); d.set(height, forKey: "rheight")
        d.set(inputTileScale, forKey: "tileScale")
    }
    private func loadSettings() {
        let d = UserDefaults.standard
        if let c = d.string(forKey: "recCodec"), let rc = RecCodec(rawValue: c) { recCodec = rc }
        if let cont = d.string(forKey: "recContainer") { recContainer = cont }
        let br = d.integer(forKey: "recBitrate"); if br > 0 { recBitrateMbps = br }
        let f = d.integer(forKey: "fpsTarget"); if f > 0 { fpsTarget = f }
        let w = d.integer(forKey: "rwidth"), h = d.integer(forKey: "rheight"); if w > 0 && h > 0 { width = w; height = h }
        let ts = d.double(forKey: "tileScale"); if ts > 0 { inputTileScale = ts }
        outputFolderPath = d.string(forKey: "outputFolder")
    }

    /// Create the right kind of source for a dropped file and place it.
    func addDroppedFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let video = ["mov", "mp4", "m4v", "mpeg", "mpg", "ts", "avi", "wmv", "mkv", "mxf"]
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
    func setResolution(width: Int, height: Int) { guard !isRecording else { return }; self.width = width; self.height = height; persistSettings() }

    func setFrameRate(_ f: Int) {
        guard !isRecording, f != fpsTarget else { return }
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

    private func stageFirst(_ id: UUID) {
        if programID == nil { programID = id }
        else if previewID == nil { previewID = id }
        else { previewID = id }
    }

    func removeSource(_ id: UUID) {
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
    }

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
    }

    // MARK: layers

    func addLayer(_ kind: Layer.Kind) { let l = Layer(kind: kind); layers.insert(l, at: 0); selectedLayerID = l.id; rightTab = 2 }
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

        if transitioning, let from = transFrom {
            drawTransition(ctx, from: from, to: previewID, t: transT, rect: full)
        } else if let p = programID, let s = sources.first(where: { $0.id == p }) {
            s.draw(in: ctx, rect: full)
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

        if let img = ctx.makeImage() { for v in consumers.allObjects { v.show(img) } }
        if isRecording, let input = videoInput, input.isReadyForMoreMediaData, let adaptor = adaptor {
            adaptor.append(pb, withPresentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }

        // ---- PREVIEW MONITOR ----
        if !previewConsumers.allObjects.isEmpty, let pv = previewID, let s = sources.first(where: { $0.id == pv }) {
            if let ctx2 = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                ctx2.setFillColor(NSColor.black.cgColor); ctx2.fill(full)
                s.draw(in: ctx2, rect: full)
                if let img = ctx2.makeImage() { for v in previewConsumers.allObjects { v.show(img) } }
            }
        }

        if let mv = multiviewConsumer, multiviewWindow?.isVisible == true,
           let grid = composeMultiview() { mv.show(grid) }

        frameCount += 1
        if now - fpsClock >= 1.0 {
            fps = frameCount; frameCount = 0; fpsClock = now
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            clockText = f.string(from: Date())
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
            let aSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                                            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            aIn.expectsMediaDataInRealTime = true
            if w.canAdd(aIn) { w.add(aIn) }
            w.startWriting(); w.startSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
            writer = w; videoInput = vIn; audioInput = aIn; adaptor = ad
            recordSeconds = 0; isRecording = true; fileOutputActive = true
            recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.recordSeconds += 1 }
        } catch { NSLog("Recording failed: \(error.localizedDescription)") }
    }

    private func stopRecording() {
        isRecording = false; fileOutputActive = false
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
        let show = ShowFile(width: width, height: height, layers: layers.map { $0.toShowLayer() })
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
        }
    }

    // MARK: windows

    func openOutputWindow() {
        if let w = outputWindow { w.makeKeyAndOrderFront(nil); return }
        let view = FrameNSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540)); addConsumer(view)
        let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 960, height: 540),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "LiveDeck — Program Out  (⌘⌃F for full screen)"; win.contentView = view
        win.collectionBehavior = [.fullScreenPrimary]; win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil); outputWindow = win; programWindowActive = true
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

    func availableScreens() -> [(index: Int, name: String)] {
        NSScreen.screens.enumerated().map { (idx, s) in
            (idx, s.localizedName.isEmpty ? "Display \(idx + 1)" : s.localizedName)
        }
    }

    func toggleScreenOutput(_ index: Int) {
        if let w = screenWindows[index] {
            w.close(); screenWindows[index] = nil; activeScreens.remove(index); return
        }
        let screens = NSScreen.screens
        guard screens.indices.contains(index) else { return }
        let screen = screens[index]
        let view = FrameNSView(frame: screen.frame)
        addConsumer(view)
        let win = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                           backing: .buffered, defer: false, screen: screen)
        win.contentView = view
        win.level = .normal
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        win.setFrame(screen.frame, display: true)
        win.makeKeyAndOrderFront(nil)
        screenWindows[index] = win
        activeScreens.insert(index)
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
        layer?.backgroundColor = NSColor.black.cgColor; layer?.contentsGravity = .resizeAspectFill
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.layer?.contents = self?.source?.currentImage()
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common); t = timer
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { t?.invalidate() }
}
