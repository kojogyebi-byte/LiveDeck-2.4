import Foundation
import AppKit
import SwiftUI
import Accelerate
import CDeckLink
import PresentationKit

// MARK: - Blackmagic DeckLink / UltraStudio (Desktop Video)

struct DeckLinkDevice: Identifiable, Hashable {
    let index: Int
    let name: String
    let canCapture: Bool
    let canPlayback: Bool
    var id: String { "\(index):\(name)" }
}

/// Program output to a DeckLink card, plus the device list. Its own observable model (not on Engine).
final class DeckLinkManager: ObservableObject {
    @Published private(set) var apiPresent = false
    @Published private(set) var apiVersion = ""
    @Published private(set) var devices: [DeckLinkDevice] = []
    @Published var outputDeviceName: String = UserDefaults.standard.string(forKey: "decklink.output") ?? "" {
        didSet { UserDefaults.standard.set(outputDeviceName, forKey: "decklink.output") }
    }
    @Published var outputAudio: Bool = UserDefaults.standard.object(forKey: "decklink.audio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(outputAudio, forKey: "decklink.audio") }
    }
    @Published private(set) var outputActive = false
    @Published private(set) var outputMode = ""
    @Published private(set) var outputError = ""

    private var handle: UnsafeMutableRawPointer?
    private let queue = DispatchQueue(label: "livedeck.decklink.out", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    private var audioL: [Float] = [], audioR: [Float] = []

    init() { refresh() }

    func refresh() {
        apiPresent = cdl_api_present() != 0
        guard apiPresent else { devices = []; apiVersion = ""; return }
        var buf = [CChar](repeating: 0, count: 64)
        _ = cdl_api_version(&buf, Int32(buf.count))
        apiVersion = String(cString: buf)
        var list: [DeckLinkDevice] = []
        for i in 0..<Int(cdl_device_count()) {
            var name = [CChar](repeating: 0, count: 256)
            var cap: Int32 = 0, play: Int32 = 0
            if cdl_device_info(Int32(i), &name, Int32(name.count), &cap, &play) != 0 {
                list.append(DeckLinkDevice(index: i, name: String(cString: name), canCapture: cap != 0, canPlayback: play != 0))
            }
        }
        devices = list
    }

    var outputDevices: [DeckLinkDevice] { devices.filter { $0.canPlayback } }
    var inputDevices: [DeckLinkDevice] { devices.filter { $0.canCapture } }

    /// Starts Program playout at the switcher's resolution and frame rate.
    func startOutput(width: Int, height: Int, format: FrameRateFormat) {
        stopOutput()
        refresh()
        guard let device = outputDevices.first(where: { $0.name == outputDeviceName }) ?? outputDevices.first else {
            outputError = apiPresent ? "No DeckLink output device found." : "Install Blackmagic Desktop Video to use DeckLink."
            return
        }
        outputDeviceName = device.name
        var err = [CChar](repeating: 0, count: 512)
        let h = cdl_output_open(Int32(device.index), Int32(width), Int32(height), Int32(format.rateNumerator), Int32(format.rateDenominator),
                                format.interlaced ? 1 : 0, outputAudio ? 1 : 0, &err, Int32(err.count))
        guard let h else { outputError = String(cString: err); outputActive = false; return }
        var mode = [CChar](repeating: 0, count: 128)
        _ = cdl_output_mode_name(h, &mode, Int32(mode.count))
        lock.lock(); handle = h; lock.unlock()
        outputMode = String(cString: mode)
        outputError = ""
        outputActive = true
    }

    func stopOutput() {
        lock.lock(); let h = handle; handle = nil; lock.unlock()
        if let h { queue.sync { cdl_output_close(h) } }
        outputActive = false
        outputMode = ""
    }

    /// Program frame from the render loop (BGRA). Dropped if the card is still busy with the previous frame.
    func send(_ pb: CVPixelBuffer) {
        lock.lock()
        guard let h = handle, !busy else { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [weak self] in
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(pb) {
                _ = cdl_output_video_bgra(h, base.assumingMemoryBound(to: UInt8.self), Int32(CVPixelBufferGetWidth(pb)),
                                          Int32(CVPixelBufferGetHeight(pb)), Int32(CVPixelBufferGetBytesPerRow(pb)))
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            self?.lock.lock(); self?.busy = false; self?.lock.unlock()
        }
    }

    /// Program audio (48 kHz stereo) from the audio render thread.
    func sendAudio(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        guard outputAudio, n > 0 else { return }
        lock.lock(); let h = handle; lock.unlock()
        guard let h else { return }
        _ = cdl_output_audio(h, l, r, Int32(n))
    }
}

// MARK: - DeckLink capture input

final class DeckLinkSource: Source, LiveAudioSource {
    let deviceName: String
    let deviceIndex: Int
    @Published var status = "Starting…"
    var audioSink: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)?
    private var handle: UnsafeMutableRawPointer?
    private let lock = NSLock()
    private var image: CGImage?
    private var argb: [UInt8] = []
    private var info = vImage_YpCbCrToARGB()
    private var infoReady = false
    private var left: [Float] = [], right: [Float] = []

    init(device: DeckLinkDevice) {
        deviceName = device.name
        deviceIndex = device.index
        super.init(name: device.name, kindLabel: "DECKLINK")
        originLocation = "decklink:\(device.name)"
        open()
    }

    private func open() {
        var err = [CChar](repeating: 0, count: 512)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        handle = cdl_input_open(Int32(deviceIndex), { ctx, data, w, h, row, pf in
            guard let ctx, let data else { return }
            Unmanaged<DeckLinkSource>.fromOpaque(ctx).takeUnretainedValue().video(data, Int(w), Int(h), Int(row), Int(pf))
        }, { ctx, samples, frames, channels in
            guard let ctx, let samples else { return }
            Unmanaged<DeckLinkSource>.fromOpaque(ctx).takeUnretainedValue().audio(samples, Int(frames), Int(channels))
        }, { ctx, signal, message in
            guard let ctx else { return }
            let text = message.map { String(cString: $0) } ?? ""
            let src = Unmanaged<DeckLinkSource>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { src.status = text }
        }, ctx, &err, Int32(err.count))
        if handle == nil { status = String(cString: err) }
    }

    private func video(_ data: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ row: Int, _ pf: Int) {
        guard w > 0, h > 0 else { return }
        if pf == 2 {
            // BGRA — copy into a CGImage
            let d = Data(bytes: data, count: row * h)
            guard let provider = CGDataProvider(data: d as CFData) else { return }
            let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            lock.lock(); image = img; lock.unlock()
            return
        }
        // 8-bit 4:2:2 UYVY → ARGB (BT.709 for HD, BT.601 for SD)
        lock.lock(); defer { lock.unlock() }
        if !infoReady {
            var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
            let matrix = h >= 720 ? kvImage_YpCbCrToARGBMatrix_ITU_R_709_2 : kvImage_YpCbCrToARGBMatrix_ITU_R_601_4
            infoReady = vImageConvert_YpCbCrToARGB_GenerateConversion(matrix, &range, &info, kvImage422CbYpCrYp8, kvImageARGB8888,
                                                                       vImage_Flags(kvImageNoFlags)) == kvImageNoError
            if !infoReady { return }
        }
        if argb.count != w * h * 4 { argb = [UInt8](repeating: 0, count: w * h * 4) }
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: data), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: row)
        let ok: Bool = argb.withUnsafeMutableBytes { raw -> Bool in
            var dst = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var map: [UInt8] = [0, 1, 2, 3]
            return vImageConvert_422CbYpCrYp8ToARGB8888(&src, &dst, &info, &map, 255, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard ok, let provider = CGDataProvider(data: Data(argb) as CFData) else { return }
        image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue), provider: provider,
                        decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func audio(_ samples: UnsafePointer<Int32>, _ frames: Int, _ channels: Int) {
        guard let sink = audioSink, frames > 0 else { return }
        if left.count < frames { left = [Float](repeating: 0, count: frames); right = left }
        let ch = max(1, channels)
        for i in 0..<frames {
            left[i] = Float(samples[i * ch]) / 2_147_483_648
            right[i] = ch > 1 ? Float(samples[i * ch + 1]) / 2_147_483_648 : left[i]
        }
        left.withUnsafeBufferPointer { lp in right.withUnsafeBufferPointer { rp in sink(lp.baseAddress!, rp.baseAddress!, frames) } }
    }

    override func currentImage() -> CGImage? { lock.lock(); defer { lock.unlock() }; return image }

    override func stop() {
        if let h = handle { cdl_input_close(h) }
        handle = nil
    }
}

// MARK: - Outputs-panel card

struct DeckLinkOutputCard: View {
    @EnvironmentObject var deckLink: DeckLinkManager
    @EnvironmentObject var engine: Engine

