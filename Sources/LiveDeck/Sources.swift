import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreImage
import CoreMediaIO
import AppKit
import Darwin
import IOKit
import WebKit
import PresentationKit

let sharedCIContext = CIContext()

// Media inputs that expose transport controls (video & audio files)
protocol MediaPlayback: AnyObject, ObservableObject {
    var currentTime: Double { get }
    var duration: Double { get }
    var paused: Bool { get }
    var loop: Bool { get set }
    var inPoint: Double { get }
    var outPoint: Double { get }
    func togglePlay()
    func seek(to seconds: Double)
    func skip(_ delta: Double)
    func restart()
    func setIn()
    func setOut()
    func clearTrim()
    func playFromIn()
}

// MARK: - Video device discovery (webcams, capture cards, DeckLink, AJA, virtual cams)

enum VideoDevices {
    /// Opt in to CoreMediaIO DAL plug-ins so third-party hardware (Blackmagic DeckLink,
    /// AJA, OBS virtual camera, etc.) is visible through AVFoundation. Requires the
    /// vendor's macOS drivers (e.g. Blackmagic Desktop Video) to be installed.
    static func enableExternalDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    static func all() -> [AVCaptureDevice] {
        enableExternalDevices()
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .externalUnknown]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }
}

// MARK: - Base source

class Source: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @Published var name: String
    let kindLabel: String
    var isPlaceholder: Bool { false }

    @Published var muted = false
    /// Input trim in dB (console "Input" knob), applied before the fader.
    @Published var trimDB: Double = 0
    /// -100 (left) … +100 (right). Stored and recalled; audible once the mix is stereo.
    @Published var pan: Double = 0
    /// Audio-follow-video: the channel is only in the mix while the input is on Program (or keyed).
    @Published var audioFollowsVideo = false
    /// File path, URL or device id the input was created from (used by presets).
    var originLocation: String?
    /// Fader × trim, as a linear gain.
    var channelGain: Double { max(0, gain) * AudioMath.dbToGain(trimDB) }
    @Published var sendToMain = true
    @Published var gain: Double = 1.0
    @Published var solo = false

    // Called when a media clip reaches its end / out-point (used by playlist)
    var onReachedEnd: (() -> Void)?

    // Per-input audio device + live level
    @Published var audioDeviceID: String?

    // Per-input audio effects (parameters; metering is live)
    // Per-input audio effects (applied to the recorded mix when fxEnabled)
    @Published var fxEnabled = false
    // Parametric EQ
    @Published var eqHPF: Double = 0          // high-pass Hz, 0 = off
    @Published var eqLowGain: Double = 0      // low shelf dB (~120 Hz)
    @Published var eqP1Freq: Double = 300
    @Published var eqP1Gain: Double = 0
    @Published var eqP1Q: Double = 1.0
    @Published var eqP2Freq: Double = 3000
    @Published var eqP2Gain: Double = 0
    @Published var eqP2Q: Double = 1.0
    @Published var eqHighGain: Double = 0     // high shelf dB (~8 kHz)
    @Published var eqLPF: Double = 0          // low-pass Hz, 0 = off
    // Noise gate
    @Published var gateThreshold: Double = -60   // dB
    @Published var gateRange: Double = -60       // dB attenuation when closed
    @Published var gateAttack: Double = 1        // ms
    @Published var gateHold: Double = 100        // ms
    @Published var gateRelease: Double = 200     // ms
    // Compressor / limiter
    @Published var compThreshold: Double = -18   // dB
    @Published var compRatio: Double = 2         // :1
    @Published var compAttack: Double = 10       // ms
    @Published var compRelease: Double = 120     // ms
    @Published var compMakeup: Double = 0        // dB

    func applyFXPreset(_ p: FXPreset) { p.apply(self) }

    // Live input adjustments (vMix-style)
    @Published var zoom: Double = 1.0        // 1 = fit
    @Published var panX: Double = 0          // fraction of width
    @Published var panY: Double = 0          // fraction of height
    @Published var rotation: Double = 0      // degrees
    @Published var cropL: Double = 0         // 0...0.45 each edge
    @Published var cropR: Double = 0
    @Published var cropT: Double = 0
    @Published var cropB: Double = 0
    @Published var brightness: Double = 0    // -1...1  (0 = none)
    @Published var contrast: Double = 1.0    // 1 = none
    @Published var saturation: Double = 1.0  // 1 = none

    func resetAdjustments() {
        zoom = 1; panX = 0; panY = 0; rotation = 0
        cropL = 0; cropR = 0; cropT = 0; cropB = 0
        brightness = 0; contrast = 1; saturation = 1
    }

    var latestBuffer: CVPixelBuffer?
    var sourceURLString: String?
    private var cachedImage: CGImage?

    init(name: String, kindLabel: String) {
        self.name = name
        self.kindLabel = kindLabel
        super.init()
    }

    func currentImage() -> CGImage? {
        if let pb = latestBuffer {
            let ci = CIImage(cvPixelBuffer: pb)
            cachedImage = sharedCIContext.createCGImage(ci, from: ci.extent)
            latestBuffer = nil
        }
        return cachedImage
    }

    /// Color-corrected and cropped image (CI applied only when adjustments are non-default).
    func processedImage() -> CGImage? {
        guard let raw = currentImage() else { return nil }
        let needColor = brightness != 0 || contrast != 1 || saturation != 1
        let needCrop = cropL > 0 || cropR > 0 || cropT > 0 || cropB > 0
        if !needColor && !needCrop { return raw }
        var ci = CIImage(cgImage: raw)
        if needCrop {
            let e = ci.extent
            let x = e.minX + cropL * e.width
            let y = e.minY + cropB * e.height
            let w = max(2, e.width * (1 - cropL - cropR))
            let h = max(2, e.height * (1 - cropT - cropB))
            ci = ci.cropped(to: CGRect(x: x, y: y, width: w, height: h))
        }
        if needColor, let f = CIFilter(name: "CIColorControls") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(brightness, forKey: "inputBrightness")
            f.setValue(contrast, forKey: "inputContrast")
            f.setValue(saturation, forKey: "inputSaturation")
            if let out = f.outputImage { ci = out }
        }
        return sharedCIContext.createCGImage(ci, from: ci.extent) ?? raw
    }

    /// Cover-fit into a rect with live zoom / pan / rotate applied (clipped).
    func draw(in ctx: CGContext, rect: CGRect) {
        guard let img = processedImage() else { return }
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0 else { return }
        let baseScale = max(rect.width / iw, rect.height / ih) * CGFloat(max(0.05, zoom))
        let dw = iw * baseScale, dh = ih * baseScale
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: rect.midX + CGFloat(panX) * rect.width,
                        y: rect.midY + CGFloat(panY) * rect.height)
        if rotation != 0 { ctx.rotate(by: CGFloat(rotation) * .pi / 180) }
        ctx.draw(img, in: CGRect(x: -dw / 2, y: -dh / 2, width: dw, height: dh))
        ctx.restoreGState()
    }

    func draw(in ctx: CGContext, width: Int, height: Int) {
        draw(in: ctx, rect: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func stop() {}
}

// MARK: - Camera

final class CameraSource: Source, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cam.queue")

    init(device: AVCaptureDevice) {
        super.init(name: device.localizedName, kindLabel: "CAMERA")
        originLocation = device.uniqueID
        session.sessionPreset = .high
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        queue.async { [weak self] in self?.session.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            DispatchQueue.main.async { [weak self] in self?.latestBuffer = pb }
        }
    }

    override func stop() { queue.async { [session] in session.stopRunning() } }
}

