import SwiftUI
import AppKit
import AVFoundation
import QuartzCore
import PresentationKit

// MARK: - Renderer (Core Graphics, seamless loops)

enum GeneratorRenderer {
    static let space = CGColorSpaceCreateDeviceRGB()

    static func cg(_ c: RGBAColor, _ alpha: Double = 1) -> CGColor {
        CGColor(colorSpace: space, components: [CGFloat(c.r), CGFloat(c.g), CGFloat(c.b), CGFloat(c.a * alpha)]) ?? CGColor(gray: 1, alpha: 1)
    }

    /// Draws one frame at time `t` (seconds). Every motion repeats exactly after `settings.loopSeconds`.
    /// Coordinates: bottom-left origin (Core Graphics).
    static func draw(_ s: GeneratorSettings, t: Double, in ctx: CGContext, size: CGSize) {
        let W = size.width, H = size.height
        let loop = max(2, s.loopSeconds)
        let phase = (t.truncatingRemainder(dividingBy: loop)) / loop                 // 0 … 1
        let cycles = max(1, (s.speed * loop / 10).rounded())                          // whole cycles per loop
        let theta = 2 * Double.pi * phase * cycles
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        let density = min(max(s.density, 0), 1)
        let sz = min(max(s.size, 0.2), 3)
        func h(_ i: Int, _ salt: Int) -> Double { GeneratorSettings.hash(i, salt, s.seed) }
        func fract(_ x: Double) -> Double { x - floor(x) }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        if !s.transparent && !s.style.isEffect {
            ctx.setFillColor(cg(s.background)); ctx.fill(rect)
        }

        switch s.style {
        case .gradientFlow:
            for i in 0..<3 {
                let cx = W * CGFloat(0.5 + 0.35 * sin(theta + Double(i) * 2.1))
                let cy = H * CGFloat(0.5 + 0.30 * cos(theta * (i == 1 ? 2 : 1) + Double(i) * 1.3))
                radial(ctx, CGPoint(x: cx, y: cy), max(W, H) * CGFloat(0.65 * sz), s.color(i), 0.85, soft: s.softness)
            }
        case .aurora:
            ctx.setBlendMode(.screen)
            for i in 0..<6 {
                let c = s.color(i)
                let base = H * CGFloat(0.35 + 0.08 * Double(i % 3))
                let amp = H * CGFloat(0.10 + 0.05 * h(i, 1)) * CGFloat(sz)
                let path = CGMutablePath()
                let steps = 48
                for k in 0...steps {
                    let x = W * CGFloat(k) / CGFloat(steps)
                    let y = base + amp * CGFloat(sin(Double(k) / Double(steps) * 2 * .pi * (1 + Double(i % 2)) + theta * (i % 2 == 0 ? 1 : -1) + Double(i)))
                    if k == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                for (w, a) in [(0.22, 0.06), (0.12, 0.10), (0.05, 0.16)] {
                    ctx.addPath(path)
                    ctx.setLineWidth(H * CGFloat(w * sz * (0.6 + s.softness)))
                    ctx.setLineCap(.round)
                    ctx.setStrokeColor(cg(c, a))
                    ctx.strokePath()
                }
            }
        case .bokeh:
            let n = 18 + Int(density * 60)
            for i in 0..<n {
                let dir: Double = h(i, 3) > 0.5 ? 1 : -1
                let x = fract(h(i, 1) + phase * dir)
                let y = h(i, 2) + 0.04 * sin(theta + Double(i))
                let r = H * CGFloat(0.02 + 0.07 * h(i, 4)) * CGFloat(sz)
                let pulse = 0.25 + 0.2 * (0.5 + 0.5 * sin(theta * (1 + Double(i % 3)) + Double(i)))
                radial(ctx, CGPoint(x: W * CGFloat(x), y: H * CGFloat(y)), r, s.color(i), pulse, soft: s.softness * 0.6)
            }
        case .lightRays:
            radial(ctx, CGPoint(x: W / 2, y: H * 1.05), H * 0.9 * CGFloat(sz), s.color(0), 0.45, soft: 0.8)
            let n = 8 + Int(density * 16)
            let origin = CGPoint(x: W / 2, y: H * 1.1)
            ctx.setBlendMode(.screen)
            for i in 0..<n {
                let base = -Double.pi / 2 + (Double(i) / Double(n) - 0.5) * 2.2
                let a = base + 0.06 * sin(theta + Double(i) * 1.7)
                let spread = 0.03 + 0.05 * h(i, 5)
                let len = Double(max(W, H)) * 1.6
                let p = CGMutablePath()
                p.move(to: origin)
                p.addLine(to: CGPoint(x: origin.x + CGFloat(cos(a - spread) * len), y: origin.y + CGFloat(sin(a - spread) * len)))
                p.addLine(to: CGPoint(x: origin.x + CGFloat(cos(a + spread) * len), y: origin.y + CGFloat(sin(a + spread) * len)))
                p.closeSubpath()
                let alpha = 0.10 + 0.10 * (0.5 + 0.5 * sin(theta * (1 + Double(i % 2)) + Double(i)))
                ctx.saveGState()
                ctx.addPath(p); ctx.clip()
                if let g = CGGradient(colorsSpace: space, colors: [cg(s.color(i), alpha), cg(s.color(i), 0)] as CFArray, locations: [0, 1]) {
                    ctx.drawLinearGradient(g, start: origin, end: CGPoint(x: W / 2, y: 0), options: [])
                }
                ctx.restoreGState()
            }
        case .starfield:
            let n = 150 + Int(density * 400)
            for i in 0..<n {
                let drift = h(i, 6) > 0.7 ? 1.0 : 0.0
                let x = fract(h(i, 1) + phase * drift)
                let y = h(i, 2)
                let tw = 0.35 + 0.65 * (0.5 + 0.5 * sin(theta * (1 + Double(i % 4)) + h(i, 3) * 6.28))
                let r = CGFloat(0.4 + 1.8 * h(i, 4) * h(i, 4)) * CGFloat(sz) * H / 1080
                ctx.setFillColor(cg(s.color(i), tw))
                ctx.fillEllipse(in: CGRect(x: W * CGFloat(x) - r, y: H * CGFloat(y) - r, width: r * 2, height: r * 2))
            }
        case .waves:
            for i in 0..<4 {
                let path = CGMutablePath()
                let baseY = H * CGFloat(0.55 - 0.12 * Double(i))
                let amp = H * CGFloat(0.05 + 0.03 * Double(i)) * CGFloat(sz)
                let freq = 1.0 + Double(i) * 0.5
                path.move(to: CGPoint(x: 0, y: 0))
                let steps = 64
                for k in 0...steps {
                    let x = W * CGFloat(k) / CGFloat(steps)
                    let y = baseY + amp * CGFloat(sin(Double(k) / Double(steps) * 2 * .pi * freq + theta * (i % 2 == 0 ? 1 : -1) + Double(i)))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: W, y: 0)); path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(cg(s.color(i), 0.35 + 0.1 * Double(i)))
                ctx.fillPath()
            }
        case .rings:
            let n = 4 + Int(density * 8)
            let maxR = max(W, H) * 0.75 * CGFloat(sz)
            let c = CGPoint(x: W / 2, y: H / 2)
            for k in 0..<n {
                let f = fract(phase * cycles + Double(k) / Double(n))
                let r = maxR * CGFloat(f)
                ctx.setStrokeColor(cg(s.color(k), (1 - f) * 0.7))
                ctx.setLineWidth(H * CGFloat(0.004 + 0.02 * (1 - f)) * CGFloat(0.5 + s.softness))
                ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            radial(ctx, c, maxR * 0.35, s.color(0), 0.35, soft: 0.9)
        case .grid:
            let horizon = H * 0.42
            radial(ctx, CGPoint(x: W / 2, y: horizon + H * 0.12), H * 0.35 * CGFloat(sz), s.color(1), 0.8, soft: 0.5)
            ctx.setStrokeColor(cg(s.color(0), 0.8))
            ctx.setLineWidth(max(1, H / 540))
            let lines = 10 + Int(density * 20)
            for i in -lines...lines {
                let x = W / 2 + CGFloat(i) * W / CGFloat(lines) * 1.4
                ctx.move(to: CGPoint(x: W / 2 + CGFloat(i) * W * 0.02, y: horizon))
                ctx.addLine(to: CGPoint(x: x, y: 0))
            }
            let rows = 12
            for k in 0..<rows {
                let z = fract(Double(k) / Double(rows) + phase * cycles)
                let y = horizon * CGFloat(pow(1 - z, 2.2))
                ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y))
            }
            ctx.strokePath()
        case .particles:
            let n = 30 + Int(density * 120)
            for i in 0..<n {
                let speedMul = 1.0 + floor(h(i, 3) * 2)
                let y = fract(h(i, 2) + phase * speedMul)
                let x = h(i, 1) + 0.02 * sin(theta * speedMul + Double(i))
                let fade = min(1, y * 4) * min(1, (1 - y) * 3)
                let r = H * CGFloat(0.002 + 0.006 * h(i, 4)) * CGFloat(sz)
                radial(ctx, CGPoint(x: W * CGFloat(x), y: H * CGFloat(y)), r * 4, s.color(i), 0.5 * fade, soft: 0.3)
                ctx.setFillColor(cg(s.color(i), fade))
                ctx.fillEllipse(in: CGRect(x: W * CGFloat(x) - r, y: H * CGFloat(y) - r, width: r * 2, height: r * 2))
            }
        case .snow:
            let n = 60 + Int(density * 260)
            for i in 0..<n {
                let speedMul = 1.0 + floor(h(i, 3) * 2)
                let y = 1 - fract(h(i, 2) + phase * speedMul)
                let x = fract(h(i, 1) + 0.03 * sin(theta * speedMul + Double(i)))
                let r = CGFloat(1 + 3.5 * h(i, 4)) * CGFloat(sz) * H / 1080
                ctx.setFillColor(cg(s.color(i), 0.55 + 0.4 * h(i, 5)))
                ctx.fillEllipse(in: CGRect(x: W * CGFloat(x) - r, y: H * CGFloat(y) - r, width: r * 2, height: r * 2))
            }
        case .confetti:
            let n = 40 + Int(density * 160)
            for i in 0..<n {
                let speedMul = 1.0 + floor(h(i, 3) * 3)
                let y = 1 - fract(h(i, 2) + phase * speedMul)
                let x = fract(h(i, 1) + 0.04 * sin(theta * speedMul + Double(i)))
                let w = H * CGFloat(0.006 + 0.008 * h(i, 4)) * CGFloat(sz)
                ctx.saveGState()
                ctx.translateBy(x: W * CGFloat(x), y: H * CGFloat(y))
                ctx.rotate(by: CGFloat(theta * speedMul + h(i, 6) * 6.28))
                ctx.scaleBy(x: 1, y: CGFloat(0.3 + 0.7 * abs(cos(theta * speedMul * 2 + Double(i)))))
                ctx.setFillColor(cg(s.color(i)))
                ctx.fill(CGRect(x: -w, y: -w * 0.6, width: w * 2, height: w * 1.2))
                ctx.restoreGState()
            }
        case .sparkles:
            let n = 12 + Int(density * 50)
            for i in 0..<n {
                let env = pow(max(0, sin(theta * (1 + Double(i % 3)) + h(i, 3) * 6.28)), 6)
                guard env > 0.02 else { continue }
                let p = CGPoint(x: W * CGFloat(h(i, 1)), y: H * CGFloat(h(i, 2)))
                let r = H * CGFloat(0.02 + 0.03 * h(i, 4)) * CGFloat(sz) * CGFloat(env)
                radial(ctx, p, r * 1.4, s.color(i), 0.6 * env, soft: 0.5)
                ctx.setFillColor(cg(s.color(i), env))
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r * 0.08, width: r * 2, height: r * 0.16))
                ctx.fillEllipse(in: CGRect(x: p.x - r * 0.08, y: p.y - r, width: r * 0.16, height: r * 2))
            }
        case .lightLeak:
            ctx.setBlendMode(.screen)
            for i in 0..<3 {
                let edge = CGPoint(x: i == 1 ? W : 0, y: H * CGFloat(0.2 + 0.6 * h(i, 1)))
                let wob = CGFloat(0.5 + 0.5 * sin(theta + Double(i) * 2))
                radial(ctx, CGPoint(x: edge.x, y: edge.y + H * 0.2 * wob), max(W, H) * CGFloat(0.35 + 0.25 * wob) * CGFloat(sz),
                       s.color(i), 0.35 + 0.25 * density, soft: 0.9)
            }
        case .vignette:
            let c = CGPoint(x: W / 2, y: H / 2)
            let strength = 0.35 + 0.6 * density
            if let g = CGGradient(colorsSpace: space, colors: [cg(s.color(0), 0), cg(s.color(0), strength)] as CFArray,
                                  locations: [CGFloat(0.35 + 0.3 * s.softness), 1]) {
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.scaleBy(x: W / H, y: 1)
                ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: H * 0.75 * CGFloat(sz),
                                       options: [.drawsAfterEndLocation])
                ctx.restoreGState()
            }
        }
    }

    /// Soft radial blob.
    static func radial(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ c: RGBAColor, _ alpha: Double, soft: Double) {
        guard radius > 0.5 else { return }
        let inner = CGFloat(max(0, min(0.95, 1 - soft)))
        guard let g = CGGradient(colorsSpace: space, colors: [cg(c, alpha), cg(c, alpha), cg(c, 0)] as CFArray,
                                 locations: [0, inner * 0.6, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    static func image(_ s: GeneratorSettings, t: Double, size: CGSize) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        draw(s, t: t, in: ctx, size: size)
        return ctx.makeImage()
    }
}

// MARK: - Live generator input

final class GeneratorSource: Source {
    @Published var settings: GeneratorSettings
    private let startTime = CACurrentMediaTime()
    private var buffers: [String: CGContext] = [:]

    init(settings: GeneratorSettings, name: String? = nil) {
        self.settings = settings
        super.init(name: name ?? settings.style.rawValue, kindLabel: settings.style.isEffect ? "EFFECT" : "GENERATOR")
    }

    override func currentImage() -> CGImage? { nil }

    override func draw(in ctx: CGContext, rect: CGRect) {
        let t = CACurrentMediaTime() - startTime
        // render big outputs at half size (soft abstract art scales up cleanly) to save CPU
        let scale: CGFloat = rect.width > 1000 ? 0.5 : 1
        let w = max(2, Int(rect.width * scale)), h = max(2, Int(rect.height * scale))
        let key = "\(w)x\(h)"
        var buf = buffers[key]
        if buf == nil {
            if buffers.count > 3 { buffers.removeAll() }
            buf = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: GeneratorRenderer.space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
            buffers[key] = buf
        }
        guard let b = buf else { return }
        b.clear(CGRect(x: 0, y: 0, width: w, height: h))
        GeneratorRenderer.draw(settings, t: t, in: b, size: CGSize(width: w, height: h))
        if let img = b.makeImage() {
            ctx.saveGState()
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: rect)
            ctx.restoreGState()
        }
    }
}

