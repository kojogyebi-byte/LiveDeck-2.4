import Foundation

// MARK: - Slide look (formatting for songs, scripture and dictionary displays)

/// Where the text block sits on screen.
public enum LookRegion: String, Codable, Sendable, CaseIterable, Identifiable {
    case full = "Full screen"
    case lowerThird = "Lower third"
    case upperThird = "Upper third"
    case center = "Centre band"
    case leftHalf = "Left half"
    case rightHalf = "Right half"
    case custom = "Custom"
    public var id: String { rawValue }
}

/// How an image/video background combines with the colour or gradient beneath it.
public enum MediaBlendMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case normal = "Normal"
    case multiply = "Multiply"
    case screen = "Screen"
    case overlay = "Overlay"
    case softLight = "Soft Light"
    case hardLight = "Hard Light"
    case darken = "Darken"
    case lighten = "Lighten"
    case colorDodge = "Colour Dodge"
    case colorBurn = "Colour Burn"
    case difference = "Difference"
    case exclusion = "Exclusion"
    case hue = "Hue"
    case saturation = "Saturation"
    case color = "Colour"
    case luminosity = "Luminosity"
    public var id: String { rawValue }
    public var hint: String {
        switch self {
        case .normal: return "Media covers the base (use opacity to tint)."
        case .multiply: return "Darkens — the base colour tints the media."
        case .screen: return "Lightens — good for glowing or light backgrounds."
        case .overlay: return "Adds contrast and colour from the base."
        case .softLight: return "Gentle colour wash."
        case .hardLight: return "Strong colour wash."
        case .darken, .lighten: return "Keeps the darker / lighter of media and base."
        case .colorDodge, .colorBurn: return "Brightens / deepens with strong colour."
        case .difference, .exclusion: return "Inverts colours where they differ."
        case .hue, .saturation, .color, .luminosity: return "Mixes one colour property from the base."
        }
    }
}

/// What sits under an image/video background.
public enum MediaBase: String, Codable, Sendable, CaseIterable, Identifiable {
    case color = "Colour"
    case gradient = "Gradient"
    public var id: String { rawValue }
}

/// How several Bible versions share the screen.
public enum ParallelLayout: String, Codable, Sendable, CaseIterable, Identifiable {
    case sideBySide = "Side by side"
    case stacked = "Stacked"
    public var id: String { rawValue }
}

/// Where the reference / song credit line goes.
public enum FooterPosition: String, Codable, Sendable, CaseIterable, Identifiable {
    case below = "Under the text"
    case above = "Above the text"
    case screenBottom = "Bottom of screen"
    case screenTop = "Top of screen"
    case hidden = "Hidden"
    public var id: String { rawValue }
}

