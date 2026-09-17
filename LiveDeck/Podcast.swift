import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import PresentationKit

// MARK: - Sound Pads input (jingles, intros, stingers, applause)

struct SoundPad: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var path: String?
    var color: Int = 0
    var volume: Double = 1
    var loop = false
}

final class SoundPadsSource: Source, LiveAudioSource {
    static let colors: [Color] = [Color(rgb: 0xE5484D), Color(rgb: 0xF2A33A), Color(rgb: 0x3FB950), Color(rgb: 0x3E9BF4),
                                  Color(rgb: 0xA371F7), Color(rgb: 0xDB61A2), Color(rgb: 0x2EC4B6), Color(rgb: 0x8B949E)]

    @Published var pads: [SoundPad] { didSet { originLocation = encoded; reloadIfNeeded() } }
    @Published private(set) var playing: Set<Int> = []
    @Published var masterVolume: Double = 1
    var audioSink: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)?

    private struct Clip { var left: [Float]; var right: [Float] }
    private var clips: [UUID: Clip] = [:]
    private var loadedPaths: [UUID: String] = [:]
    private var positions: [Int: Int] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "livedeck.soundpads", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var lastPush = CACurrentMediaTime()
    private var mixL = [Float](repeating: 0, count: 9600), mixR = [Float](repeating: 0, count: 9600)

    init(name: String = "Sound Pads", pads: [SoundPad]? = nil) {
        self.pads = pads ?? (1...8).map { SoundPad(name: "Pad \($0)", color: ($0 - 1) % 8) }
        super.init(name: name, kindLabel: "PADS")
        originLocation = encoded
        reloadIfNeeded()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.01, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
    }

    convenience init(location: String, name: String) {
        let pads = (try? JSONDecoder().decode([SoundPad].self, from: Data(location.utf8)))
        self.init(name: name, pads: pads)
    }

    var encoded: String { (try? JSONEncoder().encode(pads)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]" }

    private func reloadIfNeeded() {
        for pad in pads {
            guard let path = pad.path else { lock.lock(); clips[pad.id] = nil; lock.unlock(); continue }
            if loadedPaths[pad.id] == path { continue }
            loadedPaths[pad.id] = path
            let id = pad.id
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let clip = Self.decode(URL(fileURLWithPath: path))
                self?.lock.lock(); self?.clips[id] = clip; self?.lock.unlock()
            }
        }
    }

    /// Reads an audio file into 48 kHz stereo float (up to 10 minutes).
    private static func decode(_ url: URL) -> Clip? {
        guard let file = try? AVAudioFile(forReading: url),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2),
              let converter = AVAudioConverter(from: file.processingFormat, to: outFormat) else { return nil }
        let inFrames = AVAudioFrameCount(min(file.length, Int64(file.processingFormat.sampleRate * 600)))
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inFrames), (try? file.read(into: input)) != nil else { return nil }
        let outCapacity = AVAudioFrameCount(Double(input.frameLength) * 48000 / file.processingFormat.sampleRate) + 4800
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        guard error == nil, let ch = output.floatChannelData else { return nil }
        let n = Int(output.frameLength)
        let l = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let r = output.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: n)) : l
        return Clip(left: l, right: r)
    }

    /// Plays a pad; pressing a playing pad stops it.
    func trigger(_ index: Int) {
        guard pads.indices.contains(index) else { return }
        lock.lock()
        if positions[index] != nil { positions[index] = nil } else if clips[pads[index].id] != nil { positions[index] = 0 }
        let now = Set(positions.keys)
        lock.unlock()
        playing = now
    }

    func stopAll() {
        lock.lock(); positions.removeAll(); lock.unlock()
        playing = []
    }

    private func pump() {
        let now = CACurrentMediaTime()
        var frames = Int((now - lastPush) * 48000)
        lastPush = now
        frames = max(0, min(frames, 4800))
        guard frames > 0 else { return }
        lock.lock()
        if positions.isEmpty { lock.unlock(); return }
        for i in 0..<frames { mixL[i] = 0; mixR[i] = 0 }
        var finished: [Int] = []
        let master = Float(masterVolume)
        for (index, pos) in positions {
            guard pads.indices.contains(index), let clip = clips[pads[index].id], !clip.left.isEmpty else { finished.append(index); continue }
            let vol = Float(pads[index].volume) * master
            var p = pos
            for i in 0..<frames {
                if p >= clip.left.count {
                    if pads[index].loop { p = 0 } else { break }
                }
                mixL[i] += clip.left[p] * vol; mixR[i] += clip.right[p] * vol
                p += 1
            }
            if p >= clip.left.count && !pads[index].loop { finished.append(index) } else { positions[index] = p }
        }
        for f in finished { positions[f] = nil }
        let stillPlaying = Set(positions.keys)
        lock.unlock()
        mixL.withUnsafeBufferPointer { l in mixR.withUnsafeBufferPointer { r in audioSink?(l.baseAddress!, r.baseAddress!, frames) } }
        if !finished.isEmpty { DispatchQueue.main.async { self.playing = stillPlaying } }
    }

    override func stop() { timer?.cancel(); timer = nil }

    override func draw(in ctx: CGContext, rect: CGRect) {
        ctx.setFillColor(NSColor(white: 0.06, alpha: 1).cgColor)
        ctx.fill(rect)
        let cols = 4, rows = 2
        let gap = rect.width * 0.015
        let w = (rect.width - gap * CGFloat(cols + 1)) / CGFloat(cols), h = (rect.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, pad) in pads.prefix(8).enumerated() {
            let col = i % cols, row = i / cols
            let r = CGRect(x: rect.minX + gap + CGFloat(col) * (w + gap), y: rect.maxY - gap - h - CGFloat(row) * (h + gap), width: w, height: h)
            let base = NSColor(Self.colors[pad.color % Self.colors.count])
            base.withAlphaComponent(playing.contains(i) ? 0.95 : (pad.path == nil ? 0.15 : 0.4)).setFill()
            NSBezierPath(roundedRect: r, xRadius: h * 0.08, yRadius: h * 0.08).fill()
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let text = NSAttributedString(string: pad.name, attributes: [.font: NSFont.systemFont(ofSize: h * 0.16, weight: .semibold),
                                                                          .foregroundColor: NSColor.white, .paragraphStyle: para])
            text.draw(in: r.insetBy(dx: 6, dy: h * 0.38))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct SoundPadsCard: View {
    @ObservedObject var source: SoundPadsSource
    @State private var editing: Int?

    var body: some View {
        CPCard(title: "Sound Pads", subtitle: "Jingles, intros, stingers", icon: "square.grid.2x2.fill") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Array(source.pads.enumerated()), id: \.element.id) { i, pad in
                    Button { source.trigger(i) } label: {
                        VStack(spacing: 2) {
                            Text(pad.name).font(.system(size: 11, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                            Text(pad.path == nil ? "empty" : (source.playing.contains(i) ? "playing" : (pad.loop ? "loop" : "")))
                                .font(.system(size: 9)).opacity(0.8)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: 6).fill(SoundPadsSource.colors[pad.color % 8].opacity(source.playing.contains(i) ? 1 : (pad.path == nil ? 0.2 : 0.55))))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(editing == i ? Color.white : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit pad…") { editing = i }
                        Button("Choose sound…") { choose(i) }
                        if pad.path != nil { Button("Clear") { source.pads[i].path = nil } }
                    }
                    .help("Click to play · keyboard shortcut Pad \(i + 1) · right-click to edit")
                }
            }
            .padding(.vertical, 6)
            HStack {
                CPButton(icon: "stop.fill", title: "Stop all") { source.stopAll() }
                Spacer()
                Picker("", selection: Binding(get: { editing ?? -1 }, set: { editing = $0 < 0 ? nil : $0 })) {
                    Text("Edit a pad…").tag(-1)
                    ForEach(0..<source.pads.count, id: \.self) { i in Text(source.pads[i].name).tag(i) }
                }
                .cpPickerChrome().frame(width: 150)
            }
            if let i = editing, source.pads.indices.contains(i) {
                SectionLabel("Pad \(i + 1)")
                CPTextRow(label: "Name", text: $source.pads[i].name)
                CPRow(label: "Sound") {
                    HStack {
                        Text(source.pads[i].path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None").font(CPFont.caption).foregroundColor(CP.text2).lineLimit(1)
                        CPButton(title: "Choose…") { choose(i) }
                    }
                }
                CPSliderRow(label: "Volume", value: $source.pads[i].volume, range: 0...2, defaultValue: 1, format: "%.2f")
                CPToggleRow(label: "Loop", isOn: $source.pads[i].loop)
                CPRow(label: "Colour") {
                    HStack(spacing: 5) {
                        ForEach(0..<8, id: \.self) { c in
                            Circle().fill(SoundPadsSource.colors[c]).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: source.pads[i].color == c ? 2 : 0))
                                .onTapGesture { source.pads[i].color = c }
                        }
                    }
                }
            }
            CPNote("Pads play into the mixer on this input's channel, so they are recorded and streamed. Right-click a pad to set its sound.")
        }
    }

    private func choose(_ i: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileAccess.remember(url)
        source.pads[i].path = url.path
        if source.pads[i].name.hasPrefix("Pad ") { source.pads[i].name = url.deletingPathExtension().lastPathComponent }
        editing = i
    }
}

