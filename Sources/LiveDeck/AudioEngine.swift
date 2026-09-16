import Foundation
import AVFoundation
import MediaToolbox
import CoreMedia
import os
import PresentationKit

// MARK: - Program audio engine
//
// Every input's real audio goes through one mixer:
//
//   microphones / capture devices ──► ring buffer ─┐
//   video & audio files (tap on AVPlayer) ─► ring ─┤──► per-channel EQ/gate/comp ► trim × fader ► pan ► ON/AFV
//                                                  │         ├──► PROGRAM bus ► master EQ/dynamics ► master fader/mute ► recording + stream
//                                                  │         └──► MONITOR bus (solo = headphones) ► Mac output
//
// File audio is taken out of AVPlayer with an MTAudioProcessingTap and silenced there, so muting, faders,
// pan, AFV and the master really change what you hear, record and stream. Meters read the real samples.

/// Stereo ring buffer (48 kHz frames) shared between a capture/tap thread and the render thread.
final class StereoRing {
    private var left: [Float]
    private var right: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var stored = 0
    private var primed = false
    private let capacity: Int
    private let primeFrames: Int
    private let maxLatencyFrames: Int
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    init(capacitySeconds: Double = 2, primeSeconds: Double = 0.03, maxLatencySeconds: Double = 0.25) {
        capacity = Int(48000 * capacitySeconds)
        primeFrames = Int(48000 * primeSeconds)
        maxLatencyFrames = Int(48000 * maxLatencySeconds)
        left = [Float](repeating: 0, count: capacity)
        right = [Float](repeating: 0, count: capacity)
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }
    deinit { lock.deinitialize(count: 1); lock.deallocate() }

    func write(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        os_unfair_lock_lock(lock)
        for i in 0..<frames {
            left[writeIndex] = l[i]; right[writeIndex] = r[i]
            writeIndex += 1; if writeIndex == capacity { writeIndex = 0 }
        }
        stored += frames
        if stored > capacity { readIndex = writeIndex; stored = capacity }
        // Source clock faster than output clock → drop the oldest audio, keep latency low.
        if stored > maxLatencyFrames {
            let drop = stored - primeFrames * 2
            readIndex = (readIndex + drop) % capacity
            stored -= drop
        }
        os_unfair_lock_unlock(lock)
    }

    /// Reads `frames` frames; returns how many were real audio (the rest is silence).
    @discardableResult
    func read(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        os_unfair_lock_lock(lock)
        if !primed && stored >= primeFrames { primed = true }
        var got = 0
        if primed {
            got = min(frames, stored)
            for i in 0..<got {
                l[i] = left[readIndex]; r[i] = right[readIndex]
                readIndex += 1; if readIndex == capacity { readIndex = 0 }
            }
            stored -= got
            if stored == 0 { primed = false }
        }
        os_unfair_lock_unlock(lock)
        if got < frames {
            for i in got..<frames { l[i] = 0; r[i] = 0 }
        }
        return got
    }

    func clear() {
        os_unfair_lock_lock(lock)
        readIndex = 0; writeIndex = 0; stored = 0; primed = false
        os_unfair_lock_unlock(lock)
    }
}

// MARK: capture device → ring

final class DeviceAudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let deviceID: String
    private let ring: StereoRing
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "livedeck.audio.capture", qos: .userInteractive)

    init(deviceID: String, ring: StereoRing) {
        self.deviceID = deviceID
        self.ring = ring
        super.init()
    }

    func start() {
        guard let dev = AVCaptureDevice(uniqueID: deviceID), let input = try? AVCaptureDeviceInput(device: dev) else { return }
        let s = AVCaptureSession()
        if s.canAddInput(input) { s.addInput(input) }
        let out = AVCaptureAudioDataOutput()
        out.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        out.setSampleBufferDelegate(self, queue: queue)
        if s.canAddOutput(out) { s.addOutput(out) }
        session = s
        queue.async { s.startRunning() }
    }

    func stop() {
        let s = session
        session = nil
        queue.async { s?.stopRunning() }
        ring.clear()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let bb = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var len = 0, total = 0
        var dp: UnsafeMutablePointer<Int8>? = nil
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: &len, totalLengthOut: &total, dataPointerOut: &dp) == kCMBlockBufferNoErr,
              let dp else { return }
        let n = min(len, total) / MemoryLayout<Float>.size
        guard n > 0 else { return }
        dp.withMemoryRebound(to: Float.self, capacity: n) { fp in
            ring.write(fp, fp, frames: n)          // mono microphone → both sides (pan places it)
        }
    }
}

