import Foundation
import AppKit
import AVFoundation
import QuartzCore
import PresentationKit

// MARK: - Content shown by a slide input

struct SlideColumn: Equatable, Hashable {
    var label: String           // e.g. Bible version abbreviation
    var text: String
}

struct SlideContent: Equatable, Hashable {
    var title: String = ""      // dictionary headword / song title
    var body: String = ""
    var footer: String = ""     // scripture reference / credits / dictionary source
    var label: String = ""      // operator-facing label ("Chorus", "John 3:16")
    var columns: [SlideColumn] = []   // several Bible versions side by side / stacked

    var isEmpty: Bool { title.isEmpty && body.isEmpty && footer.isEmpty && columns.isEmpty }
}

// MARK: - Text rasteriser (Core Text via AppKit string drawing)

enum SlideRasterizer {
    static let space = CGColorSpaceCreateDeviceRGB()

    static func nsColor(_ c: RGBAColor) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    static func font(_ style: TextStyle, scale: CGFloat) -> NSFont {
        let size = max(4, CGFloat(style.size) * scale)
        let fm = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if style.bold { traits.insert(.boldFontMask) }
        if style.italic { traits.insert(.italicFontMask) }
        if let f = fm.font(withFamily: style.fontName, traits: traits, weight: style.bold ? 9 : 5, size: size) { return f }
        if let f = NSFont(name: style.fontName, size: size) {
            return traits.isEmpty ? f : fm.convert(f, toHaveTrait: traits)
        }
        let base = NSFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
        return style.italic ? fm.convert(base, toHaveTrait: .italicFontMask) : base
    }

    static func cased(_ s: String, _ c: TextCase) -> String {
        switch c {
        case .asTyped: return s
        case .upper: return s.uppercased()
        case .lower: return s.lowercased()
        case .title: return s.capitalized
        }
    }