// MARK: - Loudness monitor

final class LoudnessMonitor: ObservableObject {
    @Published private(set) var momentary = -Double.infinity
    @Published private(set) var shortTerm = -Double.infinity
    @Published private(set) var integrated = -Double.infinity
    @Published var target: LoudnessTarget = LoudnessTarget(rawValue: UserDefaults.standard.string(forKey: "loudness.target") ?? "") ?? .podcast {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: "loudness.target") }
    }
    private let meter = LoudnessMeter()
    private let lock = NSLock()
    private var timer: Timer?

    init() {
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.publish() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Program audio (audio thread).
    func process(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        guard lock.try() else { return }
        meter.process(left: l, right: r, frames: n)
        lock.unlock()
    }

    func reset() { lock.lock(); meter.reset(); lock.unlock(); publish() }

    private func publish() {
        lock.lock()
        let m = meter.momentary, s = meter.shortTerm, i = meter.integrated
        lock.unlock()
        func differs(_ a: Double, _ b: Double) -> Bool { (a.isFinite != b.isFinite) || (a.isFinite && abs(a - b) > 0.05) }
        if differs(m, momentary) { momentary = m }
        if differs(s, shortTerm) { shortTerm = s }
        if differs(i, integrated) { integrated = i }
    }

    static func text(_ v: Double) -> String { v.isFinite && v > -70 ? String(format: "%.1f", v) : "—" }
}

