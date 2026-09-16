import Foundation
import AppKit
import SwiftUI
import CoreImage
import CoreText
import PresentationKit

// MARK: - Layer model

final class Layer: ObservableObject, Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case lowerThird = "Lower Third"
        case ticker = "Ticker / Crawl"
        case countdown = "Countdown"
        case clock = "Clock"
        case scoreboard = "Scoreboard"
        case title = "Title"
        case logo = "Logo / Image"
        case qrcode = "QR Code"
        case pip = "Picture in Picture"
        case definition = "Dictionary"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .lowerThird: return "rectangle.bottomthird.inset.filled"
            case .ticker: return "text.line.last.and.arrowtriangle.forward"
            case .countdown: return "timer"
            case .clock: return "clock"
            case .scoreboard: return "sportscourt"
            case .title: return "textformat"
            case .logo: return "photo"
            case .qrcode: return "qrcode"
            case .pip: return "pip"
            case .definition: return "character.book.closed"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    @Published var name: String
    @Published var isLive = false
    var liveT: Double = 0

    @Published var text1: String
    @Published var text2: String
    @Published var accent: Color = Color(red: 1.0, green: 0.69, blue: 0.13)
    @Published var number1: Double = 5
    @Published var scoreA: Int = 0
    @Published var scoreB: Int = 0
    @Published var position: Int = 1
    @Published var use24h: Bool = true
    @Published var style: Int = 0          // lower-third preset
    @Published var sourceRef: UUID?        // PiP source

    // Editable styling (flexibility)
    @Published var textColor: Color = .white
    @Published var bgColor: Color = Color(red: 0.04, green: 0.05, blue: 0.06)
    @Published var bgOpacity: Double = 0.88
    @Published var fontScale: Double = 1.0
    @Published var align: Int = 0          // 0 left, 1 centre, 2 right

    // Chroma key (used by PiP)
    @Published var keyEnabled: Bool = false
    @Published var keyColor: Color = Color(red: 0.0, green: 0.78, blue: 0.0)
    @Published var keySimilarity: Double = 0.12
    @Published var keySmoothness: Double = 0.08

    // Overlay transform adjustments
    @Published var opacity: Double = 1.0
    @Published var offsetX: Double = 0     // fraction of width
    @Published var offsetY: Double = 0     // fraction of height
    @Published var scaleAdj: Double = 1.0
    @Published var rotationAdj: Double = 0 // degrees

    func resetTransform() { opacity = 1; offsetX = 0; offsetY = 0; scaleAdj = 1; rotationAdj = 0 }

    var remaining: Double = 300
    @Published var isRunning = false
    var lastTick: CFTimeInterval = 0

    // Countdown formatting and behaviour
    @Published var cd = CountdownStyle()
    var elapsed: Double = 0
    private var endHandled = false

    /// Seconds to show: time left (duration / to a clock time; negative past zero) or elapsed (count up).
    var displaySeconds: Double {
        switch cd.mode {
        case .duration: return remaining
        case .toTime: return CountdownClock.secondsUntil(hour: cd.targetHour, minute: cd.targetMinute)
        case .countUp: return elapsed
        }
    }

    /// Advances a running countdown. Called once per frame by the engine (whether or not it is on air).
    func tick() {
        guard kind == .countdown else { return }
        let now = CACurrentMediaTime()
        defer { lastTick = isRunning ? now : 0 }
        if cd.mode == .toTime {
            if displaySeconds <= 0 { handleEnd() } else { endHandled = false }
            return
        }
        guard isRunning, lastTick > 0 else { return }
        let dt = now - lastTick
        if cd.mode == .countUp { elapsed += dt; return }
        remaining -= dt
        if remaining <= 0 {
            if cd.endBehavior != .overtime { remaining = 0; isRunning = false }
            handleEnd()
        }
    }

    private func handleEnd() {
        guard !endHandled else { return }
        endHandled = true
        if cd.endBehavior == .hide { isLive = false }
    }

    func startCountdown() {
        if cd.mode == .duration && remaining <= 0 && cd.endBehavior != .overtime { remaining = number1 * 60 }
        endHandled = false
        lastTick = 0
        isRunning = true
    }
    func pauseCountdown() { isRunning = false }
    func resetCountdown() {
        isRunning = false
        remaining = number1 * 60
        elapsed = 0
        endHandled = false
    }
    func nudgeCountdown(_ seconds: Double) {
        if cd.mode == .countUp { elapsed = max(0, elapsed + seconds) } else { remaining = max(0, remaining + seconds) }
    }

    var logoImage: CGImage?
    var qrCache: CGImage?
    var qrCachedText: String = ""

    // mimoLive-style variants: saved states you cycle through and push live
    @Published var variants: [LayerVariant] = []
    @Published var activeVariant: Int = 0

    func captureVariant() {
        let c = accent.rgbaComponents()
        let v = LayerVariant(name: "Variant \(variants.count + 1)",
                             text1: text1, text2: text2,
                             aR: c.0, aG: c.1, aB: c.2, aA: c.3,
                             number1: number1, scoreA: scoreA, scoreB: scoreB,
                             position: position, style: style)
        variants.append(v)
        activeVariant = variants.count - 1
    }

    func applyVariant(_ i: Int) {
        guard variants.indices.contains(i) else { return }
        let v = variants[i]
        text1 = v.text1; text2 = v.text2
        accent = Color(.sRGB, red: v.aR, green: v.aG, blue: v.aB, opacity: v.aA)
        number1 = v.number1; scoreA = v.scoreA; scoreB = v.scoreB
        position = v.position; style = v.style
        activeVariant = i
    }

    func cycleVariant(_ delta: Int) {
        guard !variants.isEmpty else { return }
        let n = variants.count
        applyVariant(((activeVariant + delta) % n + n) % n)
    }

    init(kind: Kind) {
        self.kind = kind
        self.name = kind.rawValue
        switch kind {
        case .lowerThird:
            text1 = "Evangelist Dag Heward-Mills"; text2 = "Healing Jesus Campaign"
        case .ticker:
            text1 = "Welcome to the Healing Jesus Campaign  ✦  Jesus saves, heals and delivers  ✦  "
            text2 = ""; number1 = 90
        case .countdown:
            text1 = "STARTING IN"; text2 = ""; number1 = 5
        case .scoreboard:
            text1 = "TEAM A"; text2 = "TEAM B"
        case .title:
            text1 = "WELCOME"; text2 = ""; number1 = 9
        case .qrcode:
            text1 = "https://daghewardmills.org"; text2 = ""; number1 = 150
        case .logo:
            text1 = ""; text2 = ""; number1 = 14
        case .clock:
            text1 = ""; text2 = ""
        case .pip:
            text1 = ""; text2 = ""; number1 = 28; position = 3
        case .definition:
            text1 = "Grace"; text2 = "Unmerited favour."; number1 = 6
            bgColor = Color(red: 0.05, green: 0.07, blue: 0.12); bgOpacity = 0.9
        }
    }
}