// MARK: media file → tap → ring

final class MediaTapContext {
    let ring: StereoRing
    /// When true the player keeps its own output (engine not running) instead of being silenced.
    var bypass = true
    private var sampleRate: Double = 48000
    private var channels = 2
    private var nonInterleaved = true
    private var isFloat32 = true
    private var phase: Double = 0
    private var lastL: Float = 0
    private var lastR: Float = 0
    private var inL = [Float](repeating: 0, count: 16384)
    private var inR = [Float](repeating: 0, count: 16384)
    private var outL = [Float](repeating: 0, count: 16384)
    private var outR = [Float](repeating: 0, count: 16384)

    init(ring: StereoRing) { self.ring = ring }

    func prepare(_ asbd: AudioStreamBasicDescription) {
        sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
        channels = max(1, Int(asbd.mChannelsPerFrame))
        nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        isFloat32 = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && asbd.mBitsPerChannel == 32
        phase = 0
    }

    func consume(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(list)
        guard frames > 0, isFloat32, abl.count > 0 else { return }
        let n = min(frames, inL.count)
        if nonInterleaved {
            guard let l = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let r = (abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil) ?? l
            for i in 0..<n { inL[i] = l[i]; inR[i] = r[i] }
        } else {
            guard let p = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = channels
            for i in 0..<n { inL[i] = p[i * ch]; inR[i] = ch > 1 ? p[i * ch + 1] : p[i * ch] }
        }
        resampleAndWrite(n)
        if !bypass {
            for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        }
    }

    /// Linear resampling to 48 kHz (files are often 44.1 kHz).
    private func resampleAndWrite(_ n: Int) {
        if abs(sampleRate - 48000) < 1 {
            inL.withUnsafeBufferPointer { l in inR.withUnsafeBufferPointer { r in
                ring.write(l.baseAddress!, r.baseAddress!, frames: n)
            } }
            return
        }
        let step = sampleRate / 48000
        var out = 0
        var pos = phase
        while pos < Double(n) && out < outL.count {
            let i = Int(pos)
            let frac = Float(pos - Double(i))
            let l0 = i == 0 ? lastL : inL[i - 1], r0 = i == 0 ? lastR : inR[i - 1]
            let l1 = inL[min(i, n - 1)], r1 = inR[min(i, n - 1)]
            outL[out] = l0 + (l1 - l0) * frac
            outR[out] = r0 + (r1 - r0) * frac
            out += 1
            pos += step
        }
        phase = pos - Double(n)
        lastL = inL[n - 1]; lastR = inR[n - 1]
        outL.withUnsafeBufferPointer { l in outR.withUnsafeBufferPointer { r in
            ring.write(l.baseAddress!, r.baseAddress!, frames: out)
        } }
    }
}

enum MediaAudioTap {
    /// Installs a processing tap on the item's first audio track. Returns false for items without a local
    /// audio track (for example HLS streams), which keep playing through AVPlayer directly.
    static func install(on item: AVPlayerItem, context: MediaTapContext, completion: @escaping (Bool) -> Void) {
        item.asset.loadTracks(withMediaType: .audio) { tracks, _ in
            DispatchQueue.main.async {
                guard let track = tracks?.first else { completion(false); return }
                var callbacks = MTAudioProcessingTapCallbacks(
                    version: kMTAudioProcessingTapCallbacksVersion_0,
                    clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
                    init: { _, clientInfo, tapStorageOut in
                        tapStorageOut.pointee = clientInfo
                    },
                    finalize: { tap in
                        Unmanaged<MediaTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
                    },
                    prepare: { tap, _, processingFormat in
                        Unmanaged<MediaTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                            .prepare(processingFormat.pointee)
                    },
                    unprepare: { _ in },
                    process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                        let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                        guard status == noErr else { return }
                        Unmanaged<MediaTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                            .consume(bufferListInOut, frames: Int(numberFramesOut.pointee))
                    })
                var tap: MTAudioProcessingTap?
                let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
                guard err == noErr, let tap else { completion(false); return }
                let params = AVMutableAudioMixInputParameters(track: track)
                params.audioTapProcessor = tap
                let mix = AVMutableAudioMix()
                mix.inputParameters = [params]
                item.audioMix = mix
                completion(true)
            }
        }
    }
}

