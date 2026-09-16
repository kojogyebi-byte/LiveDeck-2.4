import SwiftUI
import AppKit
import PresentationKit

extension Notification.Name { static let clearStageMessage = Notification.Name("livedeck.stage.clearMessage") }

// MARK: - Running shortcut actions

enum ShortcutRunner {
    /// Performs an action. Returns false when it does not apply right now.
    @discardableResult
    static func run(_ id: String, engine: Engine, present: PresentModel?, link: LinkManager?, automation: AutomationModel?, presets: PresetStore?) -> Bool {
        let real = engine.sources
        func input(_ n: Int) -> Source? { real.indices.contains(n - 1) && !real[n - 1].isPlaceholder ? real[n - 1] : nil }
        func number(_ prefix: String) -> Int? { id.hasPrefix(prefix) ? Int(id.dropFirst(prefix.count)) : nil }

        switch id {
        case "auto": engine.runTransition()
        case "cut": engine.cut()
        case "ftb": engine.toggleFTB()
        case "transition.cut": engine.transition = .cut
        case "transition.fade": engine.transition = .fade
        case "transition.wipe": engine.transition = .wipe
        case "transition.slide": engine.transition = .slide
        case "transition.zoom": engine.transition = .zoom
        case "keys.clearProgram": engine.clearProgramKeys()
        case "keys.takePreview": engine.keyedSources.formUnion(engine.previewKeys); engine.previewKeys.removeAll()
        case "slide.next": present?.step(1)
        case "slide.prev": present?.step(-1)
        case "slide.clear": present?.clearText()
        case "slide.background": present?.toggleBackground()
        case "slide.keyProgram": present?.toggleKey()
        case "slide.keyPreview": if let t = present?.ensureTarget() { engine.toggleKeyPreview(t.id) }
        case "overlays.hideAll": engine.layers.forEach { $0.isLive = false }
        case "record": engine.toggleRecording()
        case "stream": engine.toggleStream(nil)
        case "snapshot": engine.snapshot()
        case "programOut": engine.openOutputWindow()
        case "programOut.fullscreen": engine.toggleProgramOutFullscreen()
        case "multiview": engine.openMultiviewWindow()
        case "guides": engine.showSafeGuides.toggle()
        case "marker": guard engine.isRecording else { return false }; engine.addMarker()
        case "preflight": engine.showPreflight = true
        case "stage.clearMessage": NotificationCenter.default.post(name: .clearStageMessage, object: nil)
        case "audio.masterMute": engine.masterBus.muted.toggle()
        case "audio.hearMics": engine.hearLiveInputs.toggle()
        case "audio.clearSolo": engine.sources.forEach { $0.solo = false }
        case "playlist.playPause", "playlist.next", "playlist.prev":
            let lists = real.compactMap { $0 as? PlaylistSource }
            guard let pl = lists.first(where: { engine.isOnAir($0.id) }) ?? lists.first(where: { $0.id == engine.previewID }) ?? lists.first else { return false }
            if id == "playlist.next" { pl.next() } else if id == "playlist.prev" { pl.previous() } else { pl.togglePlay() }
        case "automation.toggle":
            guard let a = automation else { return false }
            a.running ? a.stop() : a.start()
        case "help": engine.showHelp = true
        case "network.attention": link?.sendChat("", attention: true)
        case "shortcuts": engine.showHotkeys = true
        case "panel.size": engine.rightPanelSize = engine.rightPanelSize >= 3 ? 1 : engine.rightPanelSize + 1
        default:
            if let n = number("preview."), let s = input(n) { engine.setPreview(s.id); engine.selectedSourceID = s.id }
            else if let n = number("program."), let s = input(n) { engine.setPreview(s.id); engine.cut() }
            else if let n = number("keyProgram."), let s = input(n) { engine.toggleKey(s.id) }
            else if let n = number("keyPreview."), let s = input(n) { engine.toggleKeyPreview(s.id) }
            else if let n = number("overlay.") { engine.toggleOverlay(n - 1) }
            else if let n = number("tab.") { present?.deck = [DeckTab.inputs, .present, .dictionary, .ai, .images, .audio, .automation][min(6, max(0, n))].rawValue }
            else if let n = number("panel.") { engine.rightTab = [1, 0, 2, 3, 4, 5, 6][min(6, max(0, n))] }
            else if let n = number("preset."), let store = presets, store.presets.indices.contains(n - 1) {
                let p = store.presets[n - 1]
                if p.includes.inputs { engine.rightTab = 5 } else { store.recall(p, into: engine) }
            }
            else { return false }
        }
        return true
    }
}

// MARK: - Shortcuts window

