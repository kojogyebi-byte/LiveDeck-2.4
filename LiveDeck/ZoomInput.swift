import SwiftUI
import AppKit
import ScreenCaptureKit
import CoreMedia
import PresentationKit

/// Inputs that produce their own audio (Zoom window, RTMP receiver). The engine connects `audioSink`
/// to the input's mixer channel; this audio is treated like a microphone (kept out of the speakers
/// unless "hear mics" is on, so Zoom never echoes back into the meeting).
protocol LiveAudioSource: AnyObject {
    var audioSink: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)? { get set }
}

// MARK: - App window capture (Zoom, Teams, browsers…)

final class WindowCaptureSource: Source, SCStreamOutput, SCStreamDelegate, LiveAudioSource {
    static let zoomBundleIDs = ["us.zoom.xos", "us.zoom.ZoomClips"]

    @Published var status = "Starting…"
    let appBundleID: String?
    let appName: String
    private(set) var windowTitle: String
    private var windowID: CGWindowID
    var captureAudio: Bool
    var audioSink: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "livedeck.window.capture", qos: .userInteractive)
    private var scratchL = [Float](repeating: 0, count: 8192)
    private var scratchR = [Float](repeating: 0, count: 8192)
    private var retryTimer: Timer?
    private var stopped = false

    init(window: SCWindow, captureAudio: Bool = true) {
        appBundleID = window.owningApplication?.bundleIdentifier
        appName = window.owningApplication?.applicationName ?? "Window"
        windowTitle = window.title ?? appName
        windowID = window.windowID
        self.captureAudio = captureAudio
        let isZoom = WindowCaptureSource.zoomBundleIDs.contains(appBundleID ?? "")
        super.init(name: isZoom ? "Zoom" : appName, kindLabel: isZoom ? "ZOOM" : "WINDOW")
        originLocation = appBundleID
        Task { await start(window) }
    }

    static func shareableWindows(zoomOnly: Bool) async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let mine = Bundle.main.bundleIdentifier
        return content.windows.filter { w in
            guard let app = w.owningApplication, app.bundleIdentifier != mine, w.frame.width >= 240, w.frame.height >= 160 else { return false }
            if zoomOnly { return zoomBundleIDs.contains(app.bundleIdentifier) }
            return !(w.title ?? "").isEmpty
        }
        .sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }
    }

    private func start(_ w: SCWindow) async {
        do {
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let cfg = SCStreamConfiguration()
            let scale: CGFloat = 2
            let maxW: CGFloat = 1920
            let fw = min(maxW, w.frame.width * scale)
            cfg.width = Int(fw)
            cfg.height = Int(fw * w.frame.height / max(1, w.frame.width))
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = false
            cfg.queueDepth = 5
            if captureAudio {
                cfg.capturesAudio = true
                cfg.sampleRate = 48000
                cfg.channelCount = 2
                cfg.excludesCurrentProcessAudio = true
            }
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if captureAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            try await s.startCapture()
            await MainActor.run {
                self.stream = s
                self.windowID = w.windowID
                self.windowTitle = w.title ?? self.appName
                self.status = "Showing “\(self.windowTitle)”"
            }
        } catch {
            await MainActor.run {
                self.status = "Cannot capture: \(error.localizedDescription). Allow LiveDeck in System Settings → Privacy & Security → Screen & System Audio Recording."
                self.scheduleRetry()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            DispatchQueue.main.async { [weak self] in self?.latestBuffer = pb }
        case .audio:
            guard let sink = audioSink else { return }
            let frames = CMSampleBufferGetNumSamples(sb)
            guard frames > 0 else { return }
            try? sb.withAudioBufferList { abl, _ in
                guard abl.count > 0, let l = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                let n = min(frames, scratchL.count)
                if abl.count > 1, let r = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                    sink(l, r, n)
                } else if abl[0].mNumberChannels >= 2 {
                    for i in 0..<n { scratchL[i] = l[i * 2]; scratchR[i] = l[i * 2 + 1] }
                    scratchL.withUnsafeBufferPointer { lp in scratchR.withUnsafeBufferPointer { rp in sink(lp.baseAddress!, rp.baseAddress!, n) } }
                } else {
                    sink(l, l, n)
                }
            }
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stream = nil
            self.status = "The window closed — looking for it again…"
            self.scheduleRetry()
        }
    }

    /// Zoom often replaces its meeting window (joining, leaving full screen…). Find the app's best window again.
    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.findAgain() }
    }

    func findAgain() {
        guard !stopped else { return }
        let bundle = appBundleID, previousID = windowID, title = windowTitle
        Task {
            let wins = (try? await WindowCaptureSource.shareableWindows(zoomOnly: false)) ?? []
            let candidates = wins.filter { $0.owningApplication?.bundleIdentifier == bundle }
            let pick = candidates.first { $0.windowID == previousID } ?? candidates.first { $0.title == title } ?? candidates.first
            if let pick {
                try? await self.stream?.stopCapture()
                await self.start(pick)
            } else {
                await MainActor.run { self.status = "Waiting for \(self.appName) to open a window…"; self.scheduleRetry() }
            }
        }
    }

    func switchTo(_ w: SCWindow) {
        Task {
            try? await stream?.stopCapture()
            await start(w)
        }
    }

    override func stop() {
        stopped = true
        retryTimer?.invalidate()
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }
}

