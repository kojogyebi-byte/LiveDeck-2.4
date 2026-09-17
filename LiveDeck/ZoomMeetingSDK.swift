import SwiftUI
import AppKit
import Accelerate
import PresentationKit

// MARK: - Zoom inside LiveDeck (Zoom Meeting SDK)
//
// Compiled with ZOOM_SDK (set by the Xcode project, which also adds the Objective-C bridge in Sources/ZoomBridge).
// The bridge talks to ZoomSDK.framework when AppStore/Vendor/ZoomSDK is present; otherwise it reports "not included".

#if ZOOM_SDK

final class ZoomMeetingModel: NSObject, ObservableObject, LDZoomBridgeDelegate {
    static let shared = ZoomMeetingModel()

    @Published private(set) var state: LDZoomState = LDZoomBridge.isSDKAvailable() ? .idle : .unavailable
    @Published private(set) var message = ""
    @Published private(set) var participants: [LDZoomParticipant] = []
    @Published private(set) var rawAllowed = false
    @Published private(set) var rawMessage = ""

    @Published var sdkKey: String = KeychainStore.get("zoom.sdkKey") { didSet { KeychainStore.set(sdkKey, for: "zoom.sdkKey") } }
    @Published var sdkSecret: String = KeychainStore.get("zoom.sdkSecret") { didSet { KeychainStore.set(sdkSecret, for: "zoom.sdkSecret") } }
    @Published var tokenURL: String = UserDefaults.standard.string(forKey: "zoom.tokenURL") ?? "" { didSet { UserDefaults.standard.set(tokenURL, forKey: "zoom.tokenURL") } }
    @Published var meetingText: String = UserDefaults.standard.string(forKey: "zoom.sdk.meeting") ?? "" { didSet { UserDefaults.standard.set(meetingText, forKey: "zoom.sdk.meeting") } }
    @Published var passcode = ""
    /// For meetings outside the Zoom account that owns the SDK app: the joining user's ZAK or On-Behalf-Of token.
    @Published var zakToken = ""
    @Published var obfToken = ""
    @Published var displayName: String = UserDefaults.standard.string(forKey: "zoom.sdk.name") ?? "LiveDeck Studio" { didSet { UserDefaults.standard.set(displayName, forKey: "zoom.sdk.name") } }

    /// Audio subscribers by Zoom user ID (0 = mixed meeting audio).
    private var audioSinks: [UInt32: (UnsafePointer<Int16>, Int, Int, Int) -> Void] = [:]
    private let audioLock = NSLock()
    private var pendingJoin = false

    override init() {
        super.init()
        LDZoomBridge.shared().delegate = self
    }

    var sdkVersion: String { LDZoomBridge.shared().sdkVersion }
    var inMeeting: Bool { state == .inMeeting }

    // MARK: actions

    func authorizeAndJoin() {
        guard LDZoomBridge.isSDKAvailable() else { state = .unavailable; message = "The Zoom Meeting SDK is not included in this build."; return }
        guard ZoomMeeting.parse(meetingText, passcode: passcode) != nil else { message = "Enter a valid Zoom link or meeting ID."; return }
        pendingJoin = true
        if state == .ready { join(); return }
        obtainToken { [weak self] token, error in
            guard let self else { return }
            guard let token else { self.state = .failed; self.message = error ?? "No Zoom SDK token."; self.pendingJoin = false; return }
            LDZoomBridge.shared().authorize(withJWT: token)
        }
    }