struct ShortcutsView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var category = "All"
    @State private var recordingID: String?
    @State private var monitor: Any?
    @State private var note = ""

    private var conflicts: [KeyCombo: [String]] { ShortcutCatalog.conflicts(engine.shortcuts) }

    private var visible: [ShortcutAction] {
        ShortcutCatalog.actions.filter { a in
            (category == "All" || a.category == category)
                && (query.isEmpty || a.title.localizedCaseInsensitiveContains(query) || (engine.shortcuts[a.id]?.display.localizedCaseInsensitiveContains(query) ?? false))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard").font(.system(size: 18, weight: .semibold)).foregroundColor(CP.icon)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Keyboard shortcuts").font(.system(size: 14, weight: .semibold)).foregroundColor(CP.text)
                    Text("Click a shortcut, then press the keys. Delete clears it, Esc cancels.").font(.system(size: 10)).foregroundColor(CP.text2)
                }
                Spacer()
                Menu {
                    Button("Smart shortcuts — fill every empty action") {
                        let before = engine.shortcuts.count
                        engine.shortcuts = ShortcutCatalog.smartFill(engine.shortcuts)
                        note = "Added \(engine.shortcuts.count - before) shortcut(s) without changing yours."
                    }
                    Button("Reset all to recommended") { engine.shortcuts = ShortcutCatalog.defaults; note = "Recommended shortcuts restored." }
                    Button("Clear all") { engine.shortcuts = [:]; note = "All shortcuts cleared." }
                } label: { Label("Smart setup", systemImage: "wand.and.stars") }
                .menuStyle(.borderlessButton).fixedSize()
                CPButton(title: "Done", prominent: true) { stopRecording(); dismiss() }
            }
            .padding(.horizontal, 14).frame(height: 54).background(CP.cardHeader)

            HStack(spacing: 8) {
                TextField("Search actions or keys", text: $query).dsField().frame(width: 220)
                Picker("", selection: $category) {
                    Text("All categories").tag("All")
                    ForEach(ShortcutCatalog.categories, id: \.self) { Text($0).tag($0) }
                }
                .cpPickerChrome().frame(width: 170)
                Spacer()
                if !conflicts.isEmpty {
                    Label("\(conflicts.count) conflict\(conflicts.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(DS.amber)
                }
            }
            .padding(10)

            if !note.isEmpty {
                Text(note).font(.system(size: 10.5)).foregroundColor(DS.ok).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { a in row(a); CPDivider() }
                }
                .padding(.horizontal, 10)
            }
            .background(CP.card)

            Text("Plain keys (without ⌘ ⌥ ⌃) never fire while you are typing. Songs & Bible and AI Search also use ← → for slides.")
                .font(.system(size: 10)).foregroundColor(CP.text2).frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .frame(width: 700, height: 640)
        .background(CP.bg)
        .preferredColorScheme(.dark)
        .onDisappear { stopRecording() }
    }

    private func row(_ a: ShortcutAction) -> some View {
        let combo = engine.shortcuts[a.id]
        let clash = combo.flatMap { conflicts[$0] }?.filter { $0 != a.id } ?? []
        let recording = recordingID == a.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(.system(size: 12)).foregroundColor(CP.text)
                HStack(spacing: 6) {
                    Text(a.category).font(.system(size: 9)).foregroundColor(CP.text2)
                    if !clash.isEmpty {
                        Text("also used by \(clash.compactMap { ShortcutCatalog.action($0)?.title }.joined(separator: ", "))")
                            .font(.system(size: 9)).foregroundColor(DS.amber).lineLimit(1)
                    }
                    if combo?.isReserved == true { Text("macOS uses this").font(.system(size: 9)).foregroundColor(DS.amber) }
                }
            }
            Spacer()
            Button { recording ? stopRecording() : startRecording(a.id) } label: {
                Text(recording ? "Press keys…" : (combo?.display ?? "—"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(recording ? .white : (clash.isEmpty ? CP.text : DS.amber))
                    .frame(minWidth: 96).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(recording ? CP.blue : CP.field))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(clash.isEmpty ? CP.border : DS.amber, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button { engine.shortcuts[a.id] = a.defaultCombo } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.plain).foregroundColor(CP.text2).help("Recommended: \(a.defaultCombo?.display ?? "none")")
            Button { engine.shortcuts[a.id] = nil } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain).foregroundColor(CP.text2).help("Remove shortcut")
        }
        .padding(.vertical, 6)
    }

    private func startRecording(_ id: String) {
        stopRecording()
        recordingID = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            guard let rid = recordingID else { return ev }
            if ev.keyCode == 53 { stopRecording(); return nil }                           // Esc cancels
            if ev.keyCode == 51 || ev.keyCode == 117 { engine.shortcuts[rid] = nil; stopRecording(); return nil }
            guard let key = KeyCombo.keyName(keyCode: ev.keyCode, characters: ev.charactersIgnoringModifiers) else { return nil }
            let f = ev.modifierFlags
            let combo = KeyCombo(key, command: f.contains(.command), option: f.contains(.option), control: f.contains(.control), shift: f.contains(.shift))
            if combo.isReserved {
                note = "\(combo.display) is used by macOS — choose another."
                return nil
            }
            if let other = ShortcutCatalog.actionID(for: combo, in: engine.shortcuts), other != rid {
                engine.shortcuts[other] = nil
                note = "\(combo.display) moved from “\(ShortcutCatalog.action(other)?.title ?? other)”."
            } else { note = "" }
            engine.shortcuts[rid] = combo
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recordingID = nil
    }
}
