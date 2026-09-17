import Foundation
import AppKit
import SwiftUI
import CoreMediaIO
import CoreMedia
import CoreVideo
import VideoToolbox
import SystemExtensions

// MARK: - LiveDeck Camera (virtual webcam)
//
// The Camera Extension (AppStore/CameraExtension) is embedded in the Xcode builds at
// Contents/Library/SystemExtensions/<bundle id>.CameraExtension.systemextension.
// This class installs it, finds the "LiveDeck Camera" device and pushes Program frames into its sink stream.

final class VirtualCameraManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    enum InstallState: Equatable { case notBundled, unknown, notInstalled, needsApproval, installed, failed(String) }

    @Published private(set) var installState: InstallState = .unknown
    @Published var sending: Bool = UserDefaults.standard.bool(forKey: "vcam.sending") {
        didSet { UserDefaults.standard.set(sending, forKey: "vcam.sending"); if sending { connect() } else { disconnect() } }
    }
    @Published private(set) var connected = false
    @Published private(set) var status = ""

    static let deviceName = "LiveDeck Camera"
    let extensionID = (Bundle.main.bundleIdentifier ?? "com.shamaapps.livedeck") + ".CameraExtension"

    private let queue = DispatchQueue(label: "livedeck.vcam", qos: .userInteractive)
    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var sinkQueue: CMSimpleQueue?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var busy = false
    private var lastSent: CFAbsoluteTime = 0
    private let lock = NSLock()
    private var retryTimer: Timer?

    var isBundled: Bool {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(extensionID).systemextension")
        return FileManager.default.fileExists(atPath: url.path)
    }

    override init() {
        super.init()
        if !isBundled { installState = .notBundled; return }
        refreshInstallState()
        if sending { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.connect() } }
    }

    // MARK: install / uninstall

    func refreshInstallState() {
        guard isBundled else { installState = .notBundled; return }
        let r = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: extensionID, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    func install() {
        guard isBundled else { installState = .notBundled; return }
        if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
            installState = .failed("Move LiveDeck Studio into the Applications folder first, then open it from there.")
            return
        }
        status = "Installing LiveDeck Camera…"
        let r = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    func uninstall() {
        sending = false
        let r = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        installState = .needsApproval
        status = "Approve LiveDeck Camera in System Settings → General → Login Items & Extensions → Camera Extensions."
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        refreshInstallState()
        status = result == .willCompleteAfterReboot ? "Restart the Mac to finish installing LiveDeck Camera." : "LiveDeck Camera is ready."
        if sending { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.connect() } }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let e = error as NSError
        if e.domain == OSSystemExtensionErrorDomain, e.code == OSSystemExtensionError.Code.extensionNotFound.rawValue {
            installState = .notInstalled
        } else {
            installState = .failed(error.localizedDescription)
        }
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        if properties.contains(where: { $0.isEnabled }) { installState = .installed }
        else if properties.contains(where: { $0.isAwaitingUserApproval }) { installState = .needsApproval }
        else { installState = .notInstalled }
    }

    // MARK: connection to the camera device

    func connect() {
        queue.async { [weak self] in self?.connectOnQueue() }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.deviceID != 0 && self.sinkStreamID != 0 { CMIODeviceStopStream(self.deviceID, self.sinkStreamID) }
            self.deviceID = 0; self.sinkStreamID = 0; self.sinkQueue = nil
            DispatchQueue.main.async { self.connected = false; self.retryTimer?.invalidate() }
        }
    }

    private func connectOnQueue() {
        guard sinkQueue == nil else { return }
        guard let device = findDevice(named: Self.deviceName) else {
            DispatchQueue.main.async {
                self.connected = false
                self.status = "LiveDeck Camera was not found — install it below."
                self.scheduleRetry()
            }
            return
        }
        let streams = streamIDs(of: device)
        guard streams.count >= 2 else {
            DispatchQueue.main.async { self.status = "LiveDeck Camera is not ready yet."; self.scheduleRetry() }
            return
        }
        let sink = streams[1]
        var queueRef: Unmanaged<CMSimpleQueue>?
        let result = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &queueRef)
        guard result == noErr, let q = queueRef?.takeRetainedValue() else {
            DispatchQueue.main.async { self.status = "Could not open LiveDeck Camera (\(result))."; self.scheduleRetry() }
            return
        }
        let start = CMIODeviceStartStream(device, sink)
        guard start == noErr else {
            DispatchQueue.main.async { self.status = "Could not start LiveDeck Camera (\(start))."; self.scheduleRetry() }
            return
        }
        deviceID = device; sinkStreamID = sink; sinkQueue = q
        DispatchQueue.main.async {
            self.connected = true
            self.status = "Sending Program to LiveDeck Camera. Choose “LiveDeck Camera” as the camera in Zoom."
        }
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        guard sending else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.connect() }
    }

    private func findDevice(named name: String) -> CMIOObjectID? {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr else { return nil }
        for d in devices where objectName(d) == name { return d }
        return nil
    }

    private func objectName(_ object: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var name: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &name) == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }

    private func streamIDs(of device: CMIOObjectID) -> [CMIOStreamID] {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<CMIOStreamID>.size
        var ids = [CMIOStreamID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    // MARK: frames

    /// Called from the render loop with the Program frame (BGRA). Scaled to 1920×1080 off the main thread.
    func send(_ pixelBuffer: CVPixelBuffer) {
        guard sending, connected else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if busy || now - lastSent < 1.0 / 31.0 { lock.unlock(); return }
        busy = true; lastSent = now
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            guard let q = self.sinkQueue, CMSimpleQueueGetCount(q) < CMSimpleQueueGetCapacity(q) else { return }
            guard let frame = self.scaled(pixelBuffer) else { return }
            var format: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescriptionOut: &format)
            guard let fd = format else { return }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame, dataReady: true,
                                                     makeDataReadyCallback: nil, refcon: nil, formatDescription: fd,
                                                     sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sb = sample else { return }
            CMSimpleQueueEnqueue(q, element: Unmanaged.passRetained(sb).toOpaque())
        }
    }

    private func scaled(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(src) == 1920 && CVPixelBufferGetHeight(src) == 1080 &&
            CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA { return src }
        if pool == nil {
            let attrs: NSDictionary = [kCVPixelBufferWidthKey: 1920, kCVPixelBufferHeightKey: 1080,
                                       kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                       kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pool)
        }
        if transfer == nil {
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
            if let t = transfer { VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox) }
        }
        guard let pool, let transfer else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let dst = out else { return nil }
        return VTPixelTransferSessionTransferImage(transfer, from: src, to: dst) == noErr ? dst : nil
    }
}

