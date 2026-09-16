import SwiftUI
import AppKit

// MARK: - Palette & type
//
// A neutral graphite broadcast palette. Colour is reserved for meaning:
// red = on air / program, green = preview / ready, blue = selection, amber = warning / armed.

enum DS {
    static let bg0 = Color(rgb: 0x0B0C0F)      // window background
    static let bg1 = Color(rgb: 0x121418)      // panels
    static let bg2 = Color(rgb: 0x181B20)      // panel headers, bars
    static let bg3 = Color(rgb: 0x20242B)      // controls
    static let bg4 = Color(rgb: 0x2A2F37)      // hover / pressed
    static let line = Color(rgb: 0x2B3039)
    static let lineSoft = Color(rgb: 0x1E2228)
    static let text = Color(rgb: 0xE6E8EB)
    static let text2 = Color(rgb: 0x9BA2AD)
    static let text3 = Color(rgb: 0x5F6670)

    static let program = Color(rgb: 0xE5484D)  // on air
    static let preview = Color(rgb: 0x2FB36E)  // preview / ready / OK
    static let accent = Color(rgb: 0x3D8BFD)   // selection
    static let amber = Color(rgb: 0xF2A33A)    // armed / warning
    static let ok = preview

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let caption = Font.system(size: 9, weight: .bold)
    static let label = Font.system(size: 11, weight: .medium)
    static let small = Font.system(size: 10, weight: .medium)
}

extension Color {
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: opacity)
    }
}

// MARK: - Buttons

enum DSKind { case normal, primary, program, preview, danger, ghost, amber }
enum DSSize { case small, regular, large }

struct DSButtonStyle: ButtonStyle {
    var kind: DSKind = .normal
    var size: DSSize = .regular
    var active: Bool = false          // latched state (e.g. selected transition, streaming)
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind, size: size, active: active, fullWidth: fullWidth)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSKind
    let size: DSSize
    let active: Bool
    let fullWidth: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    private var tint: Color {
        switch kind {
        case .normal, .ghost: return DS.accent
        case .primary: return DS.accent
        case .program, .danger: return DS.program
        case .preview: return DS.preview
        case .amber: return DS.amber
        }
    }
    private var fill: Color {
        if kind == .ghost && !active { return hover ? DS.bg3 : Color.clear }
        if active || kind == .primary { return tint.opacity(configuration.isPressed ? 0.75 : (hover ? 0.95 : 0.85)) }
        if configuration.isPressed { return DS.bg4 }
        return hover ? DS.bg4 : DS.bg3
    }
    private var fg: Color {
        if active || kind == .primary { return .white }
        switch kind {
        case .program, .danger: return DS.program
        case .preview: return DS.preview
        case .amber: return DS.amber
        default: return DS.text
        }
    }
    private var height: CGFloat { size == .small ? 22 : (size == .regular ? 26 : 34) }
    private var font: Font {
        .system(size: size == .small ? 10 : (size == .regular ? 11 : 13), weight: .semibold)
    }

    var body: some View {
        configuration.label
            .font(font)
            .lineLimit(1)
            .padding(.horizontal, size == .small ? 8 : 11)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height, maxHeight: height)
            .foregroundColor(fg)
            .background(RoundedRectangle(cornerRadius: 5).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(active ? Color.white.opacity(0.12) : (kind == .ghost ? Color.clear : DS.line), lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static func ds(_ kind: DSKind = .normal, _ size: DSSize = .regular, active: Bool = false, fullWidth: Bool = false) -> DSButtonStyle {
        DSButtonStyle(kind: kind, size: size, active: active, fullWidth: fullWidth)
    }
}

/// Square icon button (toolbar-style).
struct DSIconButton: View {
    let symbol: String
    var help: String = ""
    var active: Bool = false
    var tint: Color = DS.text2
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundColor(active ? .white : (hover ? DS.text : tint))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 5).fill(active ? DS.accent : (hover ? DS.bg4 : DS.bg3)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DS.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Headers & sections

struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).kerning(1.2).foregroundColor(DS.text3)
            Rectangle().fill(DS.lineSoft).frame(height: 1)
        }
        .padding(.top, 4)
    }
}

struct PanelHeader<Trailing: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundColor(DS.text3) }
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).kerning(1.2).foregroundColor(DS.text2)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(DS.bg2)
        .overlay(Rectangle().fill(DS.lineSoft).frame(height: 1), alignment: .bottom)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, icon: String? = nil) { self.title = title; self.icon = icon; self.trailing = { EmptyView() } }
}

/// Label + control row used throughout inspectors.
struct FieldRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 86
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(DS.small).foregroundColor(DS.text2).frame(width: labelWidth, alignment: .leading)
            content()
        }
    }
}

// MARK: - Tabs

struct DSTabItem: Identifiable {
    let id: Int
    let title: String
    let icon: String
}

struct DSTabBar: View {
    @Binding var selection: Int
    let items: [DSTabItem]
    var compact = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let on = selection == item.id
                Button { selection = item.id } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon).font(.system(size: 10, weight: .semibold))
                        if !compact || on { Text(item.title).font(.system(size: 11, weight: .semibold)).lineLimit(1) }
                    }
                    .foregroundColor(on ? DS.text : DS.text2)
                    .padding(.horizontal, 9)
                    .frame(maxWidth: compact ? nil : .infinity, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 5).fill(on ? DS.bg4 : Color.clear))
                    .overlay(alignment: .bottom) {
                        if on { Rectangle().fill(DS.accent).frame(height: 2).padding(.horizontal, 6) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 7).fill(DS.bg1))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DS.lineSoft, lineWidth: 1))
    }
}

