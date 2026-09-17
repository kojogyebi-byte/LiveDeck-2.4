import SwiftUI
import AppKit
import PresentationKit

// MARK: - Languages

struct AppLanguage: Identifiable, Hashable {
    let code: String
    let native: String
    let english: String
    var id: String { code }

    static let all: [AppLanguage] = [
        AppLanguage(code: "en", native: "English", english: "English"),
        AppLanguage(code: "fr", native: "Français", english: "French"),
        AppLanguage(code: "es", native: "Español", english: "Spanish"),
        AppLanguage(code: "pt", native: "Português", english: "Portuguese"),
        AppLanguage(code: "de", native: "Deutsch", english: "German"),
        AppLanguage(code: "sw", native: "Kiswahili", english: "Swahili"),
        AppLanguage(code: "ru", native: "Русский", english: "Russian"),
        AppLanguage(code: "uk", native: "Українська", english: "Ukrainian"),
        AppLanguage(code: "pl", native: "Polski", english: "Polish"),
        AppLanguage(code: "ro", native: "Română", english: "Romanian"),
        AppLanguage(code: "zh-Hans", native: "简体中文", english: "Chinese (Simplified)"),
        AppLanguage(code: "zh-Hant", native: "繁體中文", english: "Chinese (Traditional)"),
        AppLanguage(code: "ko", native: "한국어", english: "Korean"),
        AppLanguage(code: "hi", native: "हिन्दी", english: "Hindi"),
        AppLanguage(code: "bn", native: "বাংলা", english: "Bengali (Bangladesh, India)"),
        AppLanguage(code: "ta", native: "தமிழ்", english: "Tamil"),
        AppLanguage(code: "id", native: "Bahasa Indonesia", english: "Indonesian")
    ]

    /// Language LiveDeck is showing now.
    static var current: String {
        let chosen = UserDefaults.standard.string(forKey: "app.language")
        if let chosen, all.contains(where: { $0.code == chosen }) { return chosen }
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return all.sorted { $0.code.count > $1.code.count }.first(where: { preferred.hasPrefix($0.code) })?.code ?? "en"
    }

    /// Stores the choice (LiveDeck only, not the whole Mac). Takes effect after a restart.
    static func choose(_ code: String) {
        UserDefaults.standard.set(code, forKey: "app.language")
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        LiveDeckAppDelegate.skipPrompt = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Setup assistant (first launch, or gear menu → Language & setup assistant)

enum UseCase: String, CaseIterable, Identifiable {
    case podcast, church, events, teaching
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .podcast: return "Podcast or video podcast"
        case .church: return "Church services and worship"
        case .events: return "Live events and streaming"
        case .teaching: return "Teaching and online classes"
        }
    }
    var icon: String {
        switch self {
        case .podcast: return "mic.fill"
        case .church: return "music.note.list"
        case .events: return "dot.radiowaves.left.and.right"
        case .teaching: return "graduationcap.fill"
        }
    }
    var detail: LocalizedStringKey {
        switch self {
        case .podcast: return "Auto Mix follows whoever is speaking, each mic records to its own track, loudness is set for podcasts and sound pads are ready for jingles."
        case .church: return "Songs & Bible opens first, loudness is set for streaming and the stage display is one click away."
        case .events: return "Streaming, recording, NDI and display outputs are set up for live productions."
        case .teaching: return "Screen capture, camera picture-in-picture and a timed Auto Mix keep lessons moving."
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var language = AppLanguage.current
    @State private var useCase: UseCase = .podcast
    private let startLanguage = AppLanguage.current

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to LiveDeck Studio").font(.system(size: 20, weight: .bold)).foregroundColor(CP.text)
                    Text("Let's set things up — it takes a minute.").font(.system(size: 12.5)).foregroundColor(CP.text2)
                }
                Spacer()
                HStack(spacing: 5) {
                    ForEach(0..<3) { i in Capsule().fill(i <= step ? CP.accentLine : CP.border).frame(width: i == step ? 22 : 8, height: 6) }
                }
            }
            .padding(22)
            Rectangle().fill(CP.divider).frame(height: 1)

