import Foundation

// MARK: - Library metadata shared by every document

public struct LibraryMeta: Codable, Hashable, Sendable {
    public var title: String
    public var folder: String          // "" = root; "Christmas/2026" style paths
    public var tags: [String]
    public var favorite: Bool
    public var created: Date
    public var modified: Date
    public var lastOpened: Date?

    public init(title: String, folder: String = "", tags: [String] = [], favorite: Bool = false,
                created: Date = Date(), modified: Date = Date(), lastOpened: Date? = nil) {
        self.title = title; self.folder = folder; self.tags = tags; self.favorite = favorite
        self.created = created; self.modified = modified; self.lastOpened = lastOpened
    }
    enum CodingKeys: String, CodingKey { case title, folder, tags, favorite, created, modified, lastOpened }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.value(.title, "Untitled"); folder = c.value(.folder, ""); tags = c.value(.tags, [])
        favorite = c.value(.favorite, false); created = c.value(.created, Date()); modified = c.value(.modified, Date())
        lastOpened = c.value(.lastOpened, nil)
    }
}

// MARK: - Text

public enum TextAlign: String, Codable, Sendable, CaseIterable { case left, center, right, justified }
public enum VerticalAlign: String, Codable, Sendable, CaseIterable { case top, middle, bottom }
public enum TextCase: String, Codable, Sendable, CaseIterable { case asTyped, upper, lower, title }

public struct TextStyle: Codable, Hashable, Sendable {
    public var fontName: String        // PostScript or family name; renderer substitutes & warns if missing
    public var size: Double            // canvas points
    public var bold: Bool, italic: Bool, underline: Bool
    public var color: RGBAColor
    public var letterSpacing: Double
    public var lineSpacing: Double     // multiplier, 1 = normal
    public var align: TextAlign
    public var textCase: TextCase
    public var outlineWidth: Double    // 0 = none
    public var outlineColor: RGBAColor
    public var shadow: Bool
    public var shadowColor: RGBAColor
    public var shadowBlur: Double

    public init(fontName: String = "Helvetica Neue", size: Double = 72, bold: Bool = false, italic: Bool = false,
                underline: Bool = false, color: RGBAColor = .white, letterSpacing: Double = 0, lineSpacing: Double = 1.05,
                align: TextAlign = .center, textCase: TextCase = .asTyped, outlineWidth: Double = 0,
                outlineColor: RGBAColor = .black, shadow: Bool = true, shadowColor: RGBAColor = RGBAColor(0, 0, 0, 0.6),
                shadowBlur: Double = 8) {
        self.fontName = fontName; self.size = size; self.bold = bold; self.italic = italic; self.underline = underline
        self.color = color; self.letterSpacing = letterSpacing; self.lineSpacing = lineSpacing; self.align = align
        self.textCase = textCase; self.outlineWidth = outlineWidth; self.outlineColor = outlineColor
        self.shadow = shadow; self.shadowColor = shadowColor; self.shadowBlur = shadowBlur
    }
    enum CodingKeys: String, CodingKey {
        case fontName, size, bold, italic, underline, color, letterSpacing, lineSpacing, align, textCase
        case outlineWidth, outlineColor, shadow, shadowColor, shadowBlur
    }
    public init(from decoder: Decoder) throws {
        let d = TextStyle()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = c.value(.fontName, d.fontName); size = c.value(.size, d.size); bold = c.value(.bold, d.bold)
        italic = c.value(.italic, d.italic); underline = c.value(.underline, d.underline); color = c.value(.color, d.color)
        letterSpacing = c.value(.letterSpacing, d.letterSpacing); lineSpacing = c.value(.lineSpacing, d.lineSpacing)
        align = c.value(.align, d.align); textCase = c.value(.textCase, d.textCase)
        outlineWidth = c.value(.outlineWidth, d.outlineWidth); outlineColor = c.value(.outlineColor, d.outlineColor)
        shadow = c.value(.shadow, d.shadow); shadowColor = c.value(.shadowColor, d.shadowColor); shadowBlur = c.value(.shadowBlur, d.shadowBlur)
    }
}