/// Loudness strip shown above the Audio tab's console.
struct LoudnessStrip: View {
    @EnvironmentObject var loudness: LoudnessMonitor
    @EnvironmentObject var engine: Engine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.33percent").foregroundColor(CP.icon)
            value("MOMENTARY", loudness.momentary)
            value("SHORT", loudness.shortTerm)
            value("INTEGRATED", loudness.integrated)
            let diff = loudness.shortTerm.isFinite ? loudness.shortTerm - loudness.target.lufs : .nan
            Text(diff.isNaN || loudness.shortTerm < -60 ? "No signal" : (abs(diff) <= 1.5 ? "On target" : (diff > 0 ? String(format: "%.0f LU too loud", diff) : String(format: "%.0f LU too quiet", -diff))))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(diff.isNaN || loudness.shortTerm < -60 ? CP.text2 : (abs(diff) <= 1.5 ? DS.ok : DS.amber))
            Spacer()
            Picker("", selection: $loudness.target) { ForEach(LoudnessTarget.allCases) { Text($0.rawValue).tag($0) } }
                .cpPickerChrome().frame(width: 200)
            Button("Reset") { loudness.reset() }.buttonStyle(.ds(.ghost, .small))
            Menu {
                Button("Podcast voice on every microphone") { engine.applyPodcastVoiceToMics() }
                Button("Podcast voice on the selected input") { if let id = engine.selectedSourceID, let s = engine.sources.first(where: { $0.id == id }) { engine.applyPodcastVoice(s) } }
            } label: { Label("Voice", systemImage: "waveform.badge.plus") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("One click: low-cut, gentle gate, compressor and presence for clear spoken voice")
        }
        .padding(.horizontal, 10).frame(height: 40)
        .background(CP.card)
        .overlay(Rectangle().fill(CP.divider).frame(height: 1), alignment: .bottom)
    }

    private func value(_ label: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 8.5, weight: .semibold)).foregroundColor(CP.text2)
            Text(LoudnessMonitor.text(v) + " LUFS").font(DS.mono(12, .semibold)).foregroundColor(CP.text)
        }
    }
}