// MARK: - Rendering helpers (CG origin is bottom-left)

private func ease(_ t: Double) -> CGFloat {
    let x = max(0, min(1, t))
    return CGFloat(x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2)
}

private func draw(_ string: String, at point: CGPoint, font: NSFont, color: NSColor,
                  in ctx: CGContext, centered: Bool = false) {
    let attr = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    let prev = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    var p = point
    if centered { p.x -= attr.size().width / 2 }
    attr.draw(at: p)
    NSGraphicsContext.current = prev
}

private func textWidth(_ string: String, font: NSFont) -> CGFloat {
    NSAttributedString(string: string, attributes: [.font: font]).size().width
}

private func coverDraw(_ img: CGImage, in rect: CGRect, ctx: CGContext) {
    let iw = CGFloat(img.width), ih = CGFloat(img.height)
    guard iw > 0, ih > 0 else { return }
    let s = max(rect.width / iw, rect.height / ih)
    let dw = iw * s, dh = ih * s
    ctx.saveGState()
    ctx.clip(to: rect)
    ctx.draw(img, in: CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh))
    ctx.restoreGState()
}

// MARK: - Layer renderer

enum LayerRenderer {

    /// Draws a layer with its transform (offset, scale, rotation, opacity). `visibility` overrides the
    /// on-air animation (1 = fully shown), used when an overlay is shown as a standalone input.
    static func renderComposited(_ layer: Layer, in ctx: CGContext, width: Int, height: Int, time: CFTimeInterval,
                                 visibility: Double? = nil, sourceImage: (UUID) -> CGImage?) {
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(layer.offsetX) * CGFloat(width), y: CGFloat(layer.offsetY) * CGFloat(height))
        if layer.scaleAdj != 1 || layer.rotationAdj != 0 {
            ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            if layer.rotationAdj != 0 { ctx.rotate(by: CGFloat(layer.rotationAdj) * .pi / 180) }
            ctx.scaleBy(x: CGFloat(layer.scaleAdj), y: CGFloat(layer.scaleAdj))
            ctx.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        }
        let useGroup = layer.opacity < 0.999
        if useGroup { ctx.setAlpha(CGFloat(layer.opacity)); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
        render(layer, in: ctx, width: width, height: height, time: time, visibility: visibility, sourceImage: sourceImage)
        if useGroup { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    static func render(_ layer: Layer, in ctx: CGContext, width: Int, height: Int,
                       time: CFTimeInterval, visibility: Double? = nil, sourceImage: (UUID) -> CGImage?) {
        let k = visibility.map { ease($0) } ?? ease(layer.liveT)
        guard k > 0 else { return }
        let W = CGFloat(width), H = CGFloat(height)
        ctx.saveGState()

        switch layer.kind {

        case .lowerThird:
            let scale = CGFloat(max(0.5, layer.fontScale))
            let barW: CGFloat = 640, barH: CGFloat = 96 * scale
            let margin: CGFloat = 60
            let targetX: CGFloat
            switch layer.align {
            case 1: targetX = (W - barW) / 2
            case 2: targetX = W - barW - margin
            default: targetX = margin
            }
            let x = targetX - (1 - k) * 60
            let y: CGFloat = 110
            ctx.setAlpha(min(1, k * 1.4))
            let acc = NSColor(layer.accent)
            let bg = NSColor(layer.bgColor).withAlphaComponent(layer.bgOpacity)
            let tcol = NSColor(layer.textColor)
            let f1 = NSFont.boldSystemFont(ofSize: H * 0.045 * scale)
            let f2 = NSFont.boldSystemFont(ofSize: H * 0.026 * scale)
            func rounded(_ r: CGRect, _ rad: CGFloat) -> CGPath {
                CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
            }
            switch layer.style {
            case 1: // boxed, no strip
                ctx.setFillColor(bg.cgColor)
                ctx.fill(CGRect(x: x, y: y, width: barW, height: barH))
                draw(layer.text1, at: CGPoint(x: x + 26, y: y + barH * 0.46), font: f1, color: tcol, in: ctx)
                draw(layer.text2.uppercased(), at: CGPoint(x: x + 26, y: y + barH * 0.13), font: f2, color: acc, in: ctx)
            case 2: // minimal underline
                draw(layer.text1, at: CGPoint(x: x + 10, y: y + 40 * scale), font: f1, color: tcol, in: ctx)
                let w = textWidth(layer.text1, font: f1)
                ctx.setFillColor(acc.cgColor)
                ctx.fill(CGRect(x: x + 12, y: y + 30 * scale, width: w, height: 4))
                draw(layer.text2.uppercased(), at: CGPoint(x: x + 12, y: y - 2), font: f2, color: acc, in: ctx)
            case 3: // two-tone: accent block + dark body
                let accW: CGFloat = 150
                ctx.setFillColor(acc.cgColor); ctx.fill(CGRect(x: x, y: y, width: accW, height: barH))
                ctx.setFillColor(bg.cgColor); ctx.fill(CGRect(x: x + accW, y: y, width: barW - accW, height: barH))
                draw(layer.text2.uppercased(), at: CGPoint(x: x + accW / 2, y: y + barH * 0.34), font: f2, color: .white, in: ctx, centered: true)
                draw(layer.text1, at: CGPoint(x: x + accW + 24, y: y + barH * 0.32), font: f1, color: tcol, in: ctx)
            case 4: // tab header
                let tabH = barH * 0.42
                ctx.setFillColor(acc.cgColor); ctx.fill(CGRect(x: x, y: y + barH, width: 300, height: tabH))
                draw(layer.text2.uppercased(), at: CGPoint(x: x + 18, y: y + barH + tabH * 0.22), font: f2, color: .white, in: ctx)
                ctx.setFillColor(bg.cgColor); ctx.fill(CGRect(x: x, y: y, width: barW, height: barH))
                draw(layer.text1, at: CGPoint(x: x + 22, y: y + barH * 0.28), font: f1, color: tcol, in: ctx)
            case 5: // outline (accent rules top & bottom, no fill)
                ctx.setFillColor(acc.cgColor)
                ctx.fill(CGRect(x: x + 10, y: y + barH - 4, width: barW * 0.7, height: 4))
                ctx.fill(CGRect(x: x + 10, y: y, width: barW * 0.4, height: 4))
                draw(layer.text1, at: CGPoint(x: x + 12, y: y + barH * 0.40), font: f1, color: tcol, in: ctx)
                draw(layer.text2.uppercased(), at: CGPoint(x: x + 12, y: y + barH * 0.10), font: f2, color: acc, in: ctx)
            case 6: // rounded pill
                ctx.addPath(rounded(CGRect(x: x, y: y, width: barW, height: barH), barH / 2)); ctx.setFillColor(bg.cgColor); ctx.fillPath()
                ctx.addPath(rounded(CGRect(x: x + 16, y: y + barH * 0.22, width: 12, height: barH * 0.56), 6)); ctx.setFillColor(acc.cgColor); ctx.fillPath()
                draw(layer.text1, at: CGPoint(x: x + 44, y: y + barH * 0.46), font: f1, color: tcol, in: ctx)
                draw(layer.text2.uppercased(), at: CGPoint(x: x + 44, y: y + barH * 0.13), font: f2, color: acc, in: ctx)
            default: // accent strip (classic)
                ctx.setFillColor(acc.cgColor)
                ctx.fill(CGRect(x: x, y: y, width: 10, height: barH))
                ctx.setFillColor(bg.cgColor)
                ctx.fill(CGRect(x: x + 10, y: y, width: barW, height: barH))
                draw(layer.text1, at: CGPoint(x: x + 34, y: y + barH * 0.46), font: f1, color: tcol, in: ctx)
                draw(layer.text2.uppercased(), at: CGPoint(x: x + 34, y: y + barH * 0.13), font: f2, color: acc, in: ctx)
            }

        case .ticker:
            let barH = H * 0.07
            let y = -barH + barH * k
            ctx.setFillColor(NSColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 0.92 * k).cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: W, height: barH))
            ctx.setAlpha(k)
            let font = NSFont.boldSystemFont(ofSize: barH * 0.5)
            let tw = max(1, textWidth(layer.text1, font: font))
            let speed = CGFloat(max(10, layer.number1))
            var x = W - CGFloat(time).truncatingRemainder(dividingBy: (tw + W) / speed) * speed
            if x < -tw { x += tw + W }
            draw(layer.text1, at: CGPoint(x: x, y: y + barH * 0.22), font: font, color: .white, in: ctx)
            if x + tw < W {
                draw(layer.text1, at: CGPoint(x: x + tw, y: y + barH * 0.22), font: font, color: .white, in: ctx)
            }

        case .countdown:
            ctx.setAlpha(k)
            CountdownRenderer.draw(layer, in: ctx, W: W, H: H, time: time)

        case .clock:
            let date = Date(); let cal = Calendar.current
            var hour = cal.component(.hour, from: date)
            let minute = cal.component(.minute, from: date)
            var suffix = ""
            if !layer.use24h {
                suffix = hour >= 12 ? " PM" : " AM"; hour = hour % 12; if hour == 0 { hour = 12 }
            }
            let str = String(format: "%02d:%02d%@", hour, minute, suffix)
            ctx.setAlpha(k)
            ctx.setFillColor(NSColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 0.8).cgColor)
            ctx.fill(CGRect(x: W - 230, y: H - 86, width: 200, height: 58))
            draw(str, at: CGPoint(x: W - 130, y: H - 72),
                 font: NSFont.monospacedDigitSystemFont(ofSize: H * 0.04, weight: .bold),
                 color: .white, in: ctx, centered: true)

        case .scoreboard:
            let y = H + 70 - 168 * k
            let cx = W / 2
            ctx.setFillColor(NSColor(layer.accent).cgColor)
            ctx.fill(CGRect(x: cx - 330, y: y, width: 250, height: 56))
            ctx.setFillColor(NSColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 0.92).cgColor)
            ctx.fill(CGRect(x: cx - 80, y: y, width: 160, height: 56))
            ctx.setFillColor(NSColor(red: 1, green: 0.23, blue: 0.23, alpha: 1).cgColor)
            ctx.fill(CGRect(x: cx + 80, y: y, width: 250, height: 56))
            let f = NSFont.boldSystemFont(ofSize: H * 0.036)
            draw(layer.text1.uppercased(), at: CGPoint(x: cx - 205, y: y + 14), font: f, color: .white, in: ctx, centered: true)
            draw(layer.text2.uppercased(), at: CGPoint(x: cx + 205, y: y + 14), font: f, color: .white, in: ctx, centered: true)
            draw("\(layer.scoreA) : \(layer.scoreB)", at: CGPoint(x: cx, y: y + 12),
                 font: NSFont.monospacedDigitSystemFont(ofSize: H * 0.042, weight: .heavy),
                 color: .white, in: ctx, centered: true)