            Group {
                switch step {
                case 0: languageStep
                case 1: useCaseStep
                default: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(22)

            Rectangle().fill(CP.divider).frame(height: 1)
            HStack {
                if step > 0 { Button("Back") { step -= 1 }.buttonStyle(.ds(.normal, .regular)) }
                Spacer()
                if step < 2 {
                    Button("Continue") { step += 1 }.buttonStyle(.ds(.primary, .regular)).keyboardShortcut(.defaultAction)
                } else {
                    Button(LocalizedStringKey(language != startLanguage ? "Finish and restart in the new language" : "Start using LiveDeck")) { finish() }
                        .buttonStyle(.ds(.primary, .regular)).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 720, height: 600)
        .background(CP.bg)
        .preferredColorScheme(.dark)
    }

    private var languageStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose your language").font(.system(size: 15, weight: .semibold)).foregroundColor(CP.text)
            Text("You can change it later in the gear menu → Language & setup assistant.").font(.system(size: 11.5)).foregroundColor(CP.text2)
            ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(AppLanguage.all) { lang in
                    Button { language = lang.code } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: lang.native).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                Text(verbatim: lang.english).font(.system(size: 10.5)).opacity(0.7).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            Spacer()
                            if language == lang.code { Image(systemName: "checkmark.circle.fill") }
                        }
                        .foregroundColor(language == lang.code ? CP.primaryText : CP.text)
                        .padding(.horizontal, 12).frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 8).fill(language == lang.code ? CP.primaryFill : CP.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CP.border, lineWidth: language == lang.code ? 0 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            }
        }
    }

    private var useCaseStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What will you make with LiveDeck?").font(.system(size: 15, weight: .semibold)).foregroundColor(CP.text)
            Text("LiveDeck sets sensible starting options. Everything stays available.").font(.system(size: 11.5)).foregroundColor(CP.text2)
            ForEach(UseCase.allCases) { u in
                Button { useCase = u } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: u.icon).font(.system(size: 18)).frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(u.title).font(.system(size: 13.5, weight: .semibold))
                            Text(u.detail).font(.system(size: 11)).opacity(0.75).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if useCase == u { Image(systemName: "checkmark.circle.fill") }
                    }
                    .foregroundColor(useCase == u ? CP.primaryText : CP.text)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(useCase == u ? CP.primaryFill : CP.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CP.border, lineWidth: useCase == u ? 0 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're ready").font(.system(size: 15, weight: .semibold)).foregroundColor(CP.text)
            tip("plus.rectangle.on.rectangle", "Add your cameras and microphones", "Click Add Input (or + on an empty holder). Choose the microphone for each camera in the Input tab.")
            tip("shuffle", "Let Auto Mix switch for you", "Automation → Auto Mix: pick inputs and a time for each, or let it follow whoever is speaking. Switch by hand at any time to take over.")
            tip("record.circle", "Record and go live", "REC records the show (and each mic separately if you choose). STREAM sends it to YouTube, Facebook or any RTMP service.")
            tip("checklist", "Check before you start", "CHECK tests cameras, audio, disk space and the internet connection.")
            tip("questionmark.circle", "Help is always one key away", "Press ⌘K to find any tool, or ⌘? for step-by-step help.")
        }
    }

    private func tip(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundColor(CP.icon).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(CP.text)
                Text(text).font(.system(size: 11.5)).foregroundColor(CP.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func finish() {
        apply(useCase)
        UserDefaults.standard.set(true, forKey: "app.welcomeDone")
        UserDefaults.standard.set(useCase.rawValue, forKey: "app.useCase")
        engine.showWelcome = false
        dismiss()
        if language != startLanguage {
            AppLanguage.choose(language)
            AppLanguage.relaunch()
        }
    }

    private func apply(_ u: UseCase) {
        switch u {
        case .podcast:
            engine.loudness.target = .podcast
            engine.recordSeparateTracks = true
            engine.autoMix.plan.mode = .voice
            present.deck = DeckTab.inputs.rawValue
        case .church:
            engine.loudness.target = .streaming
            present.deck = DeckTab.present.rawValue
        case .events:
            engine.loudness.target = .streaming
        case .teaching:
            engine.loudness.target = .streaming
            engine.autoMix.plan.mode = .timed
        }
    }
}

// MARK: - Quit: offer to save the session, never close suddenly

final class LiveDeckAppDelegate: NSObject, NSApplicationDelegate {
    static weak var engine: Engine?
    static var skipPrompt = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.skipPrompt, let engine = Self.engine else { return .terminateNow }
        let live = engine.isStreaming || engine.isRecording

        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.alertStyle = live ? .critical : .warning
        alert.messageText = live ? String(localized: "You are still live. Save and quit LiveDeck?")
                                 : String(localized: "Save your session before quitting?")
        var info = String(localized: "Your inputs, overlays, scenes and layout are saved as a show file you can open next time.")
        if engine.isStreaming { info = String(localized: "The stream will be stopped.") + " " + info }
        if engine.isRecording { info = String(localized: "The recording will be stopped and saved.") + " " + info }
        alert.informativeText = info
        alert.addButton(withTitle: engine.showURL != nil ? String(localized: "Save and Quit") : String(localized: "Save…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit Without Saving"))
        alert.buttons[1].keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            engine.saveShow(completion: { saved in
                guard saved else { NSApp.reply(toApplicationShouldTerminate: false); return }
                Self.finishLive(engine) { NSApp.reply(toApplicationShouldTerminate: true) }
            }, askForLocation: engine.showURL == nil)
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateCancel
        default:
            guard live else { return .terminateNow }
            Self.finishLive(engine) { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
    }

    /// Stops streaming and recording and gives the recording time to be written.
    private static func finishLive(_ engine: Engine, then done: @escaping () -> Void) {
        let wasRecording = engine.isRecording
        if engine.isStreaming { engine.stopStream() }
        if engine.isRecording { engine.toggleRecording() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasRecording ? 1.5 : 0.3)) { done() }
    }
}
