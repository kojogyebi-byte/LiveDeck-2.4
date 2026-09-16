import SwiftUI
import AppKit
import PresentationKit

// MARK: - Console look

enum MX {
    static let bg = Color(rgb: 0x232323)
    static let box = Color(rgb: 0x1B1B1B)
    static let boxLine = Color(rgb: 0x2E2E2E)
    static let field = Color(rgb: 0x121212)
    static let label = Color(rgb: 0x9A9A9A)
    static let text = Color(rgb: 0xE9E9E9)
    static let dim = Color(rgb: 0x5E5E5E)
    static let green = Color(rgb: 0x3FCB3F)
    static let yellow = Color(rgb: 0xE9D22A)
    static let red = Color(rgb: 0xE8332A)
    static let orange = Color(rgb: 0xF07A1E)
    static let cyan = Color(rgb: 0x3CC7D8)
    static let dyn = Color(rgb: 0xB4D23C)
    static let olive = Color(rgb: 0x8C7F2E)
    static let tallyOff = Color(rgb: 0x2A2A2A)

    // section heights (label column and strips share them)
    static let header: CGFloat = 40
    static let input: CGFloat = 96
    static let eq: CGFloat = 34
    static let dynamics: CGFloat = 46
    static let pan: CGFloat = 88
    static let mode: CGFloat = 30
    static let solo: CGFloat = 36
    static let gap: CGFloat = 6
    static let stripWidth: CGFloat = 122
    static let fixed: CGFloat = header + input + eq + dynamics + pan + mode + solo + gap * 7
    static let minHeight: CGFloat = fixed + 190

    static func levelColor(_ db: Double) -> Color { db >= -3 ? red : (db >= -20 ? yellow : green) }
}

// MARK: - Rotary knob

struct RotaryKnob: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double
    var arcColor: Color = MX.green
    var bipolar = false
    var size: CGFloat = 44
    var leftLabel = ""
    var rightLabel = ""
    var minLabel = ""
    var maxLabel = ""
    @State private var startValue: Double?

    private var span: Double { max(0.000001, range.upperBound - range.lowerBound) }
    private var frac: Double { (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span }

    var body: some View {
        ZStack {
            // track + value arc (270° sweep starting bottom-left)
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.black.opacity(0.65), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: bipolar ? min(0.375, frac * 0.75) : 0, to: bipolar ? max(0.375, frac * 0.75) : frac * 0.75)
                .stroke(arcColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: arcColor.opacity(0.5), radius: 2)
            // knob body
            Circle()
                .fill(RadialGradient(colors: [Color(rgb: 0xF4F4F4), Color(rgb: 0xB9B9B9), Color(rgb: 0x7C7C7C)],
                                     center: UnitPoint(x: 0.4, y: 0.35), startRadius: 1, endRadius: size * 0.42))
                .overlay(Circle().strokeBorder(Color(rgb: 0x6A6A6A), style: StrokeStyle(lineWidth: 2, dash: [1.5, 1.5])))
                .frame(width: size * 0.66, height: size * 0.66)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1.5)
            // pointer
            Capsule().fill(Color(rgb: 0x1E1E1E))
                .frame(width: 3, height: size * 0.2)
                .offset(y: -size * 0.16)
                .rotationEffect(.degrees(-135 + frac * 270))
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topLeading) {
            if !leftLabel.isEmpty { Text(leftLabel).font(.system(size: 8, weight: .semibold)).foregroundColor(MX.label).offset(x: -6, y: -2) }
        }
        .overlay(alignment: .topTrailing) {
            if !rightLabel.isEmpty { Text(rightLabel).font(.system(size: 8, weight: .semibold)).foregroundColor(MX.label).offset(x: 6, y: -2) }
        }
        .overlay(alignment: .bottomLeading) {
            if !minLabel.isEmpty { Text(minLabel).font(.system(size: 7)).foregroundColor(MX.dim).offset(x: -8, y: 4) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !maxLabel.isEmpty { Text(maxLabel).font(.system(size: 7)).foregroundColor(MX.dim).offset(x: 8, y: 4) }
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { d in
                if startValue == nil { startValue = value }
                let delta = Double(-d.translation.height + d.translation.width * 0.3) / 160 * span
                value = min(max((startValue ?? value) + delta, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in startValue = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = defaultValue })
        .help("Drag up/down · double-click to reset")
    }
}

// MARK: - Value box (click to type)

struct ConsoleValueField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var display: (Double) -> String
    var width: CGFloat = 78
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(MX.text)
            .focused($focused)
            .frame(width: width, height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(MX.field))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(focused ? Color(rgb: 0x3D8BFD) : Color.black, lineWidth: 1))
            .onAppear { text = display(value) }
            .onChange(of: value) { v in if !focused { text = display(v) } }
            .onChange(of: focused) { f in if !f { commit() } }
            .onSubmit { commit() }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.contains("∞") || t.lowercased() == "-inf" { value = range.lowerBound }
        else if let v = Double(t.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) }) {
            value = min(max(v, range.lowerBound), range.upperBound)
        }
        text = display(value)
    }
}

// MARK: - Vertical fader with scale