// MARK: - RTMP receiver (Zoom "Custom Live Streaming Service", OBS, encoders…)

final class RTMPListenSource: Source, LiveAudioSource {
    @Published var status = "Starting…"
    let port: Int
    let streamKey: String
    var audioSink: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)?
    private let outW = 1280, outH = 720
    private var process: Process?
    private var running = true
    private var frameImage: CGImage?

    init(port: Int = 1935, streamKey: String = "zoom", name: String = "Zoom stream") {
        self.port = port; self.streamKey = streamKey
        super.init(name: name, kindLabel: "RTMP IN")
        originLocation = "\(port)|\(streamKey)"
        launch()
    }

    var publishURL: String { "rtmp://\(RTMPListenSource.localIPAddress() ?? "this-mac-ip"):\(port)/live" }

    private func launch() {
        guard running else { return }
        guard let ff = StreamOutput.ffmpegPath() else {
            status = "ffmpeg is not installed (Terminal: brew install ffmpeg)"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-hide_banner", "-nostats", "-loglevel", "quiet",
                       "-listen", "1", "-i", "rtmp://0.0.0.0:\(port)/live/\(streamKey)",
                       "-map", "0:v:0", "-vf", "scale=\(outW):\(outH)", "-pix_fmt", "bgra", "-f", "rawvideo", "pipe:1",
                       "-map", "0:a:0?", "-ac", "2", "-ar", "48000", "-f", "f32le", "pipe:2"]
        let vPipe = Pipe(), aPipe = Pipe()
        p.standardOutput = vPipe
        p.standardError = aPipe
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.status = "Waiting for a stream on \(self.publishURL) (key: \(self.streamKey))"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.launch() }
            }
        }
        do { try p.run() } catch { status = "Could not start ffmpeg: \(error.localizedDescription)"; return }
        process = p
        status = "Waiting for a stream on \(publishURL) (key: \(streamKey))"
        let vh = vPipe.fileHandleForReading, ah = aPipe.fileHandleForReading
        Thread.detachNewThread { [weak self] in self?.videoLoop(vh) }
        Thread.detachNewThread { [weak self] in self?.audioLoop(ah) }
    }

    private func videoLoop(_ h: FileHandle) {
        let frameSize = outW * outH * 4
        var buffer = Data()
        var announced = false
        while running {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while buffer.count >= frameSize {
                let frame = Data(buffer.prefix(frameSize))
                buffer.removeFirst(frameSize)
                if let cg = FFmpegStreamSource.image(from: frame, w: outW, h: outH) {
                    let first = !announced
                    announced = true
                    DispatchQueue.main.async { [weak self] in
                        self?.frameImage = cg
                        if first { self?.status = "Receiving the stream" }
                    }
                }
            }
        }
    }

    private func audioLoop(_ h: FileHandle) {
        var pending = Data()
        var l = [Float](repeating: 0, count: 16384), r = [Float](repeating: 0, count: 16384)
        while running {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            let frames = min(pending.count / 8, l.count)
            guard frames > 0 else { continue }
            pending.withUnsafeBytes { raw in
                let f = raw.bindMemory(to: Float.self)
                for i in 0..<frames { l[i] = f[i * 2]; r[i] = f[i * 2 + 1] }
            }
            pending.removeFirst(frames * 8)
            if let sink = audioSink {
                l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in sink(lp.baseAddress!, rp.baseAddress!, frames) } }
            }
        }
    }

    override func currentImage() -> CGImage? { frameImage }

    override func stop() {
        running = false
        process?.terminate()
    }

    /// First IPv4 address of an active Ethernet/Wi-Fi interface.
    static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                let name = String(cString: p.pointee.ifa_name)
                if name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: host)
                        if name == "en0" { break }
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return address
    }
}

// MARK: - Zoom setup window

