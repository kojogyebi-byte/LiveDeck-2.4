import Foundation

// MARK: - Frame rates (progressive and interlaced)

public struct FrameRateFormat: Hashable, Identifiable, Sendable {
    public let id: String              // "59.94i"
    public let framesPerSecond: Double // full frames (interlaced: fields ÷ 2)
    public let interlaced: Bool
    public let rateNumerator: Int      // exact frame rate as a fraction (30000/1001)
    public let rateDenominator: Int

    public var fieldsPerSecond: Double { interlaced ? framesPerSecond * 2 : framesPerSecond }
    /// How many images the switcher renders per second (fields for interlaced formats).
    public var renderRate: Double { fieldsPerSecond }
    /// Nearest whole frames per second (for legacy settings and simple readouts).
    public var nominalFPS: Int { Int(framesPerSecond.rounded()) }
    /// Exact frame duration: value / timescale seconds.
    public var frameDuration: (value: Int64, timescale: Int32) { (Int64(rateDenominator), Int32(rateNumerator)) }
    /// ffmpeg rate string ("30000/1001", "25").
    public var ffmpegRate: String { rateDenominator == 1 ? "\(rateNumerator)" : "\(rateNumerator)/\(rateDenominator)" }

    /// "1080i59.94", "720p60"
    public func name(height: Int) -> String { "\(height)\(interlaced ? "i" : "p")\(rateText)" }
    public var rateText: String {
        let v = interlaced ? fieldsPerSecond : framesPerSecond
        return v.rounded() == v ? String(Int(v)) : String(format: "%.2f", v).replacingOccurrences(of: "0$", with: "", options: .regularExpression)
    }
    public var menuTitle: String {
        interlaced
            ? "\(rateText)i — interlaced (\(String(format: framesPerSecond.rounded() == framesPerSecond ? "%.0f" : "%.2f", framesPerSecond)) frames, \(rateText) fields)"
            : "\(rateText)p"
    }

    init(_ id: String, _ num: Int, _ den: Int, interlaced: Bool) {
        self.id = id; rateNumerator = num; rateDenominator = den; self.interlaced = interlaced
        framesPerSecond = Double(num) / Double(den)
    }

    public static let progressive: [FrameRateFormat] = [
        FrameRateFormat("23.976p", 24000, 1001, interlaced: false),
        FrameRateFormat("24p", 24, 1, interlaced: false),
        FrameRateFormat("25p", 25, 1, interlaced: false),
        FrameRateFormat("29.97p", 30000, 1001, interlaced: false),
        FrameRateFormat("30p", 30, 1, interlaced: false),
        FrameRateFormat("50p", 50, 1, interlaced: false),
        FrameRateFormat("59.94p", 60000, 1001, interlaced: false),
        FrameRateFormat("60p", 60, 1, interlaced: false)
    ]
    /// Interlaced: named by field rate (50i = 25 frames / 50 fields), top field first.
    public static let interlacedFormats: [FrameRateFormat] = [
        FrameRateFormat("50i", 25, 1, interlaced: true),
        FrameRateFormat("59.94i", 30000, 1001, interlaced: true),
        FrameRateFormat("60i", 30, 1, interlaced: true)
    ]
    public static let all: [FrameRateFormat] = progressive + interlacedFormats
    public static let standard = all.first { $0.id == "30p" }!

    public static func byID(_ id: String) -> FrameRateFormat? { all.first { $0.id == id } }
    /// Maps an old whole-number setting (24, 25, 30, 50, 60).
    public static func fromLegacy(_ fps: Int) -> FrameRateFormat { byID("\(fps)p") ?? standard }
}

// MARK: - Display outputs: custom region, scaling, cropping

public enum OutputScaling: String, Codable, Sendable, CaseIterable, Identifiable {
    case letterbox = "Letterbox"      // fit inside, bars on the sides or top/bottom
    case crop = "Crop to fill"        // fill the region, cutting the overflow
    case squeeze = "Squeeze"          // stretch to the region's shape
    case native = "1:1 pixels"        // no scaling, centred
    public var id: String { rawValue }
}

public enum OutputScaleQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case smooth = "Smooth"
    case sharp = "Sharp"
    case pixel = "Pixel-exact"
    public var id: String { rawValue }
}

public struct ScreenOutputSettings: Codable, Hashable, Sendable {
    public var customRegion: Bool       // extended displays only
    public var regionX: Int             // pixels from the display's top-left corner
    public var regionY: Int
    public var regionWidth: Int
    public var regionHeight: Int
    public var scaling: OutputScaling
    public var cropLeft: Double         // 0 … 0.45 of the source width/height
    public var cropRight: Double
    public var cropTop: Double
    public var cropBottom: Double
    public var outputWidth: Int         // 0 = the region's own pixel size; otherwise re-scale to this raster first
    public var outputHeight: Int
    public var quality: OutputScaleQuality
    public var showEdges: Bool
    public var letterboxRGB: [Double]   // r, g, b 0…1

