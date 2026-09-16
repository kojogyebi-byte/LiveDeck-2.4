import SwiftUI
import AppKit
import PresentationKit

// MARK: - Automation runtime

final class AutomationModel: ObservableObject {
    weak var engine: Engine?
    private let library = AutomationLibrary(libraryRoot: PresentationLibrary.defaultRoot)
    private let scheduler = AutomationScheduler()
    private var timer: Timer?

    @Published var rules: [AutomationRule] { didSet { library.rules = rules; library.save() } }
    @Published var selectedID: UUID?
    @Published private(set) var running = false
    @Published var log: [String] = []
    @Published var tick = 0            // refreshes countdowns

    init() {
        rules = library.rules
        selectedID = rules.first?.id
    }

    var selectedIndex: Int? { rules.firstIndex { $0.id == selectedID } }

    // MARK: control

    func start() {
        scheduler.start(at: now)
        running = true
        addLog("Automation started")
        if timer == nil {
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.step() }
            t.tolerance = 0.05
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func stop() {
        running = false
        scheduler.stop()
        addLog("Automation stopped")
    }

    func runNow(_ r: AutomationRule) {
        execute(scheduler.runNow(r, at: now))
        ensureTimer()                          // processes the hold-time undo even when automation is stopped
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func context() -> AutomationContext {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        let sod = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
        return AutomationContext(time: now, secondsOfDay: sod, programInputID: engine?.programID?.uuidString,
                                 recording: engine?.isRecording ?? false, streaming: engine?.isStreaming ?? false)
    }

    private func step() {
        execute(scheduler.tick(rules, context()))
        tick &+= 1
    }

    func countdown(_ r: AutomationRule) -> String {
        _ = tick
        if scheduler.isActive(r.id) { return "on air" }
        guard let s = scheduler.secondsUntilNext(r, context()) else {
            if !running { return "stopped" }
            switch r.trigger {
            case .onProgram: return "waiting for Program"
            case .onRecording: return "waiting for REC"
            case .onStreaming: return "waiting for STREAM"
            case .manual: return "manual"
            default: return r.maxRuns > 0 && scheduler.runs(r.id) >= r.maxRuns ? "done" : "—"
            }
        }
        let v = Int(s.rounded(.up))
        return v >= 3600 ? String(format: "in %d:%02d:%02d", v / 3600, v / 60 % 60, v % 60) : String(format: "in %d:%02d", v / 60, v % 60)
    }

    // MARK: editing

    func add(_ template: Int) {
        var r = AutomationRule()
        let overlay = engine?.layers.first
        let camera = engine?.sources.first { !$0.isPlaceholder }
        switch template {
        case 1:
            r.name = "Lower third after camera goes live"
            r.trigger = .onProgram; r.delay = 5; r.watchInputID = camera?.id.uuidString ?? ""
            r.target = .overlay; r.targetID = overlay?.id.uuidString ?? ""; r.action = .show; r.holdSeconds = 8
        case 2:
            r.name = "Lower third every 10 minutes"
            r.trigger = .repeating; r.delay = 60; r.interval = 600
            r.target = .overlay; r.targetID = overlay?.id.uuidString ?? ""; r.action = .show; r.holdSeconds = 10
        case 3:
            r.name = "Logo at service start"
            r.trigger = .clockTime; r.timeOfDay = 9 * 3600
            r.target = .overlay; r.targetID = overlay?.id.uuidString ?? ""; r.action = .show; r.holdSeconds = 0
        case 4:
            r.name = "Key input when recording starts"
            r.trigger = .onRecording; r.delay = 3
            r.target = .keyInput; r.targetID = engine?.sources.first(where: { $0 is SlideSource || $0 is GeneratorSource })?.id.uuidString ?? ""
            r.action = .show; r.holdSeconds = 15
        default:
            r.name = "New cue"
            r.target = .overlay; r.targetID = overlay?.id.uuidString ?? ""
        }
        rules.append(r)
        selectedID = r.id
    }

    func duplicate(_ r: AutomationRule) {
        var c = r; c.id = UUID(); c.name += " copy"
        rules.append(c); selectedID = c.id
    }

    func delete(_ r: AutomationRule) {
        rules.removeAll { $0.id == r.id }
        selectedID = rules.first?.id
    }

    // MARK: executing

    private func execute(_ cmds: [AutomationCommand]) {
        guard let engine, !cmds.isEmpty else { return }
        for c in cmds {
            let name = rules.first { $0.id == c.ruleID }?.name ?? "Cue"
            switch c.target {
            case .overlay:
                guard let layer = engine.layers.first(where: { $0.id.uuidString == c.targetID }) else { addLog("\(name): overlay not found"); continue }
                switch c.action {
                case .show: layer.isLive = true
                case .hide: layer.isLive = false
                case .toggle: layer.isLive.toggle()
                default: break
                }
                addLog("\(name): \(layer.isLive ? "showed" : "hid") “\(layer.name)”\(c.isUndo ? " (hold ended)" : "")")
            case .keyInput:
                guard let id = UUID(uuidString: c.targetID), let src = engine.sources.first(where: { $0.id == id }) else { addLog("\(name): input not found"); continue }
                let on: Bool
                switch c.action {
                case .show: on = true
                case .hide: on = false
                default: on = !engine.keyedSources.contains(id)
                }
                if on != engine.keyedSources.contains(id) { engine.toggleKey(id) }
                addLog("\(name): \(on ? "keyed" : "removed key") “\(src.name)”\(c.isUndo ? " (hold ended)" : "")")
            case .input:
                guard let id = UUID(uuidString: c.targetID), let src = engine.sources.first(where: { $0.id == id }) else { addLog("\(name): input not found"); continue }
                engine.setPreview(id)
                if c.action == .cutToProgram { engine.cut() }
                addLog("\(name): \(c.action == .cutToProgram ? "cut to" : "previewed") “\(src.name)”")
            }
        }
    }

    private func addLog(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.insert("\(f.string(from: Date()))  \(s)", at: 0)
        if log.count > 40 { log.removeLast(log.count - 40) }
    }

    func describe(_ r: AutomationRule) -> String {
        guard let engine else { return r.trigger.rawValue }
        let targetName: String = {
            switch r.target {
            case .overlay: return engine.layers.first { $0.id.uuidString == r.targetID }?.name ?? "(choose overlay)"
            default: return engine.sources.first { $0.id.uuidString == r.targetID }?.name ?? "(choose input)"
            }
        }()
        let when: String
        switch r.trigger {
        case .clockTime: when = "at " + AutomationRule.timeText(r.timeOfDay)
        case .afterStart: when = "\(Int(r.delay)) s after Start"
        case .repeating: when = "every \(AutomationModel.duration(r.interval))"
        case .onProgram: when = "\(Int(r.delay)) s after “\(engine.sources.first { $0.id.uuidString == r.watchInputID }?.name ?? "?")” is on Program"
        case .onRecording: when = "\(Int(r.delay)) s after REC starts"
        case .onStreaming: when = "\(Int(r.delay)) s after STREAM starts"
        case .manual: when = "when Run is pressed"
        }
        let hold = r.holdSeconds > 0 && r.action.undo != nil ? " for \(AutomationModel.duration(r.holdSeconds))" : ""
        return "\(r.action.rawValue) \(targetName)\(hold) — \(when)"
    }

    static func duration(_ s: Double) -> String {
        let v = Int(s)
        if v >= 3600 { return String(format: "%dh %02dm", v / 3600, v / 60 % 60) }
        if v >= 60 { return v % 60 == 0 ? "\(v / 60) min" : "\(v / 60) min \(v % 60) s" }
        return "\(v) s"
    }
}

// MARK: - Automation deck

struct AutomationDeck: View {
    @EnvironmentObject var auto: AutomationModel
    @EnvironmentObject var engine: Engine

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        auto.running ? auto.stop() : auto.start()
                    } label: {
                        Label(auto.running ? "Stop automation" : "Start automation", systemImage: auto.running ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.ds(auto.running ? .program : .preview, .regular))
                    Text(auto.running ? "Cues are armed" : "Cues wait until you press Start").font(.system(size: 11)).foregroundColor(DS.text2)
                    Spacer()
                    Menu {
                        Button("Blank cue") { auto.add(0) }
                        Divider()
                        Button("Lower third a few seconds after a camera goes live") { auto.add(1) }
                        Button("Lower third every 10 minutes") { auto.add(2) }
                        Button("Show logo at a time of day") { auto.add(3) }
                        Button("Key an input when recording starts") { auto.add(4) }
                    } label: { Label("Add cue", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(8).background(DS.bg2)

                if auto.rules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "timer").font(.system(size: 32)).foregroundColor(DS.text3)
                        Text("Automate lower thirds, logos and keyed inputs.").font(DS.label).foregroundColor(DS.text2)
                        Text("Add a cue, choose what to show and when, then press Start automation.").font(.system(size: 10)).foregroundColor(DS.text3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(auto.rules) { r in cueRow(r) }
                        }
                        .padding(8)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTIVITY").font(.system(size: 9, weight: .bold)).kerning(1).foregroundColor(DS.text3)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(auto.log.enumerated()), id: \.offset) { _, line in
                                Text(line).font(DS.mono(10)).foregroundColor(DS.text2).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 70)
                }
                .padding(8).background(DS.bg0)
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            Group {
                if let id = auto.selectedID, auto.rules.contains(where: { $0.id == id }) {
                    AutomationEditor(rule: Binding(
                        get: { auto.rules.first { $0.id == id } ?? AutomationRule(id: id) },
                        set: { v in if let i = auto.rules.firstIndex(where: { $0.id == id }) { auto.rules[i] = v } }))
                } else {
                    Text("Select or add a cue.").font(DS.label).foregroundColor(DS.text2).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 460, maxHeight: .infinity)
            .background(DS.bg1)
        }
    }