struct ConsoleFader: View {
    @Binding var db: Double                // -60 … +10
    var capWidth: CGFloat = 26
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let capH: CGFloat = 38
            let travel = max(1, g.size.height - capH)
            let pos = AudioMath.faderPosition(db: db)
            ZStack(alignment: .top) {
                // slot
                RoundedRectangle(cornerRadius: 3).fill(Color.black)
                    .frame(width: 6)
                    .padding(.vertical, capH / 2)
                // scale ticks on the left
                ForEach([10.0, 0, -10, -20, -30, -50], id: \.self) { mark in
                    Rectangle().fill(MX.dim)
                        .frame(width: 4, height: 1)
                        .offset(x: -capWidth / 2 - 4, y: capH / 2 + (1 - AudioMath.faderPosition(db: mark)) * travel)
                }
                // cap
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [Color(rgb: 0xF2F2F2), Color(rgb: 0xA9A9A9), Color(rgb: 0xE0E0E0), Color(rgb: 0x9C9C9C)],
                                             startPoint: .top, endPoint: .bottom))
                    VStack(spacing: 3) {
                        ForEach(0..<5, id: \.self) { i in
                            Rectangle().fill(i == 2 ? Color(rgb: 0x444444) : Color(rgb: 0x8A8A8A)).frame(height: i == 2 ? 2 : 1)
                        }
                    }
                    .padding(.horizontal, 3)
                }
                .frame(width: capWidth, height: capH)
                .shadow(color: .black.opacity(0.7), radius: dragging ? 4 : 2, y: 2)
                .offset(y: (1 - pos) * travel)
            }
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    dragging = true
                    let p = 1 - Double((d.location.y - capH / 2) / travel)
                    db = (AudioMath.faderDB(position: min(max(p, 0), 1)) * 100).rounded() / 100
                }
                .onEnded { _ in dragging = false })
            .simultaneousGesture(TapGesture(count: 2).onEnded { db = 0 })
        }
        .help("Drag to set the level · double-click for 0 dB")
    }
}

/// dB labels beside the fader.
struct FaderScale: View {
    var body: some View {
        GeometryReader { g in
            let capH: CGFloat = 38
            let travel = max(1, g.size.height - capH)
            ForEach([0.0, -10, -20, -30, -50], id: \.self) { mark in
                Text(mark == 0 ? "0" : String(format: "%.0f", mark))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(MX.label)
                    .position(x: g.size.width / 2, y: capH / 2 + (1 - AudioMath.faderPosition(db: mark)) * travel)
            }
        }
    }
}

// MARK: - Meters

/// Vertical segmented meter (green → yellow → red) for a -60…+6 dB scale.
struct VerticalMeter: View {
    var level: Float
    var body: some View {
        Canvas { ctx, size in
            let db = meterDB(level)
            let segH: CGFloat = 3, gap: CGFloat = 1
            let count = Int(size.height / (segH + gap))
            guard count > 0 else { return }
            for i in 0..<count {
                let frac = Double(i) / Double(max(1, count - 1))           // 0 bottom … 1 top
                let segDB = -60 + frac * 66
                let lit = segDB <= db
                let color: Color = segDB >= -3 ? MX.red : (segDB >= -20 ? MX.yellow : MX.green)
                let y = size.height - CGFloat(i + 1) * (segH + gap)
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: segH)),
                         with: .color(lit ? color : color.opacity(0.1)))
            }
        }
        .background(Color.black)
    }
}

struct ChannelStereoMeter: View {
    @EnvironmentObject var tele: Telemetry
    let id: UUID
    let active: Bool
    var body: some View {
        HStack(spacing: 2) {
            VerticalMeter(level: active ? (tele.levelsL[id] ?? 0) : 0).frame(width: 5)
            VerticalMeter(level: active ? (tele.levelsR[id] ?? 0) : 0).frame(width: 5)
        }
    }
}

struct ChannelPeakLabel: View {
    @EnvironmentObject var tele: Telemetry
    let id: UUID?
    let active: Bool
    var body: some View {
        let lv: Float = active ? (id.map { tele.levels[$0] ?? 0 } ?? tele.master) : 0
        let db = meterDB(lv)
        Text(lv > 0.0009 ? String(format: "%.2f", db) : "-∞")
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundColor(lv > 0.0009 ? MX.levelColor(db) : MX.dim)
    }
}

struct MasterStereoMeter: View {
    @EnvironmentObject var tele: Telemetry
    var body: some View {
        HStack(spacing: 2) {
            VerticalMeter(level: tele.masterL).frame(width: 6)
            VerticalMeter(level: tele.masterR).frame(width: 6)
        }
    }
}

// MARK: - Mini EQ / dynamics displays

struct MiniEQDisplay: View {
    @ObservedObject var source: Source
    var body: some View {
        GeometryReader { g in
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: g.size.width / 2, y: 0)); p.addLine(to: CGPoint(x: g.size.width / 2, y: g.size.height))
                }.stroke(MX.boxLine, lineWidth: 1)
                Path { p in
                    let steps = 60
                    for i in 0...steps {
                        let x = CGFloat(i) / CGFloat(steps) * g.size.width
                        let f = 20 * pow(1000, Double(i) / Double(steps))     // 20 Hz … 20 kHz
                        let db = source.fxEnabled ? max(-24, min(24, eqTotalDB(f, source))) : 0
                        let y = g.size.height / 2 - CGFloat(db / 24) * (g.size.height / 2 - 2)
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(source.fxEnabled ? MX.cyan : MX.cyan.opacity(0.45), lineWidth: 1.5)
            }
        }
    }
}

/// Static transfer curve: gate below its threshold, compressor above its threshold.
func dynamicsOutputDB(_ inDB: Double, _ s: Source) -> Double {
    var out = inDB
    if s.gateThreshold > -80 && inDB < s.gateThreshold { out = inDB + s.gateRange }
    if s.compRatio > 1.01 && inDB > s.compThreshold { out = s.compThreshold + (inDB - s.compThreshold) / s.compRatio }
    return out + s.compMakeup
}