// MARK: - Export (still PNG / seamless loop video)

enum GeneratorExporter {
    static func still(_ s: GeneratorSettings, to url: URL, size: CGSize = CGSize(width: 1920, height: 1080)) -> Bool {
        guard let img = GeneratorRenderer.image(s, t: s.loopSeconds * 0.25, size: size) else { return false }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// Renders an exact loop (H.264 MP4). Runs on a background queue.
    static func loop(_ s: GeneratorSettings, to url: URL, size: CGSize = CGSize(width: 1920, height: 1080), fps: Int = 30,
                     progress: @escaping (Double) -> Void, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.removeItem(at: url)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { completion(false); return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]])
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
            guard writer.canAdd(input) else { completion(false); return }
            writer.add(input)
            guard writer.startWriting() else { completion(false); return }
            writer.startSession(atSourceTime: .zero)
            let total = max(1, Int(s.loopSeconds * Double(fps)))
            var ok = true
            for i in 0..<total {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
                guard let pool = adaptor.pixelBufferPool else { ok = false; break }
                var pbOut: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
                guard let pb = pbOut else { ok = false; break }
                CVPixelBufferLockBaseAddress(pb, [])
                if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
                                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: GeneratorRenderer.space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                    ctx.setFillColor(GeneratorRenderer.cg(s.background)); ctx.fill(CGRect(origin: .zero, size: size))
                    GeneratorRenderer.draw(s, t: Double(i) / Double(fps), in: ctx, size: size)
                }
                CVPixelBufferUnlockBaseAddress(pb, [])
                if !adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) { ok = false; break }
                if i % 15 == 0 { progress(Double(i) / Double(total)) }
            }
            input.markAsFinished()
            writer.finishWriting { completion(ok && writer.status == .completed) }
        }
    }
}

