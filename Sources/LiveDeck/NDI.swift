import Foundation
import AppKit
import SwiftUI
import CoreVideo
import CNDI
import PresentationKit

// MARK: - NDI® runtime
//
// LiveDeck ships the NDI 6 runtime (libndi.dylib from the NDI SDK for Apple) inside the app at
// Contents/Frameworks/libndi.dylib. It is loaded with dlopen at launch, so the app still runs if it is missing.
// NDI® is a registered trademark of Vizrt NDI AB — https://ndi.video

final class NDIBridge {
    static let shared = NDIBridge()
    private(set) var isAvailable = false
    private(set) var versionString = ""
    private(set) var loadedPath = ""
    private(set) var lastError = ""

    init() { detect() }

    private var candidates: [String] {
        var c: [String] = []
        if let fw = Bundle.main.privateFrameworksURL { c.append(fw.appendingPathComponent("libndi.dylib").path) }
        c.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libndi.dylib").path)
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() { c.append(exe.appendingPathComponent("libndi.dylib").path) }
        c.append(NDIBridge.extractedRuntimeURL.path)
        let env = ProcessInfo.processInfo.environment
        for key in ["NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5"] { if let d = env[key] { c.append(d + "/libndi.dylib") } }
        c += ["/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
              "/usr/local/lib/libndi.dylib", "/usr/local/lib/libndi.6.dylib", "/opt/homebrew/lib/libndi.dylib",
              "/Applications/NDI Video Monitor.app/Contents/Frameworks/libndi_advanced.dylib"]
        return c
    }

    /// Where a runtime unpacked from the repository's Resources/NDI/libndi.dylib.gz is kept (for `swift run` / Xcode runs).
    static var extractedRuntimeURL: URL {
        PresentationLibrary.defaultRoot.deletingLastPathComponent().appendingPathComponent("NDI/libndi.dylib")
    }

    func detect() {
        if cndi_is_loaded() != 0 { isAvailable = true; return }
        unpackDevelopmentRuntimeIfNeeded()
        var errors: [String] = []
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if cndi_load(path) == 1 {
                isAvailable = true
                loadedPath = path
                versionString = String(cString: cndi_version())
                lastError = ""
                return
            }
            errors.append(String(cString: cndi_last_error()))
        }
        isAvailable = false
        lastError = errors.first ?? "libndi.dylib was not found in the app or on this Mac."
    }

    /// When LiveDeck runs straight from the source folder, unpack Resources/NDI/libndi.dylib.gz once.
    private func unpackDevelopmentRuntimeIfNeeded() {
        let fm = FileManager.default
        let dest = NDIBridge.extractedRuntimeURL
        guard !fm.fileExists(atPath: dest.path) else { return }
        let gz = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/NDI/libndi.dylib.gz")
        guard fm.fileExists(atPath: gz.path) else { return }
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "/usr/bin/gunzip -c \"\(gz.path)\" > \"\(dest.path)\" && chmod 755 \"\(dest.path)\""]
        try? p.run(); p.waitUntilExit()
    }
}

// MARK: - Sending

/// One NDI sender. Video frames are handed to a background queue (a busy sender drops the frame instead of
/// slowing the switcher); audio keeps its order on its own queue.
final class NDISender {
    let name: String
    private let handle: UnsafeMutableRawPointer
    private let videoQueue: DispatchQueue
    private let audioQueue: DispatchQueue
    private let lock = NSLock()
    private var busy = false
    private(set) var droppedFrames = 0

    init?(name: String) {
        guard NDIBridge.shared.isAvailable, let h = cndi_send_create(name, nil) else { return nil }
        self.name = name
        handle = h
        videoQueue = DispatchQueue(label: "livedeck.ndi.video.\(name)", qos: .userInteractive)
        audioQueue = DispatchQueue(label: "livedeck.ndi.audio.\(name)", qos: .userInteractive)
    }