// MARK: - Screen capture

final class ScreenSource: Source, SCStreamOutput {
    private var stream: SCStream?

    init() {
        super.init(name: "Screen", kindLabel: "SCREEN")
        Task { await startCapture() }
    }

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = display.width
            cfg.height = display.height
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = true
            let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screen.queue"))
            try await s.startCapture()
            self.stream = s
        } catch {
            NSLog("Screen capture failed: \(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        DispatchQueue.main.async { [weak self] in self?.latestBuffer = pb }
    }

    override func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }
}

// MARK: - Video file (loops)

final class FileSource: Source, MediaPlayback {
    /// True once the file's audio is routed through the program audio engine.
    var audioRouted = false
    var audioItem: AVPlayerItem? { player.currentItem }
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var loopObserver: NSObjectProtocol?
    private var timeObs: Any?
    private var volTimer: Timer?
    @Published var loop = true
    @Published var paused = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var inPoint: Double = 0
    @Published var outPoint: Double = 0   // 0 = clip end
    private var posterImage: CGImage?
    private var posterGen: AVAssetImageGenerator?

    /// Media files load PAUSED on their first frame (3.18); only live network streams autoplay.
    init(url: URL, displayName: String? = nil, label: String = "FILE", startLooping: Bool = true, autoplay: Bool = false) {
        let item = AVPlayerItem(url: url)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        super.init(name: displayName ?? url.lastPathComponent, kindLabel: label)
        originLocation = url.isFileURL ? url.path : url.absoluteString
        if url.scheme == "http" || url.scheme == "https" { sourceURLString = url.absoluteString }
        loop = startLooping
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in self?.endReached() }
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            self.currentTime = t.seconds.isFinite ? t.seconds : 0
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
            if self.outPoint > 0 && self.currentTime >= self.outPoint - 0.03 && !self.paused { self.endReached() }
        }
        let vt = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.player.volume = self.audioRouted ? 1 : (self.muted ? 0 : Float(min(1, self.channelGain)))
        }
        RunLoop.main.add(vt, forMode: .common); volTimer = vt
        if autoplay {
            player.play()
        } else {
            paused = true
            if url.isFileURL { loadPoster(url) }
        }
    }

    /// First frame shown in the tile / monitors while the clip is paused and hasn't played yet.
    private func loadPoster(_ url: URL) {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1920, height: 1080)
        posterGen = gen
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { [weak self] _, image, _, _, _ in
            guard let image else { return }
            DispatchQueue.main.async { self?.posterImage = image; self?.posterGen = nil }
        }
    }

    private func endReached() {
        if loop && !paused {
            player.seek(to: CMTime(seconds: inPoint, preferredTimescale: 600)); player.play()
        } else {
            player.pause(); paused = true; onReachedEnd?()
        }
    }

    func togglePlay() {
        paused.toggle()
        if paused { player.pause() } else {
            if let item = player.currentItem, item.currentTime() == item.duration { player.seek(to: CMTime(seconds: inPoint, preferredTimescale: 600)) }
            player.play()
        }
    }
    func restart() { player.seek(to: CMTime(seconds: inPoint, preferredTimescale: 600)); paused = false; player.play() }
    func seek(to seconds: Double) { player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) }
    func skip(_ delta: Double) { seek(to: min(max(0, currentTime + delta), duration > 0 ? duration : currentTime + delta)) }
    func setIn() { inPoint = currentTime; if outPoint > 0 && outPoint <= inPoint { outPoint = 0 } }
    func setOut() { outPoint = currentTime > inPoint ? currentTime : duration }
    func clearTrim() { inPoint = 0; outPoint = 0 }
    func playFromIn() { player.seek(to: CMTime(seconds: inPoint, preferredTimescale: 600)); paused = false; player.play() }
    func setPeakBitrate(_ bitsPerSecond: Double) { player.currentItem?.preferredPeakBitRate = bitsPerSecond }

    override func currentImage() -> CGImage? {
        let time = player.currentTime()
        if output.hasNewPixelBuffer(forItemTime: time),
           let pb = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            latestBuffer = pb
        }
        return super.currentImage() ?? posterImage
    }

    override func stop() {
        player.pause()
        volTimer?.invalidate()
        if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
        if let t = timeObs { player.removeTimeObserver(t) }
    }
}

// MARK: - Still image

final class ImageSource: Source {
    private let image: CGImage?

    init(url: URL) {
        let nsimg = NSImage(contentsOf: url)
        var rect = CGRect(origin: .zero, size: nsimg?.size ?? .zero)
        image = nsimg?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        super.init(name: url.lastPathComponent, kindLabel: "IMAGE")
        originLocation = url.path
    }

    override func currentImage() -> CGImage? { image }
}

// MARK: - Solid color

final class ColorSource: Source {
    @Published var color: NSColor

    init(color: NSColor = NSColor(red: 0.10, green: 0.43, blue: 0.85, alpha: 1)) {
        self.color = color
        super.init(name: "Color", kindLabel: "COLOR")
    }

    override func draw(in ctx: CGContext, rect: CGRect) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
    }
}

// MARK: - Test pattern (SMPTE-style colour bars)

final class BarsSource: Source {
    init() { super.init(name: "Test Pattern", kindLabel: "BARS") }

