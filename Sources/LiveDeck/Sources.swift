import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreImage
import CoreMediaIO
import AppKit
import Darwin

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
    @Published var fxEnabled = false
    @Published var eqLow: Double = 0      // dB  -24...24
    @Published var eqMid: Double = 0
    @Published var eqHigh: Double = 0
    @Published var compThreshold: Double = -20  // dB
    @Published var compRatio: Double = 2         // :1
    @Published var gateThreshold: Double = -60   // dB

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
    var masterGain: () -> Float = { 1 }
    var onMixed: ((CMSampleBuffer) -> Void)?

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
        let refGain = gainFor?(ref.id) ?? 1
        let mg = masterGain()
        dp.withMemoryRebound(to: Float.self, capacity: n) { fp in
            for i in 0..<n { fp[i] *= refGain }
            for t in taps.dropFirst() {
                let g = gainFor?(t.id) ?? 0
                if g <= 0 { continue }
                let s = t.pull(n)
                let c = min(n, s.count)
                for i in 0..<c { fp[i] += s[i] * g }
            }
            for i in 0..<n { let v = fp[i] * mg; fp[i] = v > 1 ? 1 : (v < -1 ? -1 : v) }
        }
        onMixed?(sb)
    }
}
