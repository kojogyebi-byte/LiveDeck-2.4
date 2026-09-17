import Foundation

// MARK: - Assignable keyboard shortcuts

public struct KeyCombo: Codable, Hashable, Sendable {
    public var key: String          // "A", "1", "Return", "Space", "Left", "PageDown", "F1" …
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool

    public init(_ key: String, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.key = key; self.command = command; self.option = option; self.control = control; self.shift = shift
    }
    public static func cmd(_ k: String) -> KeyCombo { KeyCombo(k, command: true) }
    public static func opt(_ k: String) -> KeyCombo { KeyCombo(k, option: true) }
    public static func ctrl(_ k: String) -> KeyCombo { KeyCombo(k, control: true) }
    public static func shift(_ k: String) -> KeyCombo { KeyCombo(k, shift: true) }

    /// No ⌘ ⌥ ⌃ — these never fire while you type in a text box.
    public var isPlain: Bool { !command && !option && !control }

    public var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + KeyCombo.symbol(key)
    }

    static func symbol(_ k: String) -> String {
        switch k {
        case "Return": return "↩"
        case "Space": return "Space"
        case "Left": return "←"
        case "Right": return "→"
        case "Up": return "↑"
        case "Down": return "↓"
        case "PageUp": return "⇞"
        case "PageDown": return "⇟"
        case "Home": return "↖"
        case "End": return "↘"
        case "Delete": return "⌫"
        case "Escape": return "⎋"
        case "Tab": return "⇥"
        default: return k
        }
    }

    /// Shortcuts macOS or text editing already use.
    public var isReserved: Bool {
        guard command, !control else { return false }
        let k = key.uppercased()
        if !option && !shift && ["Q", "W", "H", "M", "C", "V", "X", "A", "Z", ",", "TAB", "SPACE", "`", "N", "O", "S", "P"].contains(k) { return true }
        if shift && !option && k == "Z" { return true }
        return false
    }

    /// Key name from a macOS key code (special keys, digits) or the typed character.
    public static func keyName(keyCode: UInt16, characters: String?) -> String? {
        let special: [UInt16: String] = [
            36: "Return", 76: "Return", 49: "Space", 123: "Left", 124: "Right", 125: "Down", 126: "Up",
            116: "PageUp", 121: "PageDown", 115: "Home", 119: "End", 51: "Delete", 117: "Delete", 53: "Escape", 48: "Tab",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9", 82: "0"
        ]
        if let s = special[keyCode] { return s }
        guard let c = characters, let first = c.first, !c.isEmpty else { return nil }
        let s = String(first).uppercased()
        return s.trimmingCharacters(in: .controlCharacters).isEmpty ? nil : s
    }
}

public struct ShortcutAction: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let category: String
    public let defaultCombo: KeyCombo?
    public init(_ id: String, _ title: String, _ category: String, _ combo: KeyCombo? = nil) {
        self.id = id; self.title = title; self.category = category; self.defaultCombo = combo
    }
}

public enum ShortcutCatalog {
    public static let categories = ["Switching", "Inputs", "Keys", "Slides", "Overlays", "Output", "Audio", "Playlist", "Tabs", "Panels", "Presets", "Other", "Auto Mix", "Sound pads"]

