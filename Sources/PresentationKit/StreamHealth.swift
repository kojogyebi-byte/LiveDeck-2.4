import Foundation

// MARK: - Live stream health (from ffmpeg -progress output)

public struct FFmpegProgress: Equatable, Sendable {
    public var frame: Int = 0
    public var fps: Double = 0
    public var bitrateKbps: Double = 0
    public var totalBytes: Int64 = 0
    public var dropFrames: Int = 0
    public var dupFrames: Int = 0
    public var speed: Double = 0
    public var outTimeSeconds: Double = 0
    public init() {}

    /// Parses one or more `key=value` progress blocks; later values win.
    public mutating func apply(_ text: String) {
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "frame": frame = Int(value) ?? frame
            case "fps": fps = Double(value) ?? fps
            case "bitrate":
                // "2512.3kbits/s" or "N/A"
                let num = value.replacingOccurrences(of: "kbits/s", with: "")
                if let v = Double(num) { bitrateKbps = v }
            case "total_size": totalBytes = Int64(value) ?? totalBytes
            case "drop_frames": dropFrames = Int(value) ?? dropFrames
            case "dup_frames": dupFrames = Int(value) ?? dupFrames
            case "speed":
                if let v = Double(value.replacingOccurrences(of: "x", with: "")) { speed = v }
            case "out_time_us", "out_time_ms":
                // ffmpeg writes microseconds under both names
                if let v = Double(value) { outTimeSeconds = v / 1_000_000 }
            default: break
            }
        }
    }
}

public enum StreamHealthLevel: String, Sendable {
    case off = "Off"
    case connecting = "Connecting"
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Unstable"
    case poor = "Poor"
}

public struct StreamHealth: Equatable, Sendable {
    public var level: StreamHealthLevel
    public var bars: Int            // 0…5
    public var advice: String

    public init(level: StreamHealthLevel, bars: Int, advice: String) {
        self.level = level; self.bars = bars; self.advice = advice
    }

    /// - Parameters:
    ///   - seconds: time since the stream started
    ///   - speed: ffmpeg encode/send speed (1.0 = real time)
    ///   - backlogSeconds: how far the sender is behind real time
    ///   - droppedRecently: frames dropped in the last few seconds
    ///   - receivedProgress: whether ffmpeg has reported progress yet
    public static func evaluate(streaming: Bool, seconds: Double, speed: Double, backlogSeconds: Double,
                                droppedRecently: Int, fps: Int, receivedProgress: Bool) -> StreamHealth {
        guard streaming else { return StreamHealth(level: .off, bars: 0, advice: "") }
        if !receivedProgress || seconds < 4 {
            return StreamHealth(level: .connecting, bars: 1, advice: "Connecting to the platform…")
        }
        let f = max(1, fps)
        if backlogSeconds > 3 || (speed > 0 && speed < 0.9) {
            return StreamHealth(level: .poor, bars: 1,
                                advice: "The network or encoder cannot keep up — lower the stream bitrate or resolution.")
        }
        if backlogSeconds > 1 || (speed > 0 && speed < 0.97) || droppedRecently > f {
            return StreamHealth(level: .fair, bars: 3,
                                advice: "Some frames are late or dropped — check the internet upload speed.")
        }
        if backlogSeconds > 0.35 || (speed > 0 && speed < 0.99) || droppedRecently > 0 {
            return StreamHealth(level: .good, bars: 4, advice: "Streaming normally.")
        }
        return StreamHealth(level: .excellent, bars: 5, advice: "Streaming smoothly.")
    }
}

public enum StatusFormat {
    public static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
    public static func bytes(_ b: Int64) -> String {
        let mb = Double(b) / 1_000_000
        return mb >= 1000 ? String(format: "%.2f GB", mb / 1000) : String(format: "%.0f MB", mb)
    }
    public static func bitrate(_ kbps: Double) -> String {
        kbps >= 1000 ? String(format: "%.1f Mbps", kbps / 1000) : String(format: "%.0f kbps", kbps)
    }
    /// Hours of recording left on `freeBytes` at `mbps`.
    public static func hoursLeft(freeBytes: Int64, mbps: Double) -> Double {
        guard mbps > 0 else { return 0 }
        return Double(freeBytes) * 8 / (mbps * 1_000_000) / 3600
    }
}

// MARK: - Stream bitrate choices (video and audio separately)

public enum StreamBitrates {
    /// Video bitrate choices in kb/s, starting at 128 kb/s.
    public static let video: [Int] = [128, 192, 256, 384, 512, 768, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4500,
                                      5000, 6000, 8000, 10000, 12000, 15000, 20000, 25000, 35000, 51000]
    /// AAC audio bitrate choices in kb/s, starting at 128 kb/s.
    public static let audio: [Int] = [128, 160, 192, 256, 320]
    public static let videoRange = 128...51000
    public static let defaultVideo = 4500
    public static let defaultAudio = 160

    /// "128 kb/s", "4.5 Mb/s"
    public static func label(_ kbps: Int) -> String {
        if kbps < 1000 { return "\(kbps) kb/s" }
        let m = Double(kbps) / 1000
        return m.rounded() == m ? String(format: "%.0f Mb/s", m) : String(format: "%.1f Mb/s", m)
    }

    /// Typical video bitrate range for a resolution and frame rate (close to YouTube's live guidance).
    public static func recommendedVideo(height: Int, fps: Double) -> ClosedRange<Int> {
        let high = fps > 35
        switch height {
        case ..<500: return high ? 1000...2500 : 500...2000
        case ..<800: return high ? 2250...6000 : 1500...4000
        case ..<1200: return high ? 4500...9000 : 3000...6000
        case ..<1800: return high ? 9000...18000 : 6000...13000
        default: return high ? 20000...51000 : 13000...34000
        }
    }

    /// Advice about the chosen bitrate, or nil when it is in the usual range.
    public static func advice(videoKbps: Int, height: Int, fps: Double) -> String? {
        let r = recommendedVideo(height: height, fps: fps)
        if videoKbps < r.lowerBound / 2 {
            return "Very low for \(height)p — expect blocky video. Lower the resolution (e.g. 480p/720p) or raise the video bitrate towards \(label(r.lowerBound))."
        }
        if videoKbps < r.lowerBound {
            return "Below the usual \(label(r.lowerBound))–\(label(r.upperBound)) for \(height)p; fine for slides and still shots, softer on movement."
        }
        if videoKbps > r.upperBound * 3 / 2 {
            return "Higher than most platforms accept for \(height)p (usually up to \(label(r.upperBound)))."
        }
        return nil
    }

    /// Upload speed to have available: total stream bitrate plus 50% headroom, in kb/s.
    public static func uploadNeeded(videoKbps: Int, audioKbps: Int, audioOn: Bool, destinations: Int) -> Int {
        let total = videoKbps + (audioOn ? audioKbps : 0)
        return total * max(1, destinations) * 3 / 2
    }
}