struct MiniDynamicsDisplay: View {
    @ObservedObject var source: Source
    var body: some View {
        GeometryReader { g in
            let active = source.fxEnabled && (source.compRatio > 1.01 || source.gateThreshold > -80 || source.compMakeup > 0.01)
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: g.size.width / 2, y: 0)); p.addLine(to: CGPoint(x: g.size.width / 2, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: g.size.height / 2)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height / 2))
                }.stroke(MX.boxLine, lineWidth: 1)
                if active {
                    if source.compRatio > 1.01 {
                        let tx = CGFloat((source.compThreshold + 60) / 60) * g.size.width
                        Path { p in p.move(to: CGPoint(x: tx, y: 0)); p.addLine(to: CGPoint(x: tx, y: g.size.height)) }
                            .stroke(Color(rgb: 0x3D5BD8), lineWidth: 1)
                    }
                    Path { p in
                        for i in 0...40 {
                            let inDB = -60 + Double(i) * 1.5
                            let o = min(0, max(-60, dynamicsOutputDB(inDB, source)))
                            let pt = CGPoint(x: CGFloat(i) / 40 * g.size.width, y: g.size.height - CGFloat((o + 60) / 60) * g.size.height)
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(MX.dyn, lineWidth: 1.5)
                }
            }
        }
    }
}

// MARK: - Console

struct MixerConsole: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        let channels = engine.sources.filter { !$0.isPlaceholder }
        GeometryReader { geo in
            let h = max(geo.size.height, MX.minHeight)
            ScrollView(.vertical, showsIndicators: geo.size.height < MX.minHeight) {
                HStack(alignment: .top, spacing: 0) {
                    MixerLabelColumn(height: h)
                    if channels.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "slider.vertical.3").font(.system(size: 28)).foregroundColor(MX.dim)
                            Text("Add inputs to see their channels here.").font(.system(size: 12)).foregroundColor(MX.label)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(channels, id: \.id) { s in MixerChannelStrip(source: s, height: h) }
                            }
                            .padding(.horizontal, 6)
                        }
                    }
                    Rectangle().fill(Color.black.opacity(0.6)).frame(width: 2)
                    MixerMasterStrip(height: h).padding(.horizontal, 8)
                }
                .frame(height: h)
                .padding(.vertical, 6)
            }
        }
        .background(MX.bg)
    }
}

struct MixerLabelColumn: View {
    let height: CGFloat
    var body: some View {
        let dbH = height - MX.fixed
        VStack(alignment: .trailing, spacing: MX.gap) {
            Color.clear.frame(height: MX.header)
            label("Input", MX.input)
            label("Equalizer", MX.eq)
            label("Dynamics", MX.dynamics)
            label("dB", 28).frame(height: dbH, alignment: .top)
            label("Pan", MX.pan)
            Color.clear.frame(height: MX.mode)
            Color.clear.frame(height: MX.solo)
        }
        .frame(width: 72)
    }
    private func label(_ t: String, _ h: CGFloat) -> some View {
        Text(t).font(.system(size: 12)).foregroundColor(MX.label).frame(height: h, alignment: .center).padding(.trailing, 8)
    }
}

private struct ConsoleBox<Content: View>: View {
    var height: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(MX.box))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MX.boxLine, lineWidth: 1))
    }
}