// MARK: - Separate track per input while recording (for podcast editing)

final class MultitrackRecorder {
    private struct Track { let ring: StereoRing; let file: AVAudioFile }
    private var tracks: [UUID: Track] = [:]
    private let queue = DispatchQueue(label: "livedeck.multitrack", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    let folder: URL

    init?(folder: URL, channels: [(UUID, String)]) {
        self.folder = folder
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else { return nil }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
        for (n, ch) in channels.enumerated() {
            let safe = ch.1.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let url = folder.appendingPathComponent(String(format: "%02d %@.wav", n + 1, safe))
            guard let file = try? AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { continue }
            tracks[ch.0] = Track(ring: StereoRing(capacitySeconds: 6, primeSeconds: 0, maxLatencySeconds: 5), file: file)
        }
        guard !tracks.isEmpty else { return nil }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    /// Audio thread: one channel's post-effects, pre-fader signal.
    func write(_ id: UUID, _ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        tracks[id]?.ring.write(l, r, frames: n)
    }

    private func drain() {
        lock.lock(); defer { lock.unlock() }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 5),
              let ch = buffer.floatChannelData else { return }
        for track in tracks.values {
            let got = track.ring.read(ch[0], ch[1], frames: Int(buffer.frameCapacity))
            guard got > 0 else { continue }
            buffer.frameLength = AVAudioFrameCount(got)
            try? track.file.write(from: buffer)
        }
    }

    func finish() {
        timer?.cancel(); timer = nil
        queue.sync { drain() }
        tracks.removeAll()
    }
}

// MARK: - Engine: podcast helpers

extension Engine {
    /// Spoken-voice chain: low-cut, light gate, presence, compressor with make-up gain.
    func applyPodcastVoice(_ s: Source) {
        s.fxEnabled = true
        s.eqHPF = 80; s.eqLowGain = -1.5
        s.eqP1Freq = 300; s.eqP1Gain = -2; s.eqP1Q = 1.0
        s.eqP2Freq = 4000; s.eqP2Gain = 3; s.eqP2Q = 0.9
        s.eqHighGain = 1.5; s.eqLPF = 0
        s.gateThreshold = -52; s.gateRange = -18; s.gateAttack = 2; s.gateHold = 150; s.gateRelease = 250
        s.compThreshold = -20; s.compRatio = 3; s.compAttack = 8; s.compRelease = 150; s.compMakeup = 4
    }

    func applyPodcastVoiceToMics() {
        for s in sources where !s.isPlaceholder && s.audioDeviceID != nil { applyPodcastVoice(s) }
    }

    /// Saves the audio of a recording as an .m4a file for podcast platforms.
    func exportPodcastAudio(_ url: URL? = nil) {
        guard let source = url ?? lastRecordingURL else { return }
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return }
        let out = source.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .m4a
        export.exportAsynchronously {
            DispatchQueue.main.async {
                if export.status == .completed { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                else { NSSound.beep() }
            }
        }
    }

    func chooseRecordingForPodcastExport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audio]
        panel.directoryURL = outputFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileAccess.remember(url)
        exportPodcastAudio(url)
    }
}