        case .title:
            ctx.setAlpha(k)
            let size = H * CGFloat(max(2, layer.number1)) / 100
            let tf = NSFont.boldSystemFont(ofSize: size)
            let hasSub = !layer.text2.isEmpty
            let subF = NSFont.systemFont(ofSize: size * 0.44, weight: .medium)
            let col = NSColor(layer.accent)
            let tcol = NSColor(layer.textColor)
            let w1 = textWidth(layer.text1, font: tf)
            let w2 = hasSub ? textWidth(layer.text2, font: subF) : 0
            let blockW = max(w1, w2)
            let gap: CGFloat = hasSub ? size * 0.55 : 0
            let mainY = H * 0.5 + gap * 0.5 - size * 0.35 - (1 - k) * 30
            let subY = mainY - gap
            func xFor(_ w: CGFloat) -> CGFloat {
                switch layer.align { case 0: return 90; case 2: return W - 90 - w; default: return (W - w) / 2 }
            }
            if layer.bgOpacity > 0.01 {
                let padX: CGFloat = size * 0.45, padY: CGFloat = size * 0.32
                let bx = xFor(blockW)
                let top = mainY + size + padY
                let bot = (hasSub ? subY : mainY) - padY
                ctx.setFillColor(NSColor(layer.bgColor).withAlphaComponent(layer.bgOpacity).cgColor)
                ctx.fill(CGRect(x: bx - padX, y: bot, width: blockW + padX * 2, height: top - bot))
            }
            ctx.setShadow(offset: .zero, blur: 14, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            draw(layer.text1, at: CGPoint(x: xFor(w1), y: mainY), font: tf, color: col, in: ctx)
            if hasSub { draw(layer.text2, at: CGPoint(x: xFor(w2), y: subY), font: subF, color: tcol, in: ctx) }

        case .logo:
            if let img = layer.logoImage {
                ctx.setAlpha(k)
                let w = W * CGFloat(max(2, layer.number1)) / 100
                let h = w * CGFloat(img.height) / CGFloat(img.width)
                let m: CGFloat = 30
                let origins: [CGPoint] = [
                    CGPoint(x: m, y: H - h - m), CGPoint(x: W - w - m, y: H - h - m),
                    CGPoint(x: m, y: m), CGPoint(x: W - w - m, y: m)]
                let p = origins[min(max(layer.position, 0), 3)]
                ctx.draw(img, in: CGRect(x: p.x, y: p.y, width: w, height: h))
            }

        case .qrcode:
            if layer.qrCachedText != layer.text1 || layer.qrCache == nil {
                layer.qrCachedText = layer.text1
                layer.qrCache = Self.makeQR(layer.text1)
            }
            if let qr = layer.qrCache {
                let s = CGFloat(max(60, layer.number1)); let pad: CGFloat = 12
                let x = W - s - 40, y: CGFloat = 40
                ctx.setAlpha(k)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: x - pad, y: y - pad, width: s + pad * 2, height: s + pad * 2))
                ctx.interpolationQuality = .none
                ctx.draw(qr, in: CGRect(x: x, y: y, width: s, height: s))
            }

        case .pip:
            guard let ref = layer.sourceRef, let base = sourceImage(ref) else { break }
            let img = layer.keyEnabled
                ? (ChromaKey.apply(base, keyColor: NSColor(layer.keyColor),
                                   similarity: layer.keySimilarity, smoothness: layer.keySmoothness) ?? base)
                : base
            ctx.setAlpha(k)
            let w = W * CGFloat(max(8, layer.number1)) / 100
            let h = w * CGFloat(img.height) / CGFloat(img.width)
            let m: CGFloat = 36
            let origins: [CGPoint] = [
                CGPoint(x: m, y: H - h - m), CGPoint(x: W - w - m, y: H - h - m),
                CGPoint(x: m, y: m), CGPoint(x: W - w - m, y: m)]
            let p = origins[min(max(layer.position, 0), 3)]
            let rect = CGRect(x: p.x, y: p.y, width: w, height: h)
            if !layer.keyEnabled {
                ctx.setFillColor(NSColor(layer.accent).cgColor)
                ctx.fill(rect.insetBy(dx: -4, dy: -4))
            }
            coverDraw(img, in: rect, ctx: ctx)

        case .definition:
            ctx.setAlpha(k)
            let panelH = H * CGFloat(max(3, layer.number1)) / 100 * 5   // ~30% at number1=6
            let ph = min(H, max(H * 0.28, panelH))
            let rect = CGRect(x: 0, y: 0, width: W, height: ph)
            if let cg = LayerRenderer.definitionImage(word: layer.text1, def: layer.text2,
                                                      size: CGSize(width: W, height: ph),
                                                      bg: NSColor(layer.bgColor).withAlphaComponent(layer.bgOpacity),
                                                      accent: NSColor(layer.accent)) {
                ctx.draw(cg, in: rect)
            }
        }
        ctx.restoreGState()
    }

    /// Renders a dictionary panel (bold word + wrapped definition) to a CGImage.
    static func definitionImage(word: String, def: String, size: CGSize, bg: NSColor, accent: NSColor) -> CGImage? {
        let img = NSImage(size: size)
        img.lockFocus()
        bg.setFill(); NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        // accent bar
        accent.setFill(); NSBezierPath(rect: CGRect(x: 0, y: size.height - 8, width: size.width, height: 8)).fill()
        let pad: CGFloat = size.height * 0.12
        let wordFont = NSFont.boldSystemFont(ofSize: size.height * 0.24)
        let wordAttr: [NSAttributedString.Key: Any] = [.font: wordFont, .foregroundColor: accent]
        let wordStr = NSAttributedString(string: word, attributes: wordAttr)
        let wordH = wordStr.size().height
        wordStr.draw(at: CGPoint(x: pad, y: size.height - pad - wordH))
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping; para.alignment = .left
        let defFont = NSFont.systemFont(ofSize: size.height * 0.11, weight: .regular)
        let defAttr: [NSAttributedString.Key: Any] = [.font: defFont, .foregroundColor: NSColor.white, .paragraphStyle: para]
        let defRect = CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2 - wordH - pad * 0.6)
        NSAttributedString(string: def, attributes: defAttr).draw(in: defRect)
        img.unlockFocus()
        var rect = CGRect(origin: .zero, size: size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func makeQR(_ text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return sharedCIContext.createCGImage(scaled, from: scaled.extent)
    }
}