// MARK: - Generator model + UI

final class GeneratorModel: ObservableObject {
    weak var engine: Engine?
    @Published var settings = GeneratorSettings() { didSet { pushLive() } }
    @Published var targetID: UUID?
    @Published var liveUpdate = true
    @Published var exporting = false
    @Published var progress = 0.0
    @Published var message = ""

    var target: GeneratorSource? {
        guard let engine, let id = targetID else { return nil }
        return engine.sources.first { $0.id == id } as? GeneratorSource
    }

    private func pushLive() {
        guard liveUpdate, let t = target else { return }
        t.settings = settings
    }

    func apply(preset: GeneratorSettings) { var p = preset; p.seed = settings.seed; settings = p }
    func shuffle() { settings.seed = Int.random(in: 1...99_999) }

    enum Dest { case input, preview, program, key }

    func addAsInput(_ dest: Dest) {
        guard let engine else { return }
        let src = GeneratorSource(settings: settings)
        engine.placeInput(src)
        targetID = src.id
        switch dest {
        case .input: break
        case .preview: engine.setPreview(src.id); engine.selectedSourceID = src.id
        case .program: engine.setPreview(src.id); engine.cut()
        case .key: engine.keyedSources.insert(src.id)
        }
        message = "Added “\(src.name)” as an input."
    }

