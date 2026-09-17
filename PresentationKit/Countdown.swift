import Foundation

// MARK: - Countdown overlay: modes, time formats and styling

public enum CountdownMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case duration = "Count down"
    case toTime = "Count down to a time"
    case countUp = "Count up"
    public var id: String { rawValue }
}

public enum CountdownTimeFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto = "Auto"
    case mmss = "MM:SS"
    case hhmmss = "HH:MM:SS"
    case mss = "M:SS"
    case seconds = "Seconds"
    case tenths = "MM:SS.t"
    public var id: String { rawValue }
}

public enum CountdownLabelPosition: String, Codable, Sendable, CaseIterable, Identifiable {
    case above = "Above"
    case below = "Below"
    case left = "Left"
    case hidden = "Hidden"
    public var id: String { rawValue }
}

public enum CountdownEnd: String, Codable, Sendable, CaseIterable, Identifiable {
    case stop = "Stop at 00:00"
    case endText = "Show end text"
    case overtime = "Keep counting (overtime)"
    case hide = "Hide the overlay"
    public var id: String { rawValue }
}

public enum CountdownBox: String, Codable, Sendable, CaseIterable, Identifiable {
    case box = "Box"
    case rounded = "Rounded"
    case pill = "Pill"
    case outline = "Outline"
    case none = "Text only"
    public var id: String { rawValue }
}

public enum CountdownFont: String, Codable, Sendable, CaseIterable, Identifiable {
    case system = "System"
    case rounded = "Rounded"
    case mono = "Monospaced"
    case serif = "Serif"
    case condensed = "Condensed"
    public var id: String { rawValue }
}

public enum CountdownPlacement: String, Codable, Sendable, CaseIterable, Identifiable {
    case center = "Centre"
    case top = "Top"
    case bottom = "Bottom"
    case topLeft = "Top left"
    case topRight = "Top right"
    case bottomLeft = "Bottom left"
    case bottomRight = "Bottom right"
    public var id: String { rawValue }
}

public struct CountdownStyle: Codable, Hashable, Sendable {
    public var mode: CountdownMode = .duration
    public var targetHour: Int = 10
    public var targetMinute: Int = 0
    public var format: CountdownTimeFormat = .auto
    public var labelPosition: CountdownLabelPosition = .above
    public var uppercaseLabel = true
    public var showSubtext = true
    public var endBehavior: CountdownEnd = .stop
    public var endText = "WE ARE LIVE"
    public var box: CountdownBox = .rounded
    public var font: CountdownFont = .system
    public var weight: Int = 3                 // 0 regular · 1 semibold · 2 bold · 3 heavy · 4 black
    public var placement: CountdownPlacement = .center
    public var digitsScale: Double = 1
    public var labelScale: Double = 1
    public var padding: Double = 1
    public var letterSpacing: Double = 0
    public var shadow = true
    public var warnSeconds: Double = 60        // 0 = off
    public var warnRGB: [Double] = [1, 0.27, 0.23]
    public var flash = true
    public var flashSeconds: Double = 10

    public init() {}

    enum CodingKeys: String, CodingKey {
        case mode, targetHour, targetMinute, format, labelPosition, uppercaseLabel, showSubtext, endBehavior, endText, box, font, weight
        case placement, digitsScale, labelScale, padding, letterSpacing, shadow, warnSeconds, warnRGB, flash, flashSeconds
    }
    public init(from decoder: Decoder) throws {
        let d = CountdownStyle()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.value(.mode, d.mode); targetHour = c.value(.targetHour, d.targetHour); targetMinute = c.value(.targetMinute, d.targetMinute)
        format = c.value(.format, d.format); labelPosition = c.value(.labelPosition, d.labelPosition)
        uppercaseLabel = c.value(.uppercaseLabel, d.uppercaseLabel); showSubtext = c.value(.showSubtext, d.showSubtext)
        endBehavior = c.value(.endBehavior, d.endBehavior); endText = c.value(.endText, d.endText)
        box = c.value(.box, d.box); font = c.value(.font, d.font); weight = c.value(.weight, d.weight)
        placement = c.value(.placement, d.placement); digitsScale = c.value(.digitsScale, d.digitsScale)
        labelScale = c.value(.labelScale, d.labelScale); padding = c.value(.padding, d.padding)
        letterSpacing = c.value(.letterSpacing, d.letterSpacing); shadow = c.value(.shadow, d.shadow)
        warnSeconds = c.value(.warnSeconds, d.warnSeconds); warnRGB = c.value(.warnRGB, d.warnRGB)
        flash = c.value(.flash, d.flash); flashSeconds = c.value(.flashSeconds, d.flashSeconds)
    }
}

public enum CountdownClock {
    /// Formats a non-negative number of seconds.
    public static func display(_ seconds: Double, format: CountdownTimeFormat) -> String {
        let s = max(0, seconds)
        // count down shows the second that is running (09:59.4 → "10:00" would be wrong), so round up
        let whole = Int(s.rounded(.up))
        let h = whole / 3600, m = whole / 60 % 60, sec = whole % 60
        switch format {
        case .auto: return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
        case .mmss: return String(format: "%02d:%02d", whole / 60, sec)
        case .hhmmss: return String(format: "%02d:%02d:%02d", h, m, sec)
        case .mss: return String(format: "%d:%02d", whole / 60, sec)
        case .seconds: return "\(whole)"
        case .tenths:
            let t = Int((s * 10).rounded(.down))
            return String(format: "%02d:%02d.%d", t / 600, t / 10 % 60, t % 10)
        }
    }

    /// Seconds from `now` until hour:minute today; a time more than 12 hours ago means tomorrow.
    public static func secondsUntil(hour: Int, minute: Int, from now: Date = Date(), calendar: Calendar = .current) -> Double {
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = hour; c.minute = minute; c.second = 0
        guard let target = calendar.date(from: c) else { return 0 }
        var diff = target.timeIntervalSince(now)
        if diff < -43200 { diff += 86400 }
        return diff
    }

    public enum State: Equatable, Sendable {
        case running(String)
        case warning(String)
        case ended(String)
        case overtime(String)
    }

    /// What to show for `seconds` left (negative = past zero) under the style's rules.
    public static func state(seconds: Double, style: CountdownStyle) -> State {
        if style.mode == .countUp { return .running(display(seconds, format: style.format)) }
        if seconds > 0 {
            let text = display(seconds, format: style.format)
            return style.warnSeconds > 0 && seconds <= style.warnSeconds ? .warning(text) : .running(text)
        }
        switch style.endBehavior {
        case .overtime: return .overtime("+" + display(-seconds, format: style.format))
        case .endText: return .ended(style.endText)
        case .stop, .hide: return .ended(display(0, format: style.format))
        }
    }
}