    override func draw(in ctx: CGContext, rect: CGRect) {
        let top: [NSColor] = [
            NSColor(white: 0.75, alpha: 1),
            NSColor(red: 0.75, green: 0.75, blue: 0.0, alpha: 1),
            NSColor(red: 0.0, green: 0.75, blue: 0.75, alpha: 1),
            NSColor(red: 0.0, green: 0.75, blue: 0.0, alpha: 1),
            NSColor(red: 0.75, green: 0.0, blue: 0.75, alpha: 1),
            NSColor(red: 0.75, green: 0.0, blue: 0.0, alpha: 1),
            NSColor(red: 0.0, green: 0.0, blue: 0.75, alpha: 1)
        ]
        let bw = rect.width / CGFloat(top.count)
        let topH = rect.height * 0.67
        for (i, c) in top.enumerated() {
            ctx.setFillColor(c.cgColor)
            ctx.fill(CGRect(x: rect.minX + CGFloat(i) * bw, y: rect.minY + rect.height - topH, width: bw + 1, height: topH))
        }
        let castle: [NSColor] = [
            NSColor(red: 0.0, green: 0.0, blue: 0.75, alpha: 1), .black,
            NSColor(red: 0.75, green: 0.0, blue: 0.75, alpha: 1), .black,
            NSColor(red: 0.0, green: 0.75, blue: 0.75, alpha: 1), .black,
            NSColor(white: 0.75, alpha: 1)
        ]
        let cbw = rect.width / CGFloat(castle.count)
        let midH = rect.height * 0.10
        for (i, c) in castle.enumerated() {
            ctx.setFillColor(c.cgColor)
            ctx.fill(CGRect(x: rect.minX + CGFloat(i) * cbw, y: rect.minY + rect.height - topH - midH, width: cbw + 1, height: midH))
        }
        let bottom: [NSColor] = [
            NSColor(red: 0.0, green: 0.13, blue: 0.30, alpha: 1),
            NSColor(white: 1.0, alpha: 1),
            NSColor(red: 0.20, green: 0.0, blue: 0.40, alpha: 1),
            .black, NSColor(white: 0.07, alpha: 1), .black, NSColor(white: 0.12, alpha: 1), .black
        ]
        let bbw = rect.width / CGFloat(bottom.count)
        let botH = rect.height - topH - midH
        for (i, c) in bottom.enumerated() {
            ctx.setFillColor(c.cgColor)
            ctx.fill(CGRect(x: rect.minX + CGFloat(i) * bbw, y: rect.minY, width: bbw + 1, height: botH))
        }
    }
}

// MARK: - Audio-only file (plays + loops; no video)

final class AudioFileSource: Source, MediaPlayback {
    var audioRouted = false
    var audioItem: AVPlayerItem? { player.currentItem }
    private let player: AVPlayer
    private var loopObserver: NSObjectProtocol?
    private var volTimer: Timer?
    private var timeObs: Any?
    @Published var loop = true
    @Published var paused = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var inPoint: Double = 0
    @Published var outPoint: Double = 0

    init(url: URL, autoplay: Bool = false) {
        player = AVPlayer(url: url)
        super.init(name: url.lastPathComponent, kindLabel: "AUDIO")
        originLocation = url.path
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in self?.endReached() }
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            self.currentTime = t.seconds.isFinite ? t.seconds : 0
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
            if self.outPoint > 0 && self.currentTime >= self.outPoint - 0.03 && !self.paused { self.endReached() }
        }
        let vt = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.player.volume = self.audioRouted ? 1 : (self.muted ? 0 : Float(min(1, self.channelGain)))
        }
        RunLoop.main.add(vt, forMode: .common); volTimer = vt
        if autoplay { player.play() } else { paused = true }
    }

    private func endReached() {
        if loop && !paused {
            player.seek(to: CMTime(seconds: inPoint, preferredTimescale: 600)); player.play()
        } else {
            player.pause(); paused = true; onReachedEnd?()
        }
    }

    func togglePlay() { paused.toggle(); if paused { player.pause() } else { player.play() } }
    func restart() { player.seek(to: CMTime(seconds: inPoint, preferredTimescale: 600)); paused = false; player.play() }
    func seek(to seconds: Double) { player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) }
    func skip(_ delta: Double) { seek(to: min(max(0, currentTime + delta), duration > 0 ? duration : currentTime + delta)) }
    func setIn() { inPoint = currentTime; if outPoint > 0 && outPoint <= inPoint { outPoint = 0 } }
    func setOut() { outPoint = currentTime > inPoint ? currentTime : duration }
    func clearTrim() { inPoint = 0; outPoint = 0 }
    func playFromIn() { player.seek(to: CMTime(seconds: inPoint, preferredTimescale: 600)); paused = false; player.play() }
    override func currentImage() -> CGImage? { nil }
    override func draw(in ctx: CGContext, rect: CGRect) {
        ctx.setFillColor(NSColor(red: 0.06, green: 0.12, blue: 0.14, alpha: 1).cgColor); ctx.fill(rect)
    }
    override func stop() {
        player.pause(); volTimer?.invalidate()
        if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
        if let t = timeObs { player.removeTimeObserver(t) }
    }
}

// MARK: - Empty placeholder slot

final class EmptySource: Source {
    override var isPlaceholder: Bool { true }
    init() { super.init(name: "Empty", kindLabel: "EMPTY") }
    override func currentImage() -> CGImage? { nil }
    override func draw(in ctx: CGContext, rect: CGRect) {
        ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor); ctx.fill(rect)
    }
}

// MARK: - Per-input audio meter

// MARK: - Audio capture (selectable device → feeds the recorder)

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "audio.queue")
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    private(set) var currentLevel: Float = 0   // read on main by the engine's meter timer
    private var smoothed: Float = 0

    static func availableDevices() -> [AudioDeviceInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio, position: .unspecified)
        return discovery.devices.map { AudioDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    func start(deviceID: String?) {
        stop()
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return }
        let s = AVCaptureSession()
        if s.canAddInput(input) { s.addInput(input) }
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: queue)
        if s.canAddOutput(out) { s.addOutput(out) }
        queue.async { s.startRunning() }
        session = s
    }

    func stop() { session?.stopRunning(); session = nil; currentLevel = 0 }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onSampleBuffer?(sampleBuffer)
        if let ch = connection.audioChannels.first {
            let lin = Float(pow(10.0, Double(ch.averagePowerLevel) / 20.0))
            smoothed = max(lin, smoothed * 0.82)
            currentLevel = min(1, max(0, smoothed))
        }
    }
}

// MARK: - NDI runtime detection (safe; no guessed ABI)
//
// The two .pkg files install the NDI *runtime* (libndi) onto this Mac. We do NOT
// link or bundle it (that needs the licensed NDI SDK and would violate redistribution
// terms). Instead we dlopen the installed runtime at launch and read its version via
// the one stable, argument-free symbol `NDIlib_version`. Actual frame-sending needs the
// SDK's exact C struct definitions (Processing.NDI.*.h) to be safe, so `sendFrame` is a
// deliberate stub until those headers are wired in.


final class NDIBridge {
    static let shared = NDIBridge()
    private(set) var isAvailable = false
    private(set) var versionString = ""
    private var handle: UnsafeMutableRawPointer?

    private typealias VersionFn = @convention(c) () -> UnsafePointer<CChar>?

    init() { detect() }