/// Compact segmented control with custom look.
struct DSSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = selection == opt.0
                Button { selection = opt.0 } label: {
                    Text(opt.1).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        .foregroundColor(on ? .white : DS.text2)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: 4).fill(on ? DS.accent.opacity(0.85) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(DS.bg3))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.line, lineWidth: 1))
    }
}

// MARK: - Parameter slider

/// Compact inspector slider: label and value on one line, thin track, drag anywhere.
/// Bipolar ranges fill from zero. Double-click resets to the default value when given.
struct ParamSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double? = nil
    var format: String = "%.2f"
    @State private var dragging = false
    @State private var hover = false

    private var span: Double { max(0.000001, range.upperBound - range.lowerBound) }
    private func frac(_ v: Double) -> CGFloat { CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span) }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label).font(DS.small).foregroundColor(DS.text2).lineLimit(1)
                Spacer()
                Text(String(format: format, value)).font(DS.mono(10)).foregroundColor(dragging ? DS.text : DS.text2)
            }
            GeometryReader { g in
                let w = max(1, g.size.width)
                let f = frac(value)
                let zero: CGFloat = (range.lowerBound < 0 && range.upperBound > 0) ? frac(0) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(DS.bg4).frame(height: 4)
                    RoundedRectangle(cornerRadius: 2).fill(DS.accent)
                        .frame(width: max(0, abs(f - zero) * w), height: 4)
                        .offset(x: min(f, zero) * w)
                    Circle().fill(Color.white)
                        .frame(width: dragging || hover ? 12 : 10, height: dragging || hover ? 12 : 10)
                        .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
                        .offset(x: f * w - (dragging || hover ? 6 : 5))
                }
                .frame(width: w, height: 16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { d in
                        dragging = true
                        let t = min(max(d.location.x / w, 0), 1)
                        value = range.lowerBound + Double(t) * span
                    }
                    .onEnded { _ in dragging = false })
                .simultaneousGesture(TapGesture(count: 2).onEnded { if let dv = defaultValue { value = dv } })
                .onHover { hover = $0 }
            }
            .frame(height: 16)
        }
        .help(defaultValue != nil ? "Double-click to reset" : "")
    }
}

/// Small colour well bound to an RGBA value.
struct DSColorWell: View {
    let label: String
    @Binding var color: Color
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(DS.small).foregroundColor(DS.text2)
            Spacer()
            ColorPicker("", selection: $color, supportsOpacity: true).labelsHidden()
        }
    }
}

// MARK: - Vertical T-bar

struct TBarControl: View {
    let value: Double                  // 0 … 1
    let onDrag: (Double) -> Void
    @State private var dragging = false
    var body: some View {
        GeometryReader { g in
            let h = max(1, g.size.height)
            let handleH: CGFloat = 22
            let travel = max(1, h - handleH)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 4).fill(DS.bg0)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DS.line, lineWidth: 1))
                    .frame(width: 10)
                RoundedRectangle(cornerRadius: 2).fill(DS.program.opacity(0.8))
                    .frame(width: 4, height: CGFloat(value) * travel + handleH / 2)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Color(rgb: 0x4A505A), Color(rgb: 0x2C3037)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(dragging ? 0.4 : 0.15), lineWidth: 1))
                    .overlay(Rectangle().fill(DS.program).frame(height: 2))
                    .frame(width: 46, height: handleH)
                    .offset(y: CGFloat(value) * travel)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    dragging = true
                    onDrag(Double(min(max((d.location.y - handleH / 2) / travel, 0), 1)))
                }
                .onEnded { _ in dragging = false })
        }
    }
}

// MARK: - Panel container modifier

struct DSPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(DS.bg1)
            .overlay(RoundedRectangle(cornerRadius: 0).strokeBorder(DS.lineSoft, lineWidth: 1))
    }
}
extension View {
    func dsPanel() -> some View { modifier(DSPanel()) }
    func dsField() -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(DS.bg0))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DS.line, lineWidth: 1))
    }
}

// MARK: - Main-window chrome: no title bar in full screen

/// Hides the macOS title bar and window buttons while the main window is in full screen,
/// so the controls use the entire display. Restored when leaving full screen.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView(frame: .zero) }
    func updateNSView(_ nsView: ChromeView, context: Context) {}

    final class ChromeView: NSView {
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens = []
            guard let w = window else { return }
            w.collectionBehavior.insert(.fullScreenPrimary)
            let nc = NotificationCenter.default
            tokens.append(nc.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: w, queue: .main) { [weak w] _ in
                if let w { ChromeView.apply(fullScreen: true, to: w) }
            })
            tokens.append(nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: w, queue: .main) { [weak w] _ in
                if let w { ChromeView.apply(fullScreen: false, to: w) }
            })
            if w.styleMask.contains(.fullScreen) { ChromeView.apply(fullScreen: true, to: w) }
        }

        deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }

        static func apply(fullScreen: Bool, to w: NSWindow) {
            w.titleVisibility = fullScreen ? .hidden : .visible
            w.titlebarAppearsTransparent = fullScreen
            if fullScreen { w.styleMask.insert(.fullSizeContentView) } else { w.styleMask.remove(.fullSizeContentView) }
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(b)?.isHidden = fullScreen
            }
            w.toolbar?.isVisible = !fullScreen
        }
    }
}
