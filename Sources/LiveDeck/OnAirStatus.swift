import SwiftUI
import AppKit
import PresentationKit

// MARK: - On-air status bar (above the monitors): time, stream strength, recording and every live indicator

struct OnAirStatusBar: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var tele: Telemetry
    @EnvironmentObject var link: LinkManager
    @EnvironmentObject var automation: AutomationModel
    @EnvironmentObject var stage: StageModel
    @State private var now = Date()
    @State private var blink = false
    @State private var showStream = false
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            // time
            chip {
                VStack(alignment: .leading, spacing: 0) {
                    Text(now.formatted(.dateTime.hour().minute().second())).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundColor(DS.text)
                    Text(now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(.system(size: 8.5, weight: .semibold)).foregroundColor(DS.text3)
                }
            }
            .help("Time of day")

            if stage.timerRunning || stage.timerRemaining != 0 {
                let r = Int(stage.timerRemaining)
                chip(tint: r < 0 ? DS.program : (r < 300 ? DS.amber : nil)) {
                    label("STAGE TIMER", (r < 0 ? "-" : "") + String(format: "%d:%02d", abs(r) / 60, abs(r) % 60),
                          color: r < 0 ? DS.program : (r < 300 ? DS.amber : DS.ok))
                }
                .onTapGesture { engine.rightTab = 4 }
                .help("Stage display countdown — click to open the stage display controls")
            }

            // switcher state
            if engine.ftbOn {
                chip(tint: DS.program) { label("OUTPUT", "BLACK", color: DS.program).opacity(blink ? 1 : 0.5) }
                    .onTapGesture { engine.toggleFTB() }
                    .help("Fade to black is on — Program is black. Click to fade up.")
            }
            if !engine.keyedSources.isEmpty || !engine.previewKeys.isEmpty {
                chip(tint: DS.amber) {
                    label("KEYS", "PGM \(engine.keyedSources.count)" + (engine.previewKeys.isEmpty ? "" : " · PVW \(engine.previewKeys.count)"), color: DS.amber)
                }
                .help(keyNames)
            }
            let liveOverlays = engine.layers.filter { $0.isLive }
            if !liveOverlays.isEmpty {
                chip(tint: DS.amber) { label("OVERLAYS", "\(liveOverlays.count) on air", color: DS.amber) }
                    .onTapGesture { engine.rightTab = 2 }
                    .help(liveOverlays.map { $0.name }.joined(separator: ", "))
            }
            if automation.running {
                chip(tint: DS.ok) { label("AUTOMATION", "running", color: DS.ok) }
                    .onTapGesture { /* opened from Automation tab */ }
                    .help("Timed cues are armed")
            }
            if link.enabled {
                chip { label("LINK", "\(link.connectedPeers.count)" + (link.unread > 0 ? " · \(link.unread) msg" : ""), color: link.connectedPeers.isEmpty ? DS.text3 : DS.ok) }
                    .onTapGesture { engine.rightTab = 6; link.markRead() }
                    .help("Computers connected on the network")
            }

            Spacer(minLength: 6)

            if engine.keepingAwake {
                chip { label("POWER", "Staying awake", color: DS.ok) }
                    .help("LiveDeck is keeping the Mac awake (no sleep, screen saver or display sleep) while it is streaming, recording or showing outputs. Gear menu → Keep Mac awake to change.")
            }

            // outputs
            chip { label("PGM OUT", engine.programWindowActive ? (engine.programOutFullscreen ? "Full screen" : "Window") : "Off",
                         color: engine.programWindowActive ? DS.ok : DS.text3) }
                .onTapGesture { engine.openOutputWindow() }
                .help("Program Out — click to turn on/off")

            // frame rate
            let rate = Int(engine.frameFormat.renderRate.rounded())
            let fpsLow = tele.fps > 0 && tele.fps < rate - 2
            chip(tint: fpsLow ? DS.amber : nil) {
                label(engine.frameFormat.name(height: engine.height), "\(tele.fps)/\(rate) \(engine.frameFormat.interlaced ? "fields" : "fps")", color: fpsLow ? DS.amber : DS.text)
            }
            .help(fpsLow ? "Frame rate is low — close other apps or remove unused inputs" : "Output format and live frame rate")

            // audio
            audioChip

            // recording
            recChip

            // stream
            streamChip
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(height: 40)
        .background(Color(rgb: 0x0E0F12))
        .overlay(Rectangle().fill(DS.lineSoft).frame(height: 1), alignment: .bottom)
        .onReceive(tick) { d in now = d; blink.toggle() }
        .popover(isPresented: $showStream, arrowEdge: .bottom) { StreamDetailPopover().environmentObject(engine).environmentObject(tele) }
    }

    private var keyNames: String {
        let pgm = engine.sources.filter { engine.keyedSources.contains($0.id) }.map { $0.name }
        let pvw = engine.sources.filter { engine.previewKeys.contains($0.id) }.map { $0.name }
        return "Keyed over Program: " + (pgm.isEmpty ? "none" : pgm.joined(separator: ", ")) + "\nKeyed over Preview: " + (pvw.isEmpty ? "none" : pvw.joined(separator: ", "))
    }

    // MARK: audio

    private var audioChip: some View {
        let db = meterDB(tele.master)
        let clipping = tele.lastClip.map { now.timeIntervalSince($0) < 2 } ?? false
        let silent = (engine.isRecording || engine.isStreaming) && now.timeIntervalSince(tele.lastSignal) > 8
        let muted = engine.masterBus.muted
        let color: Color = muted || clipping ? DS.program : (silent ? DS.amber : (tele.master > 0.001 ? DS.ok : DS.text3))
        let text = muted ? "MUTED" : (clipping ? "CLIP" : (silent ? "SILENT" : (tele.master > 0.001 ? String(format: "%.0f dB", db) : "—")))
        return chip(tint: muted || clipping ? DS.program : (silent ? DS.amber : nil)) {
            HStack(spacing: 6) {
                VStack(spacing: 2) {
                    miniMeter(tele.masterL)
                    miniMeter(tele.masterR)
                }
                .frame(width: 46)
                label("AUDIO", text, color: color)
                    .opacity((muted || clipping || silent) && !blink ? 0.55 : 1)
            }
        }
        .onTapGesture { if muted { engine.masterBus.muted = false } else { engine.rightTab = 0 } }
        .help(muted ? "Master is muted — click to unmute" : (clipping ? "Audio is clipping (too loud) — lower the faders" :
              (silent ? "No sound for 8 s while recording/streaming — check microphones" : "Program audio level (click for the mixer)")))
    }

    private func miniMeter(_ level: Float) -> some View {
        GeometryReader { g in
            let db = meterDB(level)
            let f = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(LinearGradient(colors: [SK.green, SK.green, SK.amber, SK.red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width).mask(alignment: .leading) { Rectangle().frame(width: g.size.width * f) }
            }
        }
        .frame(height: 4)
    }

    // MARK: recording

    private var recChip: some View {
        let hours = StatusFormat.hoursLeft(freeBytes: tele.diskFreeBytes, mbps: Double(engine.recBitrateMbps) + 0.2)
        let lowDisk = tele.diskFreeBytes > 0 && hours < 1
        return chip(tint: engine.isRecording ? DS.program : (lowDisk ? DS.amber : nil)) {
            HStack(spacing: 6) {
                Circle().fill(engine.isRecording ? DS.program : DS.text3).frame(width: 8, height: 8)
                    .opacity(engine.isRecording && !blink ? 0.35 : 1)
                VStack(alignment: .leading, spacing: 0) {
                    Text(engine.isRecording ? "REC " + StatusFormat.duration(tele.recordSeconds) : "REC OFF")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundColor(engine.isRecording ? DS.program : DS.text3)
                    Text(engine.isRecording ? "\(StatusFormat.bytes(tele.recordBytes)) · \(hoursText(hours)) left" : (tele.diskFreeBytes > 0 ? "\(hoursText(hours)) of space" : ""))
                        .font(.system(size: 8.5, weight: .semibold)).foregroundColor(lowDisk ? DS.amber : DS.text3)
                }
            }
        }
        .onTapGesture { engine.toggleRecording() }
        .help(engine.isRecording ? "Recording — click to stop. Markers: \(max(0, engine.markers.count - 1))" : "Click to start recording")
    }

    private func hoursText(_ h: Double) -> String { h >= 10 ? String(format: "%.0f h", h) : String(format: "%.1f h", h) }

    // MARK: stream

    private var streamChip: some View {
        let h = tele.streamHealth
        let color: Color = {
            switch h.level {
            case .off: return DS.text3
            case .connecting: return DS.amber
            case .excellent, .good: return DS.ok
            case .fair: return DS.amber
            case .poor: return DS.program
            }
        }()
        let failed = !engine.isStreaming && !engine.streamReconnecting && !engine.streamError.isEmpty
        return chip(tint: engine.isStreaming ? (h.level == .poor ? DS.program : DS.program.opacity(0.7)) : (failed ? DS.program : nil)) {
            HStack(spacing: 7) {
                HStack(spacing: 3) {
                    Circle().fill(engine.isStreaming ? DS.program : (failed ? DS.program : DS.text3)).frame(width: 8, height: 8)
                        .opacity(engine.isStreaming && !blink ? 0.35 : 1)
                    Text(engine.isStreaming ? "LIVE" : (engine.streamReconnecting ? "RECONNECTING" : (failed ? "STREAM ERROR" : "OFF AIR")))
                        .font(.system(size: 11.5, weight: .heavy)).foregroundColor(engine.isStreaming || failed ? DS.program : DS.text3)
                }
                SignalBars(bars: h.bars, color: color)
                if engine.isStreaming {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(StatusFormat.duration(tele.streamSeconds)).font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundColor(DS.text)
                        Text("\(StatusFormat.bitrate(tele.streamProgress.bitrateKbps)) · \(String(format: "%.2fx", tele.streamProgress.speed)) · \(tele.streamProgress.dropFrames) dropped")
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced)).foregroundColor(color)
                    }
                    Text("→ \(engine.liveDestinations.count)").font(.system(size: 10, weight: .bold)).foregroundColor(DS.text2)
                        .help(engine.liveDestinations.map { $0.name }.joined(separator: ", "))
                } else if engine.streamReconnecting {
                    Text("try \(engine.streamReconnectAttempt + 1)").font(.system(size: 9.5, weight: .semibold)).foregroundColor(DS.amber)
                } else {
                    Text(engine.liveDestinations.isEmpty ? "no destinations" : "\(engine.liveDestinations.count) ready")
                        .font(.system(size: 9.5, weight: .semibold)).foregroundColor(DS.text3)
                }
            }
        }
        .onTapGesture { showStream = true }
        .help(engine.isStreaming ? "Stream \(h.level.rawValue.lowercased()): \(h.advice)" : (failed ? engine.streamError : "Not streaming — click for details"))
    }

    // MARK: building blocks

    private func chip<C: View>(tint: Color? = nil, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 8).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.map { $0.opacity(0.14) } ?? Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.map { $0.opacity(0.6) } ?? DS.line, lineWidth: 1))
            .contentShape(Rectangle())
    }

    private func label(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 8, weight: .heavy)).kerning(0.6).foregroundColor(DS.text3).lineLimit(1)
            Text(value).font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundColor(color).lineLimit(1)
        }
    }
}