    private func join() {
        guard let m = ZoomMeeting.parse(meetingText, passcode: passcode) else { return }
        pendingJoin = false
        LDZoomBridge.shared().joinMeeting(m.id, password: m.passcode, displayName: displayName,
                                          zak: zakToken.trimmingCharacters(in: .whitespacesAndNewlines),
                                          onBehalfToken: obfToken.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func leave() {
        audioLock.lock(); audioSinks.removeAll(); audioLock.unlock()
        LDZoomBridge.shared().leaveMeeting()
    }

    func requestAccess() { LDZoomBridge.shared().requestRawData() }

    /// SDK token: from your token server if a URL is set, otherwise signed locally with the SDK Key and Secret.
    private func obtainToken(_ done: @escaping (String?, String?) -> Void) {
        let url = tokenURL.trimmingCharacters(in: .whitespaces)
        if !url.isEmpty, let u = URL(string: url) {
            URLSession.shared.dataTask(with: u) { data, _, error in
                let token = data.flatMap { ZoomSDKToken.parseServerResponse($0) }
                DispatchQueue.main.async { done(token, token == nil ? "The token server did not return a token\(error.map { ": \($0.localizedDescription)" } ?? ".")" : nil) }
            }.resume()
            return
        }
        let key = sdkKey.trimmingCharacters(in: .whitespaces), secret = sdkSecret.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !secret.isEmpty else { done(nil, "Enter the Zoom SDK Key and Secret (Zoom App Marketplace → your Meeting SDK app → App Credentials)."); return }
        done(ZoomSDKToken.make(sdkKey: key, sdkSecret: secret), nil)
    }

    // MARK: audio fan-out

    func addAudioSink(user: UInt32, _ sink: @escaping (UnsafePointer<Int16>, Int, Int, Int) -> Void) -> String? {
        audioLock.lock(); audioSinks[user] = sink; audioLock.unlock()
        var err: NSString?
        let ok = LDZoomBridge.shared().startAudio({ [weak self] userID, pcm, frames, channels, rate in
            guard let self else { return }
            self.audioLock.lock(); let s = self.audioSinks[userID]; self.audioLock.unlock()
            s?(pcm, Int(frames), Int(channels), Int(rate))
        }, error: &err)
        return ok ? nil : (err as String? ?? "Audio unavailable")
    }

    func removeAudioSink(user: UInt32) {
        audioLock.lock(); audioSinks[user] = nil; let empty = audioSinks.isEmpty; audioLock.unlock()
        if empty { LDZoomBridge.shared().stopAudio() }
    }

    // MARK: bridge delegate

    func zoomStateChanged(_ state: LDZoomState, message: String) {
        DispatchQueue.main.async {
            self.state = state
            self.message = message
            if state == .ready && self.pendingJoin { self.join() }
            if state == .ended || state == .failed { self.participants = []; self.rawAllowed = false }
        }
    }

    func zoomParticipantsChanged() {
        DispatchQueue.main.async { self.participants = LDZoomBridge.shared().participants() }
    }

    func zoomRawDataChanged(_ allowed: Bool, message: String) {
        DispatchQueue.main.async {
            self.rawAllowed = allowed
            self.rawMessage = message
            self.participants = LDZoomBridge.shared().participants()
            NotificationCenter.default.post(name: .zoomRawDataChanged, object: nil)
        }
    }
}

extension Notification.Name { static let zoomRawDataChanged = Notification.Name("livedeck.zoom.rawData") }

/// One Zoom participant (or the whole meeting's audio) as an input.
final class ZoomParticipantSource: Source, LiveAudioSource {
    let zoomUserID: UInt32
    let highQuality: Bool
    @Published var status = "Waiting for video…"
    var audioSink: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)?
    private var token: String?
    private let lock = NSLock()
    private var image: CGImage?
    private var argb: [UInt8] = []
    private var info = vImage_YpCbCrToARGB()
    private var infoReady = false
    private var left: [Float] = [], right: [Float] = []
    private var observer: NSObjectProtocol?
    let audioOnly: Bool

    init(userID: UInt32, name: String, highQuality: Bool, audioOnly: Bool = false) {
        zoomUserID = userID
        self.highQuality = highQuality
        self.audioOnly = audioOnly
        super.init(name: name, kindLabel: audioOnly ? "ZOOM AUDIO" : "ZOOM")
        originLocation = "zoom:\(userID)"
        subscribe()
        observer = NotificationCenter.default.addObserver(forName: .zoomRawDataChanged, object: nil, queue: .main) { [weak self] _ in
            if self?.token == nil { self?.subscribe() }
        }
    }

    private func subscribe() {
        let model = ZoomMeetingModel.shared
        if let err = model.addAudioSink(user: audioOnly ? 0 : zoomUserID, { [weak self] pcm, frames, channels, rate in
            self?.deliverAudio(pcm, frames: frames, channels: channels, rate: rate)
        }) {
            status = err
        }
        guard !audioOnly else { if model.rawAllowed { status = "Receiving meeting audio" }; return }
        var err: NSString?
        token = LDZoomBridge.shared().subscribeVideo(forUser: zoomUserID, highQuality: highQuality, handler: { [weak self] y, u, v, w, h in
            self?.convert(y: y, u: u, v: v, width: Int(w), height: Int(h))
        }, error: &err)
        if token == nil { status = (err as String?) ?? "Video unavailable" } else { status = "Receiving video" }
    }

    private func convert(y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if !infoReady {
            var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
            infoReady = vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &range, &info,
                                                                       kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            if !infoReady { return }
        }
        let count = width * height * 4
        if argb.count != count { argb = [UInt8](repeating: 0, count: count) }
        var yBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: y), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
        var uBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: u), height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2), rowBytes: width / 2)
        var vBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: v), height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2), rowBytes: width / 2)
        let ok: Bool = argb.withUnsafeMutableBytes { raw -> Bool in
            var dst = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            var map: [UInt8] = [0, 1, 2, 3]
            return vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&yBuf, &uBuf, &vBuf, &dst, &info, &map, 255, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard ok, let provider = CGDataProvider(data: Data(argb) as CFData) else { return }
        image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func deliverAudio(_ pcm: UnsafePointer<Int16>, frames: Int, channels: Int, rate: Int) {
        guard let sink = audioSink, frames > 0 else { return }
        // to 48 kHz stereo float
        let ratio = 48000.0 / Double(max(8000, rate))
        let out = Int(Double(frames) * ratio)
        guard out > 0 else { return }
        if left.count < out { left = [Float](repeating: 0, count: out); right = left }
        let ch = max(1, channels)
        for i in 0..<out {
            let src = min(frames - 1, Int(Double(i) / ratio))
            let l = Float(pcm[src * ch]) / 32768
            let r = ch > 1 ? Float(pcm[src * ch + 1]) / 32768 : l
            left[i] = l; right[i] = r
        }
        left.withUnsafeBufferPointer { lp in right.withUnsafeBufferPointer { rp in sink(lp.baseAddress!, rp.baseAddress!, out) } }
    }

    override func currentImage() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return image
    }

    override func draw(in ctx: CGContext, rect: CGRect) {
        if audioOnly || currentImage() == nil {
            ctx.setFillColor(NSColor(white: 0.06, alpha: 1).cgColor); ctx.fill(rect)
            let s = rect.height / 1080
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let t = NSAttributedString(string: audioOnly ? "Zoom meeting audio" : name,
                                       attributes: [.font: NSFont.systemFont(ofSize: 64 * s, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: para])
            let sub = NSAttributedString(string: status, attributes: [.font: NSFont.systemFont(ofSize: 34 * s), .foregroundColor: NSColor(white: 0.65, alpha: 1), .paragraphStyle: para])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            t.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: 90 * s))
            sub.draw(in: CGRect(x: rect.minX + 40 * s, y: rect.midY - 70 * s, width: rect.width - 80 * s, height: 60 * s))
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        super.draw(in: ctx, rect: rect)
    }

    override func stop() {
        if let t = token { LDZoomBridge.shared().unsubscribeVideo(t) }
        token = nil
        ZoomMeetingModel.shared.removeAudioSink(user: audioOnly ? 0 : zoomUserID)
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }
}