    func detect() {
        let candidates = [
            "/usr/local/lib/libndi.dylib",
            "/usr/local/lib/libndi.4.dylib",
            "/usr/local/lib/libndi.5.dylib",
            "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
            ProcessInfo.processInfo.environment["NDI_RUNTIME_DIR_V6"].map { $0 + "/libndi.dylib" } ?? "",
            ProcessInfo.processInfo.environment["NDI_RUNTIME_DIR_V5"].map { $0 + "/libndi.dylib" } ?? ""
        ].filter { !$0.isEmpty }

        for path in candidates {
            if let h = dlopen(path, RTLD_NOW) {
                handle = h
                if let sym = dlsym(h, "NDIlib_version") {
                    let fn = unsafeBitCast(sym, to: VersionFn.self)
                    if let cstr = fn() { versionString = String(cString: cstr) }
                }
                isAvailable = true
                return
            }
        }
        isAvailable = false
    }

    /// Placeholder until the NDI SDK headers are wired in. Intentionally does nothing
    /// so it can never crash the live app. Returns false to indicate "not yet active".
    func sendFrame(_ buffer: CVPixelBuffer) -> Bool { false }
}

// MARK: - Audio DSP (biquad EQ + gate + compressor) for the recorded mix

struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1: Float = 0, z2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let out = Float(b0) * x + z1
        z1 = Float(b1) * x - Float(a1) * out + z2
        z2 = Float(b2) * x - Float(a2) * out
        if out.isNaN || out.isInfinite { z1 = 0; z2 = 0; return x }
        return out
    }
    mutating func reset() { z1 = 0; z2 = 0 }

    static func peaking(_ f: Double, q: Double, gainDB: Double, sr: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * .pi * f / sr, cw = cos(w), sw = sin(w)
        let alpha = sw / (2 * max(0.1, q))
        let a0 = 1 + alpha / A
        var bq = Biquad()
        bq.b0 = (1 + alpha * A) / a0; bq.b1 = (-2 * cw) / a0; bq.b2 = (1 - alpha * A) / a0
        bq.a1 = (-2 * cw) / a0; bq.a2 = (1 - alpha / A) / a0
        return bq
    }
    static func lowShelf(_ f: Double, gainDB: Double, sr: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * .pi * f / sr, cw = cos(w), sw = sin(w)
        let alpha = sw / 2 * sqrt((A + 1 / A) * (1 / 0.9 - 1) + 2), tsa = 2 * sqrt(A) * alpha
        let a0 = (A + 1) + (A - 1) * cw + tsa
        var bq = Biquad()
        bq.b0 = A * ((A + 1) - (A - 1) * cw + tsa) / a0
        bq.b1 = 2 * A * ((A - 1) - (A + 1) * cw) / a0
        bq.b2 = A * ((A + 1) - (A - 1) * cw - tsa) / a0
        bq.a1 = -2 * ((A - 1) + (A + 1) * cw) / a0
        bq.a2 = ((A + 1) + (A - 1) * cw - tsa) / a0
        return bq
    }
    static func highShelf(_ f: Double, gainDB: Double, sr: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * .pi * f / sr, cw = cos(w), sw = sin(w)
        let alpha = sw / 2 * sqrt((A + 1 / A) * (1 / 0.9 - 1) + 2), tsa = 2 * sqrt(A) * alpha
        let a0 = (A + 1) - (A - 1) * cw + tsa
        var bq = Biquad()
        bq.b0 = A * ((A + 1) + (A - 1) * cw + tsa) / a0
        bq.b1 = -2 * A * ((A - 1) + (A + 1) * cw) / a0
        bq.b2 = A * ((A + 1) + (A - 1) * cw - tsa) / a0
        bq.a1 = 2 * ((A - 1) - (A + 1) * cw) / a0
        bq.a2 = ((A + 1) - (A - 1) * cw - tsa) / a0
        return bq
    }
    static func highpass(_ f: Double, sr: Double) -> Biquad {
        let w = 2 * .pi * f / sr, cw = cos(w), sw = sin(w), alpha = sw / (2 * 0.707)
        let a0 = 1 + alpha
        var bq = Biquad()
        bq.b0 = (1 + cw) / 2 / a0; bq.b1 = -(1 + cw) / a0; bq.b2 = (1 + cw) / 2 / a0
        bq.a1 = (-2 * cw) / a0; bq.a2 = (1 - alpha) / a0
        return bq
    }
    static func lowpass(_ f: Double, sr: Double) -> Biquad {
        let w = 2 * .pi * f / sr, cw = cos(w), sw = sin(w), alpha = sw / (2 * 0.707)
        let a0 = 1 + alpha
        var bq = Biquad()
        bq.b0 = (1 - cw) / 2 / a0; bq.b1 = (1 - cw) / a0; bq.b2 = (1 - cw) / 2 / a0
        bq.a1 = (-2 * cw) / a0; bq.a2 = (1 - alpha) / a0
        return bq
    }

    /// Magnitude response in dB at frequency f (for drawing the EQ curve).
    func magnitudeDB(_ f: Double, sr: Double) -> Double {
        let w = 2 * .pi * f / sr, cw = cos(w), c2 = cos(2 * w), sw = sin(w), s2 = sin(2 * w)
        let nRe = b0 + b1 * cw + b2 * c2, nIm = -(b1 * sw + b2 * s2)
        let dRe = 1 + a1 * cw + a2 * c2, dIm = -(a1 * sw + a2 * s2)
        let num = nRe * nRe + nIm * nIm, den = dRe * dRe + dIm * dIm
        guard den > 0 else { return 0 }
        return 10 * log10(max(1e-9, num / den))
    }
}

struct EffectSnapshot {
    var enabled = false
    var hpf = 0.0, lowGain = 0.0, p1f = 300.0, p1g = 0.0, p1q = 1.0
    var p2f = 3000.0, p2g = 0.0, p2q = 1.0, highGain = 0.0, lpf = 0.0
    var gThresh = -60.0, gRange = -60.0, gAtt = 1.0, gHold = 100.0, gRel = 200.0
    var cThresh = -18.0, cRatio = 2.0, cAtt = 10.0, cRel = 120.0, cMakeup = 0.0
}

final class AudioDSP {
    private let sr = 48000.0
    private var hpf = Biquad(), low = Biquad(), p1 = Biquad(), p2 = Biquad(), high = Biquad(), lpf = Biquad()
    private var hpfOn = false, lpfOn = false, lowOn = false, p1On = false, p2On = false, highOn = false
    private var last = EffectSnapshot()
    private var loaded = false
    // dynamics state
    private var gEnv: Float = 0, gGain: Float = 1, holdSamples = 0
    private var cGain: Float = 1