// MARK: - Save / Load model

struct LayerVariant: Codable, Identifiable {
    var id = UUID()
    var name: String
    var text1: String, text2: String
    var aR: Double, aG: Double, aB: Double, aA: Double
    var number1: Double, scoreA: Int, scoreB: Int
    var position: Int, style: Int
}

struct ShowLayer: Codable {
    var kind: String, name: String, isLive: Bool
    var text1: String, text2: String
    var aR: Double, aG: Double, aB: Double, aA: Double
    var number1: Double, scoreA: Int, scoreB: Int
    var position: Int, use24h: Bool, style: Int
    var variants: [LayerVariant] = []
    var opacity: Double = 1
    var offsetX: Double = 0, offsetY: Double = 0
    var scaleAdj: Double = 1, rotationAdj: Double = 0
    var textR: Double = 1, textG: Double = 1, textB: Double = 1
    var bgR: Double = 0.04, bgG: Double = 0.05, bgB: Double = 0.06, bgOpacity: Double = 0.88
    var fontScale: Double = 1, align: Int = 0
    var keyEnabled: Bool = false
    var keyR: Double = 0, keyG: Double = 0.78, keyB: Double = 0
    var keySimilarity: Double = 0.12, keySmoothness: Double = 0.08
    var countdown: CountdownStyle? = nil
}