    public init(customRegion: Bool = false, regionX: Int = 0, regionY: Int = 0, regionWidth: Int = 1920, regionHeight: Int = 1080,
                scaling: OutputScaling = .letterbox, cropLeft: Double = 0, cropRight: Double = 0, cropTop: Double = 0, cropBottom: Double = 0,
                outputWidth: Int = 0, outputHeight: Int = 0, quality: OutputScaleQuality = .smooth, showEdges: Bool = false,
                letterboxRGB: [Double] = [0, 0, 0]) {
        self.customRegion = customRegion; self.regionX = regionX; self.regionY = regionY
        self.regionWidth = regionWidth; self.regionHeight = regionHeight; self.scaling = scaling
        self.cropLeft = cropLeft; self.cropRight = cropRight; self.cropTop = cropTop; self.cropBottom = cropBottom
        self.outputWidth = outputWidth; self.outputHeight = outputHeight; self.quality = quality
        self.showEdges = showEdges; self.letterboxRGB = letterboxRGB
    }

    enum CodingKeys: String, CodingKey {
        case customRegion, regionX, regionY, regionWidth, regionHeight, scaling, cropLeft, cropRight, cropTop, cropBottom
        case outputWidth, outputHeight, quality, showEdges, letterboxRGB
    }
    public init(from decoder: Decoder) throws {
        let d = ScreenOutputSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        customRegion = c.value(.customRegion, d.customRegion); regionX = c.value(.regionX, d.regionX); regionY = c.value(.regionY, d.regionY)
        regionWidth = c.value(.regionWidth, d.regionWidth); regionHeight = c.value(.regionHeight, d.regionHeight)
        scaling = c.value(.scaling, d.scaling)
        cropLeft = c.value(.cropLeft, d.cropLeft); cropRight = c.value(.cropRight, d.cropRight)
        cropTop = c.value(.cropTop, d.cropTop); cropBottom = c.value(.cropBottom, d.cropBottom)
        outputWidth = c.value(.outputWidth, d.outputWidth); outputHeight = c.value(.outputHeight, d.outputHeight)
        quality = c.value(.quality, d.quality); showEdges = c.value(.showEdges, d.showEdges); letterboxRGB = c.value(.letterboxRGB, d.letterboxRGB)
    }

    public var isDefault: Bool { self == ScreenOutputSettings() }
    public var hasCrop: Bool { cropLeft > 0.0005 || cropRight > 0.0005 || cropTop > 0.0005 || cropBottom > 0.0005 }
}

public struct PixelRect: Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

public enum OutputGeometry {
    /// The part of the source kept after cropping (top-left origin, in source pixels).
    public static func cropRect(sourceWidth: Int, sourceHeight: Int, _ s: ScreenOutputSettings) -> PixelRect {
        let w = Double(sourceWidth), h = Double(sourceHeight)
        let l = min(max(s.cropLeft, 0), 0.45), r = min(max(s.cropRight, 0), 0.45)
        let t = min(max(s.cropTop, 0), 0.45), b = min(max(s.cropBottom, 0), 0.45)
        return PixelRect(x: (w * l).rounded(), y: (h * t).rounded(),
                         width: max(1, (w * (1 - l - r)).rounded()), height: max(1, (h * (1 - t - b)).rounded()))
    }

    /// Where the (cropped) picture lands inside a target of `targetWidth × targetHeight` pixels (top-left origin).
    public static func placement(contentWidth: Double, contentHeight: Double, targetWidth: Double, targetHeight: Double,
                                 scaling: OutputScaling) -> PixelRect {
        guard contentWidth > 0, contentHeight > 0, targetWidth > 0, targetHeight > 0 else { return PixelRect(x: 0, y: 0, width: 0, height: 0) }
        switch scaling {
        case .squeeze:
            return PixelRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        case .native:
            return PixelRect(x: ((targetWidth - contentWidth) / 2).rounded(), y: ((targetHeight - contentHeight) / 2).rounded(),
                             width: contentWidth, height: contentHeight)
        case .letterbox, .crop:
            let sx = targetWidth / contentWidth, sy = targetHeight / contentHeight
            let k = scaling == .letterbox ? min(sx, sy) : max(sx, sy)
            let w = contentWidth * k, h = contentHeight * k
            return PixelRect(x: (targetWidth - w) / 2, y: (targetHeight - h) / 2, width: w, height: h)
        }
    }

    /// Scale factor from source pixels to output pixels (>1 upscaling, <1 downscaling).
    public static func scaleFactor(contentWidth: Double, contentHeight: Double, targetWidth: Double, targetHeight: Double, scaling: OutputScaling) -> Double {
        let p = placement(contentWidth: contentWidth, contentHeight: contentHeight, targetWidth: targetWidth, targetHeight: targetHeight, scaling: scaling)
        return contentHeight > 0 ? p.height / contentHeight : 1
    }

    /// Keeps a custom region on the display.
    public static func clampRegion(_ s: ScreenOutputSettings, displayWidth: Int, displayHeight: Int) -> ScreenOutputSettings {
        var o = s
        o.regionWidth = min(max(16, o.regionWidth), displayWidth)
        o.regionHeight = min(max(16, o.regionHeight), displayHeight)
        o.regionX = min(max(0, o.regionX), displayWidth - o.regionWidth)
        o.regionY = min(max(0, o.regionY), displayHeight - o.regionHeight)
        return o
    }
}
