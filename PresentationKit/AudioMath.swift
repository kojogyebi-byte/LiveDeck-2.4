import Foundation

/// Mixer maths shared by the audio console and its tests.
public enum AudioMath {
    public static let minDB = -60.0

    public static func dbToGain(_ db: Double) -> Double { db <= minDB ? 0 : pow(10, db / 20) }
    public static func gainToDB(_ g: Double) -> Double { g <= 0.000_001 ? minDB : max(minDB, 20 * log10(g)) }

    /// Constant-power pan law. `pan` is -100 (left) … +100 (right); returns (left, right) gains.
    public static func panGains(_ pan: Double) -> (left: Double, right: Double) {
        let p = (min(max(pan, -100), 100) + 100) / 200          // 0…1
        let angle = p * Double.pi / 2
        return (cos(angle) * sqrt(2), sin(angle) * sqrt(2))       // unity at centre
    }

    /// Fader position (0…1, 0.75 = 0 dB) ↔ dB, mimicking a console fader scale.
    public static func faderDB(position: Double) -> Double {
        let p = min(max(position, 0), 1)
        if p >= 0.75 { return (p - 0.75) / 0.25 * 10 }                 // 0 … +10 dB
        if p >= 0.25 { return (p - 0.75) / 0.5 * 30 }                  // -30 … 0 dB
        if p <= 0 { return minDB }
        return -30 + (p - 0.25) / 0.25 * 30                          // -60 … -30 dB
    }
    public static func faderPosition(db: Double) -> Double {
        if db <= minDB { return 0 }
        if db >= 0 { return min(1, 0.75 + db / 10 * 0.25) }
        if db >= -30 { return 0.75 + db / 30 * 0.5 }
        return max(0, 0.25 + (db + 30) / 30 * 0.25)
    }

    /// Text for a dB value: "+4.00", "-13.00", "-∞".
    public static func dbText(_ db: Double, decimals: Int = 2) -> String {
        if db <= minDB { return "-∞" }
        return String(format: "%+.\(decimals)f", db)
    }
}