    func update(_ s: EffectSnapshot) {
        if !loaded || s.hpf != last.hpf { hpfOn = s.hpf >= 20; if hpfOn { hpf = .highpass(s.hpf, sr: sr) } }
        if !loaded || s.lpf != last.lpf { lpfOn = s.lpf >= 1000 && s.lpf < 20000; if lpfOn { lpf = .lowpass(s.lpf, sr: sr) } }
        if !loaded || s.lowGain != last.lowGain { lowOn = abs(s.lowGain) > 0.1; if lowOn { low = .lowShelf(120, gainDB: s.lowGain, sr: sr) } }
        if !loaded || s.p1g != last.p1g || s.p1f != last.p1f || s.p1q != last.p1q { p1On = abs(s.p1g) > 0.1; if p1On { p1 = .peaking(s.p1f, q: s.p1q, gainDB: s.p1g, sr: sr) } }
        if !loaded || s.p2g != last.p2g || s.p2f != last.p2f || s.p2q != last.p2q { p2On = abs(s.p2g) > 0.1; if p2On { p2 = .peaking(s.p2f, q: s.p2q, gainDB: s.p2g, sr: sr) } }
        if !loaded || s.highGain != last.highGain { highOn = abs(s.highGain) > 0.1; if highOn { high = .highShelf(8000, gainDB: s.highGain, sr: sr) } }
        last = s; loaded = true
    }

    func process(_ buf: inout [Float]) {
        let s = last
        let attCoef = Float(exp(-1.0 / (max(0.1, s.gAtt) * 0.001 * sr)))
        let relCoef = Float(exp(-1.0 / (max(1.0, s.gRel) * 0.001 * sr)))
        let cAttCoef = Float(exp(-1.0 / (max(0.1, s.cAtt) * 0.001 * sr)))
        let cRelCoef = Float(exp(-1.0 / (max(1.0, s.cRel) * 0.001 * sr)))
        let holdMax = Int(max(0, s.gHold) * 0.001 * sr)
        let gThresh = Float(pow(10, s.gThresh / 20))
        let gFloor = Float(pow(10, s.gRange / 20))    // attenuation (linear) when closed
        let cThreshLin = s.cThresh, ratio = max(1, s.cRatio), makeup = Float(pow(10, s.cMakeup / 20))

        for i in 0..<buf.count {
            var x = buf[i]
            if hpfOn { x = hpf.process(x) }
            if lowOn { x = low.process(x) }
            if p1On { x = p1.process(x) }
            if p2On { x = p2.process(x) }
            if highOn { x = high.process(x) }
            if lpfOn { x = lpf.process(x) }

            // Noise gate (envelope + hold)
            let ax = abs(x)
            if ax > gEnv { gEnv = ax } else { gEnv = ax + (gEnv - ax) * relCoef }
            let targetOpen: Bool = gEnv >= gThresh
            if targetOpen { holdSamples = holdMax; gGain += (1 - gGain) * (1 - attCoef) }
            else if holdSamples > 0 { holdSamples -= 1 }
            else { gGain += (gFloor - gGain) * (1 - relCoef) }
            x *= gGain

            // Compressor / limiter
            let db = x == 0 ? -120.0 : 20 * log10(Double(abs(x)))
            var targetGainDB = 0.0
            if db > cThreshLin { targetGainDB = (cThreshLin - db) * (1 - 1 / ratio) }
            let targetLin = Float(pow(10, targetGainDB / 20))
            if targetLin < cGain { cGain += (targetLin - cGain) * (1 - cAttCoef) }
            else { cGain += (targetLin - cGain) * (1 - cRelCoef) }
            x *= cGain * makeup

            if x > 1 { x = 1 } else if x < -1 { x = -1 }
            buf[i] = x
        }
    }
}

// MARK: - Effect presets

struct FXPreset: Identifiable {
    let id = UUID()
    let name: String
    let apply: (Source) -> Void

    static let all: [FXPreset] = [
        FXPreset(name: "Flat / Reset") { s in
            s.eqHPF = 0; s.eqLowGain = 0; s.eqP1Freq = 300; s.eqP1Gain = 0; s.eqP1Q = 1
            s.eqP2Freq = 3000; s.eqP2Gain = 0; s.eqP2Q = 1; s.eqHighGain = 0; s.eqLPF = 0
            s.gateThreshold = -80; s.gateRange = -60; s.gateAttack = 1; s.gateHold = 100; s.gateRelease = 200
            s.compThreshold = 0; s.compRatio = 1; s.compAttack = 10; s.compRelease = 120; s.compMakeup = 0
        },
        FXPreset(name: "De-hum (50/60 Hz)") { s in
            s.eqP1Freq = 60; s.eqP1Gain = -18; s.eqP1Q = 8
            s.eqP2Freq = 120; s.eqP2Gain = -12; s.eqP2Q = 8; s.eqHPF = 40
        },
        FXPreset(name: "De-rumble (HPF)") { s in s.eqHPF = 90 },
        FXPreset(name: "Cut hiss (De-hiss)") { s in s.eqLPF = 8000; s.eqHighGain = -8 },
        FXPreset(name: "De-ess") { s in s.eqP2Freq = 6500; s.eqP2Gain = -7; s.eqP2Q = 3.5 },
        FXPreset(name: "Voice clarity") { s in
            s.eqHPF = 90; s.eqP1Freq = 300; s.eqP1Gain = -3; s.eqP1Q = 1.2
            s.eqP2Freq = 3000; s.eqP2Gain = 4; s.eqP2Q = 1.0; s.eqHighGain = 2
            s.compThreshold = -18; s.compRatio = 3; s.compAttack = 8; s.compRelease = 140; s.compMakeup = 3
        },
        FXPreset(name: "Warmth") { s in s.eqLowGain = 4; s.eqHighGain = -2 },
        FXPreset(name: "Brightness") { s in s.eqP2Freq = 5000; s.eqP2Gain = 3; s.eqP2Q = 1; s.eqHighGain = 5 },
        FXPreset(name: "Compressor (gentle)") { s in
            s.compThreshold = -20; s.compRatio = 2.5; s.compAttack = 15; s.compRelease = 150; s.compMakeup = 3
        },
        FXPreset(name: "Limiter (hard)") { s in
            s.compThreshold = -6; s.compRatio = 20; s.compAttack = 1; s.compRelease = 60; s.compMakeup = 0
        },
        FXPreset(name: "Noise gate") { s in
            s.gateThreshold = -45; s.gateRange = -60; s.gateAttack = 1; s.gateHold = 120; s.gateRelease = 220
        }
    ]
}

// MARK: - System monitor (CPU / RAM via mach, GPU via IORegistry best-effort)

final class SystemMonitor: ObservableObject {
    @Published var cpu: Double = 0
    @Published var ram: Double = 0
    @Published var gpu: Double = -1     // < 0 means unavailable on this Mac
    private var timer: Timer?
    private var prevUsed: Double = 0, prevTotal: Double = 0