    func saveStill(into backgrounds: BackgroundsModel) {
        let name = "\(settings.style.rawValue)-\(settings.seed).png".replacingOccurrences(of: " ", with: "-")
        let url = backgrounds.catalog.folder.appendingPathComponent(name)
        if GeneratorExporter.still(settings, to: url) {
            _ = try? backgrounds.catalog.add(file: url, id: "gen-still-\(settings.style.rawValue)-\(settings.seed)", title: settings.style.rawValue + " (still)",
                                         kind: .image, category: "Generated", provider: "LiveDeck generator")
            backgrounds.refresh()
            message = "Saved still image to Backgrounds."
        } else { message = "Could not save the image." }
    }

    func exportLoop(into backgrounds: BackgroundsModel, size: CGSize = CGSize(width: 1920, height: 1080)) {
        guard !exporting else { return }
        if settings.style.isEffect { message = "Effects are transparent — use them live as an input and key them over Program."; return }
        exporting = true; progress = 0
        let s = settings
        let name = "\(s.style.rawValue)-\(s.seed)-loop.mp4".replacingOccurrences(of: " ", with: "-")
        let url = backgrounds.catalog.folder.appendingPathComponent(name)
        GeneratorExporter.loop(s, to: url, size: size, progress: { p in
            DispatchQueue.main.async { self.progress = p }
        }, completion: { ok in
            DispatchQueue.main.async {
                self.exporting = false
                if ok {
                    _ = try? backgrounds.catalog.add(file: url, id: "gen-loop-\(s.style.rawValue)-\(s.seed)", title: s.style.rawValue + " (loop)",
                                                 kind: .video, category: "Generated", provider: "LiveDeck generator")
                    backgrounds.refresh()
                    self.message = "Saved a \(Int(s.loopSeconds)) s seamless loop to Backgrounds."
                } else { self.message = "Export failed." }
            }
        })
    }
}