/// What a text box is bound to when slides are generated (songs, scripture…).
public enum TextRole: String, Codable, Sendable { case plain, lyrics, scriptureText, scriptureReference, title, subtitle, notes }

public struct TextBox: Codable, Hashable, Sendable {
    public var text: String
    public var style: TextStyle
    public var verticalAlign: VerticalAlign
    public var shrinkToFit: Bool
    public var boxColor: RGBAColor       // background box behind text; alpha 0 = none
    public var padding: Double
    public var role: TextRole

    public init(text: String, style: TextStyle = TextStyle(), verticalAlign: VerticalAlign = .middle,
                shrinkToFit: Bool = true, boxColor: RGBAColor = .clear, padding: Double = 24, role: TextRole = .plain) {
        self.text = text; self.style = style; self.verticalAlign = verticalAlign; self.shrinkToFit = shrinkToFit
        self.boxColor = boxColor; self.padding = padding; self.role = role
    }
    enum CodingKeys: String, CodingKey { case text, style, verticalAlign, shrinkToFit, boxColor, padding, role }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.value(.text, ""); style = c.value(.style, TextStyle()); verticalAlign = c.value(.verticalAlign, .middle)
        shrinkToFit = c.value(.shrinkToFit, true); boxColor = c.value(.boxColor, .clear); padding = c.value(.padding, 24)
        role = c.value(.role, .plain)
    }
}

// MARK: - Media

public struct MediaRef: Codable, Hashable, Sendable {
    public var path: String
    public var bytes: Int64
    public var modified: Date?
    public init(path: String, bytes: Int64 = 0, modified: Date? = nil) { self.path = path; self.bytes = bytes; self.modified = modified }

    /// Missing-media detection (file gone or replaced).
    public var status: MediaStatus {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return .missing }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if bytes > 0 && size != bytes { return .changed }
        return .ok
    }
}
public enum MediaStatus: String, Sendable { case ok, missing, changed }
public enum FitMode: String, Codable, Sendable, CaseIterable { case fit, fill, stretch }

// MARK: - Elements

public enum ElementKind: String, Codable, Sendable {
    case text, image, video, shape, unknown
    public init(from decoder: Decoder) throws {
        self = ElementKind(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
    }
}
public enum ShapeKind: String, Codable, Sendable, CaseIterable { case rectangle, roundedRectangle, ellipse, line }

public struct SlideElement: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ElementKind
    public var frame: ElementFrame
    public var rotation: Double
    public var opacity: Double
    public var locked: Bool
    public var hidden: Bool
    public var text: TextBox?
    public var media: MediaRef?
    public var fit: FitMode
    public var loop: Bool
    public var volume: Double
    public var shape: ShapeKind?
    public var fill: RGBAColor
    public var cornerRadius: Double

    public init(id: UUID = UUID(), name: String, kind: ElementKind, frame: ElementFrame, text: TextBox? = nil,
                media: MediaRef? = nil, shape: ShapeKind? = nil, fill: RGBAColor = .clear) {
        self.id = id; self.name = name; self.kind = kind; self.frame = frame
        rotation = 0; opacity = 1; locked = false; hidden = false
        self.text = text; self.media = media; fit = .fit; loop = true; volume = 1
        self.shape = shape; self.fill = fill; cornerRadius = 0
    }
    enum CodingKeys: String, CodingKey {
        case id, name, kind, frame, rotation, opacity, locked, hidden, text, media, fit, loop, volume, shape, fill, cornerRadius
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); name = c.value(.name, "Element"); kind = c.value(.kind, .unknown)
        frame = c.value(.frame, ElementFrame(x: 0, y: 0, width: 100, height: 100))
        rotation = c.value(.rotation, 0); opacity = c.value(.opacity, 1); locked = c.value(.locked, false)
        hidden = c.value(.hidden, false); text = c.value(.text, nil); media = c.value(.media, nil)
        fit = c.value(.fit, .fit); loop = c.value(.loop, true); volume = c.value(.volume, 1)
        shape = c.value(.shape, nil); fill = c.value(.fill, .clear); cornerRadius = c.value(.cornerRadius, 0)
    }

    public static func textBox(_ text: String, role: TextRole, style: TextStyle, in frame: ElementFrame) -> SlideElement {
        SlideElement(name: role.rawValue, kind: .text, frame: frame, text: TextBox(text: text, style: style, role: role))
    }
}