struct MixerChannelStrip: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var source: Source
    let height: CGFloat
    @State private var showFX = false
    @State private var fxTab = 0

    private var live: Bool { engine.isChannelLive(source) }
    private var waitingAFV: Bool { source.audioFollowsVideo && source.sendToMain && !source.muted && !engine.isOnAir(source.id) }
    private var onActive: Bool { source.sendToMain && !source.muted && !source.audioFollowsVideo }
    private var afvActive: Bool { source.sendToMain && !source.muted && source.audioFollowsVideo }

    private var faderDB: Binding<Double> {
        Binding(get: { AudioMath.gainToDB(source.gain) }, set: { source.gain = AudioMath.dbToGain($0) })
    }

    var body: some View {
        let dbH = height - MX.fixed
        VStack(spacing: MX.gap) {
            // name + tally
            VStack(spacing: 6) {
                Text(source.name).font(.system(size: 13, weight: .medium)).foregroundColor(MX.text).lineLimit(1)
                Capsule().fill(live ? MX.red : (waitingAFV ? MX.olive : MX.tallyOff))
                    .frame(width: 58, height: 7)
                    .shadow(color: live ? MX.red.opacity(0.6) : .clear, radius: 3)
            }
            .frame(height: MX.header)
            .help(live ? "Live in the mix" : (waitingAFV ? "Audio follows video — waiting for Program" : "Not in the mix"))

            ConsoleBox(height: MX.input) {
                VStack(spacing: 6) {
                    RotaryKnob(value: $source.trimDB, range: -60...6, defaultValue: 0, arcColor: MX.green,
                               size: 46, minLabel: "-∞", maxLabel: "+6")
                    ConsoleValueField(value: $source.trimDB, range: -60...6, display: { AudioMath.dbText($0) })
                }
            }
            .help("Input trim")

            ConsoleBox(height: MX.eq) {
                MiniEQDisplay(source: source).padding(.horizontal, 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { fxTab = 0; showFX = true }
            .help("Equalizer — click to edit")

            ConsoleBox(height: MX.dynamics) {
                MiniDynamicsDisplay(source: source).padding(4)
            }
            .contentShape(Rectangle())
            .onTapGesture { fxTab = 1; showFX = true }
            .help("Dynamics — click to edit")
            .popover(isPresented: $showFX, arrowEdge: .trailing) { AudioEffects(source: source, initialTab: fxTab) }

            ConsoleBox(height: dbH) {
                VStack(spacing: 6) {
                    ChannelPeakLabel(id: source.id, active: true)
                        .padding(.top, 6)
                    HStack(spacing: 3) {
                        ConsoleFader(db: faderDB)
                            .frame(width: 36)
                        FaderScale().frame(width: 20)
                        VStack(spacing: 2) {
                            ChannelStereoMeter(id: source.id, active: true)
                            HStack(spacing: 5) {
                                Text("L").font(.system(size: 7)).foregroundColor(MX.label)
                                Text("R").font(.system(size: 7)).foregroundColor(MX.label)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: .infinity)
                    ConsoleValueField(value: faderDB, range: -60...10, display: { AudioMath.dbText($0) })
                        .padding(.bottom, 6)
                }
            }

            ConsoleBox(height: MX.pan) {
                VStack(spacing: 5) {
                    RotaryKnob(value: $source.pan, range: -100...100, defaultValue: 0, arcColor: MX.orange, bipolar: true,
                               size: 42, minLabel: "L", maxLabel: "R")
                    ConsoleValueField(value: $source.pan, range: -100...100, display: { String(format: "%+.2f", $0).replacingOccurrences(of: "+0.00", with: "0.00") })
                }
            }
            .help("Pan (-100 left … +100 right). Stored now; audible once the mix is stereo.")

            HStack(spacing: 0) {
                modeButton("AFV", active: afvActive) {
                    if afvActive { source.audioFollowsVideo = false; source.sendToMain = false }
                    else { source.audioFollowsVideo = true; source.sendToMain = true; source.muted = false }
                }
                .help("Audio follows video: only in the mix while this input is on Program")
                Rectangle().fill(Color.black).frame(width: 1)
                modeButton("ON", active: onActive) {
                    if onActive { source.sendToMain = false }
                    else { source.sendToMain = true; source.muted = false; source.audioFollowsVideo = false }
                }
                .help("Always in the mix")
            }
            .frame(height: MX.mode)
            .background(Capsule().fill(MX.field))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.black, lineWidth: 1))

            Button { source.solo.toggle() } label: {
                Image(systemName: "headphones")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(source.solo ? .white : MX.dim)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(source.solo ? MX.orange : MX.field))
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .frame(height: MX.solo)
            .help("Solo (headphones)")
        }
        .frame(width: MX.stripWidth)
    }

    private func modeButton(_ t: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 11, weight: .semibold))
                .foregroundColor(active ? MX.orange : MX.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MixerMasterStrip: View {
    @EnvironmentObject var engine: Engine
    let height: CGFloat
    @State private var showFX = false
    @State private var fxTab = 0

    private var faderDB: Binding<Double> {
        Binding(get: { AudioMath.gainToDB(engine.masterBus.gain) }, set: { engine.masterBus.gain = AudioMath.dbToGain($0) })
    }

    var body: some View {
        let dbH = height - MX.fixed
        VStack(spacing: MX.gap) {
            VStack(spacing: 6) {
                Text("Master").font(.system(size: 13, weight: .medium)).foregroundColor(MX.text)
                Capsule().fill(engine.isRecording || engine.isStreaming ? MX.red : MX.tallyOff).frame(width: 58, height: 7)
            }
            .frame(height: MX.header)

            ConsoleBox(height: MX.input) {
                HStack(spacing: 4) {
                    VStack(spacing: 2) {
                        Text("MONITOR").font(.system(size: 8, weight: .bold)).foregroundColor(MX.label)
                        RotaryKnob(value: $engine.monitorLevelDB, range: -60...6, defaultValue: 0, arcColor: MX.cyan, size: 38)
                        Text(AudioMath.dbText(engine.monitorLevelDB, decimals: 1)).font(.system(size: 9, weight: .semibold)).foregroundColor(MX.text)
                    }
                    VStack(spacing: 3) {
                        Image(systemName: "mic").font(.system(size: 10)).foregroundColor(MX.label)
                        Toggle("", isOn: $engine.hearLiveInputs).toggleStyle(.switch).tint(MX.orange).labelsHidden().controlSize(.mini)
                        Text("hear mics").font(.system(size: 7)).foregroundColor(MX.dim)
                    }
                }
            }
            .help("Monitor = what the Mac's speakers/headphones play. Microphones stay out of the speakers unless 'hear mics' is on (prevents feedback); they are always in the recording and stream.")

            MasterEQBox(fxTab: $fxTab, showFX: $showFX)
            MasterDynamicsBox(fxTab: $fxTab, showFX: $showFX)
                .popover(isPresented: $showFX, arrowEdge: .leading) { AudioEffects(source: engine.masterBus, initialTab: fxTab) }

            ConsoleBox(height: dbH) {
                VStack(spacing: 6) {
                    ChannelPeakLabel(id: nil, active: true).padding(.top, 6)
                    HStack(spacing: 3) {
                        ConsoleFader(db: faderDB).frame(width: 36)
                        FaderScale().frame(width: 20)
                        VStack(spacing: 2) {
                            MasterStereoMeter()
                            HStack(spacing: 6) {
                                Text("L").font(.system(size: 7)).foregroundColor(MX.label)
                                Text("R").font(.system(size: 7)).foregroundColor(MX.label)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: .infinity)
                    ConsoleValueField(value: faderDB, range: -60...10, display: { AudioMath.dbText($0) })
                        .padding(.bottom, 6)
                }
            }

            VStack(spacing: 6) {
                Button { engine.masterBus.muted.toggle() } label: {
                    Text(engine.masterBus.muted ? "MUTED" : "MUTE").font(.system(size: 11, weight: .semibold))
                        .foregroundColor(engine.masterBus.muted ? .white : MX.label)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(Capsule().fill(engine.masterBus.muted ? MX.red : MX.field))
                        .overlay(Capsule().strokeBorder(Color.black, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { engine.sources.forEach { $0.solo = false } } label: {
                    Text("CLEAR SOLO").font(.system(size: 10, weight: .semibold)).foregroundColor(MX.label)
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .background(Capsule().fill(MX.field))
                        .overlay(Capsule().strokeBorder(Color.black, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .frame(height: MX.pan)

            Color.clear.frame(height: MX.mode)
            Color.clear.frame(height: MX.solo)
        }
        .frame(width: MX.stripWidth)
    }
}

private struct MasterEQBox: View {
    @EnvironmentObject var engine: Engine
    @Binding var fxTab: Int
    @Binding var showFX: Bool
    var body: some View {
        ConsoleBox(height: MX.eq) { MiniEQDisplay(source: engine.masterBus).padding(.horizontal, 4) }
            .contentShape(Rectangle())
            .onTapGesture { fxTab = 0; showFX = true }
    }
}

private struct MasterDynamicsBox: View {
    @EnvironmentObject var engine: Engine
    @Binding var fxTab: Int
    @Binding var showFX: Bool
    var body: some View {
        ConsoleBox(height: MX.dynamics) { MiniDynamicsDisplay(source: engine.masterBus).padding(4) }
            .contentShape(Rectangle())
            .onTapGesture { fxTab = 1; showFX = true }
    }
}

// MARK: - Effects window (console style)

struct AudioEffects: View {
    @ObservedObject var source: Source
    var initialTab = 0
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(source.name).font(.system(size: 15, weight: .semibold)).foregroundColor(MX.text).lineLimit(1)
                HStack(spacing: 0) {
                    tabButton("Equalizer", 0)
                    tabButton("Dynamics", 1)
                }
                .background(Capsule().fill(MX.field)).clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.black, lineWidth: 1))
                Spacer()
                Menu("Preset") { ForEach(FXPreset.all) { p in Button(p.name) { source.applyFXPreset(p); source.fxEnabled = true } } }
                    .menuStyle(.borderlessButton).fixedSize()
                Text("EFFECTS").font(.system(size: 10, weight: .bold)).foregroundColor(MX.label)
                Toggle("", isOn: $source.fxEnabled).toggleStyle(.switch).tint(MX.orange).labelsHidden()
            }
            .padding(.horizontal, 14).frame(height: 48)
            .background(Color(rgb: 0x1A1A1A))

            if tab == 0 { equalizer } else { dynamics }

            Text("Effects change what you hear, record and stream. Double-click a knob to reset it.")
                .font(.system(size: 10)).foregroundColor(MX.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 860, height: 520)
        .background(MX.bg)
        .preferredColorScheme(.dark)
        .onAppear { tab = initialTab }
    }

    private func tabButton(_ t: String, _ i: Int) -> some View {
        Button { tab = i } label: {
            Text(t).font(.system(size: 11, weight: .semibold))
                .foregroundColor(tab == i ? MX.orange : MX.label)
                .padding(.horizontal, 14).frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: equalizer

    private var equalizer: some View {
        VStack(spacing: 10) {
            ConsoleEQGraph(source: source)
                .frame(height: 200)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(rgb: 0x141414)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MX.boxLine, lineWidth: 1))
            HStack(alignment: .top, spacing: 8) {
                band("Low Cut") {
                    knob("Freq", $source.eqHPF, 0...400, 0, MX.cyan, fmt: { $0 < 20 ? "Off" : String(format: "%.0f Hz", $0) })
                }
                band("Low Shelf") {
                    knob("Gain", $source.eqLowGain, -18...18, 0, MX.cyan, bipolar: true, fmt: { String(format: "%+.1f dB", $0) })
                }
                band("Band 1") {
                    knob("Freq", $source.eqP1Freq, 40...1200, 300, MX.cyan, fmt: { String(format: "%.0f Hz", $0) })
                    knob("Gain", $source.eqP1Gain, -18...18, 0, MX.cyan, bipolar: true, fmt: { String(format: "%+.1f dB", $0) })
                    knob("Q", $source.eqP1Q, 0.3...10, 1, MX.cyan, fmt: { String(format: "%.2f", $0) })
                }
                band("Band 2") {
                    knob("Freq", $source.eqP2Freq, 500...12000, 3000, MX.cyan, fmt: { $0 >= 1000 ? String(format: "%.1f kHz", $0 / 1000) : String(format: "%.0f Hz", $0) })
                    knob("Gain", $source.eqP2Gain, -18...18, 0, MX.cyan, bipolar: true, fmt: { String(format: "%+.1f dB", $0) })
                    knob("Q", $source.eqP2Q, 0.3...10, 1, MX.cyan, fmt: { String(format: "%.2f", $0) })
                }
                band("High Shelf") {
                    knob("Gain", $source.eqHighGain, -18...18, 0, MX.cyan, bipolar: true, fmt: { String(format: "%+.1f dB", $0) })
                }
                band("High Cut") {
                    knob("Freq", $source.eqLPF, 0...20000, 0, MX.cyan, fmt: { $0 < 1000 || $0 >= 19999 ? "Off" : String(format: "%.1f kHz", $0 / 1000) })
                }
            }
        }
        .padding(14)
    }

    // MARK: dynamics

    private var dynamics: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 10) {
                Text("NOISE GATE").font(.system(size: 11, weight: .bold)).foregroundColor(MX.label).frame(maxWidth: .infinity, alignment: .leading)
                ConsoleDynamicsGraph(source: source, gateOnly: true)
                    .frame(height: 170)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(rgb: 0x141414)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MX.boxLine, lineWidth: 1))
                HStack(spacing: 4) {
                    knob("Threshold", $source.gateThreshold, -80...0, -60, MX.dyn, fmt: { $0 <= -80 ? "Off" : String(format: "%.0f dB", $0) })
                    knob("Range", $source.gateRange, -80...0, -60, MX.dyn, fmt: { String(format: "%.0f dB", $0) })
                    knob("Attack", $source.gateAttack, 0...50, 1, MX.dyn, fmt: { String(format: "%.1f ms", $0) })
                    knob("Hold", $source.gateHold, 0...500, 100, MX.dyn, fmt: { String(format: "%.0f ms", $0) })
                    knob("Release", $source.gateRelease, 5...1000, 200, MX.dyn, fmt: { String(format: "%.0f ms", $0) })
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(MX.box))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MX.boxLine, lineWidth: 1))

            VStack(spacing: 10) {
                Text("COMPRESSOR / LIMITER").font(.system(size: 11, weight: .bold)).foregroundColor(MX.label).frame(maxWidth: .infinity, alignment: .leading)
                ConsoleDynamicsGraph(source: source, gateOnly: false)
                    .frame(height: 170)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(rgb: 0x141414)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MX.boxLine, lineWidth: 1))
                HStack(spacing: 4) {
                    knob("Threshold", $source.compThreshold, -40...0, -18, MX.dyn, fmt: { String(format: "%.0f dB", $0) })
                    knob("Ratio", $source.compRatio, 1...20, 2, MX.dyn, fmt: { String(format: "%.1f:1", $0) })
                    knob("Attack", $source.compAttack, 0...100, 10, MX.dyn, fmt: { String(format: "%.0f ms", $0) })
                    knob("Release", $source.compRelease, 10...500, 120, MX.dyn, fmt: { String(format: "%.0f ms", $0) })
                    knob("Makeup", $source.compMakeup, 0...18, 0, MX.dyn, fmt: { String(format: "%+.1f dB", $0) })
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(MX.box))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MX.boxLine, lineWidth: 1))
        }
        .padding(14)
    }

    private func band<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundColor(MX.label)
            HStack(spacing: 2) { content() }
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(MX.box))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MX.boxLine, lineWidth: 1))
    }

    private func knob(_ label: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ def: Double, _ color: Color,
                      bipolar: Bool = false, fmt: @escaping (Double) -> String) -> some View {
        VStack(spacing: 4) {
            RotaryKnob(value: v, range: r, defaultValue: def, arcColor: color, bipolar: bipolar, size: 40)
            ConsoleValueField(value: v, range: r, display: fmt, width: 62)
            Text(label).font(.system(size: 9)).foregroundColor(MX.label)
        }
        .frame(width: 66)
    }
}