/// Live animated preview (Canvas + TimelineView).
struct GeneratorPreview: View {
    let settings: GeneratorSettings
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                context.withCGContext { cg in
                    cg.translateBy(x: 0, y: size.height)
                    cg.scaleBy(x: 1, y: -1)
                    if settings.transparent || settings.style.isEffect {
                        // checkerboard so transparent effects are visible
                        let s: CGFloat = 16
                        var y: CGFloat = 0, row = 0
                        while y < size.height {
                            var x: CGFloat = row % 2 == 0 ? 0 : s
                            cg.setFillColor(CGColor(gray: 0.18, alpha: 1)); cg.fill(CGRect(origin: .zero, size: CGSize(width: size.width, height: 0)))
                            while x < size.width {
                                cg.setFillColor(CGColor(gray: 0.22, alpha: 1)); cg.fill(CGRect(x: x, y: y, width: s, height: s)); x += s * 2
                            }
                            y += s; row += 1
                        }
                    }
                    GeneratorRenderer.draw(settings, t: t, in: cg, size: size)
                }
            }
        }
        .background(Color(white: 0.14))
    }
}

struct GeneratorView: View {
    @EnvironmentObject var gen: GeneratorModel
    @EnvironmentObject var backgrounds: BackgroundsModel
    @EnvironmentObject var engine: Engine

    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                GeometryReader { geo in
                    let w = min(geo.size.width, (geo.size.height) * 16 / 9)
                    GeneratorPreview(settings: gen.settings)
                        .frame(width: w, height: w * 9 / 16)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.line, lineWidth: 1))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                HStack(spacing: 6) {
                    Button { gen.addAsInput(.input) } label: { Label("Add as input", systemImage: "plus.rectangle.on.rectangle") }.buttonStyle(.ds())
                    Button("Preview") { gen.addAsInput(.preview) }.buttonStyle(.ds(.preview))
                    Button("Program") { gen.addAsInput(.program) }.buttonStyle(.ds(.program))
                    Button("Key over Program") { gen.addAsInput(.key) }.buttonStyle(.ds(.amber))
                        .help("Best for effects (snow, confetti, sparkles, light leaks, vignette)")
                    Spacer()
                    CPToggleRow(label: "Live-update input", isOn: $gen.liveUpdate).disabled(gen.target == nil)
                        .help("Changes you make here update the generator input you added last")
                }
                HStack(spacing: 6) {
                    Button { gen.saveStill(into: backgrounds) } label: { Label("Save still", systemImage: "photo") }.buttonStyle(.ds(.normal, .small))
                    Button { gen.exportLoop(into: backgrounds) } label: { Label("Export seamless loop video", systemImage: "film") }
                        .buttonStyle(.ds(.normal, .small)).disabled(gen.exporting)
                    if gen.exporting { ProgressView(value: gen.progress).frame(width: 120) }
                    Text(gen.message).font(.system(size: 10)).foregroundColor(DS.amber).lineLimit(1)
                    Spacer()
                }
            }
            .padding(10)
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            CPInspector {
                CPCard(title: "Presets", subtitle: "\(GeneratorSettings.presets.count) ready-made looks", icon: "sparkles") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                        ForEach(Array(GeneratorSettings.presets.enumerated()), id: \.offset) { _, p in
                            Button(p.name) { gen.apply(preset: p.settings) }
                                .buttonStyle(.ds(.normal, .small, active: gen.settings.style == p.settings.style, fullWidth: true))
                                .contextMenu {
                                    Button("Use preset") { gen.apply(preset: p.settings) }
                                    Button("Use and add as input") { gen.apply(preset: p.settings); gen.addAsInput(.input) }
                                    Button("Use and key over Program") { gen.apply(preset: p.settings); gen.addAsInput(.key) }
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
                CPCard(title: "Style & colours", subtitle: gen.settings.style.rawValue + (gen.settings.style.isEffect ? " · transparent" : ""), icon: "paintpalette") {
                    FieldRow(label: "Style") {
                        Picker("", selection: $gen.settings.style) {
                            Section("Backgrounds") { ForEach(GeneratorStyle.allCases.filter { !$0.isEffect }) { s in Text(s.rawValue).tag(s) } }
                            Section("Effects (transparent)") { ForEach(GeneratorStyle.allCases.filter { $0.isEffect }) { s in Text(s.rawValue).tag(s) } }
                        }.labelsHidden()
                    }
                    DSColorWell(label: "Colour 1", color: colorBinding(colorAt(0)))
                    DSColorWell(label: "Colour 2", color: colorBinding(colorAt(1)))
                    DSColorWell(label: "Colour 3", color: colorBinding(colorAt(2)))
                    if !gen.settings.style.isEffect {
                        DSColorWell(label: "Background", color: colorBinding($gen.settings.background))
                    }
                }
                CPCard(title: "Motion", subtitle: "Variation #\(gen.settings.seed)", icon: "wind") {
                    ParamSlider(label: "Speed", value: $gen.settings.speed, range: 0.1...3, defaultValue: 1, format: "%.2f×")
                    ParamSlider(label: "Amount", value: $gen.settings.density, range: 0...1, defaultValue: 0.5, format: "%.2f")
                    ParamSlider(label: "Size", value: $gen.settings.size, range: 0.2...3, defaultValue: 1, format: "%.2f×")
                    ParamSlider(label: "Softness", value: $gen.settings.softness, range: 0...1, defaultValue: 0.6, format: "%.2f")
                    ParamSlider(label: "Loop length", value: $gen.settings.loopSeconds, range: 6...60, defaultValue: 20, format: "%.0f s")
                    HStack {
                        CPNote("Motion repeats exactly every loop, so exported videos loop without a jump.")
                        CPButton(icon: "dice", title: "Shuffle") { gen.shuffle() }
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
        }
    }

    private func colorAt(_ i: Int) -> Binding<RGBAColor> {
        Binding(get: { gen.settings.color(i) }, set: { c in
            var s = gen.settings
            while s.colors.count <= i { s.colors.append(c) }
            s.colors[i] = c
            gen.settings = s
        })
    }
}