// MARK: - Outputs panel card

struct VirtualCameraCard: View {
    @EnvironmentObject var vcam: VirtualCameraManager

    var body: some View {
        CPCard(title: "LiveDeck Camera", subtitle: subtitle, icon: "video.badge.checkmark",
               iconColor: vcam.connected && vcam.sending ? DS.ok : CP.icon) {
            switch vcam.installState {
            case .notBundled:
                CPNote("The virtual camera is part of the Xcode builds of LiveDeck Studio (Mac App Store edition). This build does not include it — use Share Screen → “LiveDeck — Program Out” in Zoom instead.")
            case .unknown, .notInstalled:
                CPNote("Install LiveDeck Camera once. Zoom, Teams, Google Meet, FaceTime and OBS can then choose “LiveDeck Camera” and receive your Program — lyrics, scripture and overlays included.")
                HStack { CPButton(icon: "square.and.arrow.down", title: "Install LiveDeck Camera", prominent: true) { vcam.install() }; Spacer() }
                    .padding(.vertical, 4)
            case .needsApproval:
                CPNote("macOS needs your approval: System Settings → General → Login Items & Extensions → Camera Extensions → turn on LiveDeck Camera.")
                HStack {
                    CPButton(icon: "gearshape", title: "Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    CPButton(icon: "arrow.clockwise", title: "Check again") { vcam.refreshInstallState() }
                    Spacer()
                }
                .padding(.vertical, 4)
            case .installed:
                CPToggleRow(icon: "video", label: "Send Program to LiveDeck Camera", isOn: $vcam.sending)
                if vcam.sending {
                    Text(vcam.connected ? "● Sending" : "Connecting…").font(CPFont.caption).foregroundColor(vcam.connected ? DS.ok : DS.amber)
                        .padding(.vertical, 2)
                }
                CPNote("In Zoom: Settings → Video → Camera → LiveDeck Camera. Turn off “Mirror my video” so text reads correctly for you (others always see it the right way). Sound: select your mixer output or use Zoom's “Share sound” when sharing.")
                HStack { Spacer(); Button("Uninstall") { vcam.uninstall() }.buttonStyle(.ds(.ghost, .small)) }
            case .failed(let message):
                Text(message).font(CPFont.caption).foregroundColor(DS.amber).fixedSize(horizontal: false, vertical: true)
                HStack { CPButton(icon: "arrow.clockwise", title: "Try again") { vcam.install() }; Spacer() }.padding(.vertical, 4)
            }
            if !vcam.status.isEmpty && vcam.installState != .notBundled {
                CPNote(vcam.status)
            }
        }
    }

    private var subtitle: String {
        switch vcam.installState {
        case .notBundled: return "Not in this build"
        case .installed: return vcam.sending ? (vcam.connected ? "Sending Program" : "Connecting") : "Installed · off"
        case .needsApproval: return "Waiting for approval"
        case .failed: return "Needs attention"
        default: return "Virtual webcam for Zoom, Teams, Meet"
        }
    }
}