/// Full-size EQ response with frequency grid.
struct ConsoleEQGraph: View {
    @ObservedObject var source: Source
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let xFor: (Double) -> CGFloat = { f in CGFloat(log10(f / 20) / 3) * w }
            ZStack(alignment: .topLeading) {
                Path { p in
                    for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
                        let x = xFor(f); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    }
                    for d in [-12.0, 0, 12] {
                        let y = h / 2 - CGFloat(d / 24) * (h / 2 - 8); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                    }
                }
                .stroke(MX.boxLine, lineWidth: 1)
                ForEach([100.0, 1000, 10000], id: \.self) { f in
                    Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))").font(.system(size: 9)).foregroundColor(MX.dim)
                        .position(x: xFor(f) + 10, y: h - 8)
                }
                Path { p in
                    let steps = 160
                    for i in 0...steps {
                        let f = 20 * pow(1000, Double(i) / Double(steps))
                        let db = max(-24, min(24, eqTotalDB(f, source)))
                        let pt = CGPoint(x: CGFloat(i) / CGFloat(steps) * w, y: h / 2 - CGFloat(db / 24) * (h / 2 - 8))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(source.fxEnabled ? MX.cyan : MX.cyan.opacity(0.4), lineWidth: 2)
            }
        }
    }
}

/// Transfer curve (input dB → output dB) for the gate or the compressor.
struct ConsoleDynamicsGraph: View {
    @ObservedObject var source: Source
    let gateOnly: Bool
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                Path { p in
                    for i in 1..<6 {
                        let x = CGFloat(i) / 6 * w, y = CGFloat(i) / 6 * h
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                    }
                }
                .stroke(MX.boxLine, lineWidth: 1)
                let threshold = gateOnly ? source.gateThreshold : source.compThreshold
                let tx = CGFloat((max(-60, threshold) + 60) / 60) * w
                Path { p in p.move(to: CGPoint(x: tx, y: 0)); p.addLine(to: CGPoint(x: tx, y: h)) }
                    .stroke(Color(rgb: 0x3D5BD8), lineWidth: 1)
                Path { p in
                    for i in 0...120 {
                        let inDB = -60 + Double(i) * 0.5
                        var o = inDB
                        if gateOnly {
                            if source.gateThreshold > -80 && inDB < source.gateThreshold { o = inDB + source.gateRange }
                        } else {
                            if source.compRatio > 1.01 && inDB > source.compThreshold { o = source.compThreshold + (inDB - source.compThreshold) / source.compRatio }
                            o += source.compMakeup
                        }
                        o = min(0, max(-60, o))
                        let pt = CGPoint(x: CGFloat(i) / 120 * w, y: h - CGFloat((o + 60) / 60) * h)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(source.fxEnabled ? MX.dyn : MX.dyn.opacity(0.4), lineWidth: 2)
            }
        }
    }
}