// MARK: - Background & transition

public enum BackgroundKind: String, Codable, Sendable, CaseIterable { case none, color, gradient, image, video, transparent }

public struct SlideBackground: Codable, Hashable, Sendable {
    public var kind: BackgroundKind
    public var color: RGBAColor
    public var color2: RGBAColor       // gradient end
    public var angle: Double
    public var media: MediaRef?
    public var fit: FitMode
    public init(kind: BackgroundKind = .color, color: RGBAColor = .black, color2: RGBAColor = .black,
                angle: Double = 90, media: MediaRef? = nil, fit: FitMode = .fill) {
        self.kind = kind; self.color = color; self.color2 = color2; self.angle = angle; self.media = media; self.fit = fit
    }
    enum CodingKeys: String, CodingKey { case kind, color, color2, angle, media, fit }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, .color); color = c.value(.color, .black); color2 = c.value(.color2, .black)
        angle = c.value(.angle, 90); media = c.value(.media, nil); fit = c.value(.fit, .fill)
    }
}

public enum SlideTransitionKind: String, Codable, Sendable, CaseIterable { case cut, fade, dissolve, push, slide, wipe, zoom }

public struct SlideTransition: Codable, Hashable, Sendable {
    public var kind: SlideTransitionKind
    public var duration: Double
    public init(kind: SlideTransitionKind = .fade, duration: Double = 0.4) { self.kind = kind; self.duration = duration }
    enum CodingKeys: String, CodingKey { case kind, duration }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, .fade); duration = c.value(.duration, 0.4)
    }
}

// MARK: - Slides & presentations

public struct Slide: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var label: String           // "Verse 1", "John 3:16"
    public var groupColor: RGBAColor?
    public var elements: [SlideElement]
    public var background: SlideBackground?   // nil → theme background
    public var transition: SlideTransition?   // nil → presentation default
    public var notes: String
    public var enabled: Bool

    public init(id: UUID = UUID(), label: String = "", elements: [SlideElement] = [], background: SlideBackground? = nil,
                transition: SlideTransition? = nil, notes: String = "", enabled: Bool = true, groupColor: RGBAColor? = nil) {
        self.id = id; self.label = label; self.elements = elements; self.background = background
        self.transition = transition; self.notes = notes; self.enabled = enabled; self.groupColor = groupColor
    }
    enum CodingKeys: String, CodingKey { case id, label, groupColor, elements, background, transition, notes, enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); label = c.value(.label, ""); groupColor = c.value(.groupColor, nil)
        elements = c.value(.elements, []); background = c.value(.background, nil); transition = c.value(.transition, nil)
        notes = c.value(.notes, ""); enabled = c.value(.enabled, true)
    }

    /// Plain text of all text elements (search, stage display, thumbnails).
    public var plainText: String { elements.compactMap { $0.text?.text }.joined(separator: "\n") }
}

