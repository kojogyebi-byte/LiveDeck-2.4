import SwiftUI
import AppKit
import Combine
import PresentationKit

// MARK: - Auto Mix (automatic switching) — controller

final class AutoMixController: ObservableObject {
    @Published var plan: AutoMixPlan {
        didSet {
            director.update(plan: plan)
            if let data = try? JSONEncoder().encode(plan) { UserDefaults.standard.set(data, forKey: "automix.plan") }
        }
    }
    @Published private(set) var state: AutoMixDirector.State = .stopped
    @Published private(set) var currentShot: String?
    @Published private(set) var lastReason = ""

    weak var engine: Engine?
    private var director: AutoMixDirector
    private var timer: Timer?
    private var autoSwitchAt = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    init() {
        let saved = UserDefaults.standard.data(forKey: "automix.plan").flatMap { try? JSONDecoder().decode(AutoMixPlan.self, from: $0) }
        let p = saved ?? AutoMixPlan()
        plan = p
        director = AutoMixDirector(plan: p, seed: UInt64(Date().timeIntervalSince1970))
    }

    func activate(engine: Engine) {
        self.engine = engine
        engine.$programID.removeDuplicates().dropFirst().sink { [weak self] id in
            guard let self, self.director.isActive, Date().timeIntervalSince(self.autoSwitchAt) > 0.6 else { return }
            let name = id.flatMap { pid in engine.sources.first { $0.id == pid }?.name }
            self.director.manualSwitch(to: name, now: self.now)
            self.lastReason = "You switched to \(name ?? "another input")"
            self.publish()
        }.store(in: &cancellables)
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }
    var isRunning: Bool { state != .stopped }
    func remaining() -> Double { director.remaining(now: now) }
    var shotLength: Double { director.shotLength }

    private var available: Set<String> {
        Set(engine?.sources.filter { !$0.isPlaceholder }.map { $0.name } ?? [])
    }
    private var programName: String? {
        guard let e = engine, let id = e.programID else { return nil }
        return e.sources.first { $0.id == id }?.name
    }

    func start() {
        guard !plan.slots.filter({ $0.enabled }).isEmpty else { lastReason = "Add at least one input to the rotation."; return }
        let d = director.start(now: now, program: programName, available: available)
        lastReason = plan.mode == .voice ? "Listening for who is speaking" : "Auto Mix started"
        perform(d)
        startTimer()
        publish()
    }

    func stop() {
        director.stop()
        timer?.invalidate(); timer = nil
        lastReason = "Auto Mix stopped"
        publish()
    }

    func toggle() { isRunning ? stop() : start() }

    func pauseOrResume() {
        switch director.state {
        case .running, .holding: director.pause(); lastReason = "Paused — you have control"
        case .paused: director.resume(now: now); lastReason = "Resumed"
        case .stopped: start(); return
        }
        publish()
    }

    func next() { perform(director.next(now: now, available: available)); publish() }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let engine else { return }
        var levels: [String: Double] = [:]
        if plan.mode == .voice {
            for s in engine.sources where !s.isPlaceholder { levels[s.name] = Double(engine.telemetry.levels[s.id] ?? 0) }
        }
        perform(director.tick(now: now, program: programName, available: available, levels: levels))
        publish()
    }

    private func perform(_ decision: AutoMixDecision?) {
        guard let d = decision, let engine, let s = engine.sources.first(where: { $0.name == d.inputName && !$0.isPlaceholder }) else { return }
        lastReason = d.reason
        guard engine.programID != s.id else { return }
        autoSwitchAt = Date()
        engine.setPreview(s.id)
        if d.useTransition { engine.runTransition() } else { engine.cut() }
    }

    private func publish() {
        if state != director.state { state = director.state }
        if currentShot != director.currentShot { currentShot = director.currentShot }
    }

    // MARK: plan editing helpers

    func addAllInputs() {
        guard let engine else { return }
        let existing = Set(plan.slots.map { $0.inputName })
        for s in engine.sources where !s.isPlaceholder && !existing.contains(s.name) {
            plan.slots.append(AutoMixSlot(inputName: s.name, seconds: plan.slots.last?.seconds ?? 8))
        }
    }

    func setAllSeconds(_ seconds: Double) {
        for i in plan.slots.indices { plan.slots[i].seconds = seconds }
    }
}

