import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreImage
import CoreMediaIO
import AppKit
import Darwin
import IOKit

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
    @Published var gain: Double = 1.0
    @Published var solo = false

    // Called when a media clip reaches its end / out-point (used by playlist)
    var onReachedEnd: (() -> Void)?

    // Per-input audio device + live level
    @Published var audioDeviceID: String? { didSet { meter.start(deviceID: audioDeviceID) } }
    let meter = InputAudioMeter()

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

    init(url: URL, displayName: String? = nil, label: String = "FILE", startLooping: Bool = true) {
        let item = AVPlayerItem(url: url)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        super.init(name: displayName ?? url.lastPathComponent, kindLabel: label)
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
            self.player.volume = self.muted ? 0 : Float(min(1, self.gain))
        }
        RunLoop.main.add(vt, forMode: .common); volTimer = vt
        player.play()
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
        return super.currentImage()
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

    init(url: URL) {
        player = AVPlayer(url: url)
        super.init(name: url.lastPathComponent, kindLabel: "AUDIO")
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
            self.player.volume = self.muted ? 0 : Float(min(1, self.gain))
        }
        RunLoop.main.add(vt, forMode: .common); volTimer = vt
        player.play()
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

final class InputAudioMeter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "input.audio.meter")
    private(set) var currentLevel: Float = 0   // read on main by the engine's meter timer
    private var smoothed: Float = 0

    func start(deviceID: String?) {
        stop()
        guard let id = deviceID, let dev = AVCaptureDevice(uniqueID: id),
              let input = try? AVCaptureDeviceInput(device: dev) else { currentLevel = 0; return }
        let s = AVCaptureSession()
        if s.canAddInput(input) { s.addInput(input) }
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: queue)
        if s.canAddOutput(out) { s.addOutput(out) }
        queue.async { s.startRunning() }
        session = s
    }

    func stop() { session?.stopRunning(); session = nil; currentLevel = 0 }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let ch = connection.audioChannels.first {
            let lin = Float(pow(10.0, Double(ch.averagePowerLevel) / 20.0))
            smoothed = max(lin, smoothed * 0.82)
            currentLevel = min(1, max(0, smoothed))
        }
    }
}

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

// MARK: - Recording audio mixer (sums input faders/mutes/solos into one bus)
//
// Design for reliability: every assigned input device is captured in a uniform
// Float32 / 48 kHz / mono format. The FIRST input is the "reference" and provides
// the clock; each other input's samples are summed *into the reference buffer in
// place* (scaled by that input's fader), and the reference buffer — which already
// carries a valid format description and presentation timestamp — is written to the
// file. No from-scratch CMSampleBuffer or timestamp generation, so it can't desync
// or produce silent takes the way a hand-rolled mixer might.

final class AudioMixRecorder {
    final class Tap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        let id: UUID
        var isReference = false
        weak var owner: AudioMixRecorder?
        let dsp = AudioDSP()
        private var session: AVCaptureSession?
        private let q: DispatchQueue
        private var ring = [Float]()
        private let lock = NSLock()

        init(id: UUID) { self.id = id; q = DispatchQueue(label: "mixtap") }

        func start(deviceID: String) {
            guard let dev = AVCaptureDevice(uniqueID: deviceID),
                  let input = try? AVCaptureDeviceInput(device: dev) else { return }
            let s = AVCaptureSession()
            if s.canAddInput(input) { s.addInput(input) }
            let out = AVCaptureAudioDataOutput()
            out.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            out.setSampleBufferDelegate(self, queue: q)
            if s.canAddOutput(out) { s.addOutput(out) }
            q.async { s.startRunning() }
            session = s
        }
        func stop() { session?.stopRunning(); session = nil; lock.lock(); ring.removeAll(); lock.unlock() }

