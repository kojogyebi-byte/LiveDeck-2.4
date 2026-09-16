import SwiftUI

@main
struct LiveDeckApp: App {
    @StateObject private var engine = Engine()
    @StateObject private var present = PresentModel()

    var body: some Scene {
        WindowGroup("LiveDeck Studio") {
            MainView()
                .environmentObject(engine)
                .environmentObject(engine.telemetry)
                .environmentObject(engine.sysMon)
                .environmentObject(present)
                .frame(minWidth: 1280, minHeight: 760)
                .onAppear { engine.start() }
        }
        .windowStyle(.titleBar)
    }
}