    var body: some View {
        CPCard(title: "Blackmagic DeckLink", subtitle: subtitle, icon: "rectangle.connected.to.line.below",
               iconColor: deckLink.outputActive ? DS.ok : CP.icon) {
            if !deckLink.apiPresent {
                CPNote("Install Blackmagic Desktop Video (the DeckLink / UltraStudio driver) from blackmagicdesign.com/support, restart the Mac, then press Refresh.")
                HStack {
                    CPButton(icon: "arrow.clockwise", title: "Refresh") { deckLink.refresh() }
                    Button("Download Desktop Video") { NSWorkspace.shared.open(URL(string: "https://www.blackmagicdesign.com/support/family/capture-and-playback")!) }
                        .buttonStyle(.ds(.ghost, .small))
                    Spacer()
                }
                .padding(.vertical, 4)
            } else if deckLink.outputDevices.isEmpty {
                CPNote("Desktop Video \(deckLink.apiVersion) is installed, but no DeckLink or UltraStudio output is connected.")
                HStack { CPButton(icon: "arrow.clockwise", title: "Refresh") { deckLink.refresh() }; Spacer() }.padding(.vertical, 4)
            } else {
                CPRow(label: "Output device") {
                    Picker("", selection: $deckLink.outputDeviceName) {
                        ForEach(deckLink.outputDevices) { d in Text(d.name).tag(d.name) }
                    }
                    .cpPickerChrome().frame(maxWidth: 200)
                    .disabled(deckLink.outputActive)
                }
                CPToggleRow(label: "Embed Program audio (SDI / HDMI)", isOn: $deckLink.outputAudio)
                    .disabled(deckLink.outputActive)
                CPToggleRow(icon: "play.rectangle", label: "Send Program to DeckLink", isOn: Binding(
                    get: { deckLink.outputActive },
                    set: { on in on ? deckLink.startOutput(width: engine.width, height: engine.height, format: engine.frameFormat) : deckLink.stopOutput() }))
                if deckLink.outputActive {
                    Text("● \(deckLink.outputMode)").font(CPFont.caption).foregroundColor(DS.ok).padding(.vertical, 2)
                }
                CPNote("Plays out at the switcher format (\(engine.frameFormat.name(height: engine.height))). Change the format in the gear menu while the output is off. DeckLink inputs: Add Input → Blackmagic DeckLink.")
            }
            if !deckLink.outputError.isEmpty {
                Text(deckLink.outputError).font(CPFont.caption).foregroundColor(DS.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subtitle: String {
        if !deckLink.apiPresent { return "Desktop Video not installed" }
        if deckLink.outputActive { return "Sending · \(deckLink.outputDeviceName)" }
        return "\(deckLink.devices.count) device\(deckLink.devices.count == 1 ? "" : "s") · Desktop Video \(deckLink.apiVersion)"
    }
}