    static func attributes(_ style: TextStyle, scale: CGFloat, strokeOnly: Bool = false) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        switch style.align {
        case .left: p.alignment = .left
        case .center: p.alignment = .center
        case .right: p.alignment = .right
        case .justified: p.alignment = .justified
        }
        p.lineHeightMultiple = CGFloat(max(0.6, style.lineSpacing))
        p.lineBreakMode = .byWordWrapping
        var a: [NSAttributedString.Key: Any] = [
            .font: font(style, scale: scale),
            .foregroundColor: nsColor(style.color),
            .paragraphStyle: p,
            .kern: CGFloat(style.letterSpacing) * scale
        ]
        if style.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strokeOnly {
            a[.strokeColor] = nsColor(style.outlineColor)
            // positive stroke width = stroke only, as a percentage of font size
            let pct = CGFloat(style.outlineWidth) * 2 * 100 / max(1, CGFloat(style.size))
            a[.strokeWidth] = pct
            a[.foregroundColor] = NSColor.clear
        }
        return a
    }

    /// Everything except the background, on a transparent image of `size` pixels.
    static func renderText(_ content: SlideContent, look: SlideLook, size: CGSize) -> CGImage? {
        let W = max(2, Int(size.width)), H = max(2, Int(size.height))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        if content.isEmpty { return ctx.makeImage() }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }

        let scale = CGFloat(H) / 1080
        let region = look.textRegion(width: Double(W), height: Double(H))
        // top-left fractions → AppKit bottom-left rect
        let area = CGRect(x: region.x, y: Double(H) - region.y - region.height, width: region.width, height: region.height)

        if !content.columns.isEmpty {
            drawColumns(content, look: look, area: area, W: W, H: H, scale: scale, ctx: ctx)
            return ctx.makeImage()
        }

        let showTitle = look.showTitle && !content.title.isEmpty
        let footerInline = (look.footerPosition == .below || look.footerPosition == .above) && !content.footer.isEmpty
        let footerScreen = (look.footerPosition == .screenBottom || look.footerPosition == .screenTop) && !content.footer.isEmpty

        var shrink: CGFloat = 1
        var blocks: [(NSAttributedString, NSAttributedString?, TextStyle)] = []
        var total: CGFloat = 0
        let gap = 18 * scale

        func build(_ k: CGFloat) {
            blocks = []
            func add(_ text: String, _ style: TextStyle) {
                var st = style; st.size *= Double(k)
                let str = cased(text, st.textCase)
                let fill = NSAttributedString(string: str, attributes: attributes(st, scale: scale))
                let stroke = st.outlineWidth > 0 ? NSAttributedString(string: str, attributes: attributes(st, scale: scale, strokeOnly: true)) : nil
                blocks.append((fill, stroke, st))
            }
            if footerInline && look.footerPosition == .above { add(content.footer, look.footer) }
            if showTitle { add(content.title, look.title) }
            if !content.body.isEmpty { add(content.body, look.body) }
            if footerInline && look.footerPosition == .below { add(content.footer, look.footer) }
            total = blocks.reduce(0) { $0 + height($1.0, width: area.width) } + gap * CGFloat(max(0, blocks.count - 1))
        }
        build(1)
        if look.shrinkToFit {
            var tries = 0
            while total > area.height && shrink > 0.25 && tries < 14 { shrink *= 0.9; build(shrink); tries += 1 }
        }

        // vertical placement
        let usedH = min(total, area.height)
        var top: CGFloat
        switch look.verticalAlign {
        case .top: top = area.maxY
        case .middle: top = area.midY + usedH / 2
        case .bottom: top = area.minY + usedH
        }

        // box / band
        if look.boxColor.a > 0.001 {
            let pad = CGFloat(look.boxPadding) * scale
            var widest: CGFloat = 0
            for b in blocks { widest = max(widest, b.0.boundingRect(with: CGSize(width: area.width, height: .greatestFiniteMagnitude),
                                                                     options: [.usesLineFragmentOrigin, .usesFontLeading]).width) }
            var box: CGRect
            if look.boxFullWidth {
                box = CGRect(x: 0, y: top - usedH - pad, width: CGFloat(W), height: usedH + pad * 2)
            } else {
                let align = look.body.align
                let x: CGFloat = align == .left ? area.minX : (align == .right ? area.maxX - widest : area.midX - widest / 2)
                box = CGRect(x: x - pad, y: top - usedH - pad, width: widest + pad * 2, height: usedH + pad * 2)
            }
            let r = CGFloat(look.boxRadius) * scale
            ctx.setFillColor(nsColor(look.boxColor).cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: min(r, box.width / 2), cornerHeight: min(r, box.height / 2), transform: nil))
            ctx.fillPath()
        }

        var y = top
        for (fill, stroke, st) in blocks {
            let h = height(fill, width: area.width)
            let rect = CGRect(x: area.minX, y: y - h, width: area.width, height: h)
            draw(fill, stroke: stroke, style: st, in: rect, scale: scale, ctx: ctx)
            y -= h + gap
        }

        if footerScreen {
            var st = look.footer
            st.size *= Double(min(1, max(0.6, shrink)))
            let fill = NSAttributedString(string: cased(content.footer, st.textCase), attributes: attributes(st, scale: scale))
            let stroke = st.outlineWidth > 0 ? NSAttributedString(string: cased(content.footer, st.textCase), attributes: attributes(st, scale: scale, strokeOnly: true)) : nil
            let mx = CGFloat(look.marginX) * CGFloat(W), my = CGFloat(max(0.03, look.marginY * 0.6)) * CGFloat(H)
            let fw = CGFloat(W) - mx * 2
            let fh = height(fill, width: fw)
            let fy = look.footerPosition == .screenBottom ? my : CGFloat(H) - my - fh
            draw(fill, stroke: stroke, style: st, in: CGRect(x: mx, y: fy, width: fw, height: fh), scale: scale, ctx: ctx)
        }
        return ctx.makeImage()
    }

    /// Several versions of the same passage: one column (or row) each, same text size for all.
    static func drawColumns(_ content: SlideContent, look: SlideLook, area: CGRect, W: Int, H: Int, scale: CGFloat, ctx: CGContext) {
        let n = content.columns.count
        let gap = CGFloat(look.columnGap) * scale
        let side = look.parallelLayout == .sideBySide
        var frames: [CGRect] = []
        for i in 0..<n {
            if side {
                let w = (area.width - gap * CGFloat(n - 1)) / CGFloat(n)
                frames.append(CGRect(x: area.minX + CGFloat(i) * (w + gap), y: area.minY, width: w, height: area.height))
            } else {
                let h = (area.height - gap * CGFloat(n - 1)) / CGFloat(n)
                frames.append(CGRect(x: area.minX, y: area.maxY - CGFloat(i + 1) * h - CGFloat(i) * gap, width: area.width, height: h))
            }
        }
        // footer takes space at the bottom (or top) of the screen
        let footerText = content.footer
        var footerH: CGFloat = 0
        var footerStyle = look.footer
        if !footerText.isEmpty && look.footerPosition != .hidden {
            let f = NSAttributedString(string: cased(footerText, footerStyle.textCase), attributes: attributes(footerStyle, scale: scale))
            footerH = height(f, width: CGFloat(W) - CGFloat(look.marginX) * CGFloat(W) * 2)
        }

        var labelStyle = look.title
        labelStyle.size = max(18, look.body.size * 0.5)
        labelStyle.align = look.body.align

        func build(_ k: CGFloat) -> [(NSAttributedString?, NSAttributedString, NSAttributedString?, TextStyle, CGFloat)] {
            content.columns.enumerated().map { i, col in
                var bodyStyle = look.body; bodyStyle.size *= Double(k)
                var ls = labelStyle; ls.size *= Double(max(0.6, k))
                let label = look.showVersionLabels && !col.label.isEmpty
                    ? NSAttributedString(string: cased(col.label, ls.textCase), attributes: attributes(ls, scale: scale)) : nil
                let text = NSAttributedString(string: cased(col.text, bodyStyle.textCase), attributes: attributes(bodyStyle, scale: scale))
                let stroke = bodyStyle.outlineWidth > 0
                    ? NSAttributedString(string: cased(col.text, bodyStyle.textCase), attributes: attributes(bodyStyle, scale: scale, strokeOnly: true)) : nil
                let w = frames[i].width
                let total = (label.map { height($0, width: w) + 8 * scale } ?? 0) + height(text, width: w)
                return (label, text, stroke, bodyStyle, total)
            }
        }
        let limitH = (frames.first?.height ?? 0) - (side ? 0 : 0)
        var k: CGFloat = 1
        var blocks = build(k)
        if look.shrinkToFit {
            var tries = 0
            while blocks.contains(where: { $0.4 > limitH }) && k > 0.25 && tries < 16 { k *= 0.9; blocks = build(k); tries += 1 }
        }

        for (i, b) in blocks.enumerated() {
            let fr = frames[i]
            let used = min(b.4, fr.height)
            var top: CGFloat
            switch look.verticalAlign {
            case .top: top = fr.maxY
            case .middle: top = fr.midY + used / 2
            case .bottom: top = fr.minY + used
            }
            if look.boxColor.a > 0.001 {
                let pad = CGFloat(look.boxPadding) * scale
                let box = CGRect(x: fr.minX - pad / 2, y: top - used - pad, width: fr.width + pad, height: used + pad * 2)
                let r = CGFloat(look.boxRadius) * scale
                ctx.setFillColor(nsColor(look.boxColor).cgColor)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: min(r, box.width / 2), cornerHeight: min(r, box.height / 2), transform: nil))
                ctx.fillPath()
            }
            var y = top
            if let label = b.0 {
                let lh = height(label, width: fr.width)
                draw(label, stroke: nil, style: labelStyle, in: CGRect(x: fr.minX, y: y - lh, width: fr.width, height: lh), scale: scale, ctx: ctx)
                y -= lh + 8 * scale
            }
            let th = height(b.1, width: fr.width)
            draw(b.1, stroke: b.2, style: b.3, in: CGRect(x: fr.minX, y: y - th, width: fr.width, height: th), scale: scale, ctx: ctx)
        }

        if footerH > 0 {
            footerStyle.size *= Double(min(1, max(0.6, k)))
            let fill = NSAttributedString(string: cased(footerText, footerStyle.textCase), attributes: attributes(footerStyle, scale: scale))
            let mx = CGFloat(look.marginX) * CGFloat(W), my = CGFloat(max(0.03, look.marginY * 0.5)) * CGFloat(H)
            let fw = CGFloat(W) - mx * 2
            let fh = height(fill, width: fw)
            let fy = (look.footerPosition == .screenTop || look.footerPosition == .above) ? CGFloat(H) - my - fh : my
            draw(fill, stroke: nil, style: footerStyle, in: CGRect(x: mx, y: fy, width: fw, height: fh), scale: scale, ctx: ctx)
        }
    }

    static func height(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(s.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    static func draw(_ fill: NSAttributedString, stroke: NSAttributedString?, style: TextStyle, in rect: CGRect, scale: CGFloat, ctx: CGContext) {
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        ctx.saveGState()
        if style.shadow {
            let sh = NSShadow()
            sh.shadowColor = nsColor(style.shadowColor)
            sh.shadowBlurRadius = CGFloat(style.shadowBlur) * scale
            sh.shadowOffset = NSSize(width: 0, height: -2 * scale)
            sh.set()
        }
        if let stroke { stroke.draw(with: rect, options: opts, context: nil) }
        fill.draw(with: rect, options: opts, context: nil)
        ctx.restoreGState()
    }

    static func cgBlend(_ m: MediaBlendMode) -> CGBlendMode {
        switch m {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .softLight: return .softLight
        case .hardLight: return .hardLight
        case .darken: return .darken
        case .lighten: return .lighten
        case .colorDodge: return .colorDodge
        case .colorBurn: return .colorBurn
        case .difference: return .difference
        case .exclusion: return .exclusion
        case .hue: return .hue
        case .saturation: return .saturation
        case .color: return .color
        case .luminosity: return .luminosity
        }
    }

    /// Draws `img` into `rect` with the given fit.
    static func drawImage(_ img: CGImage, in rect: CGRect, fit: FitMode, ctx: CGContext) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0 else { return }
        var r = rect
        switch fit {
        case .stretch: break
        case .fill, .fit:
            let s = fit == .fill ? max(rect.width / iw, rect.height / ih) : min(rect.width / iw, rect.height / ih)
            r = CGRect(x: rect.midX - iw * s / 2, y: rect.midY - ih * s / 2, width: iw * s, height: ih * s)
        }
        ctx.saveGState(); ctx.clip(to: rect); ctx.interpolationQuality = .medium
        ctx.draw(img, in: r)
        ctx.restoreGState()
    }
}

