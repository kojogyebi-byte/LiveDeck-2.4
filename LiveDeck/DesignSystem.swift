import SwiftUI
import AppKit

// MARK: - Palette & type
//
// A neutral graphite broadcast palette. Colour is reserved for meaning:
// red = on air / program, green = preview / ready, blue = selection, amber = warning / armed.

enum DS {
    static let bg0 = Color(rgb: 0x0E0E0F)      // window background
    static let bg1 = Color(rgb: 0x151516)      // panels
    static let bg2 = Color(rgb: 0x1B1B1D)      // panel headers, bars
    static let bg3 = Color(rgb: 0x242426)      // controls
    static let bg4 = Color(rgb: 0x2F2F32)      // hover / pressed
    static let line = Color(rgb: 0x323235)
    static let lineSoft = Color(rgb: 0x232325)
    static let text = Color(rgb: 0xEBEBEC)
    static let text2 = Color(rgb: 0xA0A0A5)
    static let text3 = Color(rgb: 0x6A6A6F)

    static let program = Color(rgb: 0xE5484D)  // on air
    static let preview = Color(rgb: 0x2FB36E)  // preview / ready / OK
    /// Selection is neutral steel: red, green and amber stay reserved for tally and warnings (broadcast convention).
    static let accent = Color(rgb: 0x4E535B)       // selected fills (white text on top)
    static let accentText = Color(rgb: 0xD5D8DD)   // selected text, icons, outlines
    static let amber = Color(rgb: 0xF2A33A)    // armed / warning
    static let ok = preview

    /// Numbers: SF Pro with fixed-width digits (Apple system font), so values don't jump.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
    static let caption = Font.system(size: 9.5, weight: .semibold)
    static let label = Font.system(size: 11.5, weight: .medium)
    static let small = Font.system(size: 10.5, weight: .medium)
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
        .system(size: size == .small ? 10.5 : (size == .regular ? 11.5 : 13), weight: .medium)
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
        Text(LocalizedStringKey(title)).textCase(.uppercase).font(CPFont.section).kerning(0.9).foregroundColor(CP.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12).padding(.bottom, 4)
    }
}

struct PanelHeader<Trailing: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundColor(CP.icon) }
            Text(L10n.key(title)).font(CPFont.title).foregroundColor(CP.text)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(CP.cardHeader)
        .overlay(Rectangle().fill(CP.border).frame(height: 1), alignment: .bottom)
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
            Text(L10n.key(label)).font(CPFont.label).foregroundColor(CP.text).lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: labelWidth, alignment: .leading)
            content().controlSize(.small)
        }
        .frame(minHeight: 26)
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
                        Image(systemName: item.icon).font(.system(size: 10.5, weight: .medium))
                        if !compact || on { Text(L10n.key(item.title)).font(.system(size: 11.5, weight: on ? .semibold : .medium)).lineLimit(1) }
                    }
                    .foregroundColor(on ? DS.text : DS.text2)
                    .padding(.horizontal, 9)
                    .frame(maxWidth: compact ? nil : .infinity, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 5).fill(on ? DS.bg4 : Color.clear))
                    .overlay(alignment: .bottom) {
                        if on { Rectangle().fill(DS.accentText).frame(height: 2).padding(.horizontal, 6) }
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
                    Text(L10n.key(opt.1)).font(.system(size: 11, weight: on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundColor(on ? CP.text : CP.text2)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: 4).fill(on ? CP.selected : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Color.white.opacity(0.08) : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(CP.field))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CP.border, lineWidth: 1))
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
    var body: some View {
        CPSliderRow(label: label, value: $value, range: range, defaultValue: defaultValue, format: format, showDivider: false)
    }
}

/// Small colour well bound to an RGBA value.
struct DSColorWell: View {
    let label: String
    @Binding var color: Color
    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.key(label)).font(.system(size: 11.5)).foregroundColor(CP.text).lineLimit(1)
            Spacer()
            ColorPicker("", selection: $color, supportsOpacity: true).labelsHidden().controlSize(.small)
        }
        .frame(minHeight: 26)
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
            .font(CPFont.body)
            .foregroundColor(CP.text)
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(CP.field))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(CP.border, lineWidth: 1))
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

