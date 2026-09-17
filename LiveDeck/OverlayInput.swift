import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PresentationKit

// MARK: - Overlay as a standalone input (with a background, or transparent for keying)

enum OverlayInputBackground: String, Codable, CaseIterable, Identifiable {
    case transparent = "Transparent"
    case color = "Colour"
    case image = "Image"
    var id: String { rawValue }
}

/// Settings saved with presets (in the preset input's `location`).
struct OverlayInputSpec: Codable {
    var layerName: String
    var background: OverlayInputBackground = .transparent
    var rgba: [Double] = [0, 0, 0, 1]
    var imagePath: String?
    var followOnAir = false
}

final class OverlaySource: Source {
    /// The engine whose overlays these inputs show (set when LiveDeck starts).
    static weak var engine: Engine?

    @Published var layerID: UUID?
    @Published var layerName: String
    @Published var background: OverlayInputBackground = .transparent
    @Published var backgroundColor: NSColor = .black
    @Published var imagePath: String? { didSet { loadImage() } }
    /// Off: always shows the overlay. On: appears/disappears with the overlay's own on-air switch.
    @Published var followOnAir = false
    private var image: CGImage?

    init(layer: Layer, background: OverlayInputBackground = .transparent) {
        layerID = layer.id
        layerName = layer.name
        self.background = background
        super.init(name: layer.name, kindLabel: "OVERLAY")
    }

    init(spec: OverlayInputSpec, name: String) {
        layerName = spec.layerName
        background = spec.background
        backgroundColor = NSColor(srgbRed: CGFloat(spec.rgba[safe: 0] ?? 0), green: CGFloat(spec.rgba[safe: 1] ?? 0),
                                  blue: CGFloat(spec.rgba[safe: 2] ?? 0), alpha: CGFloat(spec.rgba[safe: 3] ?? 1))
        imagePath = spec.imagePath
        followOnAir = spec.followOnAir
        super.init(name: name, kindLabel: "OVERLAY")
        loadImage()
    }