// MARK: mixer

struct ChannelParams {
    var fader: Float = 1          // trim × fader (linear)
    var on: Float = 1             // 0 when muted / off / AFV not on Program
    var panL: Float = 1
    var panR: Float = 1
    var solo = false
    var fx = EffectSnapshot()
}

final class MixChannel {
    let id: UUID
    let mediaRing = StereoRing(primeSeconds: 0.02)
    let liveRing = StereoRing(primeSeconds: 0.03)
    var capture: DeviceAudioCapture?
    var tapContext: MediaTapContext?
    var tapInstalledForItem: ObjectIdentifier?
    var params = ChannelParams()
    let dspL = AudioDSP(), dspR = AudioDSP()
    var lastGain: Float = 0

    // render scratch (resized when the block size changes)
    var mL = [Float](), mR = [Float](), lL = [Float](), lR = [Float]()
    // meters (render writes, UI reads)
    var peakL: Float = 0
    var peakR: Float = 0

    init(id: UUID) { self.id = id }
}

final class ProgramAudioEngine {
    static let sampleRate = 48000.0

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private(set) var isRunning = false
    private(set) var lastError = ""

    private var channels: [UUID: MixChannel] = [:]
    private var order: [MixChannel] = []
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    // master / monitor (set from the main thread)
    var masterGain: Float = 1
    var masterFX = EffectSnapshot()
    var monitorGain: Float = 1
    var hearLiveInputs = false
    private var lastMasterGain: Float = 1
    private let masterDSPL = AudioDSP(), masterDSPR = AudioDSP()
    private(set) var masterPeakL: Float = 0
    private(set) var masterPeakR: Float = 0

    // program output consumers (called on the render thread — keep them short)
    var programSink: ((UnsafePointer<Float>, UnsafePointer<Float>, Int, CMTime) -> Void)?