/// Built-in Zoom meeting window (credentials, join, access, participants).
struct ZoomMeetingPanel: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var zoom = ZoomMeetingModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var highQuality = true
    @State private var showCredentials = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "video.bubble.left.fill").font(.system(size: 20)).foregroundColor(CP.icon)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Zoom inside LiveDeck").font(.system(size: 14, weight: .semibold)).foregroundColor(CP.text)
                    Text(zoom.state == .unavailable ? "Zoom Meeting SDK not included in this build" : "Join a meeting and use each participant as an input")
                        .font(CPFont.caption).foregroundColor(CP.text2)
                }
                Spacer()
                CPButton(title: "Done", prominent: true) { dismiss() }
            }
            .padding(.horizontal, 14).frame(height: 54).background(CP.cardHeader)

            CPInspector {
                if zoom.state == .unavailable {
                    CPCard(title: "Not available in this build", icon: "exclamationmark.triangle") {
                        CPNote("Built-in Zoom needs the Zoom Meeting SDK for macOS. Download it from the Zoom App Marketplace, put it in AppStore/Vendor/ZoomSDK and run AppStore/scripts/prepare-appstore.sh again (see ZOOM_AND_CAMERA_GUIDE.md). Until then use Add Input → Zoom Meeting / App Window.")
                    }
                } else {
                    CPCard(title: "Zoom SDK credentials", subtitle: credentialsSubtitle, icon: "key") {
                        if showCredentials || zoom.sdkKey.isEmpty && zoom.tokenURL.isEmpty {
                            CPTextRow(label: "SDK Key (Client ID)", text: $zoom.sdkKey, showDivider: true)
                            CPTextRow(label: "SDK Secret", text: $zoom.sdkSecret, secure: true, showDivider: true)
                            CPTextRow(label: "Or token server URL", text: $zoom.tokenURL, prompt: "optional — https://…")
                            CPNote("Zoom App Marketplace → Develop → your General app with Meeting SDK → App Credentials. The key and secret are stored in the Mac's Keychain. For apps given to other churches, use a token server instead of sharing the secret.")
                        } else {
                            HStack { Text(zoom.tokenURL.isEmpty ? "Key and secret saved in the Keychain" : "Using the token server").font(CPFont.caption).foregroundColor(CP.text2); Spacer()
                                Button("Change") { showCredentials = true }.buttonStyle(.ds(.ghost, .small)) }
                        }
                    }

                    CPCard(title: "Meeting", subtitle: stateText, icon: "phone.arrow.up.right", iconColor: zoom.inMeeting ? DS.ok : CP.icon) {
                        CPTextRow(label: "Link or meeting ID", text: $zoom.meetingText, prompt: "https://zoom.us/j/…", showDivider: true)
                        CPTextRow(label: "Passcode", text: $zoom.passcode, prompt: "if not in the link", secure: true, showDivider: true)
                        CPTextRow(label: "Name in the meeting", text: $zoom.displayName, showDivider: true)
                        DisclosureGroup {
                            CPTextRow(label: "ZAK token", text: $zoom.zakToken, prompt: "optional", secure: true, showDivider: true)
                            CPTextRow(label: "On-behalf token", text: $zoom.obfToken, prompt: "optional", secure: true)
                            CPNote("Only for meetings hosted outside your own Zoom account: Zoom requires the SDK app to be reviewed by Zoom and to join with a ZAK or On-Behalf-Of token of a signed-in user.")
                        } label: {
                            Text("Meeting on another Zoom account").font(CPFont.caption).foregroundColor(CP.text2)
                        }
                        .padding(.vertical, 4)
                        HStack(spacing: 6) {
                            if zoom.inMeeting || zoom.state == .joining || zoom.state == .waiting {
                                CPButton(icon: "phone.down.fill", title: "Leave meeting") { zoom.leave() }
                            } else {
                                CPButton(icon: "video.fill", title: "Join meeting", prominent: true) { zoom.authorizeAndJoin() }
                            }
                            Spacer()
                            if !zoom.sdkVersion.isEmpty { Text("SDK \(zoom.sdkVersion)").font(CPFont.caption).foregroundColor(CP.text2) }
                        }
                        .padding(.vertical, 6)
                        if !zoom.message.isEmpty { CPNote(zoom.message) }
                    }

                    if zoom.inMeeting {
                        CPCard(title: "Video and audio access", subtitle: zoom.rawAllowed ? "Granted" : "Needs the host", icon: "lock.open",
                               iconColor: zoom.rawAllowed ? DS.ok : DS.amber) {
                            CPNote(zoom.rawAllowed ? "LiveDeck can receive participants' video and the meeting audio."
                                   : "Zoom only lets LiveDeck receive video when the host allows it: make “\(zoom.displayName)” a co-host, or click Allow when asked to let it record.")
                            if !zoom.rawMessage.isEmpty { Text(zoom.rawMessage).font(CPFont.caption).foregroundColor(zoom.rawAllowed ? DS.ok : DS.amber) }
                            if !zoom.rawAllowed {
                                HStack { CPButton(icon: "hand.raised", title: "Request access") { zoom.requestAccess() }; Spacer() }.padding(.vertical, 4)
                            }
                        }

                        CPCard(title: "Participants", subtitle: "\(zoom.participants.count) in the meeting", icon: "person.2") {
                            CPToggleRow(label: "High quality (1080p) video", isOn: $highQuality)
                            HStack {
                                Text("Whole meeting audio").font(CPFont.emphasis).foregroundColor(CP.text)
                                Spacer()
                                CPButton(icon: "plus", title: "Add as input") {
                                    engine.placeInput(ZoomParticipantSource(userID: 0, name: "Zoom audio", highQuality: false, audioOnly: true))
                                }
                                .disabled(!zoom.rawAllowed)
                            }
                            .padding(.vertical, 6)
                            ForEach(zoom.participants.filter { !$0.isMe }, id: \.userID) { p in
                                CPDivider()
                                HStack(spacing: 8) {
                                    Image(systemName: p.videoOn ? "video.fill" : "video.slash").foregroundColor(p.videoOn ? CP.icon : CP.text2).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(p.name).font(CPFont.emphasis).foregroundColor(CP.text).lineLimit(1)
                                        if p.isHost { Text("Host").font(CPFont.caption).foregroundColor(CP.text2) }
                                    }
                                    Spacer()
                                    CPButton(icon: "plus", title: "Add as input", prominent: true) {
                                        engine.placeInput(ZoomParticipantSource(userID: p.userID, name: p.name, highQuality: highQuality))
                                    }
                                    .disabled(!zoom.rawAllowed)
                                }
                                .padding(.vertical, 6)
                            }
                            CPNote("Each participant input carries that person's video and voice into the mixer. Zoom's own meeting window stays open for muting, chat and managing the meeting.")
                        }
                    }
                }
                CPNote("Zoom is a trademark of Zoom Communications, Inc.")
            }
        }
        .frame(width: 560, height: 700)
        .background(CP.bg)
        .preferredColorScheme(.dark)
    }

    private var credentialsSubtitle: String {
        if !zoom.tokenURL.isEmpty { return "Token server" }
        return zoom.sdkKey.isEmpty ? "Not set" : "Saved"
    }

    private var stateText: String {
        switch zoom.state {
        case .unavailable: return "Unavailable"
        case .idle: return "Not connected"
        case .authorizing: return "Authorising…"
        case .ready: return "Ready to join"
        case .joining: return "Joining…"
        case .waiting: return "Waiting"
        case .inMeeting: return "In the meeting"
        case .ended: return "Ended"
        case .failed: return "Problem"
        @unknown default: return ""
        }
    }
}

#else

/// Builds without the Xcode project: explain how to get built-in Zoom.
struct ZoomMeetingPanel: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zoom inside LiveDeck").font(.system(size: 15, weight: .semibold)).foregroundColor(CP.text)
            Text("Joining Zoom meetings inside LiveDeck (each participant as an input) is part of the Xcode build with the Zoom Meeting SDK — see AppStore/ZOOM_AND_CAMERA_GUIDE.md.\n\nIn this build use Add Input → Zoom Meeting / App Window: join in the Zoom app and add its window as an input with the meeting audio.")
                .font(CPFont.body).foregroundColor(CP.text2).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); CPButton(title: "OK", prominent: true) { dismiss() } }
        }
        .padding(20)
        .frame(width: 460)
        .background(CP.bg)
        .preferredColorScheme(.dark)
    }
}

#endif
