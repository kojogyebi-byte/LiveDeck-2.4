import SwiftUI

@main
struct LiveDeckApp: App {
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

    var body: some Scene {
        WindowGroup("LiveDeck Studio") {
            MainView()
                .environmentObject(engine)
                .environmentObject(engine.telemetry)
                .environmentObject(engine.ndiOutputs)
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
                .frame(minWidth: 1280, minHeight: 760)
                .onAppear {
                    present.engine = engine
                    dictionary.engine = engine
                    images.engine = engine
                    backgrounds.engine = engine
                    generator.engine = engine
                    automation.engine = engine
                    ai.engine = engine
                    link.engine = engine
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
                Button("Find a Tool…") { engine.showHelp = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}