/// Complete, user-editable formatting for a slide display. All sizes are in 1080p canvas
/// points and scale with the output resolution; positions are fractions of the screen.
public struct SlideLook: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String

    // Background
    public var background: SlideBackground
    public var dim: Double                  // 0…0.9 black layer over image/video for readability
    public var mediaBlend: MediaBlendMode        // image/video blended onto the base colour/gradient
    public var mediaOpacity: Double         // 0…1
    public var mediaBase: MediaBase

    // Text
    public var body: TextStyle
    public var title: TextStyle             // headword (dictionary) / song title
    public var footer: TextStyle            // scripture reference / credits
    public var showTitle: Bool
    public var footerPosition: FooterPosition

    // Layout
    public var region: LookRegion
    public var custom: ElementFrame         // fractions (x, y, w, h), top-left origin — used when region == .custom
    public var marginX: Double              // fraction of width
    public var marginY: Double              // fraction of height
    public var verticalAlign: VerticalAlign
    public var shrinkToFit: Bool

    // Text box / band
    public var boxColor: RGBAColor          // alpha 0 = no box
    public var boxPadding: Double
    public var boxRadius: Double
    public var boxFullWidth: Bool           // band across the whole screen width

    // Content rules
    public var showVerseNumbers: Bool
    public var maxCharsPerSlide: Int        // scripture
    public var linesPerSlide: Int           // songs; 0 = use the song's own setting
    public var maxSenses: Int               // dictionary
    public var showExamples: Bool           // dictionary
    public var fadeDuration: Double
    public var parallelLayout: ParallelLayout   // several Bible versions at once
    public var showVersionLabels: Bool
    public var columnGap: Double                // 1080p points between version columns

    public init(id: UUID = UUID(), name: String = "Look") {
        self.id = id; self.name = name
        background = SlideBackground(kind: .color, color: .black)
        dim = 0
        mediaBlend = .normal
        mediaOpacity = 1
        mediaBase = .color
        body = TextStyle(size: 80, bold: true, align: .center, shadow: true)
        title = TextStyle(size: 96, bold: true, color: RGBAColor(1, 0.78, 0.30), align: .center)
        footer = TextStyle(size: 40, color: RGBAColor(0.85, 0.85, 0.85), align: .center, shadow: true)
        showTitle = false
        footerPosition = .below
        region = .full
        custom = ElementFrame(x: 0.1, y: 0.6, width: 0.8, height: 0.3)
        marginX = 0.06; marginY = 0.08
        verticalAlign = .middle
        shrinkToFit = true
        boxColor = .clear; boxPadding = 28; boxRadius = 10; boxFullWidth = false
        showVerseNumbers = true
        maxCharsPerSlide = 280
        linesPerSlide = 0
        maxSenses = 3
        showExamples = false
        fadeDuration = 0.35
        parallelLayout = .sideBySide
        showVersionLabels = true
        columnGap = 48
    }

    enum CodingKeys: String, CodingKey {
        case id, name, background, dim, mediaBlend, mediaOpacity, mediaBase, body, title, footer, showTitle, footerPosition, region, custom, marginX, marginY
        case verticalAlign, shrinkToFit, boxColor, boxPadding, boxRadius, boxFullWidth, showVerseNumbers, maxCharsPerSlide
        case linesPerSlide, maxSenses, showExamples, fadeDuration, parallelLayout, showVersionLabels, columnGap
    }
    public init(from decoder: Decoder) throws {
        let d = SlideLook()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); name = c.value(.name, d.name)
        background = c.value(.background, d.background); dim = c.value(.dim, d.dim)
        mediaBlend = c.value(.mediaBlend, d.mediaBlend); mediaOpacity = c.value(.mediaOpacity, d.mediaOpacity)
        mediaBase = c.value(.mediaBase, d.mediaBase)
        body = c.value(.body, d.body); title = c.value(.title, d.title); footer = c.value(.footer, d.footer)
        showTitle = c.value(.showTitle, d.showTitle); footerPosition = c.value(.footerPosition, d.footerPosition)
        region = c.value(.region, d.region); custom = c.value(.custom, d.custom)
        marginX = c.value(.marginX, d.marginX); marginY = c.value(.marginY, d.marginY)
        verticalAlign = c.value(.verticalAlign, d.verticalAlign); shrinkToFit = c.value(.shrinkToFit, d.shrinkToFit)
        boxColor = c.value(.boxColor, d.boxColor); boxPadding = c.value(.boxPadding, d.boxPadding)
        boxRadius = c.value(.boxRadius, d.boxRadius); boxFullWidth = c.value(.boxFullWidth, d.boxFullWidth)
        showVerseNumbers = c.value(.showVerseNumbers, d.showVerseNumbers); maxCharsPerSlide = c.value(.maxCharsPerSlide, d.maxCharsPerSlide)
        linesPerSlide = c.value(.linesPerSlide, d.linesPerSlide); maxSenses = c.value(.maxSenses, d.maxSenses)
        showExamples = c.value(.showExamples, d.showExamples); fadeDuration = c.value(.fadeDuration, d.fadeDuration)
        parallelLayout = c.value(.parallelLayout, d.parallelLayout); showVersionLabels = c.value(.showVersionLabels, d.showVersionLabels)
        columnGap = c.value(.columnGap, d.columnGap)
    }

    /// The text region in pixels (top-left origin) for a screen of the given size, margins applied.
    public func textRegion(width W: Double, height H: Double) -> ElementFrame {
        var f: ElementFrame
        switch region {
        case .full: f = ElementFrame(x: 0, y: 0, width: 1, height: 1)
        case .lowerThird: f = ElementFrame(x: 0, y: 0.64, width: 1, height: 0.36)
        case .upperThird: f = ElementFrame(x: 0, y: 0, width: 1, height: 0.36)
        case .center: f = ElementFrame(x: 0, y: 0.3, width: 1, height: 0.4)
        case .leftHalf: f = ElementFrame(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: f = ElementFrame(x: 0.5, y: 0, width: 0.5, height: 1)
        case .custom:
            let x = min(max(custom.x, 0), 0.95), y = min(max(custom.y, 0), 0.95)
            f = ElementFrame(x: x, y: y, width: min(max(custom.width, 0.05), 1 - x), height: min(max(custom.height, 0.05), 1 - y))
        }
        let mx = min(max(marginX, 0), 0.4) * W, my = min(max(marginY, 0), 0.4) * H
        let x = f.x * W + mx, y = f.y * H + my
        return ElementFrame(x: x, y: y, width: max(10, f.width * W - 2 * mx), height: max(10, f.height * H - 2 * my))
    }

    // MARK: Presets

    public static let fullScreen: SlideLook = {
        SlideLook(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B001") ?? UUID(), name: "Full screen — white on black")
    }()

    public static let lowerThirdKey: SlideLook = {
        var l = SlideLook(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B002") ?? UUID(), name: "Lower third — transparent (key over cameras)")
        l.background = SlideBackground(kind: .transparent)
        l.region = .lowerThird
        l.marginX = 0.04; l.marginY = 0.05
        l.body = TextStyle(size: 58, bold: true, align: .center, outlineWidth: 0, shadow: true, shadowBlur: 10)
        l.footer = TextStyle(size: 30, color: RGBAColor(1, 0.8, 0.35), align: .right, shadow: true)
        l.boxColor = RGBAColor(0, 0, 0, 0.62); l.boxFullWidth = true; l.boxRadius = 0; l.boxPadding = 22
        l.verticalAlign = .bottom
        l.maxCharsPerSlide = 160
        l.linesPerSlide = 2
        return l
    }()

    public static let scriptureOnImage: SlideLook = {
        var l = SlideLook(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B003") ?? UUID(), name: "Scripture — image friendly")
        l.background = SlideBackground(kind: .gradient, color: RGBAColor(0.05, 0.09, 0.20), color2: RGBAColor(0.01, 0.02, 0.05), angle: 90)
        l.dim = 0.45
        l.body = TextStyle(size: 70, bold: false, lineSpacing: 1.15, align: .center, shadow: true, shadowBlur: 12)
        l.footer = TextStyle(size: 42, bold: true, color: RGBAColor(1, 0.8, 0.35), align: .center, shadow: true)
        l.marginX = 0.09; l.marginY = 0.1
        return l
    }()

    public static let dictionaryPanel: SlideLook = {
        var l = SlideLook(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B004") ?? UUID(), name: "Dictionary — definition card")
        l.background = SlideBackground(kind: .gradient, color: RGBAColor(0.07, 0.08, 0.12), color2: RGBAColor(0.02, 0.02, 0.04), angle: 90)
        l.showTitle = true
        l.title = TextStyle(size: 110, bold: true, color: RGBAColor(1, 0.78, 0.30), align: .left, shadow: false)
        l.body = TextStyle(size: 50, bold: false, lineSpacing: 1.1, align: .left, shadow: false)
        l.footer = TextStyle(size: 30, color: RGBAColor(0.6, 0.62, 0.68), align: .left, shadow: false)
        l.footerPosition = .screenBottom
        l.verticalAlign = .middle
        l.marginX = 0.08; l.marginY = 0.1
        l.maxSenses = 3
        return l
    }()

    public static let dictionaryLowerThird: SlideLook = {
        var l = SlideLook(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B005") ?? UUID(), name: "Dictionary — lower third (key)")
        l.background = SlideBackground(kind: .transparent)
        l.region = .lowerThird
        l.showTitle = true
        l.title = TextStyle(size: 64, bold: true, color: RGBAColor(1, 0.78, 0.30), align: .left, shadow: false)
        l.body = TextStyle(size: 38, align: .left, shadow: false)
        l.footerPosition = .hidden
        l.boxColor = RGBAColor(0.03, 0.04, 0.07, 0.88); l.boxFullWidth = true; l.boxRadius = 0; l.boxPadding = 26
        l.marginX = 0.05; l.marginY = 0.04
        l.verticalAlign = .bottom
        l.maxSenses = 1
        return l
    }()

    public static let builtIn: [SlideLook] = [fullScreen, lowerThirdKey, scriptureOnImage, dictionaryPanel, dictionaryLowerThird]
}

/// User-saved looks (Library/looks.json).
public final class LookLibrary {
    public let url: URL
    public private(set) var looks: [SlideLook] = []

    public init(libraryRoot: URL) {
        url = libraryRoot.appendingPathComponent("looks.json")
        looks = (try? JSONFile.read([SlideLook].self, from: url)) ?? []
    }

    public var all: [SlideLook] { SlideLook.builtIn + looks }

    @discardableResult
    public func save(_ look: SlideLook, as name: String) throws -> SlideLook {
        var l = look
        l.name = name.trimmed.isEmpty ? look.name : name.trimmed
        if let i = looks.firstIndex(where: { $0.name == l.name }) { l.id = looks[i].id; looks[i] = l }
        else { l.id = UUID(); looks.append(l) }
        try JSONFile.write(looks, to: url)
        return l
    }

    public func delete(_ id: UUID) throws {
        looks.removeAll { $0.id == id }
        try JSONFile.write(looks, to: url)
    }
}