    private func cueRow(_ r: AutomationRule) -> some View {
        let active = auto.countdown(r) == "on air"
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { r.enabled }, set: { v in if let i = auto.rules.firstIndex(where: { $0.id == r.id }) { auto.rules[i].enabled = v } }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            Circle().fill(active ? DS.program : (auto.running && r.enabled ? DS.ok : DS.text3)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 12, weight: .semibold)).foregroundColor(DS.text).lineLimit(1)
                Text(auto.describe(r)).font(.system(size: 10)).foregroundColor(DS.text2).lineLimit(1)
            }
            Spacer()
            Text(auto.countdown(r)).font(DS.mono(11)).foregroundColor(active ? DS.program : DS.amber)
            Button("Run") { auto.runNow(r) }.buttonStyle(.ds(.normal, .small)).help("Fire this cue now")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(auto.selectedID == r.id ? DS.accent.opacity(0.16) : DS.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(auto.selectedID == r.id ? DS.accent : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { auto.selectedID = r.id }
        .contextMenu {
            Button("Run now") { auto.runNow(r) }
            Button("Duplicate") { auto.duplicate(r) }
            Button("Delete", role: .destructive) { auto.delete(r) }
        }
    }
}

struct AutomationEditor: View {
    @EnvironmentObject var auto: AutomationModel
    @EnvironmentObject var engine: Engine
    @Binding var rule: AutomationRule

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "Cue", icon: "timer")
                Group {
                    FieldRow(label: "Name") { TextField("Name", text: $rule.name).dsField() }

                    SectionLabel("What")
                    FieldRow(label: "Target") {
                        Picker("", selection: Binding(get: { rule.target }, set: { t in
                            rule.target = t
                            if !t.actions.contains(rule.action) { rule.action = t.actions[0] }
                            rule.targetID = ""
                        })) { ForEach(AutomationTarget.allCases) { t in Text(t.rawValue).tag(t) } }.labelsHidden()
                    }
                    FieldRow(label: rule.target == .overlay ? "Overlay" : "Input") {
                        Picker("", selection: $rule.targetID) {
                            Text("Choose…").tag("")
                            if rule.target == .overlay {
                                ForEach(engine.layers) { l in Text(l.name).tag(l.id.uuidString) }
                            } else {
                                ForEach(engine.sources.filter { !$0.isPlaceholder }) { s in Text(s.name).tag(s.id.uuidString) }
                            }
                        }.labelsHidden()
                    }
                    FieldRow(label: "Action") {
                        Picker("", selection: $rule.action) { ForEach(rule.target.actions) { a in Text(a.rawValue).tag(a) } }.labelsHidden()
                    }
                    if rule.action.undo != nil {
                        numberRow("Hold for", $rule.holdSeconds, suffix: "s (0 = stay on)", range: 0...3600)
                    }
                }
                Group {
                    SectionLabel("When")
                    FieldRow(label: "Trigger") {
                        Picker("", selection: $rule.trigger) { ForEach(AutomationTrigger.allCases) { t in Text(t.rawValue).tag(t) } }.labelsHidden()
                    }
                    switch rule.trigger {
                    case .clockTime:
                        FieldRow(label: "Time") { TimeOfDayField(seconds: $rule.timeOfDay) }
                    case .afterStart:
                        numberRow("Delay", $rule.delay, suffix: "s after Start", range: 0...86400)
                    case .repeating:
                        numberRow("Every", $rule.interval, suffix: "s", range: 1...86400)
                        numberRow("First after", $rule.delay, suffix: "s", range: 0...86400)
                    case .onProgram:
                        FieldRow(label: "Input") {
                            Picker("", selection: $rule.watchInputID) {
                                Text("Choose…").tag("")
                                ForEach(engine.sources.filter { !$0.isPlaceholder }) { s in Text(s.name).tag(s.id.uuidString) }
                            }.labelsHidden()
                        }
                        numberRow("Delay", $rule.delay, suffix: "s", range: 0...3600)
                        Toggle("Undo when the input leaves Program", isOn: $rule.revertWhenEnds).font(DS.small)
                    case .onRecording, .onStreaming:
                        numberRow("Delay", $rule.delay, suffix: "s", range: 0...3600)
                        Toggle("Undo when it stops", isOn: $rule.revertWhenEnds).font(DS.small)
                    case .manual:
                        Text("This cue only fires when you press Run.").font(DS.small).foregroundColor(DS.text2)
                    }
                    FieldRow(label: "Limit") {
                        Stepper(rule.maxRuns == 0 ? "Unlimited runs" : "\(rule.maxRuns) run\(rule.maxRuns == 1 ? "" : "s")", value: $rule.maxRuns, in: 0...999)
                            .font(DS.small)
                    }
                }
                Text(auto.describe(rule)).font(.system(size: 11)).foregroundColor(DS.accent).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Run now") { auto.runNow(rule) }.buttonStyle(.ds(.primary, .small))
                    Button("Duplicate") { auto.duplicate(rule) }.buttonStyle(.ds(.normal, .small))
                    Spacer()
                    Button("Delete") { auto.delete(rule) }.buttonStyle(.ds(.danger, .small))
                }
                Text("Tip: add lower thirds in Overlays (control panel). Keyed inputs are shown over Program like the KEY button.")
                    .font(.system(size: 9.5)).foregroundColor(DS.text3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
        }
    }

    private func numberRow(_ label: String, _ value: Binding<Double>, suffix: String, range: ClosedRange<Double>) -> some View {
        FieldRow(label: label) {
            HStack(spacing: 6) {
                TextField("", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }),
                          format: .number.precision(.fractionLength(0...1)))
                    .dsField().frame(width: 80)
                Text(suffix).font(DS.small).foregroundColor(DS.text2)
                Spacer()
            }
        }
    }
}

struct TimeOfDayField: View {
    @Binding var seconds: Int
    var body: some View {
        HStack(spacing: 4) {
            part(Binding(get: { seconds / 3600 }, set: { seconds = $0 * 3600 + seconds % 3600 }), 0...23)
            Text(":")
            part(Binding(get: { seconds / 60 % 60 }, set: { seconds = seconds / 3600 * 3600 + $0 * 60 + seconds % 60 }), 0...59)
            Text(":")
            part(Binding(get: { seconds % 60 }, set: { seconds = seconds / 60 * 60 + $0 }), 0...59)
            Spacer()
        }
    }
    private func part(_ v: Binding<Int>, _ r: ClosedRange<Int>) -> some View {
        TextField("", value: Binding(get: { v.wrappedValue }, set: { v.wrappedValue = min(max($0, r.lowerBound), r.upperBound) }),
                  format: .number)
            .dsField().frame(width: 44).multilineTextAlignment(.center)
    }
}
