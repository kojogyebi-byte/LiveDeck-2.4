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
