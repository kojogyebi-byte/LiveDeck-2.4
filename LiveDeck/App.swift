import SwiftUI

@main
struct LiveDeckApp: App {
    @NSApplicationDelegateAdaptor(LiveDeckAppDelegate.self) private var appDelegate
    @StateObject private var engine = Engine()
    @StateObject private var present = PresentModel()
    @StateObject private var dictionary = DictionaryModel()
    @StateObject private var images = ImageSearchModel()
    @StateObject private var presets = PresetStore()
    @StateObject private var backgrounds = BackgroundsModel()
    @StateObject private var generator = GeneratorModel()
    @StateObject private var automation = AutomationModel()
    @StateObject private var ai = AIModel()
    @StateObject private var link = LinkManager()
    @StateObject private var stage = StageModel()
    @StateObject private var session = SessionGuard()
    @StateObject private var license = LicenseManager()

    var body: some Scene {
        WindowGroup("LiveDeck Studio") {
            MainView()
                .environmentObject(engine)
                .environmentObject(engine.telemetry)
                .environmentObject(engine.ndiOutputs)
                .environmentObject(engine.virtualCamera)
                .environmentObject(engine.deckLink)
                .environmentObject(engine.atem)
                .environmentObject(engine.autoMix)
                .environmentObject(engine.loudness)
                .environmentObject(engine.sysMon)
                .environmentObject(present)
                .environmentObject(dictionary)
                .environmentObject(images)
                .environmentObject(presets)
                .environmentObject(backgrounds)
                .environmentObject(generator)
                .environmentObject(automation)
                .environmentObject(ai)
                .environmentObject(link)
                .environmentObject(stage)
                .environmentObject(session)
                .environmentObject(license)
                .frame(minWidth: 1280, minHeight: 760)
                .onAppear {
                    FileAccess.restoreAll()
                    Task { await license.start() }
                    present.engine = engine
                    dictionary.engine = engine
                    images.engine = engine
                    backgrounds.engine = engine
                    generator.engine = engine
                    automation.engine = engine
                    ai.engine = engine
                    link.engine = engine
                    OverlaySource.engine = engine
                    engine.atem.activate(engine: engine)
                    engine.autoMix.activate(engine: engine)
                    LiveDeckAppDelegate.engine = engine
                    link.backgrounds = backgrounds
                    link.present = present
                    link.presets = presets
                    link.activate()
                    session.engine = engine
                    session.presets = presets
                    session.activate()
                    engine.start()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            if AppEdition.isAppStore {
                CommandGroup(after: .appInfo) {
                    Button("Buy LiveDeck Studio…") { license.showPaywall = true }
                    Button("Restore Purchases") { Task { await license.restore() } }
                }
            }
            CommandMenu("Output") {
                Button("Program Out") { engine.openOutputWindow() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Switch Program Out: Window ↔ Full Screen") { engine.toggleProgramOutFullscreen() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Close Program Out") { engine.closeOutputWindow() }
                Divider()
                Button("Multiview") { engine.openMultiviewWindow() }
            }
            CommandGroup(replacing: .help) {
                Button("LiveDeck Help") { engine.helpQuery = ""; engine.showHelp = true }
                    .keyboardShortcut("?", modifiers: .command)
                if let notices = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt", subdirectory: "Licenses") {
                    Button("Third-Party Notices (FFmpeg, NDI®)") { NSWorkspace.shared.open(notices) }
                }
                Button("Find a Tool…") { engine.showHelp = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}