    func start() {
        guard timer == nil else { return }
        _ = sampleCPU()   // prime the delta baseline
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    private func sample() {
        let c = sampleCPU(); let m = sampleRAM(); let g = sampleGPU()
        DispatchQueue.main.async { self.cpu = c; self.ram = m; if let g { self.gpu = g } }
    }

    private func sampleCPU() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return cpu }
        let user = Double(info.cpu_ticks.0), sys = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2), nice = Double(info.cpu_ticks.3)
        let used = user + sys + nice, total = used + idle
        let du = used - prevUsed, dt = total - prevTotal
        prevUsed = used; prevTotal = total
        return dt > 0 ? min(100, max(0, du / dt * 100)) : cpu
    }

    private func sampleRAM() -> Double {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return ram }
        let ps = Double(vm_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * ps
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? min(100, used / total * 100) : ram
    }

    private func sampleGPU() -> Double? {
        let matching = IOServiceMatching("IOAccelerator")
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double? = nil
        var obj = IOIteratorNext(iter)
        while obj != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(obj, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any] {
                for key in ["Device Utilization %", "GPU Activity(%)", "Device Utilization",
                            "GPU Core Utilization", "Renderer Utilization %"] {
                    if let v = perf[key] as? Int { best = Double(v); break }
                    if let v = perf[key] as? NSNumber { best = v.doubleValue; break }
                }
            }
            IOObjectRelease(obj)
            obj = IOIteratorNext(iter)
        }
        return best
    }
}

// MARK: - RTMP/SRT streaming via a user-installed ffmpeg
//
// LiveDeck does not bundle ffmpeg (GPL redistribution + signing an external binary).
// It detects an ffmpeg the user installs (`brew install ffmpeg`) and feeds it:
//   • VIDEO: raw BGRA Program frames on stdin, paced by a wall-clock thread that
//     writes exactly `fps` frames per second (repeating the last frame if the
//     renderer is late) so the video timeline never drifts from real time.
//   • AUDIO (3.17): the mixed program bus as 48 kHz mono Float32 into a named pipe
//     (FIFO), paced the same way (silence is inserted if no audio arrives), so the
//     two timelines stay aligned. If audio is switched off, a silent AAC track is used.
// One enabled destination → direct flv/mpegts. Several → ffmpeg `tee` (simulcast),
// where one failing destination doesn't stop the others.

final class StreamOutput {
    private var process: Process?
    private(set) var isStreaming = false
    private(set) var lastError = ""
    private(set) var withAudio = false
    /// Called on the main thread if ffmpeg exits on its own (bad key, network drop…).
    var onUnexpectedExit: ((String) -> Void)?

    private let lock = NSLock()
    private var running = false
    private var latestFrame: Data?
    private var audioRing = [Float]()
    private var fifoPath: String?
    private var startTime: TimeInterval = 0
    private var fps: Double = 30
    private var stderrTail = ""
    private var progress = FFmpegProgress()
    private var progressReceived = false
    private var backlogFrames: Int64 = 0

    /// Live numbers for the on-air status bar.
    func statsSnapshot() -> (progress: FFmpegProgress, received: Bool, backlogSeconds: Double, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        let secs = running ? ProcessInfo.processInfo.systemUptime - startTime : 0
        return (progress, progressReceived, Double(backlogFrames) / max(1, fps), secs)
    }