// MARK: - Control panel (right-hand inspector) — card design
//
// Neutral graphite cards (no tint), quiet headers, condensed small-caps section labels, SF Pro Text
// for labels and SF Mono for numbers — the look of broadcast control software. Colour is kept for
// meaning only: red on air, green preview/OK, amber warning.

enum CP {
    static let bg = Color(rgb: 0x131314)          // panel background
    static let card = Color(rgb: 0x1B1B1D)        // card body
    static let cardHeader = Color(rgb: 0x202023)  // hover / raised strip
    static let border = Color(rgb: 0x2A2A2D)
    static let divider = Color(rgb: 0x252527)
    static let field = Color(rgb: 0x0F0F10)
    /// Selected fill (white text readable on it). Named `blue` for compatibility — it is steel grey.
    static let blue = Color(rgb: 0x4E535B)
    static let blueSoft = Color.white.opacity(0.06)
    static let selected = Color(rgb: 0x38383C)    // selected segment / tab
    static let accentLine = Color(rgb: 0xC9CCD2)  // focus rings, selection outlines, active underline
    static let toggle = Color(rgb: 0x9DA2AA)      // switch "on", faders, progress
    static let primaryFill = Color(rgb: 0xE4E5E8) // primary buttons (dark text)
    static let primaryText = Color(rgb: 0x111113)
    static let icon = Color(rgb: 0xA3A5AA)
    static let text = Color(rgb: 0xECECEE)
    static let text2 = Color(rgb: 0x9A9AA0)
    static let track = Color(rgb: 0x333336)
}

/// Type scale for the panels and dialogs — Apple's system font (SF Pro) throughout, with fixed-width digits for numbers.
enum CPFont {
    static let body = Font.system(size: 12)
    static let label = Font.system(size: 12)
    static let emphasis = Font.system(size: 12, weight: .medium)
    static let title = Font.system(size: 12.5, weight: .semibold)
    static let subtitle = Font.system(size: 10.5)
    static let caption = Font.system(size: 10.5)
    static let section = Font.system(size: 10, weight: .semibold)
    static let tab = Font.system(size: 10.5, weight: .medium)
    static let value = Font.system(size: 11, weight: .medium).monospacedDigit()
    static let button = Font.system(size: 11.5, weight: .medium)
}

/// Icon-over-label tab bar: flat, neutral, with a light underline on the selected tab.
/// With `onClose`, each tab shows a close button on hover and a “Hide” item in its context menu.
struct CPTabBar: View {
    @Binding var selection: Int
    let items: [DSTabItem]
    var showLabels = true
    var onClose: ((Int) -> Void)? = nil
    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let on = selection == item.id
                Button { selection = item.id } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon).font(.system(size: showLabels ? 13 : 12.5, weight: on ? .semibold : .regular))
                        if showLabels { Text(L10n.key(item.title)).font(CPFont.tab).lineLimit(1).minimumScaleFactor(0.75) }
                    }
                    .foregroundColor(on ? CP.text : CP.text2)
                    .frame(maxWidth: .infinity, minHeight: showLabels ? 40 : 28)
                    .background(RoundedRectangle(cornerRadius: 5).fill(on ? CP.selected : (hovered == item.id ? CP.cardHeader : Color.clear)))
                    .overlay(alignment: .bottom) {
                        if on { Rectangle().fill(CP.accentLine).frame(height: 2).padding(.horizontal, 10) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let onClose, hovered == item.id {
                            Button { onClose(item.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)).foregroundColor(CP.text2)
                                    .frame(width: 14, height: 14)
                                    .background(Circle().fill(CP.bg.opacity(0.9)))
                            }
                            .buttonStyle(.plain).padding(3)
                            .help("Hide the \(item.title) tab (bring it back from the grid button above)")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
                .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                .contextMenu {
                    if let onClose { Button("Hide \(item.title)") { onClose(item.id) } }
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 7).fill(CP.card))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(CP.border, lineWidth: 1))
    }
}

/// Small circular reset button (arrow counter-clockwise).
struct CPResetButton: View {
    var help = "Reset"
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(hover ? CP.text : CP.text2)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hover ? CP.cardHeader : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Collapsible section card: icon · title + subtitle · reset · chevron. Open/closed is remembered per card.
struct CPCard<Content: View>: View {
    let title: String
    var subtitle: String = ""
    var icon: String
    var iconColor: Color = CP.icon
    var onReset: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content
    @State private var expanded = true
    @State private var hover = false