struct ZoomSetupView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("zoom.lastMeeting") private var meetingText = ""
    @AppStorage("zoom.displayName") private var displayName = "LiveDeck"
    @AppStorage("zoom.rtmpPort") private var rtmpPort = 1935
    @AppStorage("zoom.rtmpKey") private var rtmpKey = "zoom"
    @State private var passcode = ""
    @State private var windows: [SCWindow] = []
    @State private var allApps = false
    @State private var includeAudio = true
    @State private var message = ""
    @State private var loading = false
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var zoomInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "us.zoom.xos") != nil }
    private var meeting: ZoomMeeting? { ZoomMeeting.parse(meetingText, passcode: passcode) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "video.bubble.left.fill").font(.system(size: 20)).foregroundColor(Color(rgb: 0x2D8CFF))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Zoom meeting").font(.system(size: 14, weight: .semibold)).foregroundColor(CP.text)
                    Text("Join a meeting and show it as an input — video and meeting audio").font(.system(size: 10)).foregroundColor(CP.text2)
                }
                Spacer()
                CPButton(title: "Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14).frame(height: 54).background(CP.cardHeader)

            CPInspector {
                CPCard(title: "1 · Join", subtitle: zoomInstalled ? "Zoom app installed" : "Zoom app not found", icon: "phone.arrow.up.right") {
                    CPTextRow(label: "Link or meeting ID", text: $meetingText, prompt: "https://zoom.us/j/…  or  850 1234 5678", showDivider: true)
                    CPTextRow(label: "Passcode", text: $passcode, prompt: "if not in the link", secure: true, showDivider: true)
                    CPTextRow(label: "Your name in Zoom", text: $displayName)
                    HStack(spacing: 6) {
                        CPButton(icon: "video.fill", title: "Join in Zoom app", prominent: true) {
                            guard let m = meeting, let u = m.appURL(displayName: displayName) else { message = "Enter a valid Zoom link or meeting ID."; return }
                            NSWorkspace.shared.open(u)
                            message = "Zoom is opening meeting \(m.displayID). When the meeting window appears, add it below."
                        }
                        .disabled(meeting == nil || !zoomInstalled)
                        if let m = meeting, let web = m.webURL {
                            CPButton(icon: "safari", title: "Open in browser") { NSWorkspace.shared.open(web) }
                        }
                        Spacer()
                        if !zoomInstalled {
                            Button("Get Zoom") { NSWorkspace.shared.open(URL(string: "https://zoom.us/download")!) }.buttonStyle(.ds(.ghost, .small))
                        }
                    }
                    .padding(.vertical, 6)
                    if !message.isEmpty { CPNote(message) }
                }

                CPCard(title: "2 · Show the meeting window", subtitle: windows.isEmpty ? "No windows found yet" : "\(windows.count) window(s)", icon: "macwindow.on.rectangle") {
                    HStack {
                        DSSegmented(selection: $allApps, options: [(false, "Zoom windows"), (true, "All apps")]).frame(width: 200)
                        Spacer()
                        CPToggleRow(label: "Meeting audio", isOn: $includeAudio)
                        CPButton(icon: "arrow.clockwise", title: "") { reload() }
                    }
                    .padding(.vertical, 4)
                    if windows.isEmpty {
                        CPNote(allApps ? "No app windows found. LiveDeck needs Screen & System Audio Recording permission (System Settings → Privacy & Security)."
                                       : "Join the meeting first. The Zoom meeting window appears here within a few seconds.")
                    }
                    ForEach(windows, id: \.windowID) { w in
                        CPDivider()
                        HStack(spacing: 8) {
                            Image(systemName: WindowCaptureSource.zoomBundleIDs.contains(w.owningApplication?.bundleIdentifier ?? "") ? "video.fill" : "macwindow")
                                .foregroundColor(CP.icon).frame(width: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(w.title?.isEmpty == false ? w.title! : "Untitled window").font(.system(size: 11.5, weight: .medium)).foregroundColor(CP.text).lineLimit(1)
                                Text("\(w.owningApplication?.applicationName ?? "") · \(Int(w.frame.width))×\(Int(w.frame.height))")
                                    .font(.system(size: 9)).foregroundColor(CP.text2)
                            }
                            Spacer()
                            CPButton(icon: "plus", title: "Add as input", prominent: true) {
                                engine.placeInput(WindowCaptureSource(window: w, captureAudio: includeAudio))
                                message = "Added. Use Preview / Program or key it like any input; crop the Zoom toolbar in the Input panel."
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    CPNote("Tips: use Speaker or Gallery view, hide the Zoom toolbar (Zoom Settings → General → uncheck ‘Always show meeting controls’), pin or spotlight the speaker, and crop the edges in the Input panel. Zoom audio is kept out of your speakers to avoid echo; it is recorded and streamed.")
                }

                CPCard(title: "Alternative · Receive Zoom's live stream (RTMP)", subtitle: StreamOutput.ffmpegPath() == nil ? "needs ffmpeg" : "for hosts: no window needed", icon: "antenna.radiowaves.left.and.right") {
                    CPRow(label: "Port") {
                        TextField("", value: $rtmpPort, format: .number.grouping(.never)).dsField().frame(width: 80)
                    }
                    CPTextRow(label: "Stream key", text: $rtmpKey, showDivider: true)
                    let url = "rtmp://\(RTMPListenSource.localIPAddress() ?? "this-mac-ip"):\(rtmpPort)/live"
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Stream URL: \(url)").font(DS.mono(10)).foregroundColor(CP.text).textSelection(.enabled)
                            Text("Stream key: \(rtmpKey)").font(DS.mono(10)).foregroundColor(CP.text).textSelection(.enabled)
                        }
                        Spacer()
                        CPButton(icon: "doc.on.doc", title: "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("Stream URL: \(url)\nStream key: \(rtmpKey)", forType: .string)
                        }
                    }
                    .padding(.vertical, 6)
                    HStack {
                        CPButton(icon: "plus", title: "Add Zoom stream input", prominent: true) {
                            engine.placeInput(RTMPListenSource(port: rtmpPort, streamKey: rtmpKey.isEmpty ? "zoom" : rtmpKey))
                            message = "Stream input added — now start the live stream in Zoom."
                        }
                        .disabled(StreamOutput.ffmpegPath() == nil)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    CPNote("In the Zoom web portal turn on Settings → In Meeting (Advanced) → Allow live streaming → Custom Live Streaming Service. In the meeting: More → Live on Custom Live Streaming Service, paste the URL and key above. Zoom sends the meeting's video and audio here (a few seconds behind).")
                }

                CPCard(title: "Zoom inside LiveDeck", subtitle: "Each participant as a separate input", icon: "person.2.wave.2") {
                    CPNote("Join the meeting directly in LiveDeck with the Zoom Meeting SDK and add every participant as their own input with their voice — no window capture.")
                    HStack {
                        CPButton(icon: "person.crop.rectangle.stack", title: "Open built-in Zoom", prominent: true) {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { engine.showZoomMeeting = true }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                CPCard(title: "Send LiveDeck into Zoom", icon: "rectangle.on.rectangle") {
                    CPNote("Best: Outputs → LiveDeck Camera, then choose “LiveDeck Camera” as your camera in Zoom (Xcode / App Store build).")
                    CPNote("Open PROGRAM OUT in a window, then in Zoom choose Share Screen → “LiveDeck — Program Out” (tick ‘Share sound’). Participants see your Program with lyrics, scripture and overlays.")
                    HStack {
                        CPButton(icon: "macwindow", title: "Open Program Out window") { engine.showProgramOut(fullscreen: false) }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 640, height: 720)
        .background(CP.bg)
        .preferredColorScheme(.dark)
        .onAppear { reload() }
        .onReceive(refresh) { _ in reload() }
        .onChange(of: allApps) { _ in reload() }
    }

    private func reload() {
        guard !loading else { return }
        loading = true
        let zoomOnly = !allApps
        Task {
            let w = (try? await WindowCaptureSource.shareableWindows(zoomOnly: zoomOnly)) ?? []
            await MainActor.run { windows = w; loading = false }
        }
    }
}

/// Input panel card for window / RTMP inputs.
struct CaptureStatusCard: View {
    @ObservedObject var source: Source
    var body: some View {
        if let w = source as? WindowCaptureSource {
            WindowStatus(source: w)
        } else if let r = source as? RTMPListenSource {
            RTMPStatus(source: r)
        }
    }
}

private struct WindowStatus: View {
    @ObservedObject var source: WindowCaptureSource
    @State private var windows: [SCWindow] = []
    var body: some View {
        CPCard(title: source.kindLabel == "ZOOM" ? "Zoom meeting window" : "Window capture", subtitle: source.appName, icon: "macwindow") {
            CPNote(source.status)
            HStack(spacing: 6) {
                CPButton(icon: "arrow.clockwise", title: "Find window again") { source.findAgain() }
                Menu("Switch window") {
                    ForEach(windows, id: \.windowID) { w in Button(w.title ?? "Untitled") { source.switchTo(w) } }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }
            .padding(.vertical, 6)
            .onAppear {
                Task {
                    let all = (try? await WindowCaptureSource.shareableWindows(zoomOnly: false)) ?? []
                    let mine = all.filter { $0.owningApplication?.bundleIdentifier == source.appBundleID }
                    await MainActor.run { windows = mine }
                }
            }
        }
    }
}

private struct RTMPStatus: View {
    @ObservedObject var source: RTMPListenSource
    var body: some View {
        CPCard(title: "Stream receiver", subtitle: "\(source.publishURL) · key \(source.streamKey)", icon: "antenna.radiowaves.left.and.right") {
            CPNote(source.status)
        }
    }
}