    static func ffmpegPath() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }
    static func ytdlpPath() -> String? {
        let candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp",
                          "/opt/homebrew/bin/youtube-dl", "/usr/local/bin/youtube-dl"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }
    var available: Bool { StreamOutput.ffmpegPath() != nil }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    /// True while the stream wants program-audio samples.
    var acceptsAudio: Bool { lock.lock(); defer { lock.unlock() }; return running && withAudio }

    static func muxer(for url: String) -> String { url.lowercased().hasPrefix("srt://") ? "mpegts" : "flv" }

    func start(urls: [String], width: Int, height: Int, fps: Double, rate: String, interlaced: Bool, bitrateKbps: Int, audioBitrateKbps: Int = 160, audio: Bool) -> Bool {
        let targets = urls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !isStreaming else { return false }
        guard let ff = StreamOutput.ffmpegPath() else { lastError = "ffmpeg not found."; return false }
        guard !targets.isEmpty else { lastError = "Stream URL is empty."; return false }
        signal(SIGPIPE, SIG_IGN)   // a dead ffmpeg must produce a write error, not kill LiveDeck

        var args: [String] = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-progress", "pipe:1",
            "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "\(width)x\(height)",
            "-framerate", rate, "-i", "pipe:0"
        ]
        var useAudio = false
        if audio {
            let path = NSTemporaryDirectory() + "livedeck-audio-\(UUID().uuidString.prefix(8)).f32"
            unlink(path)
            if mkfifo(path, 0o600) == 0 {
                fifoPath = path; useAudio = true
                args += ["-thread_queue_size", "1024", "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", path]
            }
        }
        if !useAudio {
            args += ["-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"]
        }
        args += [
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-pix_fmt", "yuv420p",
            "-b:v", "\(bitrateKbps)k", "-maxrate", "\(bitrateKbps)k", "-bufsize", "\(bitrateKbps * 2)k",
            "-g", "\(max(2, Int((fps * 2).rounded())))", "-keyint_min", "\(max(2, Int((fps * 2).rounded())))", "-sc_threshold", "0",
            "-c:a", "aac", "-b:a", "\(max(128, audioBitrateKbps))k", "-ar", "48000", "-ac", "2"
        ]
        if interlaced {
            // woven fields, top field first
            args += ["-x264opts", "tff=1", "-field_order", "tt"]
            if targets.count == 1 { args += ["-flags", "+ildct+ilme"] }
        }
        if targets.count == 1 {
            args += ["-f", StreamOutput.muxer(for: targets[0]), targets[0]]
        } else {
            let spec = targets.map { u -> String in
                StreamOutput.muxer(for: u) == "mpegts"
                    ? "[f=mpegts:onfail=ignore:bsfs/v=dump_extra]\(u)"
                    : "[f=flv:onfail=ignore]\(u)"
            }.joined(separator: "|")
            args += ["-flags", interlaced ? "+global_header+ildct+ilme" : "+global_header", "-f", "tee", spec]
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = args
        let inPipe = Pipe(), errPipe = Pipe(), progressPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = progressPipe
        progressPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            self.lock.lock()
            self.progress.apply(s)
            self.progressReceived = true
            self.lock.unlock()
        }
        p.standardError = errPipe
        stderrTail = ""
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            self.lock.lock()
            self.stderrTail = String((self.stderrTail + s).suffix(600))
            self.lock.unlock()
        }
        p.terminationHandler = { [weak self] proc in
            // short delay so the last stderr lines (the actual error) are captured first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                errPipe.fileHandleForReading.readabilityHandler = nil
                progressPipe.fileHandleForReading.readabilityHandler = nil
                self?.processEnded(proc)
            }
        }

        lock.lock()
        running = true; withAudio = useAudio; latestFrame = nil; audioRing.removeAll()
        progress = FFmpegProgress(); progressReceived = false; backlogFrames = 0
        self.fps = fps; startTime = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        do { try p.run() } catch {
            lock.lock(); running = false; withAudio = false; lock.unlock()
            cleanupFIFO()
            lastError = error.localizedDescription
            return false
        }
        process = p; isStreaming = true; lastError = ""

        let vh = inPipe.fileHandleForWriting
        let vt = Thread { [weak self] in self?.videoLoop(vh) }
        vt.name = "livedeck.stream.video"; vt.qualityOfService = .userInteractive; vt.start()
        if useAudio, let path = fifoPath {
            let at = Thread { [weak self] in self?.audioLoop(path) }
            at.name = "livedeck.stream.audio"; at.qualityOfService = .userInteractive; at.start()
        }
        return true
    }

    /// Called from the render loop (main thread) with each Program frame.
    func writeFrame(_ pb: CVPixelBuffer) {
        guard isStreaming else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let w = CVPixelBufferGetWidth(pb), ht = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        var data = Data(count: w * 4 * ht)
        if let base = CVPixelBufferGetBaseAddress(pb) {
            data.withUnsafeMutableBytes { dst in
                guard let d = dst.baseAddress else { return }
                if bpr == w * 4 {
                    memcpy(d, base, w * 4 * ht)
                } else {
                    for row in 0..<ht { memcpy(d.advanced(by: row * w * 4), base.advanced(by: row * bpr), w * 4) }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        lock.lock(); latestFrame = data; lock.unlock()
    }

    /// Program mix from the audio engine (48 kHz stereo). Stored interleaved.
    func pushStereo(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        guard n > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard running && withAudio else { return }
        audioRing.reserveCapacity(audioRing.count + n * 2)
        for i in 0..<n { audioRing.append(l[i]); audioRing.append(r[i]) }
        // Output clock faster than wall clock → never let latency build past 0.5 s.
        if audioRing.count > 48000 { audioRing.removeFirst(audioRing.count - 9600) }
    }

    private func videoLoop(_ h: FileHandle) {
        var written: Int64 = 0
        var failed = false
        while isRunning {
            lock.lock(); let t0 = startTime, rate = fps, frame = latestFrame; lock.unlock()
            let elapsed = ProcessInfo.processInfo.systemUptime - t0
            let due = Int64(elapsed * rate) + 1
            lock.lock(); backlogFrames = max(0, due - written - 1); lock.unlock()
            if written >= due {
                Thread.sleep(forTimeInterval: max(0.001, Double(written) / rate - elapsed))
                continue
            }
            guard let frame else { Thread.sleep(forTimeInterval: 0.005); continue }
            if due - written > Int64(rate * 20) {
                failed = true
                lock.lock(); stderrTail = "Encoder/network can't keep up (20 s behind). Lower resolution, frame rate or bitrate.\n" + stderrTail; lock.unlock()
                break
            }
            do { try h.write(contentsOf: frame) } catch { failed = true; break }
            written += 1
        }
        try? h.close()
        if failed { DispatchQueue.main.async { [weak self] in self?.process?.terminate() } }
    }

    private func audioLoop(_ path: String) {
        let fd = open(path, O_WRONLY)          // blocks until ffmpeg opens the FIFO
        guard fd >= 0 else { return }
        defer { close(fd) }
        var written: Int64 = 0
        let sr = 48000.0
        while isRunning {
            lock.lock(); let t0 = startTime; lock.unlock()
            let due = Int64((ProcessInfo.processInfo.systemUptime - t0) * sr)
            let need = Int(min(due - written, 48000))
            if need < 480 { Thread.sleep(forTimeInterval: 0.004); continue }

            lock.lock()
            let take = min(need, audioRing.count / 2)                 // frames (stereo interleaved)
            // Only write real samples; insert silence only when we're >100 ms short, keeping a 50 ms cushion.
            let pad = (take < need && need > 4800) ? max(0, need - take - 2400) : 0
            var buf = [Float](repeating: 0, count: (take + pad) * 2)
            if take > 0 {
                for i in 0..<(take * 2) { buf[i] = audioRing[i] }
                audioRing.removeFirst(take * 2)
            }
            lock.unlock()
            if buf.isEmpty { Thread.sleep(forTimeInterval: 0.004); continue }

            let ok = buf.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return true }
                var off = 0
                while off < raw.count {
                    let r = Darwin.write(fd, base.advanced(by: off), raw.count - off)
                    if r < 0 { if errno == EINTR { continue }; return false }
                    if r == 0 { return false }
                    off += r
                }
                return true
            }
            if !ok { break }
            written += Int64(buf.count / 2)
        }
    }

    private func processEnded(_ proc: Process) {
        // Ignore exits of a process the user already stopped (or an older session).
        guard let cur = process, cur === proc else { return }
        lock.lock(); let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines); lock.unlock()
        teardown()
        lastError = tail.isEmpty ? "ffmpeg stopped (exit \(proc.terminationStatus))." : "Stream stopped: " + tail
        onUnexpectedExit?(lastError)
    }

    private func teardown() {
        lock.lock(); running = false; withAudio = false; latestFrame = nil; audioRing.removeAll(); lock.unlock()
        isStreaming = false
        process = nil
        cleanupFIFO()
    }

    private func cleanupFIFO() {
        guard let path = fifoPath else { return }
        fifoPath = nil
        // Unblock an audio thread still waiting in open() (ffmpeg never opened the pipe).
        DispatchQueue.global().async {
            let rfd = open(path, O_RDONLY | O_NONBLOCK)
            if rfd >= 0 { Thread.sleep(forTimeInterval: 0.3); close(rfd) }
            unlink(path)
        }
    }

    func stop() {
        guard isStreaming else { return }
        let p = process
        teardown()          // stops the writer threads → stdin closes → ffmpeg flushes & exits
        if let p, p.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        }
    }
}

// MARK: - RTMP / RTSP / SRT input via ffmpeg (pulls & decodes to frames)
//
// Uses the user-installed ffmpeg to open an RTMP/RTSP/SRT/HTTP stream, decode it to
// raw BGRA frames, and feed them into LiveDeck as an input. Requires ffmpeg; if it's
// not installed the source stays black. Best-effort — protocol/codec support depends
// on the installed ffmpeg build.

final class FFmpegStreamSource: Source {
    private var process: Process?
    private var ytdlpProcess: Process?
    private var readThread: Thread?
    private let outW = 1280, outH = 720
    private var running = false
    private var frameImage: CGImage?

    init(url: String) {
        super.init(name: URL(string: url)?.host ?? "Stream", kindLabel: "RTMP/RTSP")
        sourceURLString = url
        startPull(url)
    }

    private func startPull(_ url: String) {
        guard let ff = StreamOutput.ffmpegPath() else { return }
        let host = URL(string: url)?.host?.lowercased() ?? ""
        let socialHosts = ["youtube.com", "youtu.be", "twitch.tv", "facebook.com", "fb.watch"]
        let isSocial = socialHosts.contains { host.contains($0) }

        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: ff)
        let outPipe = Pipe()
        ffmpeg.standardOutput = outPipe
        ffmpeg.standardError = FileHandle.nullDevice