struct ShowScene: Codable {
    var name: String
    var layout: Int
    var slots: [Int]
    var gridCount: Int = 4
}

struct ShowFile: Codable {
    var width: Int, height: Int
    var layers: [ShowLayer]
    var layout: Int = 0
    var slots: [Int] = []
    var gridCount: Int = 4
    var scenes: [ShowScene] = []
}

extension Color {
    func rgbaComponents() -> (Double, Double, Double, Double) {
        let n = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        return (Double(n.redComponent), Double(n.greenComponent),
                Double(n.blueComponent), Double(n.alphaComponent))
    }
}

extension Layer {
    func toShowLayer() -> ShowLayer {
        let c = accent.rgbaComponents()
        let tc = textColor.rgbaComponents()
        let bc = bgColor.rgbaComponents()
        let kc = keyColor.rgbaComponents()
        return ShowLayer(kind: kind.rawValue, name: name, isLive: isLive,
                         text1: text1, text2: text2,
                         aR: c.0, aG: c.1, aB: c.2, aA: c.3,
                         number1: number1, scoreA: scoreA, scoreB: scoreB,
                         position: position, use24h: use24h, style: style,
                         variants: variants,
                         opacity: opacity, offsetX: offsetX, offsetY: offsetY,
                         scaleAdj: scaleAdj, rotationAdj: rotationAdj,
                         textR: tc.0, textG: tc.1, textB: tc.2,
                         bgR: bc.0, bgG: bc.1, bgB: bc.2, bgOpacity: bgOpacity,
                         fontScale: fontScale, align: align,
                         keyEnabled: keyEnabled, keyR: kc.0, keyG: kc.1, keyB: kc.2,
                         keySimilarity: keySimilarity, keySmoothness: keySmoothness,
                         countdown: kind == .countdown ? cd : nil)
    }

