import Foundation

// MARK: - Auto Mix: automatic switching between chosen inputs

public enum AutoMixMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case timed = "Timed"
    case voice = "Follow the voice"
    public var id: String { rawValue }
}

public enum AutoMixOrder: String, Codable, Sendable, CaseIterable, Identifiable {
    case sequence = "In order"
    case random = "Shuffle"
    public var id: String { rawValue }
}

public enum AutoMixOverride: String, Codable, Sendable, CaseIterable, Identifiable {
    case pause = "Pause Auto Mix"
    case resumeAfter = "Resume after a while"
    case continueFromThere = "Carry on from my shot"
    public var id: String { rawValue }
}

public struct AutoMixSlot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var inputName: String
    public var seconds: Double
    public var enabled: Bool
    /// Voice mode: the input whose microphone level decides this shot (nil = the input itself).
    public var micName: String?
    public init(id: UUID = UUID(), inputName: String, seconds: Double = 8, enabled: Bool = true, micName: String? = nil) {
        self.id = id; self.inputName = inputName; self.seconds = seconds; self.enabled = enabled; self.micName = micName
    }
}

public struct AutoMixPlan: Codable, Equatable, Sendable {
    public var mode: AutoMixMode = .timed
    public var order: AutoMixOrder = .sequence
    public var useTransition = true
    public var override: AutoMixOverride = .resumeAfter
    public var resumeAfterSeconds: Double = 20
    public var variation: Double = 0            // 0…0.5: ± share of each slot's time, for a natural feel
    public var slots: [AutoMixSlot] = []
    // voice mode
    public var voiceThreshold: Double = 0.06    // linear peak level that counts as speaking
    public var switchDelay: Double = 0.7        // a new speaker must lead this long
    public var minShotSeconds: Double = 2.5     // never cut faster than this
    public var wideShotName: String?            // several people talking or silence → this input
    public var silenceSeconds: Double = 5
    public init() {}

    enum CodingKeys: String, CodingKey {
        case mode, order, useTransition, override, resumeAfterSeconds, variation, slots, voiceThreshold, switchDelay, minShotSeconds, wideShotName, silenceSeconds
    }
    public init(from decoder: Decoder) throws {
        let d = AutoMixPlan()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.value(.mode, d.mode); order = c.value(.order, d.order); useTransition = c.value(.useTransition, d.useTransition)
        override = c.value(.override, d.override); resumeAfterSeconds = c.value(.resumeAfterSeconds, d.resumeAfterSeconds)
        variation = c.value(.variation, d.variation); slots = c.value(.slots, d.slots)
        voiceThreshold = c.value(.voiceThreshold, d.voiceThreshold); switchDelay = c.value(.switchDelay, d.switchDelay)
        minShotSeconds = c.value(.minShotSeconds, d.minShotSeconds); wideShotName = try? c.decodeIfPresent(String.self, forKey: .wideShotName)
        silenceSeconds = c.value(.silenceSeconds, d.silenceSeconds)
    }
}

public struct AutoMixDecision: Equatable, Sendable {
    public var inputName: String
    public var useTransition: Bool
    public var reason: String
}

/// Pure switching logic; the app calls `tick` about ten times a second.
public struct AutoMixDirector: Sendable {
    public enum State: Equatable, Sendable { case stopped, running, paused, holding(until: Double) }

    public private(set) var plan: AutoMixPlan
    public private(set) var state: State = .stopped
    public private(set) var currentIndex: Int?
    public private(set) var shotStarted: Double = 0
    public private(set) var shotLength: Double = 0
    private var rng: UInt64
    private var lastShuffle: [Int] = []
    // voice
    private var candidate: String?
    private var candidateSince: Double = 0
    private var silenceSince: Double?
    private var groupSince: Double?
    public private(set) var currentShot: String?

    public init(plan: AutoMixPlan, seed: UInt64 = 0x9E3779B97F4A7C15) {
        self.plan = plan
        rng = seed
    }

    public mutating func update(plan: AutoMixPlan) {
        self.plan = plan
        if let i = currentIndex, i >= plan.slots.count { currentIndex = nil }
    }

    public var isActive: Bool { state != .stopped }

    private var activeSlots: [Int] { plan.slots.indices.filter { plan.slots[$0].enabled } }

    private mutating func random() -> Double {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Double(rng >> 11) / Double(1 << 53)
    }

    private mutating func length(of index: Int) -> Double {
        let base = max(1, plan.slots[index].seconds)
        guard plan.variation > 0 else { return base }
        let v = min(0.5, plan.variation)
        return max(1, base * (1 + (random() * 2 - 1) * v))
    }