// MARK: - Base class for slide-type inputs (Presentation, Dictionary)

class SlideSource: Source {
    @Published var look: SlideLook {
        didSet {
            if oldValue.background != look.background { loadBackground() }
            if oldValue != look { textCache.removeAll() }
        }
    }
    @Published private(set) var content = SlideContent()
    @Published var textCleared = false { didSet { if oldValue != textCleared { startFade() } } }
    @Published var backgroundCleared = false

    private var textCache: [String: CGImage] = [:]
    private var prevCache: [String: CGImage] = [:]
    private var prevContent = SlideContent()
    private var fadeStart: CFTimeInterval = 0
    private var bgImage: CGImage?
    private var bgVideo: FileSource?
    private(set) var backgroundProblem: String?

    init(name: String, kindLabel: String, look: SlideLook) {
        self.look = look
        super.init(name: name, kindLabel: kindLabel)
        loadBackground()
    }

    func show(_ c: SlideContent) {
        guard c != content || textCleared else { return }
        prevCache = textCache
        prevContent = textCleared ? SlideContent() : content
        textCache.removeAll()
        content = c
        if textCleared { textCleared = false } else { startFade() }
    }

    private func startFade() {
        fadeStart = CACurrentMediaTime()
    }

    override func currentImage() -> CGImage? { nil }   // draw-only source