    func sendVideo(_ pb: CVPixelBuffer, rateN: Int, rateD: Int, interlaced: Bool) {
        lock.lock()
        if busy { droppedFrames += 1; lock.unlock(); return }
        busy = true
        lock.unlock()
        videoQueue.async { [self] in
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(pb) {
                cndi_send_video_bgra(handle, Int32(CVPixelBufferGetWidth(pb)), Int32(CVPixelBufferGetHeight(pb)),
                                     Int32(CVPixelBufferGetBytesPerRow(pb)), base.assumingMemoryBound(to: UInt8.self),
                                     Int32(rateN), Int32(rateD), interlaced ? 1 : 0, 0)
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            lock.lock(); busy = false; lock.unlock()
        }
    }

    /// BGRA bytes already copied (e.g. the Preview render).
    func sendVideo(bytes: Data, width: Int, height: Int, stride: Int, rateN: Int, rateD: Int) {
        lock.lock()
        if busy { droppedFrames += 1; lock.unlock(); return }
        busy = true
        lock.unlock()
        videoQueue.async { [self] in
            bytes.withUnsafeBytes { raw in
                if let p = raw.bindMemory(to: UInt8.self).baseAddress {
                    cndi_send_video_bgra(handle, Int32(width), Int32(height), Int32(stride), p, Int32(rateN), Int32(rateD), 0, 0)
                }
            }
            lock.lock(); busy = false; lock.unlock()
        }
    }

    /// Program mix (48 kHz stereo). Called from the audio render thread: copies, then sends on a queue.
    func sendAudio(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        guard n > 0 else { return }
        var planar = [Float](repeating: 0, count: n * 2)
        planar.withUnsafeMutableBufferPointer { p in
            p.baseAddress!.update(from: l, count: n)
            (p.baseAddress! + n).update(from: r, count: n)
        }
        audioQueue.async { [self] in
            planar.withUnsafeBufferPointer { p in cndi_send_audio_planar(handle, 48000, 2, Int32(n), p.baseAddress) }
        }
    }

    func status() -> (connections: Int, program: Bool, preview: Bool) {
        var pgm: Int32 = 0, pvw: Int32 = 0
        _ = cndi_send_tally(handle, &pgm, &pvw)
        return (Int(cndi_send_connections(handle)), pgm != 0, pvw != 0)
    }

    // Queued work retains the sender, so by the time it is released nothing is still sending.
    deinit { cndi_send_destroy(handle) }
}

/// NDI outputs of LiveDeck (Program and optional Preview) with their settings and live status.
/// Kept separate from Engine so the per-second status never refreshes the whole window.
final class NDIOutputs: ObservableObject {
    @Published var programEnabled: Bool { didSet { save(); rebuild() } }
    @Published var programName: String { didSet { save() } }
    @Published var previewEnabled: Bool { didSet { save(); rebuild() } }
    @Published var previewName: String { didSet { save() } }
    @Published var sendAudio: Bool { didSet { save() } }
    @Published private(set) var runtimeAvailable = NDIBridge.shared.isAvailable
    @Published private(set) var programConnections = 0
    @Published private(set) var previewConnections = 0
    @Published private(set) var tallyProgram = false
    @Published private(set) var tallyPreview = false
    @Published private(set) var error = ""

    private let lock = NSLock()
    private var program: NDISender?
    private var preview: NDISender?

    init() {
        let d = UserDefaults.standard
        let host = Host.current().localizedName ?? "LiveDeck"
        programEnabled = d.bool(forKey: "ndi.program")
        programName = d.string(forKey: "ndi.programName") ?? "LiveDeck Program"
        previewEnabled = d.bool(forKey: "ndi.preview")
        previewName = d.string(forKey: "ndi.previewName") ?? "LiveDeck Preview"
        sendAudio = d.object(forKey: "ndi.audio") as? Bool ?? true
        _ = host
        rebuild()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(programEnabled, forKey: "ndi.program"); d.set(programName, forKey: "ndi.programName")
        d.set(previewEnabled, forKey: "ndi.preview"); d.set(previewName, forKey: "ndi.previewName")
        d.set(sendAudio, forKey: "ndi.audio")
    }

    /// Re-creates senders (after turning them on/off or renaming).
    func rebuild() {
        NDIBridge.shared.detect()
        runtimeAvailable = NDIBridge.shared.isAvailable
        let p = programEnabled && runtimeAvailable ? (program?.name == programName ? program : NDISender(name: cleanName(programName))) : nil
        let v = previewEnabled && runtimeAvailable ? (preview?.name == previewName ? preview : NDISender(name: cleanName(previewName))) : nil
        lock.lock(); program = p; preview = v; lock.unlock()
        error = (programEnabled || previewEnabled) && !runtimeAvailable ? NDIBridge.shared.lastError : ""
        if !programEnabled { programConnections = 0; tallyProgram = false }
        if !previewEnabled { previewConnections = 0 }
    }

    private func cleanName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "LiveDeck" : t
    }

    var programSender: NDISender? { lock.lock(); defer { lock.unlock() }; return program }
    var previewSender: NDISender? { lock.lock(); defer { lock.unlock() }; return preview }
    var wantsPreview: Bool { previewSender != nil }