    private var storageKey: String { "cp.card." + title }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.key(title)).font(CPFont.title).foregroundColor(CP.text).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(L10n.key(subtitle)).font(CPFont.subtitle).foregroundColor(CP.text2).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let onReset { CPResetButton(help: "Reset \(title.lowercased())", action: onReset) }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(CP.text2)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(hover ? CP.cardHeader : Color.clear)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
                UserDefaults.standard.set(expanded, forKey: storageKey)
            }

            if expanded {
                Rectangle().fill(CP.divider).frame(height: 1)
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
            }
        }
        .background(CP.card)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CP.border, lineWidth: 1))
        .onAppear { if let v = UserDefaults.standard.object(forKey: storageKey) as? Bool { expanded = v } }
    }
}

/// Thin divider used between rows inside a card.
struct CPDivider: View {
    var body: some View { Rectangle().fill(CP.divider).frame(height: 1) }
}

/// Blue fader track + white knob (no labels).
struct CPFader: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var dragging = false
    private var span: Double { max(0.000001, range.upperBound - range.lowerBound) }
    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width)
            let f = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span)
            ZStack(alignment: .leading) {
                Capsule().fill(CP.track).frame(height: 3)
                Capsule().fill(CP.toggle)
                    .frame(width: max(0, f * w), height: 3)
                Circle().fill(Color(rgb: 0xF2F2F4))
                    .frame(width: dragging ? 13 : 11, height: dragging ? 13 : 11)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 1.5, y: 1)
                    .offset(x: f * w - (dragging ? 7 : 6))
            }
            .frame(width: w, height: 18)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    dragging = true
                    value = range.lowerBound + Double(min(max(d.location.x / w, 0), 1)) * span
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 18)
    }
}

/// Editable numeric value box (type a value and press Return).
struct CPValueField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.2f"
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(CPFont.value)
            .foregroundColor(CP.text)
            .focused($focused)
            .frame(width: 54, height: 22)
            .background(RoundedRectangle(cornerRadius: 4).fill(CP.field))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? CP.accentLine : CP.border, lineWidth: 1))
            .onAppear { text = String(format: format, value) }
            .onChange(of: value) { v in if !focused { text = String(format: format, v) } }
            .onChange(of: focused) { f in if !f { commit() } }
            .onSubmit { commit() }
    }
    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) }
        if let v = Double(cleaned) { value = min(max(v, range.lowerBound), range.upperBound) }
        text = String(format: format, value)
    }
}

/// icon · label · fader · value box · reset
struct CPSliderRow: View {
    var icon: String? = nil
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double? = nil
    var format: String = "%.2f"
    var showDivider = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundColor(CP.text2).frame(width: 16)
                }
                Text(L10n.key(label)).font(CPFont.label).foregroundColor(CP.text).lineLimit(2).minimumScaleFactor(0.8)
                    .frame(width: icon == nil ? 100 : 80, alignment: .leading)
                    .help(label)
                CPFader(value: $value, range: range)
                CPValueField(value: $value, range: range, format: format)
                if let d = defaultValue {
                    CPResetButton(help: "Reset \(label.lowercased())") { value = d }
                } else {
                    Color.clear.frame(width: 20, height: 20)
                }
            }
            .frame(minHeight: 30)
            if showDivider { CPDivider() }
        }
    }
}

/// icon · label · trailing control (picker, toggle…)
struct CPRow<Trailing: View>: View {
    var icon: String? = nil
    let label: String
    var showDivider = true
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundColor(CP.text2).frame(width: 16)
                }
                Text(L10n.key(label)).font(CPFont.label).foregroundColor(CP.text).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                trailing().controlSize(.small)
            }
            .frame(minHeight: 32)
            if showDivider { CPDivider() }
        }
    }
}