// MARK: - Compact console (Input tab)

struct EffectKnob: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var color: Color = MX.cyan
    var bipolar = false
    let format: (Double) -> String
    var body: some View {
        VStack(spacing: 3) {
            RotaryKnob(value: $value, range: range, defaultValue: defaultValue, arcColor: color, bipolar: bipolar, size: 36)
            ConsoleValueField(value: $value, range: range, display: format, width: 60)
            Text(label).font(.system(size: 9)).foregroundColor(MX.label).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

enum FXFormat {
    static let hz: (Double) -> String = { $0 >= 1000 ? String(format: "%.1fk", $0 / 1000) : String(format: "%.0f Hz", $0) }
    static let lowCut: (Double) -> String = { $0 < 20 ? "Off" : String(format: "%.0f Hz", $0) }
    static let highCut: (Double) -> String = { $0 < 1000 || $0 >= 19999 ? "Off" : String(format: "%.1fk", $0 / 1000) }
    static let db: (Double) -> String = { String(format: "%+.1f dB", $0) }
    static let dbPlain: (Double) -> String = { String(format: "%.0f dB", $0) }
    static let gate: (Double) -> String = { $0 <= -80 ? "Off" : String(format: "%.0f dB", $0) }
    static let q: (Double) -> String = { String(format: "%.2f", $0) }
    static let ms: (Double) -> String = { String(format: "%.0f ms", $0) }
    static let ratio: (Double) -> String = { String(format: "%.1f:1", $0) }
}

private struct ConsolePanel<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 11).fill(MX.bg))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
    }
}