public struct Theme: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var canvas: CanvasSize
    public var background: SlideBackground
    public var body: TextStyle           // lyrics / scripture text
    public var reference: TextStyle      // scripture reference / song footer
    public var bodyFrame: ElementFrame
    public var referenceFrame: ElementFrame
    public var transition: SlideTransition

    public init(id: UUID = UUID(), name: String, canvas: CanvasSize = .hd, background: SlideBackground = SlideBackground(),
                body: TextStyle = TextStyle(), reference: TextStyle = TextStyle(size: 40, align: .right),
                bodyFrame: ElementFrame = ElementFrame(x: 120, y: 120, width: 1680, height: 760),
                referenceFrame: ElementFrame = ElementFrame(x: 120, y: 900, width: 1680, height: 80),
                transition: SlideTransition = SlideTransition()) {
        self.id = id; self.name = name; self.canvas = canvas; self.background = background; self.body = body
        self.reference = reference; self.bodyFrame = bodyFrame; self.referenceFrame = referenceFrame; self.transition = transition
    }
    enum CodingKeys: String, CodingKey { case id, name, canvas, background, body, reference, bodyFrame, referenceFrame, transition }
    public init(from decoder: Decoder) throws {
        let d = Theme(name: "")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); name = c.value(.name, "Theme"); canvas = c.value(.canvas, d.canvas)
        background = c.value(.background, d.background); body = c.value(.body, d.body); reference = c.value(.reference, d.reference)
        bodyFrame = c.value(.bodyFrame, d.bodyFrame); referenceFrame = c.value(.referenceFrame, d.referenceFrame)
        transition = c.value(.transition, d.transition)
    }

    /// Full-screen default: white centred text on black.
    public static let standard = Theme(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001") ?? UUID(), name: "Standard")
    /// Lower-third lyrics on a transparent background — for keying over cameras.
    public static let lowerThird = Theme(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000A002") ?? UUID(), name: "Lower third (key)",
        background: SlideBackground(kind: .transparent),
        body: TextStyle(size: 54, outlineWidth: 2, shadowBlur: 6),
        reference: TextStyle(size: 30, align: .right),
        bodyFrame: ElementFrame(x: 160, y: 760, width: 1600, height: 220),
        referenceFrame: ElementFrame(x: 160, y: 985, width: 1600, height: 50))
}

public enum PresentationKind: String, Codable, Sendable, CaseIterable { case general, song, scripture, announcement, graphics }

public struct Presentation: Codable, Identifiable, Hashable, Sendable {
    public static let schemaVersion = 1
    public var id: UUID
    public var schema: Int
    public var meta: LibraryMeta
    public var kind: PresentationKind
    public var canvas: CanvasSize
    public var theme: Theme
    public var slides: [Slide]
    public var transition: SlideTransition

    public init(id: UUID = UUID(), title: String, kind: PresentationKind = .general, theme: Theme = .standard, slides: [Slide] = []) {
        self.id = id; schema = Presentation.schemaVersion; meta = LibraryMeta(title: title); self.kind = kind
        canvas = theme.canvas; self.theme = theme; self.slides = slides; transition = theme.transition
    }
    enum CodingKeys: String, CodingKey { case id, schema, meta, kind, canvas, theme, slides, transition }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); schema = c.value(.schema, 1); meta = c.value(.meta, LibraryMeta(title: "Untitled"))
        kind = c.value(.kind, .general); canvas = c.value(.canvas, .hd); theme = c.value(.theme, .standard)
        slides = c.value(.slides, []); transition = c.value(.transition, SlideTransition())
    }
}

// MARK: - Service (running order)

public enum ServiceItemKind: String, Codable, Sendable { case header, song, scripture, presentation, media }

public struct ServiceItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: ServiceItemKind
    public var documentID: UUID?          // song or presentation
    public var scripture: String?         // reference text, e.g. "John 3:16-18"
    public var bibleID: String?
    public var arrangement: String?       // per-service song order, e.g. "V1 C V2 C B C"
    public var collapsed: Bool
    public init(id: UUID = UUID(), title: String, kind: ServiceItemKind, documentID: UUID? = nil,
                scripture: String? = nil, bibleID: String? = nil, arrangement: String? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.documentID = documentID
        self.scripture = scripture; self.bibleID = bibleID; self.arrangement = arrangement; collapsed = false
    }
    enum CodingKeys: String, CodingKey { case id, title, kind, documentID, scripture, bibleID, arrangement, collapsed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); title = c.value(.title, "Item"); kind = c.value(.kind, .header)
        documentID = c.value(.documentID, nil); scripture = c.value(.scripture, nil); bibleID = c.value(.bibleID, nil)
        arrangement = c.value(.arrangement, nil); collapsed = c.value(.collapsed, false)
    }
}

public struct ServicePlan: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var meta: LibraryMeta
    public var date: Date?
    public var items: [ServiceItem]
    public init(id: UUID = UUID(), title: String, date: Date? = nil, items: [ServiceItem] = []) {
        self.id = id; meta = LibraryMeta(title: title); self.date = date; self.items = items
    }
    enum CodingKeys: String, CodingKey { case id, meta, date, items }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); meta = c.value(.meta, LibraryMeta(title: "Service")); date = c.value(.date, nil)
        items = c.value(.items, [])
    }
}