    private mutating func nextIndex(after current: Int?, available: Set<String>) -> Int? {
        let candidates = activeSlots.filter { available.contains(plan.slots[$0].inputName) }
        guard !candidates.isEmpty else { return nil }
        if plan.order == .random && candidates.count > 1 {
            let pool = candidates.filter { $0 != current }
            return pool[min(pool.count - 1, Int(random() * Double(pool.count)))]
        }
        guard let current, let pos = activeSlots.firstIndex(of: current) else { return candidates.first }
        for step in 1...activeSlots.count {
            let idx = activeSlots[(pos + step) % activeSlots.count]
            if available.contains(plan.slots[idx].inputName) { return idx }
        }
        return nil
    }

    /// Starts Auto Mix; returns the first shot (timed) or nothing (voice waits for someone to speak).
    public mutating func start(now: Double, program: String?, available: Set<String>) -> AutoMixDecision? {
        state = .running
        candidate = nil; silenceSince = nil; groupSince = nil
        currentShot = program
        if plan.mode == .voice { shotStarted = now; return nil }
        if let program, let i = activeSlots.first(where: { plan.slots[$0].inputName == program }) {
            currentIndex = i; shotStarted = now; shotLength = length(of: i)
            return nil
        }
        guard let first = nextIndex(after: nil, available: available) else { return nil }
        return take(first, now: now, reason: "Auto Mix started")
    }

    public mutating func stop() { state = .stopped; candidate = nil }
    public mutating func pause() { if state != .stopped { state = .paused } }

    public mutating func resume(now: Double) {
        guard state != .stopped else { return }
        state = .running
        shotStarted = now
        if let i = currentIndex { shotLength = length(of: i) }
        candidate = nil
    }

    private mutating func take(_ index: Int, now: Double, reason: String) -> AutoMixDecision {
        currentIndex = index
        shotStarted = now
        shotLength = length(of: index)
        currentShot = plan.slots[index].inputName
        return AutoMixDecision(inputName: plan.slots[index].inputName, useTransition: plan.useTransition, reason: reason)
    }

    /// Skips to the next shot now.
    public mutating func next(now: Double, available: Set<String>) -> AutoMixDecision? {
        guard state != .stopped, let i = nextIndex(after: currentIndex, available: available) else { return nil }
        if case .holding = state { state = .running }
        if state == .paused { state = .running }
        return take(i, now: now, reason: "Next shot")
    }

    /// The operator switched by hand.
    public mutating func manualSwitch(to name: String?, now: Double) {
        guard state != .stopped else { return }
        currentShot = name
        if let name, let i = plan.slots.firstIndex(where: { $0.inputName == name }) { currentIndex = i }
        switch plan.override {
        case .pause: state = .paused
        case .resumeAfter: state = .holding(until: now + max(1, plan.resumeAfterSeconds))
        case .continueFromThere:
            shotStarted = now
            if let i = currentIndex { shotLength = length(of: i) }
        }
        candidate = nil
    }

    public func remaining(now: Double) -> Double {
        switch state {
        case .holding(let until): return max(0, until - now)
        case .running where plan.mode == .timed: return max(0, shotLength - (now - shotStarted))
        default: return 0
        }
    }

    /// `levels`: current microphone level (0…1) by input name.
    public mutating func tick(now: Double, program: String?, available: Set<String>, levels: [String: Double] = [:]) -> AutoMixDecision? {
        switch state {
        case .stopped, .paused: return nil
        case .holding(let until):
            guard now >= until else { return nil }
            state = .running
            shotStarted = now
            if let i = currentIndex { shotLength = length(of: i) }
            if plan.mode == .timed { return nil }
        case .running: break
        }
        return plan.mode == .timed ? tickTimed(now: now, available: available) : tickVoice(now: now, program: program, available: available, levels: levels)
    }

    private mutating func tickTimed(now: Double, available: Set<String>) -> AutoMixDecision? {
        if let i = currentIndex, i < plan.slots.count, plan.slots[i].enabled, available.contains(plan.slots[i].inputName) {
            guard now - shotStarted >= shotLength else { return nil }
        }
        guard let next = nextIndex(after: currentIndex, available: available) else { return nil }
        if next == currentIndex { shotStarted = now; return nil }
        return take(next, now: now, reason: "Time slot")
    }