struct CompactChannelConsole: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var source: Source
    @Binding var audioDevices: [AudioDeviceInfo]

    private var faderDB: Binding<Double> {
        Binding(get: { AudioMath.gainToDB(source.gain) }, set: { source.gain = AudioMath.dbToGain($0) })
    }
    private var live: Bool { engine.isChannelLive(source) }
    private var onActive: Bool { source.sendToMain && !source.muted && !source.audioFollowsVideo }
    private var afvActive: Bool { source.sendToMain && !source.muted && source.audioFollowsVideo }

    var body: some View {
        ConsolePanel {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 15)).foregroundColor(MX.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Audio").font(.system(size: 13, weight: .semibold)).foregroundColor(MX.text)
                    Text(live ? "Live in the mix" : "Not in the mix").font(.system(size: 9)).foregroundColor(live ? MX.red : MX.dim)
                }
                Capsule().fill(live ? MX.red : MX.tallyOff).frame(width: 36, height: 6)
                Spacer()
                Button {
                    source.gain = 1; source.trimDB = 0; source.pan = 0; source.muted = false; source.sendToMain = true
                    source.audioFollowsVideo = false; source.solo = false
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold)).foregroundColor(MX.label)
                        .frame(width: 24, height: 24).background(Circle().fill(MX.field))
                }
                .buttonStyle(.plain).help("Reset audio")
            }

            HStack(spacing: 6) {
                Image(systemName: "headphones").font(.system(size: 12)).foregroundColor(MX.label)
                Picker("", selection: Binding(get: { source.audioDeviceID ?? "" }, set: { source.audioDeviceID = $0.isEmpty ? nil : $0 })) {
                    Text(source is FileSource || source is AudioFileSource ? "File audio only" : "No microphone").tag("")
                    ForEach(audioDevices) { d in Text(d.name).tag(d.id) }
                }
                .labelsHidden()
                Button { audioDevices = AudioCapture.availableDevices() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).foregroundColor(MX.text)
                        .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 6).fill(MX.field))
                }
                .buttonStyle(.plain).help("Refresh audio devices")
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 6) {
                    ChannelPeakLabel(id: source.id, active: true)
                    HStack(spacing: 3) {
                        ConsoleFader(db: faderDB).frame(width: 36)
                        FaderScale().frame(width: 20)
                        VStack(spacing: 2) {
                            ChannelStereoMeter(id: source.id, active: true)
                            HStack(spacing: 5) {
                                Text("L").font(.system(size: 7)).foregroundColor(MX.label)
                                Text("R").font(.system(size: 7)).foregroundColor(MX.label)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .frame(height: 200)
                    ConsoleValueField(value: faderDB, range: -60...10, display: { AudioMath.dbText($0) })
                }
                .padding(8)
                .frame(width: 118)
                .background(RoundedRectangle(cornerRadius: 6).fill(MX.box))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MX.boxLine, lineWidth: 1))

                VStack(spacing: 8) {
                    VStack(spacing: 4) {
                        Text("INPUT").font(.system(size: 9, weight: .bold)).foregroundColor(MX.label)
                        RotaryKnob(value: $source.trimDB, range: -60...6, defaultValue: 0, arcColor: MX.green, size: 44, minLabel: "-∞", maxLabel: "+6")
                        ConsoleValueField(value: $source.trimDB, range: -60...6, display: { AudioMath.dbText($0) }, width: 72)
                    }
                    .padding(8).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(MX.box))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MX.boxLine, lineWidth: 1))

                    VStack(spacing: 4) {
                        Text("PAN").font(.system(size: 9, weight: .bold)).foregroundColor(MX.label)
                        RotaryKnob(value: $source.pan, range: -100...100, defaultValue: 0, arcColor: MX.orange, bipolar: true, size: 40, minLabel: "L", maxLabel: "R")
                        ConsoleValueField(value: $source.pan, range: -100...100, display: { String(format: "%+.0f", $0).replacingOccurrences(of: "+0", with: "0") }, width: 72)
                    }
                    .padding(8).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(MX.box))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MX.boxLine, lineWidth: 1))
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    pill("AFV", active: afvActive) {
                        if afvActive { source.audioFollowsVideo = false; source.sendToMain = false }
                        else { source.audioFollowsVideo = true; source.sendToMain = true; source.muted = false }
                    }
                    Rectangle().fill(Color.black).frame(width: 1)
                    pill("ON", active: onActive) {
                        if onActive { source.sendToMain = false }
                        else { source.sendToMain = true; source.muted = false; source.audioFollowsVideo = false }
                    }
                }
                .frame(height: 30)
                .background(Capsule().fill(MX.field)).clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.black, lineWidth: 1))

                Button { source.muted.toggle() } label: {
                    Text(source.muted ? "MUTED" : "MUTE").font(.system(size: 11, weight: .semibold))
                        .foregroundColor(source.muted ? .white : MX.label)
                        .frame(width: 70, height: 30)
                        .background(Capsule().fill(source.muted ? MX.red : MX.field))
                        .overlay(Capsule().strokeBorder(Color.black, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button { source.solo.toggle() } label: {
                    Image(systemName: "headphones").font(.system(size: 14))
                        .foregroundColor(source.solo ? .white : MX.dim)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(source.solo ? MX.orange : MX.field))
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
                }
                .buttonStyle(.plain).help("Solo to the Mac's speakers/headphones")
            }
        }
    }

    private func pill(_ t: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 11, weight: .semibold)).foregroundColor(active ? MX.orange : MX.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CompactEffectsConsole: View {
    @ObservedObject var source: Source
    @State private var expanded = false
    @State private var tab = 0

    var body: some View {
        ConsolePanel {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 14)).foregroundColor(MX.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Audio Effects").font(.system(size: 13, weight: .semibold)).foregroundColor(MX.text)
                    Text("EQ · Compressor · Gate").font(.system(size: 9)).foregroundColor(MX.dim)
                }
                Spacer()
                Menu("Preset") { ForEach(FXPreset.all) { p in Button(p.name) { source.applyFXPreset(p); source.fxEnabled = true } } }
                    .menuStyle(.borderlessButton).fixedSize()
                Toggle("", isOn: $source.fxEnabled).toggleStyle(.switch).tint(MX.orange).labelsHidden().controlSize(.small)
                Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold)).foregroundColor(MX.label)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                MiniEQDisplay(source: source).frame(height: 30)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(MX.box))
                    .onTapGesture { tab = 0; expanded = true }
                MiniDynamicsDisplay(source: source).frame(width: 60, height: 30)
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(MX.box))
                    .onTapGesture { tab = 1; expanded = true }
            }

            if expanded {
                HStack(spacing: 0) {
                    tabButton("Equalizer", 0)
                    tabButton("Dynamics", 1)
                }
                .background(Capsule().fill(MX.field)).clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.black, lineWidth: 1))

                if tab == 0 {
                    ConsoleEQGraph(source: source).frame(height: 110)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(rgb: 0x141414)))
                    knobGrid {
                        EffectKnob(label: "Low cut", value: $source.eqHPF, range: 0...400, defaultValue: 0, format: FXFormat.lowCut)
                        EffectKnob(label: "Low shelf", value: $source.eqLowGain, range: -18...18, defaultValue: 0, bipolar: true, format: FXFormat.db)
                        EffectKnob(label: "High shelf", value: $source.eqHighGain, range: -18...18, defaultValue: 0, bipolar: true, format: FXFormat.db)
                        EffectKnob(label: "Band 1 freq", value: $source.eqP1Freq, range: 40...1200, defaultValue: 300, format: FXFormat.hz)
                        EffectKnob(label: "Band 1 gain", value: $source.eqP1Gain, range: -18...18, defaultValue: 0, bipolar: true, format: FXFormat.db)
                        EffectKnob(label: "Band 1 Q", value: $source.eqP1Q, range: 0.3...10, defaultValue: 1, format: FXFormat.q)
                        EffectKnob(label: "Band 2 freq", value: $source.eqP2Freq, range: 500...12000, defaultValue: 3000, format: FXFormat.hz)
                        EffectKnob(label: "Band 2 gain", value: $source.eqP2Gain, range: -18...18, defaultValue: 0, bipolar: true, format: FXFormat.db)
                        EffectKnob(label: "Band 2 Q", value: $source.eqP2Q, range: 0.3...10, defaultValue: 1, format: FXFormat.q)
                        EffectKnob(label: "High cut", value: $source.eqLPF, range: 0...20000, defaultValue: 0, format: FXFormat.highCut)
                    }
                } else {
                    Text("NOISE GATE").font(.system(size: 9, weight: .bold)).foregroundColor(MX.label)
                    ConsoleDynamicsGraph(source: source, gateOnly: true).frame(height: 80)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(rgb: 0x141414)))
                    knobGrid {
                        EffectKnob(label: "Threshold", value: $source.gateThreshold, range: -80...0, defaultValue: -60, color: MX.dyn, format: FXFormat.gate)
                        EffectKnob(label: "Range", value: $source.gateRange, range: -80...0, defaultValue: -60, color: MX.dyn, format: FXFormat.dbPlain)
                        EffectKnob(label: "Attack", value: $source.gateAttack, range: 0...50, defaultValue: 1, color: MX.dyn, format: FXFormat.ms)
                        EffectKnob(label: "Hold", value: $source.gateHold, range: 0...500, defaultValue: 100, color: MX.dyn, format: FXFormat.ms)
                        EffectKnob(label: "Release", value: $source.gateRelease, range: 5...1000, defaultValue: 200, color: MX.dyn, format: FXFormat.ms)
                    }
                    Text("COMPRESSOR / LIMITER").font(.system(size: 9, weight: .bold)).foregroundColor(MX.label)
                    ConsoleDynamicsGraph(source: source, gateOnly: false).frame(height: 80)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(rgb: 0x141414)))
                    knobGrid {
                        EffectKnob(label: "Threshold", value: $source.compThreshold, range: -40...0, defaultValue: -18, color: MX.dyn, format: FXFormat.dbPlain)
                        EffectKnob(label: "Ratio", value: $source.compRatio, range: 1...20, defaultValue: 2, color: MX.dyn, format: FXFormat.ratio)
                        EffectKnob(label: "Attack", value: $source.compAttack, range: 0...100, defaultValue: 10, color: MX.dyn, format: FXFormat.ms)
                        EffectKnob(label: "Release", value: $source.compRelease, range: 10...500, defaultValue: 120, color: MX.dyn, format: FXFormat.ms)
                        EffectKnob(label: "Makeup", value: $source.compMakeup, range: 0...18, defaultValue: 0, color: MX.dyn, format: FXFormat.db)
                    }
                }
            }
        }
    }

    private func tabButton(_ t: String, _ i: Int) -> some View {
        Button { tab = i } label: {
            Text(t).font(.system(size: 11, weight: .semibold)).foregroundColor(tab == i ? MX.orange : MX.label)
                .frame(maxWidth: .infinity).frame(height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func knobGrid<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 10) {
            content()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(MX.box))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MX.boxLine, lineWidth: 1))
    }
}
