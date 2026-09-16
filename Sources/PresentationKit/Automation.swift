import Foundation

// MARK: - Timed / automated cues (lower thirds, keyed inputs, cuts)

public enum AutomationTrigger: String, Codable, Sendable, CaseIterable, Identifiable {
    case clockTime = "At a time of day"
    case afterStart = "After a delay (from Start)"
    case repeating = "Repeat every…"
    case onProgram = "When an input goes on Program"
    case onRecording = "When recording starts"
    case onStreaming = "When streaming starts"
    case manual = "Only when I press Run"
    public var id: String { rawValue }
}

public enum AutomationAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case show = "Show"
    case hide = "Hide"
    case toggle = "Toggle"
    case cutToProgram = "Cut to Program"
    case preview = "Put on Preview"
    public var id: String { rawValue }
    /// What undoes this action when the hold time ends.
    public var undo: AutomationAction? {
        switch self {
        case .show: return .hide
        case .hide: return .show
        case .toggle: return .toggle
        case .cutToProgram, .preview: return nil
        }
    }
}

public enum AutomationTarget: String, Codable, Sendable, CaseIterable, Identifiable {
    case overlay = "Overlay / lower third"
    case keyInput = "Keyed input (over Program)"
    case input = "Input (switcher)"
    public var id: String { rawValue }
    public var actions: [AutomationAction] {
        switch self {
        case .overlay, .keyInput: return [.show, .hide, .toggle]
        case .input: return [.cutToProgram, .preview]
        }
    }
}

public struct AutomationRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var trigger: AutomationTrigger
    public var timeOfDay: Int          // seconds after midnight (clockTime)
    public var delay: Double           // seconds (afterStart, onProgram, onRecording, onStreaming, first repeat)
    public var interval: Double        // seconds (repeating)
    public var watchInputID: String    // input UUID string (onProgram)
    public var action: AutomationAction
    public var target: AutomationTarget
    public var targetID: String        // layer or input UUID string
    public var holdSeconds: Double     // > 0 → undo after this long
    public var revertWhenEnds: Bool    // onProgram/onRecording/onStreaming → undo when the condition ends
    public var maxRuns: Int            // 0 = unlimited

    public init(id: UUID = UUID(), name: String = "New cue", enabled: Bool = true, trigger: AutomationTrigger = .afterStart,
                timeOfDay: Int = 10 * 3600, delay: Double = 10, interval: Double = 300, watchInputID: String = "",
                action: AutomationAction = .show, target: AutomationTarget = .overlay, targetID: String = "",
                holdSeconds: Double = 8, revertWhenEnds: Bool = false, maxRuns: Int = 0) {
        self.id = id; self.name = name; self.enabled = enabled; self.trigger = trigger; self.timeOfDay = timeOfDay
        self.delay = delay; self.interval = interval; self.watchInputID = watchInputID; self.action = action
        self.target = target; self.targetID = targetID; self.holdSeconds = holdSeconds; self.revertWhenEnds = revertWhenEnds
        self.maxRuns = maxRuns
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, trigger, timeOfDay, delay, interval, watchInputID, action, target, targetID, holdSeconds, revertWhenEnds, maxRuns
    }
    public init(from decoder: Decoder) throws {
        let d = AutomationRule()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); name = c.value(.name, d.name); enabled = c.value(.enabled, d.enabled)
        trigger = c.value(.trigger, d.trigger); timeOfDay = c.value(.timeOfDay, d.timeOfDay); delay = c.value(.delay, d.delay)
        interval = c.value(.interval, d.interval); watchInputID = c.value(.watchInputID, d.watchInputID)
        action = c.value(.action, d.action); target = c.value(.target, d.target); targetID = c.value(.targetID, d.targetID)
        holdSeconds = c.value(.holdSeconds, d.holdSeconds); revertWhenEnds = c.value(.revertWhenEnds, d.revertWhenEnds)
        maxRuns = c.value(.maxRuns, d.maxRuns)
    }

    public static func timeText(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600 % 24, seconds / 60 % 60, seconds % 60)
    }
}

/// What the app should do now.
public struct AutomationCommand: Equatable, Sendable {
    public let ruleID: UUID
    public let action: AutomationAction
    public let target: AutomationTarget
    public let targetID: String
    public let isUndo: Bool
}

public struct AutomationContext: Sendable {
    public var time: Double            // monotonic seconds
    public var secondsOfDay: Int
    public var programInputID: String?
    public var recording: Bool
    public var streaming: Bool
    public init(time: Double, secondsOfDay: Int, programInputID: String?, recording: Bool, streaming: Bool) {
        self.time = time; self.secondsOfDay = secondsOfDay; self.programInputID = programInputID
        self.recording = recording; self.streaming = streaming
    }
}

/// Pure scheduling logic: feed it the rules and the current state every tick; it returns commands.
public final class AutomationScheduler {
    struct State {
        var runs = 0
        var nextRepeat: Double?
        var pendingAt: Double?
        var undoAt: Double?
        var active = false            // performed and waiting for undo/revert
        var armedFired = false        // afterStart already fired
    }

    public private(set) var running = false
    public private(set) var startedAt: Double = 0
    private var states: [UUID: State] = [:]
    private var prev: AutomationContext?

    public init() {}