    var spec: OverlayInputSpec {
        let c = backgroundColor.usingColorSpace(.sRGB) ?? .black
        return OverlayInputSpec(layerName: resolvedLayer?.name ?? layerName, background: background,
                                rgba: [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent)],
                                imagePath: imagePath, followOnAir: followOnAir)
    }

    private func loadImage() {
        guard let p = imagePath, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { image = nil; return }
        image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    var resolvedLayer: Layer? {
        guard let e = OverlaySource.engine else { return nil }
        if let id = layerID, let l = e.layers.first(where: { $0.id == id }) { return l }
        if let l = e.layers.first(where: { $0.name == layerName }) { layerID = l.id; return l }
        return nil
    }

    override func currentImage() -> CGImage? { nil }

    override func draw(in ctx: CGContext, rect: CGRect) {
        switch background {
        case .transparent: break
        case .color:
            ctx.setFillColor(backgroundColor.cgColor); ctx.fill(rect)
        case .image:
            if let img = image {
                let iw = CGFloat(img.width), ih = CGFloat(img.height)
                let s = max(rect.width / iw, rect.height / ih)
                ctx.saveGState(); ctx.clip(to: rect)
                ctx.draw(img, in: CGRect(x: rect.midX - iw * s / 2, y: rect.midY - ih * s / 2, width: iw * s, height: ih * s))
                ctx.restoreGState()
            } else {
                ctx.setFillColor(NSColor.black.cgColor); ctx.fill(rect)
            }
        }
        guard let layer = resolvedLayer, let e = OverlaySource.engine else { return }
        let cw = max(1, e.width), ch = max(1, e.height)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / CGFloat(cw), y: rect.height / CGFloat(ch))
        LayerRenderer.renderComposited(layer, in: ctx, width: cw, height: ch, time: CACurrentMediaTime(),
                                       visibility: followOnAir ? layer.liveT : 1,
                                       sourceImage: { id in e.sources.first(where: { $0.id == id })?.currentImage() })
        ctx.restoreGState()
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Input panel card for an overlay input.
struct OverlayInputCard: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var source: OverlaySource

    var body: some View {
        CPCard(title: "Overlay input", subtitle: source.resolvedLayer.map { "Shows “\($0.name)”" } ?? "Overlay not found", icon: "square.stack.3d.up") {
            CPRow(label: "Overlay") {
                Picker("", selection: Binding(get: { source.layerID }, set: { id in
                    source.layerID = id
                    if let l = engine.layers.first(where: { $0.id == id }) { source.layerName = l.name }
                })) {
                    ForEach(engine.layers) { l in Text(l.name).tag(Optional(l.id)) }
                }
                .cpPickerChrome().frame(maxWidth: 180)
            }
            SectionLabel("Background")
            DSSegmented(selection: $source.background, options: OverlayInputBackground.allCases.map { ($0, $0.rawValue) })
                .padding(.vertical, 4)
            switch source.background {
            case .transparent:
                CPNote("Transparent: use K·P / K·L to key this input over Program or Preview, or send it to a display or NDI with the overlay on black.")
            case .color:
                CPColorRow(label: "Colour", color: Binding(get: { Color(nsColor: source.backgroundColor) },
                                                           set: { source.backgroundColor = NSColor($0) }))
            case .image:
                CPRow(label: "Image") {
                    HStack(spacing: 6) {
                        Text(source.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None").font(CPFont.caption).foregroundColor(CP.text2).lineLimit(1)
                        CPButton(title: "Choose…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.image]
                            if panel.runModal() == .OK, let u = panel.url { FileAccess.remember(u); source.imagePath = u.path }
                        }
                    }
                }
            }
            SectionLabel("Visibility")
            CPToggleRow(label: "Follow the overlay's on-air switch", isOn: $source.followOnAir)
            CPNote(source.followOnAir ? "The overlay appears in this input only while it is on air (with its animation)."
                                      : "The overlay is always shown in this input, even when it is not on air over Program.")
            HStack {
                Spacer()
                CPButton(icon: "slider.horizontal.3", title: "Edit overlay") {
                    if let l = source.resolvedLayer { engine.selectedLayerID = l.id }
                    engine.rightTab = 2
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// "Use as input" menu entries for an overlay layer.
struct OverlayAsInputMenu: View {
    @EnvironmentObject var engine: Engine
    let layer: Layer
    var body: some View {
        Menu("Use as an input") {
            Button("Transparent background (for keying)") { add(.transparent) }
            Button("Black background") { add(.color) }
            Button("Image background…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                if panel.runModal() == .OK, let url = panel.url {
                    FileAccess.remember(url)
                    let s = OverlaySource(layer: layer, background: .image)
                    s.imagePath = url.path
                    engine.placeInput(s); engine.selectedSourceID = s.id; engine.rightTab = 1
                }
            }
        }
    }
    private func add(_ bg: OverlayInputBackground) {
        let s = OverlaySource(layer: layer, background: bg)
        engine.placeInput(s)
        engine.selectedSourceID = s.id
    }
}


// MARK: - Countdown editor (content, behaviour and formatting)

struct CountdownEditor: View {
    @ObservedObject var layer: Layer

    private func bind<T>(_ kp: WritableKeyPath<CountdownStyle, T>) -> Binding<T> {
        Binding(get: { layer.cd[keyPath: kp] }, set: { layer.cd[keyPath: kp] = $0 })
    }
    private var targetDate: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: layer.cd.targetHour, minute: layer.cd.targetMinute, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            layer.cd.targetHour = c.hour ?? 10; layer.cd.targetMinute = c.minute ?? 0
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Timer")
            DSSegmented(selection: bind(\.mode), options: CountdownMode.allCases.map { ($0, $0 == .toTime ? "To a time" : $0.rawValue) })
                .padding(.vertical, 4)
            switch layer.cd.mode {
            case .duration:
                ParamSlider(label: "Minutes", value: $layer.number1, range: 0.25...180, defaultValue: 5, format: "%.2f")
            case .toTime:
                CPRow(label: "Count down to") {
                    DatePicker("", selection: targetDate, displayedComponents: .hourAndMinute).labelsHidden()
                }
            case .countUp:
                CPNote("Counts up from 00:00 when you press Start — for sermon length or elapsed time.")
            }
            if layer.cd.mode != .toTime {
                HStack(spacing: 6) {
                    CPButton(icon: "play.fill", title: "Start", prominent: true) { layer.startCountdown() }
                    CPButton(icon: "pause.fill", title: "Pause") { layer.pauseCountdown() }
                    CPButton(icon: "arrow.counterclockwise", title: "Reset") { layer.resetCountdown() }
                    Spacer()
                    CPButton(title: "−1 min") { layer.nudgeCountdown(-60) }
                    CPButton(title: "+1 min") { layer.nudgeCountdown(60) }
                }
                .padding(.vertical, 6)
            }

            SectionLabel("Text")
            CPTextRow(label: "Label", text: $layer.text1, prompt: "e.g. STARTING IN")
            CPTextRow(label: "Sub-text", text: $layer.text2, prompt: "optional, e.g. Service begins at 10:00")
            CPRow(label: "Label position") {
                DSSegmented(selection: bind(\.labelPosition), options: CountdownLabelPosition.allCases.map { ($0, $0.rawValue) }).frame(width: 220)
            }
            CPToggleRow(label: "Capital letters for the label", isOn: bind(\.uppercaseLabel))
            CPToggleRow(label: "Show sub-text", isOn: bind(\.showSubtext))

            SectionLabel("Time format")
            DSSegmented(selection: bind(\.format), options: CountdownTimeFormat.allCases.map { ($0, $0.rawValue) })
                .padding(.vertical, 4)

            SectionLabel("Font")
            CPRow(label: "Typeface") {
                Picker("", selection: bind(\.font)) { ForEach(CountdownFont.allCases) { Text($0.rawValue).tag($0) } }.cpPickerChrome().frame(maxWidth: 160)
            }
            CPRow(label: "Weight") {
                Picker("", selection: bind(\.weight)) {
                    Text("Regular").tag(0); Text("Semibold").tag(1); Text("Bold").tag(2); Text("Heavy").tag(3); Text("Black").tag(4)
                }
                .cpPickerChrome().frame(maxWidth: 160)
            }
            ParamSlider(label: "Overall size", value: $layer.fontScale, range: 0.4...3, defaultValue: 1, format: "%.2f")
            ParamSlider(label: "Digits size", value: bind(\.digitsScale), range: 0.4...2.5, defaultValue: 1, format: "%.2f")
            ParamSlider(label: "Label size", value: bind(\.labelScale), range: 0.4...2.5, defaultValue: 1, format: "%.2f")
            ParamSlider(label: "Letter spacing", value: bind(\.letterSpacing), range: -2...10, defaultValue: 0, format: "%.1f")
            CPColorRow(label: "Digits colour", color: $layer.textColor, opacity: false)
            CPColorRow(label: "Label colour", color: $layer.accent, opacity: false)
            CPToggleRow(label: "Text shadow", isOn: bind(\.shadow))

            SectionLabel("Background box")
            DSSegmented(selection: bind(\.box), options: CountdownBox.allCases.map { ($0, $0.rawValue) })
                .padding(.vertical, 4)
            if layer.cd.box != .none && layer.cd.box != .outline {
                CPColorRow(label: "Box colour", color: $layer.bgColor, opacity: false)
                ParamSlider(label: "Box opacity", value: $layer.bgOpacity, range: 0...1, defaultValue: 0.88, format: "%.2f")
            }
            if layer.cd.box == .outline { CPNote("The outline uses the label colour.") }
            ParamSlider(label: "Padding", value: bind(\.padding), range: 0.3...3, defaultValue: 1, format: "%.2f")

            SectionLabel("Placement")
            CPRow(label: "Position on screen") {
                Picker("", selection: bind(\.placement)) { ForEach(CountdownPlacement.allCases) { Text($0.rawValue).tag($0) } }.cpPickerChrome().frame(maxWidth: 160)
            }

            if layer.cd.mode != .countUp {
                SectionLabel("Warning and end")
                ParamSlider(label: "Warn in last (s)", value: bind(\.warnSeconds), range: 0...600, defaultValue: 60, format: "%.0f")
                CPColorRow(label: "Warning colour", color: Binding(
                    get: { let c = layer.cd.warnRGB; return Color(red: c.count > 0 ? c[0] : 1, green: c.count > 1 ? c[1] : 0.27, blue: c.count > 2 ? c[2] : 0.23) },
                    set: { col in
                        let n = NSColor(col).usingColorSpace(.sRGB) ?? .red
                        layer.cd.warnRGB = [Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent)]
                    }), opacity: false)
                CPToggleRow(label: "Flash near the end", isOn: bind(\.flash))
                if layer.cd.flash {
                    ParamSlider(label: "Flash in last (s)", value: bind(\.flashSeconds), range: 3...120, defaultValue: 10, format: "%.0f")
                }
                CPRow(label: "At zero") {
                    Picker("", selection: bind(\.endBehavior)) { ForEach(CountdownEnd.allCases) { Text($0.rawValue).tag($0) } }.cpPickerChrome().frame(maxWidth: 200)
                }
                if layer.cd.endBehavior == .endText {
                    CPTextRow(label: "End text", text: bind(\.endText), prompt: "WE ARE LIVE")
                }
            }
            HStack {
                Spacer()
                Button("Reset formatting") {
                    let mode = layer.cd.mode, h = layer.cd.targetHour, m = layer.cd.targetMinute
                    layer.cd = CountdownStyle(); layer.cd.mode = mode; layer.cd.targetHour = h; layer.cd.targetMinute = m
                    layer.fontScale = 1; layer.textColor = .white; layer.accent = Color(red: 1.0, green: 0.69, blue: 0.13)
                    layer.bgColor = Color(red: 0.04, green: 0.05, blue: 0.06); layer.bgOpacity = 0.88
                }
                .buttonStyle(.ds(.ghost, .small))
            }
            .padding(.vertical, 6)
        }
    }
}