/// Rounded pill button with icon, title and chevron (e.g. "Audio Effects  ›").
struct CPPillButton: View {
    let icon: String
    let title: String
    var expanded = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(L10n.key(title)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(CP.text)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(hover ? CP.cardHeader : CP.field))
            .overlay(Capsule().strokeBorder(expanded ? CP.accentLine : CP.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Text button in the card style (e.g. "Reset" in the Input Channel card).
struct CPButton: View {
    var icon: String? = nil
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .medium)) }
                if !title.isEmpty { Text(L10n.key(title)).font(CPFont.button).lineLimit(1) }
            }
            .foregroundColor(prominent ? CP.primaryText : CP.text)
            .padding(.horizontal, title.isEmpty ? 8 : 11).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(prominent ? (hover ? Color.white : CP.primaryFill) : (hover ? CP.cardHeader : Color(rgb: 0x26262A))))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(prominent ? Color.clear : CP.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

extension View {
    /// Dark field look for native pickers inside cards.
    func cpPickerChrome() -> some View {
        self.labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 6).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(CP.field))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(CP.border, lineWidth: 1))
    }
}


// MARK: - Compact console rows used by every inspector

/// label · switch
struct CPToggleRow: View {
    var icon: String? = nil
    let label: String
    @Binding var isOn: Bool
    var showDivider = false
    var body: some View {
        CPRow(icon: icon, label: label, showDivider: showDivider) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).tint(CP.toggle).labelsHidden().controlSize(.mini)
        }
    }
}

/// label · colour swatch
struct CPColorRow: View {
    var icon: String? = nil
    let label: String
    @Binding var color: Color
    var opacity = true
    var showDivider = false
    var body: some View {
        CPRow(icon: icon, label: label, showDivider: showDivider) {
            ColorPicker("", selection: $color, supportsOpacity: opacity).labelsHidden()
        }
    }
}

/// label · text field
struct CPTextRow: View {
    var icon: String? = nil
    let label: String
    @Binding var text: String
    var prompt = ""
    var secure = false
    var showDivider = false
    var body: some View {
        CPRow(icon: icon, label: label, showDivider: showDivider) {
            Group {
                if secure { SecureField(prompt, text: $text) } else { TextField(prompt, text: $text) }
            }
            .textFieldStyle(.plain).font(CPFont.body).foregroundColor(CP.text)
            .padding(.horizontal, 8).frame(height: 26).frame(maxWidth: 200)
            .background(RoundedRectangle(cornerRadius: 5).fill(CP.field))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(CP.border, lineWidth: 1))
        }
    }
}

/// Small helper text inside cards.
struct CPNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(L10n.key(text)).font(CPFont.caption).foregroundColor(CP.text2).lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
    }
}

/// Scrolling inspector column in the console style.
struct CPInspector<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(10)
        }
        .background(CP.bg)
        .font(CPFont.body)
    }
}


// MARK: - Illuminated switcher keys (hardware-panel look)

enum SK {
    static let red = Color(rgb: 0xEF3B2D)
    static let green = Color(rgb: 0x4CD13A)
    static let amber = Color(rgb: 0xF4C430)
    static let white = Color(rgb: 0xEDEDED)
}

private struct KeyCornerMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Square illuminated key: glows in its colour when lit, dark with coloured text when not.
struct SwitcherKeyStyle: ButtonStyle {
    let color: Color
    let lit: Bool
    var minWidth: CGFloat = 40
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .heavy))
            .lineLimit(1)
            .foregroundColor(lit ? Color.black.opacity(0.85) : color.opacity(0.85))
            .padding(.horizontal, 6)
            .frame(minWidth: minWidth, minHeight: 26)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(lit ? color : Color(rgb: 0x262626))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: [Color.white.opacity(lit ? 0.28 : 0.06), Color.clear, Color.black.opacity(lit ? 0.12 : 0.25)],
                                             startPoint: .top, endPoint: .bottom))
                }
            )
            .overlay(alignment: .topTrailing) {
                KeyCornerMark().fill(Color.black.opacity(lit ? 0.38 : 0.55)).frame(width: 7, height: 7).padding(3)
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.black.opacity(0.85), lineWidth: 1.5))
            .overlay(RoundedRectangle(cornerRadius: 4).inset(by: 1.5).strokeBorder(Color.white.opacity(lit ? 0.35 : 0.07), lineWidth: 1))
            .shadow(color: lit ? color.opacity(0.8) : .clear, radius: 6)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.1 : 0)
            .animation(.easeOut(duration: 0.12), value: lit)
            .contentShape(Rectangle())
    }
}


// MARK: - Localization helper

enum L10n {
    /// Strings given to components as `String` are looked up in Localizable.strings (English is the key).
    static func key(_ s: String) -> LocalizedStringKey { LocalizedStringKey(s) }
}