    func pushAudio(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        guard let s = programSender else { return }
        if sendAudio { s.sendAudio(l, r, n) }
    }

    /// 1 Hz from Engine.
    func poll() {
        if let p = programSender {
            let st = p.status()
            if st.connections != programConnections { programConnections = st.connections }
            if st.program != tallyProgram { tallyProgram = st.program }
            if st.preview != tallyPreview { tallyPreview = st.preview }
        }
        if let v = previewSender {
            let c = v.status().connections
            if c != previewConnections { previewConnections = c }
        }
    }
}

// MARK: - Receiving (NDI source as an input)

final class NDISource: Source, LiveAudioSource {
    let sourceName: String
    @Published var status = "Connecting…"
    var audioSink: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)?
    var lowBandwidth = false
    private let lock = NSLock()
    private var image: CGImage?
    private var running = true
    private var tallyProgram = false, tallyPreview = false, tallyDirty = true
    private var resampleL: [Float] = [], resampleR: [Float] = []

    init(sourceName: String) {
        self.sourceName = sourceName
        super.init(name: NDISource.displayName(sourceName), kindLabel: "NDI")
        originLocation = sourceName
        let t = Thread { [weak self] in self?.receiveLoop() }
        t.name = "livedeck.ndi.receive"
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// "MACHINE (Camera 1)" → "Camera 1"
    static func displayName(_ full: String) -> String {
        if let open = full.firstIndex(of: "("), full.hasSuffix(")") {
            let inner = full[full.index(after: open)..<full.index(before: full.endIndex)]
            if !inner.isEmpty { return String(inner) }
        }
        return full
    }

    func setTally(program: Bool, preview: Bool) {
        lock.lock()
        if program != tallyProgram || preview != tallyPreview { tallyProgram = program; tallyPreview = preview; tallyDirty = true }
        lock.unlock()
    }

    private func receiveLoop() {
        guard NDIBridge.shared.isAvailable else {
            DispatchQueue.main.async { self.status = "NDI runtime not available" }
            return
        }
        var receiver: UnsafeMutableRawPointer?
        var lastFrame = Date()
        var announced = false
        while isRunning {
            if receiver == nil {
                receiver = cndi_recv_create(sourceName, "LiveDeck", lowBandwidth ? 1 : 0)
                if receiver == nil { Thread.sleep(forTimeInterval: 2); continue }
                lock.lock(); tallyDirty = true; lock.unlock()
            }
            guard let r = receiver else { continue }
            lock.lock()
            if tallyDirty { cndi_recv_set_tally(r, tallyProgram ? 1 : 0, tallyPreview ? 1 : 0); tallyDirty = false }
            lock.unlock()

            var video = cndi_video()
            var audio = cndi_audio()
            let kind = cndi_recv_capture(r, 100, &video, &audio)
            switch kind {
            case 1:
                if let img = makeImage(video) {
                    lock.lock(); image = img; lock.unlock()
                    lastFrame = Date()
                    if !announced {
                        announced = true
                        let text = "Receiving \(video.width)×\(video.height)"
                        DispatchQueue.main.async { self.status = text }
                    }
                }
                cndi_recv_free_video(r, &video)
            case 2:
                deliverAudio(audio)
                cndi_recv_free_audio(r, &audio)
            case -1:
                cndi_recv_destroy(r)
                receiver = nil
                announced = false
                DispatchQueue.main.async { self.status = "Source lost — reconnecting…" }
                Thread.sleep(forTimeInterval: 1)
            default:
                if announced && Date().timeIntervalSince(lastFrame) > 3 {
                    announced = false
                    DispatchQueue.main.async { self.status = "No video from the source" }
                }
            }
        }
        if let r = receiver { cndi_recv_destroy(r) }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func makeImage(_ v: cndi_video) -> CGImage? {
        guard let src = v.data, v.width > 0, v.height > 0, v.stride >= v.width * 4 else { return nil }
        let w = Int(v.width), h = Int(v.height), stride = Int(v.stride)
        let data = Data(bytes: src, count: stride * h)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let alpha: CGImageAlphaInfo = v.has_alpha != 0 ? .first : .noneSkipFirst
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func deliverAudio(_ a: cndi_audio) {
        guard let sink = audioSink, let data = a.data, a.samples > 0, a.channels > 0 else { return }
        let n = Int(a.samples)
        let stride = Int(a.channel_stride) / MemoryLayout<Float>.size
        let l = data
        let r = a.channels > 1 ? data + stride : data
        if a.sample_rate == 48000 {
            sink(l, r, n)
            return
        }
        // simple linear resample to 48 kHz
        let ratio = 48000.0 / Double(max(1, a.sample_rate))
        let outN = Int(Double(n) * ratio)
        guard outN > 0 else { return }
        if resampleL.count < outN { resampleL = [Float](repeating: 0, count: outN); resampleR = resampleL }
        for i in 0..<outN {
            let pos = Double(i) / ratio
            let i0 = min(n - 1, Int(pos)), i1 = min(n - 1, i0 + 1)
            let f = Float(pos - Double(i0))
            resampleL[i] = l[i0] + (l[i1] - l[i0]) * f
            resampleR[i] = r[i0] + (r[i1] - r[i0]) * f
        }
        resampleL.withUnsafeBufferPointer { lp in resampleR.withUnsafeBufferPointer { rp in sink(lp.baseAddress!, rp.baseAddress!, outN) } }
    }

    override func currentImage() -> CGImage? { lock.lock(); defer { lock.unlock() }; return image }

    override func stop() {
        lock.lock(); running = false; lock.unlock()
    }
}

/// Watches the network for NDI sources while a picker is open.
final class NDIFinder: ObservableObject {
    @Published private(set) var sources: [String] = []
    private var finder: UnsafeMutableRawPointer?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        NDIBridge.shared.detect()
        guard NDIBridge.shared.isAvailable else { return }
        finder = cndi_find_create()
        refresh()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let f = finder { cndi_find_destroy(f) }
        finder = nil
    }

    private func refresh() {
        guard let f = finder else { return }
        var buffer = [CChar](repeating: 0, count: 16384)
        _ = cndi_find_sources(f, &buffer, Int32(buffer.count))
        let list = String(cString: buffer).split(separator: "\n").map(String.init)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if list != sources { sources = list }
    }

    deinit { stop() }
}

// MARK: - Interface

struct NDISourcePicker: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var finder = NDIFinder()
    @State private var lowBandwidth = false
    @State private var added: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 18, weight: .semibold)).foregroundColor(CP.icon)
                VStack(alignment: .leading, spacing: 0) {
                    Text("NDI® sources").font(.system(size: 14, weight: .semibold)).foregroundColor(CP.text)
                    Text(NDIBridge.shared.isAvailable ? "Cameras, computers and apps sending NDI on this network" : "NDI runtime not available")
                        .font(.system(size: 10)).foregroundColor(CP.text2)
                }
                Spacer()
                CPButton(title: "Done", prominent: true) { dismiss() }
            }
            .padding(.horizontal, 14).frame(height: 54).background(CP.cardHeader)
            CPInspector {
                CPCard(title: "On the network", subtitle: finder.sources.isEmpty ? "Searching…" : "\(finder.sources.count) source(s)", icon: "network") {
                    if !NDIBridge.shared.isAvailable {
                        CPNote(NDIBridge.shared.lastError)
                    } else if finder.sources.isEmpty {
                        CPNote("Looking for NDI sources… PTZ/NDI cameras, OBS, vMix, NDI Screen Capture and other LiveDeck computers appear here. They must be on the same network.")
                    }
                    ForEach(finder.sources, id: \.self) { src in
                        CPDivider()
                        HStack(spacing: 8) {
                            Image(systemName: "video.fill").foregroundColor(CP.icon).frame(width: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(NDISource.displayName(src)).font(.system(size: 12, weight: .semibold)).foregroundColor(CP.text)
                                Text(src).font(.system(size: 9.5)).foregroundColor(CP.text2).lineLimit(1)
                            }
                            Spacer()
                            if added.contains(src) {
                                Label("Added", systemImage: "checkmark").font(.system(size: 11)).foregroundColor(DS.ok)
                            } else {
                                CPButton(icon: "plus", title: "Add as input", prominent: true) {
                                    let s = NDISource(sourceName: src)
                                    s.lowBandwidth = lowBandwidth
                                    engine.placeInput(s)
                                    added.insert(src)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    CPDivider()
                    CPToggleRow(label: "Low bandwidth (smaller preview-quality stream)", isOn: $lowBandwidth)
                }
                CPNote("NDI® is a registered trademark of Vizrt NDI AB. ndi.video")
            }
        }
        .frame(width: 520, height: 520)
        .background(CP.bg)
        .preferredColorScheme(.dark)
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
    }
}

/// Outputs-panel card: NDI Program / Preview output.
struct NDIOutputCard: View {
    @EnvironmentObject var ndi: NDIOutputs
    @EnvironmentObject var engine: Engine
    @State private var programDraft = ""
    @State private var previewDraft = ""

    var body: some View {
        CPCard(title: "NDI® Output", subtitle: ndi.runtimeAvailable ? "NDI \(shortVersion) ready" : "NDI runtime not found",
               icon: "dot.radiowaves.left.and.right", iconColor: ndi.programEnabled && ndi.runtimeAvailable ? DS.ok : CP.icon) {
            if !ndi.runtimeAvailable {
                CPNote("LiveDeck could not load libndi.dylib: \(NDIBridge.shared.lastError). Builds from GitHub include it; for local builds install the NDI SDK for Apple.")
                HStack { Spacer(); CPButton(icon: "arrow.clockwise", title: "Try again") { ndi.rebuild() } }.padding(.vertical, 4)
            }
            CPToggleRow(icon: "tv", label: "Send Program over NDI", isOn: $ndi.programEnabled)
            if ndi.programEnabled {
                nameRow("Source name", draft: $programDraft, current: ndi.programName) { ndi.programName = $0; ndi.rebuild() }
                CPToggleRow(label: "Include Program audio", isOn: $ndi.sendAudio)
                HStack(spacing: 10) {
                    statusPill(ndi.programConnections == 0 ? "No receivers" : "\(ndi.programConnections) receiver\(ndi.programConnections == 1 ? "" : "s")",
                               ndi.programConnections > 0 ? DS.ok : CP.text2)
                    if ndi.tallyProgram { statusPill("ON AIR downstream", DS.program) }
                    if ndi.tallyPreview { statusPill("PREVIEW downstream", DS.preview) }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            CPDivider()
            CPToggleRow(icon: "eye", label: "Send Preview over NDI", isOn: $ndi.previewEnabled)
            if ndi.previewEnabled {
                nameRow("Source name", draft: $previewDraft, current: ndi.previewName) { ndi.previewName = $0; ndi.rebuild() }
                statusPill(ndi.previewConnections == 0 ? "No receivers" : "\(ndi.previewConnections) receiver(s)", ndi.previewConnections > 0 ? DS.ok : CP.text2)
                    .padding(.vertical, 4)
            }
            if !ndi.error.isEmpty { Text(ndi.error).font(.system(size: 10.5)).foregroundColor(DS.amber) }
            CPNote("Other computers see “\(Host.current().localizedName ?? "this Mac") (\(ndi.programName))” in OBS, vMix, NDI Studio Monitor, TriCaster and more. Sent at \(engine.frameFormat.name(height: engine.height)). To receive NDI, use Add Input → NDI Source….")
            CPNote("NDI® is a registered trademark of Vizrt NDI AB. ndi.video")
        }
        .onAppear { programDraft = ndi.programName; previewDraft = ndi.previewName }
    }

    private var shortVersion: String {
        let v = NDIBridge.shared.versionString
        if let r = v.range(of: "v[0-9.]+", options: .regularExpression) { return String(v[r]) }
        return v
    }

    private func nameRow(_ label: String, draft: Binding<String>, current: String, apply: @escaping (String) -> Void) -> some View {
        CPRow(label: label) {
            HStack(spacing: 4) {
                TextField("Name", text: draft).dsField().frame(maxWidth: 160).onSubmit { apply(draft.wrappedValue) }
                if draft.wrappedValue != current { CPButton(title: "Set") { apply(draft.wrappedValue) } }
            }
        }
    }

    private func statusPill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundColor(color)
            .padding(.horizontal, 7).frame(height: 20)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
    }
}

/// Status-bar chip.
struct NDIStatusChip: View {
    @EnvironmentObject var ndi: NDIOutputs
    @EnvironmentObject var engine: Engine
    var body: some View {
        if ndi.programEnabled || ndi.previewEnabled {
            let color: Color = !ndi.runtimeAvailable ? DS.amber : (ndi.tallyProgram ? DS.program : (ndi.programConnections > 0 ? DS.ok : DS.text3))
            VStack(alignment: .leading, spacing: 0) {
                Text("NDI").font(.system(size: 8, weight: .heavy)).kerning(0.6).foregroundColor(DS.text3)
                Text(!ndi.runtimeAvailable ? "not loaded" : (ndi.tallyProgram ? "on air · \(ndi.programConnections)" : "\(ndi.programConnections) receiver\(ndi.programConnections == 1 ? "" : "s")"))
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundColor(color).lineLimit(1)
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.5), lineWidth: 1))
            .onTapGesture { engine.rightTab = 4 }
            .help("NDI output — receivers connected and tally from the other systems")
        }
    }
}