    static func from(_ s: ShowLayer) -> Layer? {
        guard let kind = Kind(rawValue: s.kind) else { return nil }
        let l = Layer(kind: kind)
        l.name = s.name; l.isLive = s.isLive; l.text1 = s.text1; l.text2 = s.text2
        l.accent = Color(.sRGB, red: s.aR, green: s.aG, blue: s.aB, opacity: s.aA)
        l.number1 = s.number1; l.scoreA = s.scoreA; l.scoreB = s.scoreB
        l.position = s.position; l.use24h = s.use24h; l.style = s.style
        l.variants = s.variants
        l.opacity = s.opacity; l.offsetX = s.offsetX; l.offsetY = s.offsetY
        l.scaleAdj = s.scaleAdj; l.rotationAdj = s.rotationAdj
        l.textColor = Color(.sRGB, red: s.textR, green: s.textG, blue: s.textB, opacity: 1)
        l.bgColor = Color(.sRGB, red: s.bgR, green: s.bgG, blue: s.bgB, opacity: 1)
        l.bgOpacity = s.bgOpacity; l.fontScale = s.fontScale; l.align = s.align
        l.keyEnabled = s.keyEnabled
        l.keyColor = Color(.sRGB, red: s.keyR, green: s.keyG, blue: s.keyB, opacity: 1)
        l.keySimilarity = s.keySimilarity; l.keySmoothness = s.keySmoothness
        if kind == .countdown { l.remaining = s.number1 * 60; if let c = s.countdown { l.cd = c } }
        return l
    }
}

// MARK: - Overlay templates (one-click presets)

struct OverlayTemplate: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let make: () -> Layer

    static let all: [OverlayTemplate] = [
        OverlayTemplate(name: "News — accent strip", icon: "rectangle.bottomthird.inset.filled") {
            let l = Layer(kind: .lowerThird); l.name = "News"; l.style = 0; l.align = 0
            l.accent = Color(red: 0.85, green: 0.12, blue: 0.12)
            l.text1 = "John Smith"; l.text2 = "Reporting Live"; return l
        },
        OverlayTemplate(name: "Speaker — two-tone", icon: "person.crop.rectangle") {
            let l = Layer(kind: .lowerThird); l.name = "Speaker"; l.style = 3; l.align = 0
            l.accent = Color(red: 0.12, green: 0.45, blue: 0.95)
            l.text1 = "Jane Doe"; l.text2 = "Keynote"; return l
        },
        OverlayTemplate(name: "Social handle — pill", icon: "at") {
            let l = Layer(kind: .lowerThird); l.name = "Social"; l.style = 6; l.align = 2
            l.accent = Color(red: 0.55, green: 0.27, blue: 0.95)
            l.text1 = "@yourhandle"; l.text2 = "Follow us"; return l
        },
        OverlayTemplate(name: "Breaking — tab header", icon: "exclamationmark.bubble") {
            let l = Layer(kind: .lowerThird); l.name = "Breaking"; l.style = 4; l.align = 0
            l.accent = Color(red: 0.85, green: 0.10, blue: 0.10)
            l.text1 = "Breaking News"; l.text2 = "Live"; return l
        },
        OverlayTemplate(name: "Caption — outline", icon: "captions.bubble") {
            let l = Layer(kind: .lowerThird); l.name = "Caption"; l.style = 5; l.align = 1
            l.accent = Color(red: 1.0, green: 0.78, blue: 0.0)
            l.text1 = "Caption text goes here"; l.text2 = ""; return l
        },
        OverlayTemplate(name: "Sermon — boxed", icon: "book.closed") {
            let l = Layer(kind: .lowerThird); l.name = "Sermon"; l.style = 1; l.align = 0
            l.accent = Color(red: 0.95, green: 0.72, blue: 0.18)
            l.text1 = "The Power of Faith"; l.text2 = "Today's Message"; return l
        },
        OverlayTemplate(name: "Title card — centred", icon: "textformat") {
            let l = Layer(kind: .title); l.name = "Title"; l.align = 1; l.number1 = 9
            l.accent = .white; l.text1 = "Welcome"; return l
        },
        OverlayTemplate(name: "Title + subtitle", icon: "textformat.size") {
            let l = Layer(kind: .title); l.name = "Title+Sub"; l.align = 1; l.number1 = 8
            l.accent = .white; l.textColor = Color(white: 0.75)
            l.text1 = "Main Title"; l.text2 = "Subtitle goes here"; return l
        },
        OverlayTemplate(name: "Announcement box", icon: "megaphone") {
            let l = Layer(kind: .title); l.name = "Announcement"; l.align = 1; l.number1 = 6
            l.accent = .white; l.bgColor = Color(red: 0.10, green: 0.12, blue: 0.16); l.bgOpacity = 0.8
            l.text1 = "Service starts at 9:00 AM"; return l
        },
        OverlayTemplate(name: "Quote — centred", icon: "quote.bubble") {
            let l = Layer(kind: .title); l.name = "Quote"; l.align = 1; l.number1 = 7
            l.accent = .white; l.textColor = Color(white: 0.7)
            l.text1 = "“Faith is taking the first step.”"; l.text2 = "— Author"; return l
        },
        OverlayTemplate(name: "Credits — left", icon: "list.bullet.rectangle") {
            let l = Layer(kind: .title); l.name = "Credits"; l.align = 0; l.number1 = 5
            l.accent = .white; l.textColor = Color(white: 0.7)
            l.text1 = "Produced by"; l.text2 = "Your Ministry Media Team"; return l
        },
        OverlayTemplate(name: "Now speaking", icon: "person.wave.2") {
            let l = Layer(kind: .lowerThird); l.name = "Now speaking"; l.style = 3; l.align = 0
            l.accent = Color(red: 0.90, green: 0.55, blue: 0.10)
            l.text1 = "Speaker Name"; l.text2 = "Now Speaking"; return l
        },
        OverlayTemplate(name: "Scripture — minimal", icon: "text.alignleft") {
            let l = Layer(kind: .lowerThird); l.name = "Scripture"; l.style = 2; l.align = 0
            l.accent = Color(red: 0.2, green: 0.7, blue: 0.5)
            l.text1 = "John 3:16"; l.text2 = "Holy Bible"; return l
        }
    ]
}