    private func loadBackground() {
        bgVideo?.stop(); bgVideo = nil; bgImage = nil; backgroundProblem = nil
        let bg = look.background
        guard let media = bg.media else { return }
        let url = URL(fileURLWithPath: media.path)
        if media.status == .missing { backgroundProblem = "Background file not found: \(url.lastPathComponent)"; return }
        switch bg.kind {
        case .image:
            if let img = NSImage(contentsOf: url) {
                var r = CGRect(origin: .zero, size: img.size)
                bgImage = img.cgImage(forProposedRect: &r, context: nil, hints: nil)
            }
            if bgImage == nil { backgroundProblem = "Could not read image \(url.lastPathComponent)" }
        case .video:
            let v = FileSource(url: url, displayName: url.lastPathComponent, label: "BG", startLooping: true, autoplay: true)
            v.muted = true
            bgVideo = v
        default: break
        }
    }

    func drawBackground(in ctx: CGContext, rect: CGRect, ignoreCleared: Bool = false) {
        let bg = look.background
        guard ignoreCleared || !backgroundCleared else { return }
        switch bg.kind {
        case .none, .transparent:
            break
        case .color:
            ctx.setFillColor(SlideRasterizer.nsColor(bg.color).cgColor); ctx.fill(rect)
        case .gradient:
            drawGradient(bg.color, bg.color2, angle: bg.angle, in: ctx, rect: rect)
        case .image, .video:
            // base layer under the media
            if look.mediaBase == .gradient { drawGradient(bg.color, bg.color2, angle: bg.angle, in: ctx, rect: rect) }
            else { ctx.setFillColor(SlideRasterizer.nsColor(bg.color).cgColor); ctx.fill(rect) }
            let media: CGImage? = bg.kind == .image ? bgImage : bgVideo?.currentImage()
            if let img = media {
                ctx.saveGState()
                ctx.setBlendMode(SlideRasterizer.cgBlend(look.mediaBlend))
                ctx.setAlpha(CGFloat(min(1, max(0, look.mediaOpacity))))
                SlideRasterizer.drawImage(img, in: rect, fit: bg.fit, ctx: ctx)
                ctx.restoreGState()
            }
        }
        if look.dim > 0.001 && bg.kind != .transparent && bg.kind != .none {
            ctx.setFillColor(NSColor.black.withAlphaComponent(CGFloat(min(0.95, look.dim))).cgColor); ctx.fill(rect)
        }
    }