    private mutating func tickVoice(now: Double, program: String?, available: Set<String>, levels: [String: Double]) -> AutoMixDecision? {
        let speakers = activeSlots.filter { available.contains(plan.slots[$0].inputName) }
        guard !speakers.isEmpty else { return nil }
        let scored = speakers.map { i -> (Int, Double) in
            let s = plan.slots[i]
            return (i, levels[s.micName ?? s.inputName] ?? 0)
        }.sorted { $0.1 > $1.1 }
        let talking = scored.filter { $0.1 >= plan.voiceThreshold }
        let sinceShot = now - shotStarted
        let wide = plan.wideShotName.flatMap { available.contains($0) ? $0 : nil }

        // silence → wide shot
        if talking.isEmpty {
            if silenceSince == nil { silenceSince = now }
            candidate = nil; groupSince = nil
            if let wide, currentShot != wide, now - (silenceSince ?? now) >= plan.silenceSeconds, sinceShot >= plan.minShotSeconds {
                return takeName(wide, now: now, reason: "Nobody speaking")
            }
            return nil
        }
        silenceSince = nil

        // several people at once → wide shot
        if talking.count >= 2, talking[1].1 >= talking[0].1 * 0.7, let wide {
            if groupSince == nil { groupSince = now }
            if currentShot != wide, now - (groupSince ?? now) >= plan.switchDelay * 1.5, sinceShot >= plan.minShotSeconds {
                candidate = nil
                return takeName(wide, now: now, reason: "Several people speaking")
            }
            return nil
        }
        groupSince = nil

        let leader = plan.slots[talking[0].0].inputName
        if leader == currentShot { candidate = nil; return nil }
        if candidate != leader { candidate = leader; candidateSince = now; return nil }
        guard now - candidateSince >= plan.switchDelay, sinceShot >= plan.minShotSeconds else { return nil }
        candidate = nil
        return take(talking[0].0, now: now, reason: "\(leader) is speaking")
    }

    private mutating func takeName(_ name: String, now: Double, reason: String) -> AutoMixDecision {
        currentShot = name
        shotStarted = now
        if let i = plan.slots.firstIndex(where: { $0.inputName == name }) { currentIndex = i }
        return AutoMixDecision(inputName: name, useTransition: plan.useTransition, reason: reason)
    }
}

// MARK: - Loudness (ITU-R BS.1770 / EBU R128)

/// K-weighted loudness: momentary (400 ms), short-term (3 s) and gated integrated LUFS.
public final class LoudnessMeter {
    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private let sampleRate: Double
    private var shelfL: Biquad, shelfR: Biquad, hpL: Biquad, hpR: Biquad
    private let blockSize: Int                 // 100 ms
    private var blockSum = 0.0, blockCount = 0
    private var blocks: [Double] = []          // mean-square energy of each 100 ms block
    private var gatedBlocks: [Double] = []     // 400 ms blocks (75% overlap) for the integrated value

    public private(set) var momentary = -Double.infinity
    public private(set) var shortTerm = -Double.infinity
    public private(set) var integrated = -Double.infinity

    public init(sampleRate: Double = 48000) {
        self.sampleRate = sampleRate
        // BS.1770 pre-filter (high shelf) and RLB high-pass, derived for the sample rate
        let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
        let k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        let f1 = 38.13547087602444, q1 = 0.5003270373238773
        let k1 = tan(Double.pi * f1 / sampleRate)
        let a01 = 1 + k1 / q1 + k1 * k1
        let hp = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k1 * k1 - 1) / a01, a2: (1 - k1 / q1 + k1 * k1) / a01)
        shelfL = shelf; shelfR = shelf; hpL = hp; hpR = hp
        blockSize = Int(sampleRate / 10)
    }

    public func reset() {
        blocks = []; gatedBlocks = []; blockSum = 0; blockCount = 0
        momentary = -.infinity; shortTerm = -.infinity; integrated = -.infinity
    }

    static func lufs(_ meanSquare: Double) -> Double { meanSquare <= 0 ? -.infinity : -0.691 + 10 * log10(meanSquare) }

    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        for i in 0..<frames {
            let l = hpL.process(shelfL.process(Double(left[i])))
            let r = hpR.process(shelfR.process(Double(right[i])))
            blockSum += l * l + r * r
            blockCount += 1
            if blockCount == blockSize { finishBlock() }
        }
    }

    private func finishBlock() {
        blocks.append(blockSum / Double(blockSize))
        blockSum = 0; blockCount = 0
        if blocks.count > 30 { blocks.removeFirst(blocks.count - 30) }
        if blocks.count >= 4 {
            let m = blocks.suffix(4).reduce(0, +) / 4
            momentary = Self.lufs(m)
            if gatedBlocks.count < 36_000 { gatedBlocks.append(m) }     // up to 1 hour at 10 blocks/s
            updateIntegrated()
        }
        let st = blocks.suffix(30)
        shortTerm = st.count == 30 ? Self.lufs(st.reduce(0, +) / 30) : momentary
    }

    private func updateIntegrated() {
        let absolute = gatedBlocks.filter { Self.lufs($0) > -70 }
        guard !absolute.isEmpty else { integrated = -.infinity; return }
        let relativeGate = Self.lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { Self.lufs($0) > relativeGate }
        integrated = gated.isEmpty ? -.infinity : Self.lufs(gated.reduce(0, +) / Double(gated.count))
    }
}

public enum LoudnessTarget: String, Codable, Sendable, CaseIterable, Identifiable {
    case podcast = "Podcast (−16 LUFS)"
    case streaming = "YouTube / streaming (−14 LUFS)"
    case broadcast = "Broadcast EBU R128 (−23 LUFS)"
    public var id: String { rawValue }
    public var lufs: Double { self == .podcast ? -16 : (self == .streaming ? -14 : -23) }
}