        func appendSamples(_ p: UnsafePointer<Float>, _ n: Int) {
            lock.lock()
            for i in 0..<n { ring.append(p[i]) }
            if ring.count > 96000 { ring.removeFirst(ring.count - 96000) }   // cap ~2s
            lock.unlock()
        }
        func pull(_ n: Int) -> [Float] {
            lock.lock(); defer { lock.unlock() }
            if ring.count >= n { let out = Array(ring.prefix(n)); ring.removeFirst(n); return out }
            var out = Array(ring); ring.removeAll()
            if out.count < n { out.append(contentsOf: [Float](repeating: 0, count: n - out.count)) }
            return out
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            if isReference { owner?.mixReference(sampleBuffer); return }
            guard let bb = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            var len = 0, total = 0; var dp: UnsafeMutablePointer<Int8>? = nil
            guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: &len,
                                              totalLengthOut: &total, dataPointerOut: &dp) == kCMBlockBufferNoErr,
                  let dp else { return }
            let n = total / MemoryLayout<Float>.size
            dp.withMemoryRebound(to: Float.self, capacity: n) { fp in appendSamples(fp, n) }
        }
    }

    private(set) var taps: [Tap] = []
    var gainFor: ((UUID) -> Float)?
    var snapshotFor: ((UUID) -> EffectSnapshot?)?
    var masterSnapshot: (() -> EffectSnapshot?)?
    var masterGain: () -> Float = { 1 }
    var onMixed: ((CMSampleBuffer) -> Void)?
    private let masterDSP = AudioDSP()

    func start(_ inputs: [(id: UUID, deviceID: String)]) {
        stop()
        for (i, inp) in inputs.enumerated() {
            let t = Tap(id: inp.id); t.owner = self; t.isReference = (i == 0)
            taps.append(t); t.start(deviceID: inp.deviceID)
        }
    }
    func stop() { for t in taps { t.stop() }; taps.removeAll() }

    fileprivate func mixReference(_ sb: CMSampleBuffer) {
        guard let bb = CMSampleBufferGetDataBuffer(sb), let ref = taps.first else { return }
        var len = 0, total = 0; var dp: UnsafeMutablePointer<Int8>? = nil
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: &len,
                                          totalLengthOut: &total, dataPointerOut: &dp) == kCMBlockBufferNoErr,
              let dp else { return }
        let n = total / MemoryLayout<Float>.size
        guard n > 0 else { return }
        let mg = masterGain()
        dp.withMemoryRebound(to: Float.self, capacity: n) { fp in
            var refBuf = [Float](repeating: 0, count: n)
            for i in 0..<n { refBuf[i] = fp[i] }
            if let snap = snapshotFor?(ref.id), snap.enabled { ref.dsp.update(snap); ref.dsp.process(&refBuf) }
            let refGain = gainFor?(ref.id) ?? 1
            for i in 0..<n { fp[i] = refBuf[i] * refGain }
            for t in taps.dropFirst() {
                let g = gainFor?(t.id) ?? 0
                if g <= 0 { continue }
                var s = t.pull(n)
                if let snap = snapshotFor?(t.id), snap.enabled { t.dsp.update(snap); t.dsp.process(&s) }
                let c = min(n, s.count)
                for i in 0..<c { fp[i] += s[i] * g }
            }
            for i in 0..<n { fp[i] *= mg }
            if let ms = masterSnapshot?(), ms.enabled {
                var mbuf = [Float](repeating: 0, count: n)
                for i in 0..<n { mbuf[i] = fp[i] }
                masterDSP.update(ms); masterDSP.process(&mbuf)   // process() clamps
                for i in 0..<n { fp[i] = mbuf[i] }
            } else {
                for i in 0..<n { let v = fp[i]; fp[i] = v > 1 ? 1 : (v < -1 ? -1 : v) }
            }
        }
        onMixed?(sb)
    }
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
// LiveDeck does not bundle ffmpeg (that means GPL redistribution + signing an
// external binary, which we can't verify here). Instead it detects an ffmpeg the
// user installs (e.g. `brew install ffmpeg`) and pipes the Program frames to it.
// This first version streams VIDEO with a silent AAC track so platforms accept the
// feed; real program audio is the next increment.

final class StreamOutput {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private let q = DispatchQueue(label: "livedeck.stream.write")
    private var busy = false
    private(set) var isStreaming = false
    private(set) var lastError = ""

    static func ffmpegPath() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }
    var available: Bool { StreamOutput.ffmpegPath() != nil }

    func start(url: String, width: Int, height: Int, fps: Int, bitrateKbps: Int) -> Bool {
        guard !isStreaming, let ff = StreamOutput.ffmpegPath(),
              !url.trimmingCharacters(in: .whitespaces).isEmpty else { lastError = "ffmpeg not found or URL empty"; return false }
        let isSRT = url.hasPrefix("srt://")
        let outFmt = isSRT ? "mpegts" : "flv"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = [
            "-loglevel", "error",
            "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "\(width)x\(height)", "-framerate", "\(fps)", "-i", "pipe:0",
            "-f", "lavfi", "-i", "anullsrc=channel_layout=mono:sample_rate=48000",
            "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
            "-b:v", "\(bitrateKbps)k", "-maxrate", "\(bitrateKbps)k", "-bufsize", "\(bitrateKbps * 2)k",
            "-g", "\(max(2, fps * 2))", "-tune", "zerolatency",
            "-c:a", "aac", "-b:a", "128k",
            "-f", outFmt, url
        ]
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { lastError = error.localizedDescription; return false }
        process = p; stdinHandle = inPipe.fileHandleForWriting; isStreaming = true; lastError = ""
        return true
    }

    func writeFrame(_ pb: CVPixelBuffer) {
        guard isStreaming, let h = stdinHandle, !busy else { return }
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
        busy = true
        q.async { [weak self] in
            do { try h.write(contentsOf: data) } catch { DispatchQueue.main.async { self?.stop() } }
            self?.busy = false
        }
    }

    func stop() {
        guard isStreaming else { return }
        isStreaming = false
        let handle = stdinHandle
        q.async { try? handle?.close() }
        process?.terminate()
        process = nil; stdinHandle = nil
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = [
            "-loglevel", "error",
            "-rtsp_transport", "tcp",
            "-fflags", "nobuffer", "-flags", "low_delay",
            "-i", url,
            "-an", "-vf", "scale=\(outW):\(outH)",
            "-pix_fmt", "bgra", "-f", "rawvideo", "-"
        ]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        process = p; running = true
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
    }
}