    private func drawGradient(_ c1: RGBAColor, _ c2: RGBAColor, angle: Double, in ctx: CGContext, rect: CGRect) {
        let colors = [SlideRasterizer.nsColor(c1).cgColor, SlideRasterizer.nsColor(c2).cgColor] as CFArray
        guard let g = CGGradient(colorsSpace: SlideRasterizer.space, colors: colors, locations: [0, 1]) else { return }
        let a = CGFloat(angle) * .pi / 180
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let d = max(rect.width, rect.height) / 2
        let start = CGPoint(x: c.x - cos(a) * d, y: c.y + sin(a) * d)
        let end = CGPoint(x: c.x + cos(a) * d, y: c.y - sin(a) * d)
        ctx.saveGState(); ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private func textImage(_ c: SlideContent, cache: inout [String: CGImage], size: CGSize) -> CGImage? {
        let key = "\(Int(size.width))x\(Int(size.height))"
        if let img = cache[key] { return img }
        guard let img = SlideRasterizer.renderText(c, look: look, size: size) else { return nil }
        if cache.count >= 4 { cache.removeAll() }
        cache[key] = img
        return img
    }

    override func draw(in ctx: CGContext, rect: CGRect) {
        drawBackground(in: ctx, rect: rect)
        let size = CGSize(width: rect.width.rounded(), height: rect.height.rounded())
        let duration = max(0.001, look.fadeDuration)
        let t = min(1, (CACurrentMediaTime() - fadeStart) / duration)
        if t < 1, !prevContent.isEmpty, let prev = textImage(prevContent, cache: &prevCache, size: size) {
            ctx.saveGState(); ctx.setAlpha(CGFloat(1 - t)); ctx.draw(prev, in: rect); ctx.restoreGState()
        }
        guard !textCleared || t < 1 else { return }
        if let img = textImage(content, cache: &textCache, size: size) {
            ctx.saveGState()
            let alpha = textCleared ? 1 - t : t
            if alpha < 1 { ctx.setAlpha(CGFloat(alpha)) }
            ctx.draw(img, in: rect)
            ctx.restoreGState()
        }
    }

    /// Still image for slide thumbnails (static background + text), independent of what is live.
    func still(_ c: SlideContent, size: CGSize) -> CGImage? {
        let W = max(2, Int(size.width)), H = max(2, Int(size.height))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: SlideRasterizer.space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        if look.background.kind == .transparent || look.background.kind == .none {
            // checkerboard hint that the slide is transparent
            ctx.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor); ctx.fill(rect)
            ctx.setFillColor(NSColor(white: 0.21, alpha: 1).cgColor)
            let s = CGFloat(H) / 9
            var yy: CGFloat = 0, row = 0
            while yy < CGFloat(H) {
                var xx: CGFloat = (row % 2 == 0) ? 0 : s
                while xx < CGFloat(W) { ctx.fill(CGRect(x: xx, y: yy, width: s, height: s)); xx += s * 2 }
                yy += s; row += 1
            }
        } else {
            drawBackground(in: ctx, rect: rect, ignoreCleared: true)
        }
        if let text = SlideRasterizer.renderText(c, look: look, size: CGSize(width: W, height: H)) { ctx.draw(text, in: rect) }
        return ctx.makeImage()
    }