    public static let actions: [ShortcutAction] = {
        var a: [ShortcutAction] = [
            ShortcutAction("auto", "AUTO transition", "Switching", KeyCombo("Return")),
            ShortcutAction("cut", "CUT", "Switching", KeyCombo("C")),
            ShortcutAction("ftb", "Fade to black", "Switching", KeyCombo("B")),
            ShortcutAction("transition.cut", "Transition: Cut", "Switching", .shift("1")),
            ShortcutAction("transition.fade", "Transition: Fade", "Switching", .shift("2")),
            ShortcutAction("transition.wipe", "Transition: Wipe", "Switching", .shift("3")),
            ShortcutAction("transition.slide", "Transition: Slide", "Switching", .shift("4")),
            ShortcutAction("transition.zoom", "Transition: Zoom", "Switching", .shift("5")),
            ShortcutAction("keys.clearProgram", "Clear all Program keys", "Keys", KeyCombo("K", shift: true)),
            ShortcutAction("keys.takePreview", "Take Preview keys to Program", "Keys", KeyCombo("K")),
            ShortcutAction("slide.next", "Next slide", "Slides", KeyCombo("PageDown")),
            ShortcutAction("slide.prev", "Previous slide", "Slides", KeyCombo("PageUp")),
            ShortcutAction("slide.clear", "Clear slide text", "Slides", KeyCombo("X")),
            ShortcutAction("slide.background", "Hide / show slide background", "Slides", KeyCombo("X", shift: true)),
            ShortcutAction("slide.keyProgram", "Key slides over Program", "Slides", KeyCombo("J")),
            ShortcutAction("slide.keyPreview", "Key slides over Preview", "Slides", KeyCombo("J", shift: true)),
            ShortcutAction("overlays.hideAll", "Hide all overlays", "Overlays", KeyCombo("H")),
            ShortcutAction("record", "Record on/off", "Output", KeyCombo("R")),
            ShortcutAction("stream", "Stream on/off", "Output", KeyCombo("L")),
            ShortcutAction("snapshot", "Snapshot", "Output", KeyCombo("S")),
            ShortcutAction("programOut", "Program Out on/off", "Output", KeyCombo("O", command: true, shift: true)),
            ShortcutAction("programOut.fullscreen", "Program Out: window ↔ full screen", "Output", KeyCombo("F", command: true, shift: true)),
            ShortcutAction("multiview", "Multiview window", "Output", KeyCombo("M", command: true, shift: true)),
            ShortcutAction("guides", "Safe-area guides", "Output", KeyCombo("G")),
            ShortcutAction("marker", "Add chapter marker to the recording", "Output", KeyCombo("M")),
            ShortcutAction("preflight", "Pre-service check", "Other", KeyCombo("P", command: true, shift: true)),
            ShortcutAction("stage.clearMessage", "Clear stage display message", "Other", KeyCombo("Escape", shift: true)),
            ShortcutAction("audio.masterMute", "Mute / unmute master", "Audio", .ctrl("M")),
            ShortcutAction("audio.hearMics", "Hear mics in speakers", "Audio", .opt("M")),
            ShortcutAction("audio.clearSolo", "Clear all solos", "Audio", .opt("S")),
            ShortcutAction("playlist.playPause", "Playlist play / pause", "Playlist", KeyCombo("P")),
            ShortcutAction("playlist.next", "Playlist next item", "Playlist", KeyCombo("N")),
            ShortcutAction("playlist.prev", "Playlist previous item", "Playlist", KeyCombo("N", shift: true)),
            ShortcutAction("automation.toggle", "Start / stop automation", "Other", KeyCombo("A", command: true, shift: true)),
            ShortcutAction("automix.toggle", "Auto Mix start / stop", "Auto Mix"),
            ShortcutAction("automix.pause", "Auto Mix pause / resume (take control)", "Auto Mix"),
            ShortcutAction("automix.next", "Auto Mix next shot", "Auto Mix"),
            ShortcutAction("pads.stop", "Sound pads: stop all", "Sound pads"),
            ShortcutAction("help", "Help & Find a tool", "Other", .cmd("K")),
            ShortcutAction("network.attention", "Network: Attention to everyone", "Other", KeyCombo("A", option: true, shift: true)),
            ShortcutAction("shortcuts", "Keyboard shortcuts window", "Other", KeyCombo("/", command: true, option: true))
        ]
        for n in 1...8 {
            a.append(ShortcutAction("pad.\(n)", "Sound pad \(n)", "Sound pads"))
        }
        for n in 1...9 {
            a.append(ShortcutAction("preview.\(n)", "Input \(n) to Preview", "Inputs", KeyCombo("\(n)")))
            a.append(ShortcutAction("program.\(n)", "Input \(n) to Program (cut)", "Inputs", .opt("\(n)")))
            a.append(ShortcutAction("keyProgram.\(n)", "Key input \(n) over Program", "Keys", .ctrl("\(n)")))
            a.append(ShortcutAction("keyPreview.\(n)", "Key input \(n) over Preview", "Keys", KeyCombo("\(n)", option: true, control: true)))
        }
        for n in 1...4 { a.append(ShortcutAction("overlay.\(n)", "Overlay \(n) on/off", "Overlays", KeyCombo("F\(n)"))) }
        let tabs = ["Inputs", "Songs & Bible", "Dictionary", "AI Search", "Media", "Audio Mixer", "Automation"]
        for (i, t) in tabs.enumerated() { a.append(ShortcutAction("tab.\(i)", "Show \(t) tab", "Tabs", .cmd("\(i + 1)"))) }
        let panels = ["Input", "Audio", "Overlays", "Scenes", "Outputs", "Presets", "Network"]
        for (i, t) in panels.enumerated() { a.append(ShortcutAction("panel.\(i)", "Control panel: \(t)", "Panels", KeyCombo("\(i + 1)", command: true, option: true))) }
        a.append(ShortcutAction("panel.size", "Control panel size (narrow → half → wide)", "Panels", KeyCombo("\\", command: true, option: true)))
        for n in 1...5 { a.append(ShortcutAction("preset.\(n)", "Recall preset \(n)", "Presets", KeyCombo("\(n)", command: true, control: true))) }
        return a
    }()

    public static var defaults: [String: KeyCombo] {
        var m: [String: KeyCombo] = [:]
        for a in actions { if let c = a.defaultCombo { m[a.id] = c } }
        return m
    }

    public static func action(_ id: String) -> ShortcutAction? { actions.first { $0.id == id } }

    /// Which action a key press triggers.
    public static func actionID(for combo: KeyCombo, in map: [String: KeyCombo]) -> String? {
        map.first { $0.value == combo }?.key
    }

    /// Combos used by more than one action.
    public static func conflicts(_ map: [String: KeyCombo]) -> [KeyCombo: [String]] {
        var by: [KeyCombo: [String]] = [:]
        for (id, c) in map { by[c, default: []].append(id) }
        return by.filter { $0.value.count > 1 }.mapValues { $0.sorted() }
    }

    /// Fills unassigned actions: first with their recommended key (when it is free), then with free keys that
    /// fit the category, skipping reserved macOS combos. Existing choices are never changed.
    public static func smartFill(_ current: [String: KeyCombo]) -> [String: KeyCombo] {
        var map = current
        var used = Set(map.values)
        for a in actions where map[a.id] == nil {
            if let c = a.defaultCombo, !used.contains(c), !c.isReserved { map[a.id] = c; used.insert(c) }
        }
        let pool: [KeyCombo] = "QWERTYUIOPDFGVZ".map { KeyCombo(String($0), control: true, shift: true) }
            + "QWERTYUIOPDFGHJLVBXZ".map { KeyCombo(String($0), option: true, shift: true) }
            + (5...12).map { KeyCombo("F\($0)") }
        var it = pool.makeIterator()
        for a in actions where map[a.id] == nil {
            while let c = it.next() {
                if !used.contains(c) && !c.isReserved { map[a.id] = c; used.insert(c); break }
            }
        }
        return map
    }
}