/// Five signal-strength bars.
struct SignalBars: View {
    let bars: Int
    let color: Color
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? color : Color.white.opacity(0.12))
                    .frame(width: 4, height: CGFloat(5 + i * 4))
            }
        }
        .frame(height: 21, alignment: .bottom)
    }
}

/// Click on the stream indicator: full numbers, destinations and the latest error.
struct StreamDetailPopover: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var tele: Telemetry
    var body: some View {
        let p = tele.streamProgress
        let h = tele.streamHealth
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SignalBars(bars: h.bars, color: h.level == .poor ? DS.program : (h.level == .fair || h.level == .connecting ? DS.amber : DS.ok))
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.isStreaming ? "Stream: \(h.level.rawValue)" : "Not streaming").font(.system(size: 13, weight: .semibold)).foregroundColor(CP.text)
                    if !h.advice.isEmpty { Text(h.advice).font(.system(size: 10.5)).foregroundColor(CP.text2).fixedSize(horizontal: false, vertical: true) }
                }
            }
            if engine.isStreaming {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    row("Live for", StatusFormat.duration(tele.streamSeconds))
                    row("Sending", "\(StatusFormat.bitrate(p.bitrateKbps)) total")
                    row("Video target", StreamBitrates.label(engine.streamBitrateKbps))
                    row("Audio target", engine.streamAudio ? StreamBitrates.label(engine.streamAudioBitrateKbps) + " AAC" : "silent")
                    row("Speed", String(format: "%.2fx real time", p.speed))
                    row("Encoder fps", String(format: "%.1f", p.fps))
                    row("Dropped frames", "\(p.dropFrames)")
                    row("Sent", StatusFormat.bytes(p.totalBytes))
                    row("Audio", engine.streamAudio ? "Program mix (stereo)" : "silent track")
                }
            }
            Divider()
            Text("DESTINATIONS").font(.system(size: 9, weight: .bold)).foregroundColor(CP.text2)
            if engine.liveDestinations.isEmpty { Text("None enabled").font(.system(size: 11)).foregroundColor(CP.text2) }
            ForEach(engine.liveDestinations) { d in
                HStack { Circle().fill(engine.isStreaming ? DS.program : CP.text2).frame(width: 6, height: 6); Text("\(d.name) · \(d.platform)").font(.system(size: 11)).foregroundColor(CP.text) }
            }
            if !engine.streamError.isEmpty {
                Text(engine.streamError).font(.system(size: 10)).foregroundColor(DS.amber).textSelection(.enabled).lineLimit(6)
            }
            Toggle("Reconnect automatically if the stream drops", isOn: $engine.autoReconnectStream).font(.system(size: 11))
            if engine.streamReconnecting {
                Text("Reconnecting… attempt \(engine.streamReconnectAttempt + 1)").font(.system(size: 11, weight: .semibold)).foregroundColor(DS.amber)
            }
            HStack {
                Button(engine.isStreaming || engine.streamReconnecting ? "Stop streaming" : "Go live") { engine.toggleStream(nil) }
                    .buttonStyle(.ds(.program, .small, active: engine.isStreaming))
                    .disabled(!engine.isStreaming && !engine.streamReconnecting && engine.liveDestinations.isEmpty)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(CP.bg)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(.system(size: 11)).foregroundColor(CP.text2)
            Text(v).font(.system(size: 11, design: .monospaced)).foregroundColor(CP.text)
        }
    }
}