// MARK: - Chroma key (Core Image colour cube; GPU accelerated)

enum ChromaKey {
    private static var cubeCache: (key: String, data: Data)?
    private static let dim = 64

    static func apply(_ image: CGImage, keyColor: NSColor, similarity: Double, smoothness: Double) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let data = cubeData(keyColor: keyColor, similarity: similarity, smoothness: smoothness)
        guard let f = CIFilter(name: "CIColorCube") else { return image }
        f.setValue(dim, forKey: "inputCubeDimension")
        f.setValue(data, forKey: "inputCubeData")
        f.setValue(ci, forKey: kCIInputImageKey)
        guard let out = f.outputImage,
              let cg = sharedCIContext.createCGImage(out, from: ci.extent) else { return image }
        return cg
    }

    private static func cubeData(keyColor: NSColor, similarity: Double, smoothness: Double) -> Data {
        let kc = keyColor.usingColorSpace(.sRGB) ?? keyColor
        let key = String(format: "%.3f-%.3f-%.3f-%.3f-%.3f",
                         kc.redComponent, kc.greenComponent, kc.blueComponent, similarity, smoothness)
        if let c = cubeCache, c.key == key { return c.data }
        let (kh, _, _) = rgb2hsv(Float(kc.redComponent), Float(kc.greenComponent), Float(kc.blueComponent))
        let sim = Float(max(0.01, similarity))
        let smooth = Float(max(0.001, smoothness))
        var cube = [Float](repeating: 0, count: dim * dim * dim * 4)
        var offset = 0
        for b in 0..<dim {
            for g in 0..<dim {
                for r in 0..<dim {
                    let rr = Float(r) / Float(dim - 1)
                    let gg = Float(g) / Float(dim - 1)
                    let bb = Float(b) / Float(dim - 1)
                    let (h, s, v) = rgb2hsv(rr, gg, bb)
                    var alpha: Float = 1
                    if s > 0.15 && v > 0.15 {
                        var dh = abs(h - kh); if dh > 0.5 { dh = 1 - dh }
                        alpha = min(1, max(0, (dh - sim) / smooth))
                    }
                    cube[offset + 0] = rr * alpha
                    cube[offset + 1] = gg * alpha
                    cube[offset + 2] = bb * alpha
                    cube[offset + 3] = alpha
                    offset += 4
                }
            }
        }
        let data = Data(bytes: cube, count: cube.count * MemoryLayout<Float>.size)
        cubeCache = (key, data)
        return data
    }

    private static func rgb2hsv(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h: Float = 0
        if d != 0 {
            if mx == r { h = (g - b) / d }
            else if mx == g { h = 2 + (b - r) / d }
            else { h = 4 + (r - g) / d }
            h /= 6; if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
}


// MARK: - Countdown drawing (stacked, measured layout — the label never overlaps the digits)

enum CountdownRenderer {
    static func font(_ choice: CountdownFont, size: CGFloat, weight: Int, digits: Bool) -> NSFont {
        let w: NSFont.Weight = [.regular, .semibold, .bold, .heavy, .black][min(4, max(0, weight))]
        var f: NSFont
        switch choice {
        case .condensed: f = NSFont.systemFont(ofSize: size, weight: w, width: .condensed)
        case .mono: f = NSFont.monospacedSystemFont(ofSize: size, weight: w)
        default: f = NSFont.systemFont(ofSize: size, weight: w)
        }
        let design: NSFontDescriptor.SystemDesign? = choice == .rounded ? .rounded : (choice == .serif ? .serif : nil)
        if let design, let d = f.fontDescriptor.withDesign(design), let nf = NSFont(descriptor: d, size: size) { f = nf }
        if digits && choice != .mono {
            let features: [[NSFontDescriptor.FeatureKey: Int]] = [[.typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector]]
            let d = f.fontDescriptor.addingAttributes([.featureSettings: features])
            if let nf = NSFont(descriptor: d, size: size) { f = nf }
        }
        return f
    }

    private struct Item { let text: NSAttributedString; let size: CGSize }

    static func draw(_ layer: Layer, in ctx: CGContext, W: CGFloat, H: CGFloat, time: CFTimeInterval) {
        let st = layer.cd
        let scale = CGFloat(max(0.3, layer.fontScale))
        let state = CountdownClock.state(seconds: layer.displaySeconds, style: st)
        let digitsColor: NSColor
        let digitsText: String
        var blinking = false
        let warn = NSColor(srgbRed: CGFloat(st.warnRGB.count > 0 ? st.warnRGB[0] : 1), green: CGFloat(st.warnRGB.count > 1 ? st.warnRGB[1] : 0.27),
                           blue: CGFloat(st.warnRGB.count > 2 ? st.warnRGB[2] : 0.23), alpha: 1)
        switch state {
        case .running(let s): digitsText = s; digitsColor = NSColor(layer.textColor)
        case .warning(let s):
            digitsText = s; digitsColor = warn
            blinking = st.flash && st.mode != .countUp && layer.displaySeconds <= st.flashSeconds
        case .ended(let s): digitsText = s; digitsColor = st.endBehavior == .endText ? NSColor(layer.textColor) : warn; blinking = st.flash && st.endBehavior != .endText
        case .overtime(let s): digitsText = s; digitsColor = warn
        }
        var isEndText = false
        if case .ended = state, st.endBehavior == .endText { isEndText = true }
        let kern = CGFloat(st.letterSpacing) * H * 0.002

        let digitsFont = font(st.font, size: H * (isEndText ? 0.085 : 0.14) * CGFloat(st.digitsScale) * scale, weight: st.weight, digits: true)
        let labelFont = font(st.font, size: H * 0.034 * CGFloat(st.labelScale) * scale, weight: max(1, st.weight - 1), digits: false)
        let subFont = font(st.font, size: H * 0.026 * CGFloat(st.labelScale) * scale, weight: 0, digits: false)

        func item(_ s: String, _ f: NSFont, _ c: NSColor) -> Item? {
            guard !s.isEmpty else { return nil }
            let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .kern: kern])
            let r = a.boundingRect(with: CGSize(width: 10000, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading])
            return Item(text: a, size: CGSize(width: ceil(r.width), height: ceil(r.height)))
        }
        let labelString = st.uppercaseLabel ? layer.text1.uppercased() : layer.text1
        let label = st.labelPosition == .hidden ? nil : item(labelString, labelFont, NSColor(layer.accent))
        let digits = item(digitsText, digitsFont, blinking && Int(time * 2) % 2 == 1 ? digitsColor.withAlphaComponent(0.25) : digitsColor)
        let sub = st.showSubtext ? item(layer.text2, subFont, NSColor(layer.textColor).withAlphaComponent(0.8)) : nil
        guard let digitsItem = digits else { return }

        let gap = H * 0.012 * CGFloat(st.padding)
        let padY = H * 0.028 * CGFloat(st.padding)
        let padX = padY * 1.6
        let inline = st.labelPosition == .left && label != nil
        var rows: [[Item]] = []
        if inline { rows.append([label!, digitsItem]) }
        else if st.labelPosition == .below { rows.append([digitsItem]); if let l = label { rows.append([l]) } }
        else { if let l = label { rows.append([l]) }; rows.append([digitsItem]) }
        if let s = sub { rows.append([s]) }

        let rowSizes = rows.map { r -> CGSize in
            CGSize(width: r.map { $0.size.width }.reduce(0, +) + CGFloat(max(0, r.count - 1)) * gap * 2,
                   height: r.map { $0.size.height }.max() ?? 0)
        }
        let contentW = rowSizes.map { $0.width }.max() ?? 0
        let contentH = rowSizes.map { $0.height }.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * gap
        let boxW = contentW + padX * 2, boxH = contentH + padY * 2
        let margin = H * 0.06
        let cx: CGFloat, cy: CGFloat
        switch st.placement {
        case .center: cx = W / 2; cy = H / 2
        case .top: cx = W / 2; cy = H - margin - boxH / 2
        case .bottom: cx = W / 2; cy = margin + boxH / 2
        case .topLeft: cx = margin + boxW / 2; cy = H - margin - boxH / 2
        case .topRight: cx = W - margin - boxW / 2; cy = H - margin - boxH / 2
        case .bottomLeft: cx = margin + boxW / 2; cy = margin + boxH / 2
        case .bottomRight: cx = W - margin - boxW / 2; cy = margin + boxH / 2
        }
        let box = CGRect(x: cx - boxW / 2, y: cy - boxH / 2, width: boxW, height: boxH)

        let bg = NSColor(layer.bgColor).withAlphaComponent(CGFloat(layer.bgOpacity))
        switch st.box {
        case .box:
            ctx.setFillColor(bg.cgColor); ctx.fill(box)
        case .rounded, .pill:
            let r = st.box == .pill ? boxH / 2 : H * 0.018
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: min(r, boxW / 2), cornerHeight: min(r, boxH / 2), transform: nil))
            ctx.setFillColor(bg.cgColor); ctx.fillPath()
        case .outline:
            let r = H * 0.018
            ctx.addPath(CGPath(roundedRect: box.insetBy(dx: 2, dy: 2), cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.setStrokeColor(NSColor(layer.accent).cgColor); ctx.setLineWidth(max(2, H * 0.004)); ctx.strokePath()
        case .none:
            break
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        if st.shadow {
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(st.box == .none ? 0.8 : 0.45)
            sh.shadowBlurRadius = H * 0.008
            sh.shadowOffset = NSSize(width: 0, height: -H * 0.002)
            sh.set()
        }
        var top = box.maxY - padY
        for (i, row) in rows.enumerated() {
            let rs = rowSizes[i]
            var x = cx - rs.width / 2
            for it in row {
                // vertically centre each item in its row
                let y = top - rs.height + (rs.height - it.size.height) / 2
                it.text.draw(with: CGRect(x: x, y: y, width: it.size.width + 2, height: it.size.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
                x += it.size.width + gap * 2
            }
            top -= rs.height + gap
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
