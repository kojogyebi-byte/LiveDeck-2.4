import SwiftUI

@main
struct LiveDeckApp: App {
    @StateObject private var engine = Engine()
    @StateObject private var present = PresentModel()
    @StateObject private var dictionary = DictionaryModel()

    var body: some Scene {
        WindowGroup("LiveDeck Studio") {
            MainView()
                .environmentObject(engine)
                .environmentObject(engine.telemetry)
                .environmentObject(engine.sysMon)
                .environmentObject(present)
                .environmentObject(dictionary)
                .frame(minWidth: 1280, minHeight: 760)
                .onAppear {
                    present.engine = engine
                    dictionary.engine = engine
                    engine.start()
                }
        }
        .windowStyle(.titleBar)
    }
}