/// Stream settings: video and audio bitrate chosen separately (from 128 kb/s), with total and advice.
struct StreamBitrateCard: View {
    @EnvironmentObject var engine: Engine
    let streamAudioNote: String
    @State private var customVideo = ""

    var body: some View {
        let total = engine.streamBitrateKbps + (engine.streamAudio ? engine.streamAudioBitrateKbps : 0)
        let dests = max(1, engine.liveDestinations.count)
        let upload = StreamBitrates.uploadNeeded(videoKbps: engine.streamBitrateKbps, audioKbps: engine.streamAudioBitrateKbps,
                                                 audioOn: engine.streamAudio, destinations: dests)
        let rec = StreamBitrates.recommendedVideo(height: engine.height, fps: engine.frameFormat.framesPerSecond)
        CPCard(title: "Quality & audio", subtitle: "Video \(StreamBitrates.label(engine.streamBitrateKbps)) + audio \(engine.streamAudio ? StreamBitrates.label(engine.streamAudioBitrateKbps) : "off")", icon: "slider.horizontal.3") {
            SectionLabel("Video")
            CPRow(label: "Video bitrate") {
                HStack(spacing: 6) {
                    Picker("", selection: $engine.streamBitrateKbps) {
                        if !StreamBitrates.video.contains(engine.streamBitrateKbps) {
                            Text(StreamBitrates.label(engine.streamBitrateKbps) + " (custom)").tag(engine.streamBitrateKbps)
                        }
                        ForEach(StreamBitrates.video, id: \.self) { b in Text(StreamBitrates.label(b)).tag(b) }
                    }
                    .cpPickerChrome().frame(maxWidth: 140)
                    TextField("kb/s", text: $customVideo)
                        .dsField().frame(width: 62)
                        .onSubmit {
                            if let v = Int(customVideo.filter { $0.isNumber }) {
                                engine.streamBitrateKbps = min(max(v, StreamBitrates.videoRange.lowerBound), StreamBitrates.videoRange.upperBound)
                            }
                            customVideo = ""
                        }
                        .help("Type any video bitrate from 128 to 51000 kb/s and press Return")
                }
                .disabled(engine.isStreaming)
            }
            CPNote("Usual for \(engine.frameFormat.name(height: engine.height)): \(StreamBitrates.label(rec.lowerBound))–\(StreamBitrates.label(rec.upperBound)).")
            if let advice = StreamBitrates.advice(videoKbps: engine.streamBitrateKbps, height: engine.height, fps: engine.frameFormat.framesPerSecond) {
                Text(advice).font(.system(size: 10.5)).foregroundColor(DS.amber).fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
            }

            SectionLabel("Audio")
            CPToggleRow(label: "Send program audio", isOn: $engine.streamAudio, showDivider: true)
                .disabled(engine.isStreaming)
            CPRow(label: "Audio bitrate (AAC stereo)") {
                Picker("", selection: $engine.streamAudioBitrateKbps) {
                    ForEach(StreamBitrates.audio, id: \.self) { b in Text(StreamBitrates.label(b)).tag(b) }
                }
                .cpPickerChrome().frame(maxWidth: 140)
                .disabled(engine.isStreaming || !engine.streamAudio)
            }
            CPNote(engine.streamAudioBitrateKbps >= 256 ? "256–320 kb/s suits music-heavy services." : "128–160 kb/s is clear for speech; choose 192 kb/s or more for worship music.")

            SectionLabel("Total")
            HStack(alignment: .firstTextBaseline) {
                Text(StreamBitrates.label(total)).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundColor(CP.text)
                Text("per destination").font(.system(size: 10)).foregroundColor(CP.text2)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Upload needed").font(.system(size: 9, weight: .bold)).foregroundColor(CP.text2)
                    Text("≈ \(StreamBitrates.label(upload))").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(CP.text)
                }
            }
            .padding(.vertical, 4)
            CPNote("Upload needed = total × \(dests) destination\(dests == 1 ? "" : "s") + 50% headroom. Test your internet upload speed before the service.")
            CPNote(streamAudioNote)
            if engine.isStreaming { CPNote("Stop streaming to change bitrates.") }
        }
    }
}