// MARK: - Auto Mix panel (Automation tab)

struct AutoMixView: View {
    @EnvironmentObject var autoMix: AutoMixController
    @EnvironmentObject var engine: Engine
    @State private var sameSeconds: Double = 8

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        slotList
                    }
                    .padding(10)
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.bg1)

            CPInspector {
                CPCard(title: "How Auto Mix switches", icon: "shuffle") {
                    DSSegmented(selection: $autoMix.plan.mode, options: AutoMixMode.allCases.map { ($0, $0.rawValue) }).padding(.vertical, 6)
                    CPNote(autoMix.plan.mode == .timed
                           ? "Each input stays on Program for its own time, then Auto Mix moves to the next one."
                           : "Auto Mix cuts to the person who is speaking, using each input's microphone level — ideal for podcasts and interviews.")
                    if autoMix.plan.mode == .timed {
                        CPRow(label: "Order") {
                            DSSegmented(selection: $autoMix.plan.order, options: AutoMixOrder.allCases.map { ($0, $0.rawValue) }).frame(width: 170)
                        }
                        CPSliderRow(label: "Natural variation", value: $autoMix.plan.variation, range: 0...0.5, defaultValue: 0, format: "%.2f")
                        CPNote("Variation makes each shot a little shorter or longer so the rotation feels less mechanical.")
                    } else {
                        CPSliderRow(label: "Sensitivity", value: Binding(get: { 1 - autoMix.plan.voiceThreshold * 5 }, set: { autoMix.plan.voiceThreshold = max(0.005, (1 - $0) / 5) }),
                                    range: 0...0.97, defaultValue: 0.7, format: "%.2f")
                        CPSliderRow(label: "Speaker must lead (s)", value: $autoMix.plan.switchDelay, range: 0.2...3, defaultValue: 0.7, format: "%.1f")
                        CPSliderRow(label: "Shortest shot (s)", value: $autoMix.plan.minShotSeconds, range: 1...15, defaultValue: 2.5, format: "%.1f")
                        CPRow(label: "Wide shot") {
                            Picker("", selection: Binding(get: { autoMix.plan.wideShotName ?? "" }, set: { autoMix.plan.wideShotName = $0.isEmpty ? nil : $0 })) {
                                Text("None").tag("")
                                ForEach(engine.sources.filter { !$0.isPlaceholder }, id: \.id) { s in Text(s.name).tag(s.name) }
                            }
                            .cpPickerChrome().frame(maxWidth: 170)
                        }
                        CPSliderRow(label: "Wide after silence (s)", value: $autoMix.plan.silenceSeconds, range: 1...30, defaultValue: 5, format: "%.0f")
                        CPNote("The wide shot is used when several people talk at once or nobody speaks.")
                    }
                    CPToggleRow(label: "Use the transition (AUTO) instead of CUT", isOn: $autoMix.plan.useTransition)
                }
                CPCard(title: "When you switch by hand", icon: "hand.raised") {
                    DSSegmented(selection: $autoMix.plan.override, options: AutoMixOverride.allCases.map { ($0, $0 == .continueFromThere ? "Carry on" : ($0 == .pause ? "Pause" : "Resume later")) })
                        .padding(.vertical, 6)
                    if autoMix.plan.override == .resumeAfter {
                        CPSliderRow(label: "Resume after (s)", value: $autoMix.plan.resumeAfterSeconds, range: 5...300, defaultValue: 20, format: "%.0f")
                    }
                    CPNote(overrideNote)
                }
            }
            .frame(minWidth: 280, idealWidth: 330, maxWidth: 420)
        }
    }

    private var overrideNote: String {
        switch autoMix.plan.override {
        case .pause: return "Any CUT, AUTO or input you take yourself pauses Auto Mix until you press Resume."
        case .resumeAfter: return "Your own switch holds for a while, then Auto Mix carries on automatically."
        case .continueFromThere: return "Your shot counts as the current one and the rotation continues from there."
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { autoMix.toggle() } label: {
                Label(autoMix.isRunning ? "Stop Auto Mix" : "Start Auto Mix", systemImage: autoMix.isRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.ds(autoMix.isRunning ? .program : .preview, .regular))
            if autoMix.isRunning {
                Button(pauseTitle) { autoMix.pauseOrResume() }.buttonStyle(.ds(.normal, .regular))
                Button { autoMix.next() } label: { Label("Next", systemImage: "forward.end.fill") }.buttonStyle(.ds(.normal, .regular))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(statusLine).font(.system(size: 12, weight: .semibold)).foregroundColor(DS.text).lineLimit(1)
                Text(autoMix.lastReason).font(.system(size: 10.5)).foregroundColor(DS.text2).lineLimit(1)
            }
            Spacer()
            if autoMix.isRunning && autoMix.plan.mode == .timed {
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    let rem = autoMix.remaining()
                    HStack(spacing: 6) {
                        ProgressView(value: autoMix.shotLength > 0 ? max(0, min(1, 1 - rem / autoMix.shotLength)) : 0).tint(CP.toggle).frame(width: 90)
                        Text(String(format: "%.0f s", rem.rounded(.up))).font(DS.mono(11)).foregroundColor(DS.text2).frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 10).frame(height: 52).background(DS.bg2)
        .overlay(Rectangle().fill(DS.lineSoft).frame(height: 1), alignment: .bottom)
    }

    private var pauseTitle: String {
        switch autoMix.state { case .paused: return "Resume"; default: return "Pause" }
    }

    private var statusLine: String {
        switch autoMix.state {
        case .stopped: return "Auto Mix is off"
        case .paused: return "Paused — you are switching"
        case .holding: return "Holding your shot, then resuming"
        case .running: return "On air: \(autoMix.currentShot ?? "—")"
        }
    }

    private var slotList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("INPUTS IN THE ROTATION").font(CPFont.section).foregroundColor(DS.text3)
                Spacer()
                Menu {
                    ForEach(engine.sources.filter { !$0.isPlaceholder }, id: \.id) { s in
                        Button(s.name) { autoMix.plan.slots.append(AutoMixSlot(inputName: s.name, seconds: sameSeconds)) }
                    }
                    Divider()
                    Button("All inputs") { autoMix.addAllInputs() }
                } label: { Label("Add input", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if autoMix.plan.slots.isEmpty {
                Text("Add the cameras or inputs Auto Mix should switch between. Give each its own time on air — the same or different.")
                    .font(.system(size: 11)).foregroundColor(DS.text2).padding(.vertical, 20).frame(maxWidth: .infinity)
            }
            ForEach(Array(autoMix.plan.slots.enumerated()), id: \.element.id) { index, slot in
                slotRow(index, slot)
            }
            if autoMix.plan.mode == .timed && !autoMix.plan.slots.isEmpty {
                HStack(spacing: 6) {
                    Text("Same time for all").font(.system(size: 11)).foregroundColor(DS.text2)
                    TextField("", value: $sameSeconds, format: .number).dsField().frame(width: 54)
                    Text("s").font(.system(size: 11)).foregroundColor(DS.text3)
                    Button("Apply") { autoMix.setAllSeconds(max(1, sameSeconds)) }.buttonStyle(.ds(.normal, .small))
                    Spacer()
                    let total = autoMix.plan.slots.filter { $0.enabled }.reduce(0) { $0 + $1.seconds }
                    Text("One full round: \(Int(total)) s").font(.system(size: 10.5)).foregroundColor(DS.text3)
                }
                .padding(.top, 4)
            }
        }
    }

    private func slotRow(_ index: Int, _ slot: AutoMixSlot) -> some View {
        let binding = Binding<AutoMixSlot>(get: { index < autoMix.plan.slots.count ? autoMix.plan.slots[index] : slot },
                                           set: { if index < autoMix.plan.slots.count { autoMix.plan.slots[index] = $0 } })
        let onAir = autoMix.isRunning && autoMix.currentShot == slot.inputName
        let exists = engine.sources.contains { $0.name == slot.inputName && !$0.isPlaceholder }
        return HStack(spacing: 8) {
            Toggle("", isOn: binding.enabled).toggleStyle(.checkbox).labelsHidden()
            Text("\(index + 1)").font(DS.mono(10)).foregroundColor(DS.text3).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(slot.inputName).font(.system(size: 12, weight: .medium)).foregroundColor(exists ? DS.text : DS.text3).lineLimit(1)
                if !exists { Text("Input not found").font(.system(size: 9.5)).foregroundColor(DS.amber) }
            }
            .frame(minWidth: 120, alignment: .leading)
            if onAir {
                Text("ON AIR").font(.system(size: 9, weight: .heavy)).foregroundColor(.white).padding(.horizontal, 5).frame(height: 16)
                    .background(RoundedRectangle(cornerRadius: 3).fill(DS.program))
            }
            Spacer()
            if autoMix.plan.mode == .timed {
                TextField("", value: binding.seconds, format: .number).dsField().frame(width: 54)
                Stepper("", value: binding.seconds, in: 1...3600, step: 1).labelsHidden()
                Text("s").font(.system(size: 11)).foregroundColor(DS.text3)
            } else {
                Text("Mic").font(.system(size: 10.5)).foregroundColor(DS.text3)
                Picker("", selection: Binding(get: { slot.micName ?? "" }, set: { binding.wrappedValue.micName = $0.isEmpty ? nil : $0 })) {
                    Text("This input").tag("")
                    ForEach(engine.sources.filter { !$0.isPlaceholder }, id: \.id) { s in Text(s.name).tag(s.name) }
                }
                .frame(width: 140)
                LevelBar(telemetry: engine.telemetry, sourceID: engine.sources.first { $0.name == (slot.micName ?? slot.inputName) }?.id,
                         threshold: autoMix.plan.voiceThreshold)
            }
            Button { if index > 0 { autoMix.plan.slots.swapAt(index, index - 1) } } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).foregroundColor(DS.text3).disabled(index == 0)
            Button { if index + 1 < autoMix.plan.slots.count { autoMix.plan.slots.swapAt(index, index + 1) } } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).foregroundColor(DS.text3).disabled(index + 1 >= autoMix.plan.slots.count)
            Button { autoMix.plan.slots.remove(at: index) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundColor(DS.text3)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(onAir ? DS.program.opacity(0.12) : DS.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(onAir ? DS.program.opacity(0.6) : DS.lineSoft, lineWidth: 1))
    }
}

private struct LevelBar: View {
    @ObservedObject var telemetry: Telemetry
    let sourceID: UUID?
    let threshold: Double
    var body: some View {
        let level = Double(sourceID.flatMap { telemetry.levels[$0] } ?? 0)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(DS.bg0)
                RoundedRectangle(cornerRadius: 2).fill(level >= threshold ? DS.ok : DS.text3).frame(width: g.size.width * CGFloat(min(1, level * 2)))
                Rectangle().fill(DS.amber).frame(width: 1).offset(x: g.size.width * CGFloat(min(1, threshold * 2)))
            }
        }
        .frame(width: 70, height: 8)
    }
}

/// On-air status bar chip.
struct AutoMixStatusChip: View {
    @EnvironmentObject var autoMix: AutoMixController
    var body: some View {
        if autoMix.isRunning {
            Button { autoMix.pauseOrResume() } label: {
                HStack(spacing: 5) {
                    Image(systemName: autoMix.plan.mode == .voice ? "waveform" : "shuffle").font(.system(size: 10, weight: .semibold))
                    Text(autoMix.state == .paused ? "AUTO MIX · PAUSED" : "AUTO MIX").font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(autoMix.state == .paused ? DS.amber : DS.ok)
                .padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(DS.bg0))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder((autoMix.state == .paused ? DS.amber : DS.ok).opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Auto Mix — click to pause or resume")
        }
    }
}
