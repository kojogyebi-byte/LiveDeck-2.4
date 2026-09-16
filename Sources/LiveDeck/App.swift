import SwiftUI

@main
struct LiveDeckApp: App {
    @StateObject private var engine = Engine()
    @StateObject private var present = PresentModel()
    @StateObject private var dictionary = DictionaryModel()
    @StateObject private var images = ImageSearchModel()
    @StateObject private var presets = PresetStore()

    var body: some Scene {
        WindowGroup("LiveDeck Studio") {
            MainView()
                .environmentObject(engine)
                .environmentObject(engine.telemetry)
                .environmentObject(engine.sysMon)
                .environmentObject(present)
                .environmentObject(dictionary)
                .environmentObject(images)
                .environmentObject(presets)
                .frame(minWidth: 1280, minHeight: 760)
                .onAppear {
                    present.engine = engine
                    dictionary.engine = engine
                    images.engine = engine
                    engine.start()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .help) {
                Button("LiveDeck Help") { engine.helpQuery = ""; engine.showHelp = true }
                    .keyboardShortcut("?", modifiers: .command)
                Button("Find a Tool…") { engine.showHelp = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}