    // render scratch
    private var progL = [Float](), progR = [Float](), monL = [Float](), monR = [Float](), soloL = [Float](), soloR = [Float]()

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restartAfterDeviceChange()
        }
    }

    // MARK: lifecycle

    func start() {
        guard !isRunning else { return }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2) else { return }
        if sourceNode == nil {
            let node = AVAudioSourceNode(format: fmt) { [weak self] _, timestamp, frameCount, _, outputData -> OSStatus in
                self?.render(frames: Int(frameCount), timestamp: timestamp, output: outputData)
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            sourceNode = node
        }
        engine.mainMixerNode.outputVolume = 1
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            lastError = ""
        } catch {
            isRunning = false
            lastError = "Audio output could not start: \(error.localizedDescription)"
        }
        setBypass(!isRunning)
    }

    private func restartAfterDeviceChange() {
        isRunning = false
        engine.stop()
        start()
    }

    private func setBypass(_ on: Bool) {
        withLock { for c in order { c.tapContext?.bypass = on } }
    }

    @inline(__always) private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return body()
    }

    // MARK: channel management (main thread)

    func channel(_ id: UUID) -> MixChannel {
        if let c = channels[id] { return c }
        let c = MixChannel(id: id)
        withLock { channels[id] = c; order.append(c) }
        return c
    }

    func removeChannels(notIn keep: Set<UUID>) {
        let gone = channels.values.filter { !keep.contains($0.id) }
        guard !gone.isEmpty else { return }
        for c in gone { c.capture?.stop(); c.capture = nil; c.tapContext?.bypass = true }
        withLock {
            for c in gone { channels[c.id] = nil }
            order.removeAll { !keep.contains($0.id) }
        }
    }

    func setDevice(_ deviceID: String?, for c: MixChannel) {
        if c.capture?.deviceID == deviceID { return }
        c.capture?.stop()
        c.capture = nil
        c.liveRing.clear()
        if let d = deviceID {
            let cap = DeviceAudioCapture(deviceID: d, ring: c.liveRing)
            cap.start()
            c.capture = cap
        }
    }

    /// Routes a player's audio through the mixer (once per player item).
    func attachMedia(_ item: AVPlayerItem, to c: MixChannel, onResult: @escaping (Bool) -> Void) {
        let key = ObjectIdentifier(item)
        guard c.tapInstalledForItem != key else { return }
        c.tapInstalledForItem = key
        let ctx = MediaTapContext(ring: c.mediaRing)
        ctx.bypass = !isRunning
        MediaAudioTap.install(on: item, context: ctx) { [weak self] ok in
            if ok { c.tapContext = ctx; ctx.bypass = !(self?.isRunning ?? false) }
            onResult(ok)
        }
    }

    func update(_ c: MixChannel, _ p: ChannelParams) {
        withLock { c.params = p }
    }

    /// Peaks since the last call (then reset). L, R per channel and master.
    func takeMeters() -> (channels: [UUID: (Float, Float)], master: (Float, Float)) {
        withLock {
            var out: [UUID: (Float, Float)] = [:]
            for c in order { out[c.id] = (c.peakL, c.peakR); c.peakL = 0; c.peakR = 0 }
            let m = (masterPeakL, masterPeakR)
            masterPeakL = 0; masterPeakR = 0
            return (out, m)
        }
    }

    // MARK: render (audio thread)

    private func ensure(_ a: inout [Float], _ n: Int) { if a.count != n { a = [Float](repeating: 0, count: n) } }

    private func render(frames n: Int, timestamp: UnsafePointer<AudioTimeStamp>, output: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(output)
        guard n > 0, abl.count >= 2,
              let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        os_unfair_lock_lock(lock)
        let chans = order
        let mGain = masterGain, mFX = masterFX, monGain = monitorGain, hearLive = hearLiveInputs
        var snapshot: [ChannelParams] = []
        snapshot.reserveCapacity(chans.count)
        for c in chans { snapshot.append(c.params) }
        os_unfair_lock_unlock(lock)

        ensure(&progL, n); ensure(&progR, n); ensure(&monL, n); ensure(&monR, n); ensure(&soloL, n); ensure(&soloR, n)
        for i in 0..<n { progL[i] = 0; progR[i] = 0; monL[i] = 0; monR[i] = 0; soloL[i] = 0; soloR[i] = 0 }
        let anySolo = snapshot.contains { $0.solo }
        var peaks = [(Float, Float)](repeating: (0, 0), count: chans.count)

        for (idx, c) in chans.enumerated() {
            let p = snapshot[idx]
            ensure(&c.mL, n); ensure(&c.mR, n); ensure(&c.lL, n); ensure(&c.lR, n)
            let gotMedia = c.mL.withUnsafeMutableBufferPointer { l in c.mR.withUnsafeMutableBufferPointer { r in
                c.mediaRing.read(l.baseAddress!, r.baseAddress!, frames: n) } }
            let gotLive = c.lL.withUnsafeMutableBufferPointer { l in c.lR.withUnsafeMutableBufferPointer { r in
                c.liveRing.read(l.baseAddress!, r.baseAddress!, frames: n) } }
            let hasAudio = gotMedia > 0 || gotLive > 0

            if hasAudio && p.fx.enabled {
                // effects process the sum of the channel's media and live audio
                for i in 0..<n { c.mL[i] += c.lL[i]; c.mR[i] += c.lR[i]; c.lL[i] = 0; c.lR[i] = 0 }
                c.dspL.update(p.fx); c.dspR.update(p.fx)
                c.dspL.process(&c.mL); c.dspR.process(&c.mR)
            }

            let target = p.fader * p.on
            let start = c.lastGain
            c.lastGain = target
            let meterGainL = p.fader * p.panL, meterGainR = p.fader * p.panR
            var pkL: Float = 0, pkR: Float = 0
            let invN = 1 / Float(n)
            for i in 0..<n {
                let g = start + (target - start) * Float(i + 1) * invN        // click-free gain ramp
                let mediaL = c.mL[i], mediaR = c.mR[i], liveL = c.lL[i], liveR = c.lR[i]
                let sumL = mediaL + liveL, sumR = mediaR + liveR
                let aL = abs(sumL * meterGainL), aR = abs(sumR * meterGainR)
                if aL > pkL { pkL = aL }
                if aR > pkR { pkR = aR }
                let pl = sumL * g * p.panL, pr = sumR * g * p.panR
                progL[i] += pl; progR[i] += pr
                // monitor: media always, live inputs only when "hear mics" is on (avoids feedback)
                monL[i] += (mediaL + (hearLive ? liveL : 0)) * g * p.panL
                monR[i] += (mediaR + (hearLive ? liveR : 0)) * g * p.panR
                if p.solo { soloL[i] += sumL * p.fader * p.panL; soloR[i] += sumR * p.fader * p.panR }
            }
            peaks[idx] = (pkL, pkR)
        }

        // master
        if mFX.enabled {
            masterDSPL.update(mFX); masterDSPR.update(mFX)
            masterDSPL.process(&progL); masterDSPR.process(&progR)
        }
        let mStart = lastMasterGain
        lastMasterGain = mGain
        var mpL: Float = 0, mpR: Float = 0
        let invN = 1 / Float(n)
        for i in 0..<n {
            let g = mStart + (mGain - mStart) * Float(i + 1) * invN
            var l = progL[i] * g, r = progR[i] * g
            l = l > 1 ? 1 : (l < -1 ? -1 : l)
            r = r > 1 ? 1 : (r < -1 ? -1 : r)
            progL[i] = l; progR[i] = r
            if abs(l) > mpL { mpL = abs(l) }
            if abs(r) > mpR { mpR = abs(r) }
            var ml: Float, mr: Float
            if anySolo { ml = soloL[i]; mr = soloR[i] } else { ml = monL[i] * g; mr = monR[i] * g }
            ml *= monGain; mr *= monGain
            outL[i] = ml > 1 ? 1 : (ml < -1 ? -1 : ml)
            outR[i] = mr > 1 ? 1 : (mr < -1 ? -1 : mr)
        }
        os_unfair_lock_lock(lock)
        for (idx, c) in chans.enumerated() {
            if peaks[idx].0 > c.peakL { c.peakL = peaks[idx].0 }
            if peaks[idx].1 > c.peakR { c.peakR = peaks[idx].1 }
        }
        if mpL > masterPeakL { masterPeakL = mpL }
        if mpR > masterPeakR { masterPeakR = mpR }
        os_unfair_lock_unlock(lock)

        if let sink = programSink {
            let ts = timestamp.pointee
            let time: CMTime = (ts.mFlags.contains(.hostTimeValid) && ts.mHostTime > 0)
                ? CMClockMakeHostTimeFromSystemUnits(ts.mHostTime)
                : CMClockGetTime(CMClockGetHostTimeClock())
            progL.withUnsafeBufferPointer { l in progR.withUnsafeBufferPointer { r in
                sink(l.baseAddress!, r.baseAddress!, n, time)
            } }
        }
    }
}

// MARK: - Recording helper: stereo float → CMSampleBuffer

enum PCMSampleBuffer {
    static let format: CMAudioFormatDescription? = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: ProgramAudioEngine.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        return desc
    }()

    /// `interleaved` holds frames × 2 Float32 samples.
    static func make(interleaved: Data, frames: Int, time: CMTime) -> CMSampleBuffer? {
        guard let format, frames > 0 else { return nil }
        var block: CMBlockBuffer?
        let bytes = interleaved.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let ok = interleaved.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == kCMBlockBufferNoErr
        }
        guard ok else { return nil }
        var sb: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                           formatDescription: format, sampleCount: frames,
                                                                           presentationTimeStamp: time, packetDescriptions: nil,
                                                                           sampleBufferOut: &sb)
        return status == noErr ? sb : nil
    }
}
