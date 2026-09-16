import SwiftUI
import AppKit
import PresentationKit

/// Per-display output settings: custom region (extended displays), letterbox / crop / squeeze / 1:1,
/// cropping the picture, re-scaling to an output resolution and filter quality.
struct ScreenOutputEditor: View {
    @EnvironmentObject var engine: Engine
    let index: Int

    private var s: ScreenOutputSettings { engine.outputSettings(index) }
    private func bind<T>(_ kp: WritableKeyPath<ScreenOutputSettings, T>) -> Binding<T> {
        Binding(get: { engine.outputSettings(index)[keyPath: kp] }, set: { v in
            var n = engine.outputSettings(index); n[keyPath: kp] = v; engine.setOutputSettings(index, n)
        })
    }
    var body: some View {
        let px = engine.displayPixels(index)
        let extended = engine.isExtendedDisplay(index)
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Area on this display")
            if extended {
                CPToggleRow(icon: "rectangle.dashed", label: "Custom size and position", isOn: bind(\.customRegion))
                if s.customRegion {
                    HStack(spacing: 6) {
                        pixelField("X", \.regionX, max: px.width)
                        pixelField("Y", \.regionY, max: px.height)
                        pixelField("W", \.regionWidth, max: px.width)
                        pixelField("H", \.regionHeight, max: px.height)
                    }
                    .padding(.vertical, 4)
                    HStack(spacing: 4) {
                        preset("Full", 0, 0, px.width, px.height)
                        preset("Top ½", 0, 0, px.width, px.height / 2)
                        preset("Bottom ½", 0, px.height / 2, px.width, px.height / 2)
                        preset("Left ½", 0, 0, px.width / 2, px.height)
                        preset("Right ½", px.width / 2, 0, px.width / 2, px.height)
                        Menu("Size") {
                            ForEach(["1280x720", "1920x1080", "2560x1440", "3840x2160", "1920x540", "3840x1080", "1024x768"], id: \.self) { size in
                                Button(size.replacingOccurrences(of: "x", with: "×")) {
                                    let wh = size.split(separator: "x").compactMap { Int($0) }
                                    var n = s; n.regionWidth = wh[0]; n.regionHeight = wh[1]; engine.setOutputSettings(index, n)
                                }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    CPNote("Pixels on a \(px.width)×\(px.height) display, from the top-left corner. Use it for LED processors, edge-blended or partial screens.")
                }
            } else {
                CPNote("The main display always uses the whole window or full screen. Custom size is available on extended displays.")
            }

            SectionLabel("Fit")
            DSSegmented(selection: bind(\.scaling), options: OutputScaling.allCases.map { ($0, $0.rawValue) })
                .padding(.vertical, 4)
            CPNote(fitHint)

            SectionLabel("Crop the picture")
            ParamSlider(label: "Left", value: bind(\.cropLeft), range: 0...0.45, defaultValue: 0, format: "%.3f")
            ParamSlider(label: "Right", value: bind(\.cropRight), range: 0...0.45, defaultValue: 0, format: "%.3f")
            ParamSlider(label: "Top", value: bind(\.cropTop), range: 0...0.45, defaultValue: 0, format: "%.3f")
            ParamSlider(label: "Bottom", value: bind(\.cropBottom), range: 0...0.45, defaultValue: 0, format: "%.3f")
            HStack(spacing: 4) {
                Button("4:3 centre") { var n = s; n.cropLeft = 0.125; n.cropRight = 0.125; n.cropTop = 0; n.cropBottom = 0; engine.setOutputSettings(index, n) }
                    .buttonStyle(.ds(.normal, .small))
                Button("Remove black bars") { var n = s; n.cropTop = 0.12; n.cropBottom = 0.12; engine.setOutputSettings(index, n) }
                    .buttonStyle(.ds(.normal, .small))
                Button("No crop") { var n = s; n.cropLeft = 0; n.cropRight = 0; n.cropTop = 0; n.cropBottom = 0; engine.setOutputSettings(index, n) }
                    .buttonStyle(.ds(.normal, .small))
            }
            .padding(.vertical, 4)

            SectionLabel("Upscale / downscale")
            CPRow(label: "Output resolution") {
                Menu(s.outputWidth > 0 ? "\(s.outputWidth)×\(s.outputHeight)" : "Match the area") {
                    Button("Match the area (scaled by the display)") { var n = s; n.outputWidth = 0; n.outputHeight = 0; engine.setOutputSettings(index, n) }
                    Divider()
                    ForEach(["640x360", "1280x720", "1920x1080", "2560x1440", "3840x2160", "720x576", "720x480", "1024x768"], id: \.self) { size in
                        Button(size.replacingOccurrences(of: "x", with: "×")) {
                            let wh = size.split(separator: "x").compactMap { Int($0) }
                            var n = s; n.outputWidth = wh[0]; n.outputHeight = wh[1]; engine.setOutputSettings(index, n)
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            CPRow(label: "Quality") {
                DSSegmented(selection: bind(\.quality), options: OutputScaleQuality.allCases.map { ($0, $0.rawValue) }).frame(width: 220)
            }
            CPNote(scaleText(px: px))

            SectionLabel("Look")
            CPColorRow(label: "Letterbox colour", color: Binding(
                get: { let c = s.letterboxRGB; return Color(red: c.count > 0 ? c[0] : 0, green: c.count > 1 ? c[1] : 0, blue: c.count > 2 ? c[2] : 0) },
                set: { col in
                    let ns = NSColor(col).usingColorSpace(.sRGB) ?? .black
                    var n = s; n.letterboxRGB = [Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent)]
                    engine.setOutputSettings(index, n)
                }), opacity: false)
            CPToggleRow(label: "Show red edges (to line up the area)", isOn: bind(\.showEdges))
            HStack {
                Spacer()
                Button("Reset this display") { engine.setOutputSettings(index, ScreenOutputSettings(regionWidth: px.width, regionHeight: px.height)) }
                    .buttonStyle(.ds(.ghost, .small))
            }
            .padding(.vertical, 4)
        }
        .padding(.vertical, 4)
    }

    private var fitHint: String {
        switch s.scaling {
        case .letterbox: return "Keeps the whole picture; bars fill the leftover space."
        case .crop: return "Fills the area; edges of the picture that do not fit are cut off."
        case .squeeze: return "Stretches or squeezes the picture to the area's exact shape."
        case .native: return "No scaling — one picture pixel per display pixel, centred."
        }
    }

    private func scaleText(px: (width: Int, height: Int)) -> String {
        let crop = OutputGeometry.cropRect(sourceWidth: engine.width, sourceHeight: engine.height, s)
        let areaW = Double(s.customRegion ? s.regionWidth : px.width), areaH = Double(s.customRegion ? s.regionHeight : px.height)
        let rasterW = s.outputWidth > 0 ? Double(s.outputWidth) : areaW, rasterH = s.outputHeight > 0 ? Double(s.outputHeight) : areaH
        let k = OutputGeometry.scaleFactor(contentWidth: crop.width, contentHeight: crop.height, targetWidth: rasterW, targetHeight: rasterH, scaling: s.scaling)
        let kind = abs(k - 1) < 0.005 ? "same size" : (k > 1 ? "upscaled" : "downscaled")
        var t = "Picture \(Int(crop.width))×\(Int(crop.height)) → \(Int(rasterW))×\(Int(rasterH)): \(kind) \(String(format: "%.2f", k))×."
        if s.outputWidth > 0 && (Int(rasterW) != Int(areaW) || Int(rasterH) != Int(areaH)) {
            t += " Then shown on the \(Int(areaW))×\(Int(areaH)) area."
        }
        if s.outputWidth > 0 { t += " Re-scaling to a fixed resolution uses more CPU." }
        return t
    }

    private func pixelField(_ label: String, _ kp: WritableKeyPath<ScreenOutputSettings, Int>, max: Int) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(CP.text2)
            TextField("", value: Binding(get: { engine.outputSettings(index)[keyPath: kp] }, set: { v in
                var n = engine.outputSettings(index); n[keyPath: kp] = min(Swift.max(0, v), max); engine.setOutputSettings(index, n)
            }), format: .number.grouping(.never))
            .dsField().frame(width: 58)
        }
    }

    private func preset(_ title: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> some View {
        Button(title) {
            var n = s; n.customRegion = true; n.regionX = x; n.regionY = y; n.regionWidth = w; n.regionHeight = h
            engine.setOutputSettings(index, n)
        }
        .buttonStyle(.ds(.normal, .small))
    }
}