    public func start(at t: Double) { running = true; startedAt = t; states = [:]; prev = nil }
    public func stop() { running = false; states = [:]; prev = nil }

    /// Remaining seconds until the rule next fires, if known.
    public func secondsUntilNext(_ r: AutomationRule, _ ctx: AutomationContext) -> Double? {
        guard running, r.enabled else { return nil }
        let s = states[r.id] ?? State()
        if let p = s.pendingAt { return max(0, p - ctx.time) }
        switch r.trigger {
        case .clockTime:
            var d = r.timeOfDay - ctx.secondsOfDay
            if d < 0 { d += 86400 }
            return Double(d)
        case .afterStart: return s.armedFired ? nil : max(0, startedAt + r.delay - ctx.time)
        case .repeating: return max(0, (s.nextRepeat ?? (startedAt + r.delay)) - ctx.time)
        default: return nil
        }
    }

    public func isActive(_ id: UUID) -> Bool { states[id]?.active ?? false }
    public func runs(_ id: UUID) -> Int { states[id]?.runs ?? 0 }

    /// Fires a rule immediately (the Run button).
    public func runNow(_ r: AutomationRule, at t: Double) -> [AutomationCommand] {
        var s = states[r.id] ?? State()
        let cmds = perform(r, &s, at: t)
        states[r.id] = s
        return cmds
    }

    public func tick(_ rules: [AutomationRule], _ ctx: AutomationContext) -> [AutomationCommand] {
        var out: [AutomationCommand] = []
        let p = prev
        prev = ctx
        for r in rules {
            var s = states[r.id] ?? State()
            // undo after hold time runs even when paused/disabled so nothing is left on screen
            if let u = s.undoAt, ctx.time >= u {
                s.undoAt = nil
                if s.active, let undo = r.action.undo { out.append(cmd(r, undo, undo: true)) }
                s.active = false
            }
            guard running, r.enabled else { s.pendingAt = nil; states[r.id] = s; continue }
            if r.maxRuns > 0 && s.runs >= r.maxRuns && s.pendingAt == nil { states[r.id] = s; continue }

            switch r.trigger {
            case .clockTime:
                if let p {
                    let a = p.secondsOfDay, b = ctx.secondsOfDay, t = r.timeOfDay
                    let crossed = a <= b ? (a < t && t <= b) : (t > a || t <= b)       // handles midnight
                    if crossed && a != b { out += perform(r, &s, at: ctx.time) }
                }
            case .afterStart:
                if !s.armedFired && ctx.time >= startedAt + r.delay { s.armedFired = true; out += perform(r, &s, at: ctx.time) }
            case .repeating:
                let iv = max(1, r.interval)
                var next = s.nextRepeat ?? (startedAt + max(0, r.delay))
                if ctx.time >= next {
                    out += perform(r, &s, at: ctx.time)
                    while next <= ctx.time { next += iv }
                }
                s.nextRepeat = next
            case .onProgram:
                let isOn = !r.watchInputID.isEmpty && ctx.programInputID == r.watchInputID
                let wasOn = !r.watchInputID.isEmpty && p?.programInputID == r.watchInputID
                out += edge(r, &s, isOn: isOn, wasOn: p == nil ? isOn : wasOn, ctx)
            case .onRecording:
                out += edge(r, &s, isOn: ctx.recording, wasOn: p?.recording ?? ctx.recording, ctx)
            case .onStreaming:
                out += edge(r, &s, isOn: ctx.streaming, wasOn: p?.streaming ?? ctx.streaming, ctx)
            case .manual:
                break
            }
            states[r.id] = s
        }
        return out
    }

    private func edge(_ r: AutomationRule, _ s: inout State, isOn: Bool, wasOn: Bool, _ ctx: AutomationContext) -> [AutomationCommand] {
        var out: [AutomationCommand] = []
        if isOn && !wasOn { s.pendingAt = ctx.time + max(0, r.delay) }
        if !isOn && wasOn {
            s.pendingAt = nil
            if r.revertWhenEnds && s.active, let undo = r.action.undo {
                out.append(cmd(r, undo, undo: true)); s.active = false; s.undoAt = nil
            }
        }
        if let pend = s.pendingAt, ctx.time >= pend, isOn {
            s.pendingAt = nil
            out += perform(r, &s, at: ctx.time)
        }
        return out
    }

    private func perform(_ r: AutomationRule, _ s: inout State, at t: Double) -> [AutomationCommand] {
        s.runs += 1
        s.active = r.action.undo != nil
        s.undoAt = (r.holdSeconds > 0 && r.action.undo != nil) ? t + r.holdSeconds : nil
        return [cmd(r, r.action, undo: false)]
    }

    private func cmd(_ r: AutomationRule, _ a: AutomationAction, undo: Bool) -> AutomationCommand {
        AutomationCommand(ruleID: r.id, action: a, target: r.target, targetID: r.targetID, isUndo: undo)
    }
}

/// Saved cue list (Library/automation.json).
public final class AutomationLibrary {
    public let url: URL
    public var rules: [AutomationRule]
    public init(libraryRoot: URL) {
        url = libraryRoot.appendingPathComponent("automation.json")
        rules = (try? JSONFile.read([AutomationRule].self, from: url)) ?? []
    }
    public func save() { try? JSONFile.write(rules, to: url) }
}