    override func stop() { bgVideo?.stop(); bgVideo = nil }
}

final class PresentationSource: SlideSource {
    init(name: String = "Presentation", look: SlideLook = .fullScreen) {
        super.init(name: name, kindLabel: "PRESENT", look: look)
    }
}

/// Answers from AI search (Claude, ChatGPT, Gemini…) shown as formatted slides.
final class AISource: SlideSource {
    init(name: String = "AI Search", look: SlideLook = AISource.defaultLook) {
        super.init(name: name, kindLabel: "AI", look: look)
    }
    static var defaultLook: SlideLook {
        var l = SlideLook.fullScreen
        l.name = "AI answer"
        l.maxCharsPerSlide = 260
        l.showTitle = false
        return l
    }
}

final class DictionarySource: SlideSource {
    @Published var entry: WordEntry?
    init(name: String = "Dictionary", look: SlideLook = .dictionaryPanel) {
        super.init(name: name, kindLabel: "DICT", look: look)
    }
    func showEntry(_ e: WordEntry?) {
        entry = e
        guard let e else { show(SlideContent()); return }
        show(DictionarySource.content(for: e, look: look))
    }
    static func content(for e: WordEntry, look: SlideLook) -> SlideContent {
        SlideContent(title: e.titleText, body: e.bodyText(maxSenses: look.maxSenses, examples: look.showExamples),
                     footer: e.source, label: e.word)
    }
}