        if isSocial, let yt = StreamOutput.ytdlpPath() {
            // yt-dlp (extracts the real media) | ffmpeg (decodes to raw frames)
            let ytp = Process()
            ytp.executableURL = URL(fileURLWithPath: yt)
            ytp.arguments = ["-f", "best", "-o", "-", "--quiet", "--no-warnings", url]
            let chain = Pipe()
            ytp.standardOutput = chain
            ytp.standardError = FileHandle.nullDevice
            ffmpeg.standardInput = chain
            ffmpeg.arguments = ["-loglevel", "error", "-i", "pipe:0", "-an",
                                "-vf", "scale=\(outW):\(outH)", "-pix_fmt", "bgra", "-f", "rawvideo", "-"]
            ytdlpProcess = ytp
        } else {
            ffmpeg.arguments = ["-loglevel", "error", "-rtsp_transport", "tcp", "-fflags", "nobuffer",
                                "-i", url, "-an", "-vf", "scale=\(outW):\(outH)",
                                "-pix_fmt", "bgra", "-f", "rawvideo", "-"]
        }
        do { try ffmpeg.run(); try ytdlpProcess?.run() } catch { return }
        process = ffmpeg; running = true
        let handle = outPipe.fileHandleForReading
        let t = Thread { [weak self] in self?.readLoop(handle) }
        t.stackSize = 1 << 20
        readThread = t
        t.start()
    }

    private func readLoop(_ handle: FileHandle) {
        let frameSize = outW * outH * 4
        var buffer = Data()
        while running {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while buffer.count >= frameSize {
                let frame = Data(buffer.prefix(frameSize))
                buffer.removeFirst(frameSize)
                if let cg = FFmpegStreamSource.image(from: frame, w: outW, h: outH) {
                    DispatchQueue.main.async { [weak self] in self?.frameImage = cg }
                }
            }
        }
    }

    static func image(from data: Data, w: Int, h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    override func currentImage() -> CGImage? { frameImage }

    override func stop() {
        running = false
        process?.terminate(); process = nil
        ytdlpProcess?.terminate(); ytdlpProcess = nil
    }
}

// MARK: - Web page input (renders a website into the switcher via WKWebView snapshots)

/// Web page input.
///
/// Why pages used to show as a white tile: WKWebView only renders while it is inside a window that
/// macOS considers visible. A web view that is not in any window (or in a window placed fully
/// off-screen, which macOS marks as occluded) loads the page but never paints, so every snapshot
/// was blank white. The page is now hosted in a borderless, click-through, practically transparent
/// window that keeps a single pixel on screen, so WebKit keeps rendering while the user never sees it.
final class WebSource: Source {
    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var timer: Timer?
    private var frameImage: CGImage?
    private var snapping = false
    private var delegateProxy: WebNavigationProxy?
    @Published private(set) var status = "Loading…"
    let outW = 1280, outH = 720

    /// Adds https:// when the scheme is missing ("example.com" → "https://example.com").
    static func normalized(_ raw: String) -> URL? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let u = URL(string: t) ?? URL(string: t.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? t),
              let scheme = u.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        return u
    }

    init(url: String) {
        let u = WebSource.normalized(url)
        super.init(name: u?.host ?? "Web page", kindLabel: "WEB")
        sourceURLString = u?.absoluteString ?? url
        if u == nil { status = "Invalid address" }
        DispatchQueue.main.async { [weak self] in self?.setup(u) }
    }

    private func setup(_ url: URL?) {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: outW, height: outH), configuration: cfg)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        let proxy = WebNavigationProxy(owner: self)
        wv.navigationDelegate = proxy
        delegateProxy = proxy

        // Rendering host: borderless, ignores the mouse, alpha ~0, 1 pixel left on screen.
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: screen.minX - CGFloat(outW) + 1, y: screen.minY - CGFloat(outH) + 1)
        let win = NSWindow(contentRect: CGRect(origin: origin, size: CGSize(width: outW, height: outH)),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.isOpaque = false
        win.backgroundColor = .clear
        win.alphaValue = 0.02
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.contentView = wv
        win.orderFrontRegardless()
        hostWindow = win
        webView = wv

        if let url { wv.load(URLRequest(url: url)) }
        let t = Timer(timeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in self?.snapshot() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    fileprivate func navigationChanged(_ text: String, loaded: Bool) {
        status = text
        if loaded { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.snapshot() } }
    }

    func reload() {
        guard let s = sourceURLString, let u = WebSource.normalized(s) else { return }
        status = "Loading…"
        webView?.load(URLRequest(url: u))
    }

    private func snapshot() {
        guard let wv = webView, !snapping else { return }
        takeSnapshot(wv)
    }

    private func takeSnapshot(_ wv: WKWebView) {
        snapping = true
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: outW, height: outH)
        cfg.afterScreenUpdates = true
        cfg.snapshotWidth = NSNumber(value: outW)
        wv.takeSnapshot(with: cfg) { [weak self] image, _ in
            self?.snapping = false
            guard let image else { return }
            var r = CGRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return }
            self?.frameImage = cg
        }
    }

    override func currentImage() -> CGImage? { frameImage }

    /// Until the first frame arrives, show the page status instead of a blank tile.
    override func draw(in ctx: CGContext, rect: CGRect) {
        if frameImage != nil { super.draw(in: ctx, rect: rect); return }
        ctx.setFillColor(NSColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1).cgColor)
        ctx.fill(rect)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let title = NSAttributedString(string: "🌐  " + (sourceURLString ?? "Web page"), attributes: [
            .font: NSFont.systemFont(ofSize: max(9, rect.height * 0.045), weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: p])
        let sub = NSAttributedString(string: status, attributes: [
            .font: NSFont.systemFont(ofSize: max(8, rect.height * 0.035)),
            .foregroundColor: NSColor(white: 0.65, alpha: 1), .paragraphStyle: p])
        let h = rect.height * 0.08
        title.draw(with: CGRect(x: rect.minX + 10, y: rect.midY, width: rect.width - 20, height: h), options: [.usesLineFragmentOrigin])
        sub.draw(with: CGRect(x: rect.minX + 10, y: rect.midY - h, width: rect.width - 20, height: h), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    override func stop() {
        timer?.invalidate(); timer = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        hostWindow?.orderOut(nil); hostWindow?.contentView = nil; hostWindow?.close()
        hostWindow = nil; webView = nil; delegateProxy = nil
    }
}

private final class WebNavigationProxy: NSObject, WKNavigationDelegate {
    weak var owner: WebSource?
    init(owner: WebSource) { self.owner = owner }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { owner?.navigationChanged("Loading…", loaded: false) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { owner?.navigationChanged("Loaded", loaded: true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        owner?.navigationChanged("Could not load: \(error.localizedDescription)", loaded: false)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        owner?.navigationChanged("Could not load: \(error.localizedDescription)", loaded: false)
    }
}
