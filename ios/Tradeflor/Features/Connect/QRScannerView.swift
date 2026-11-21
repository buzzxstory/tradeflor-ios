import SwiftUI
import AVFoundation
import ImageIO
import CoreImage
import os

/// How fast the scanner is on a real phone (web ea10bd9 asks for tap → screen, tap → first frame, tap → first decode):
/// written to the device log under "ScanTiming" (Console.app, or `log stream --predicate 'category == "ScanTiming"'`).
enum ScanTiming {
    private static var tapAt: Date?
    private static let log = Logger(subsystem: "com.tradeflor.ios", category: "ScanTiming")
    static func tapped() { tapAt = Date() }
    static func mark(_ what: String) {
        guard let t = tapAt else { return }
        let ms = Int(Date().timeIntervalSince(t) * 1000)
        log.notice("\(what, privacy: .public): \(ms) ms")
    }
    static func done() { tapAt = nil }
}

// The camera behind the Scan QR tab (ScanConnectScreen). Rear camera first, any camera of the phone can be picked (the
// choice is remembered), the next one is one tap away; the camera stops on My Code, on close, in the background and as
// soon as a code is read. States as on the website: starting, live, paused, denied, unsupported, busy, lost, error.

/// Reads a QR code from a picture, on the phone.
enum QRDecode {
    /// Call it off the main thread: a 48 MP photo took 0.5-2 s. The picture is read at 1600 px at most (a QR needs no more).
    static func decode(_ data: Data) -> String? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                                     kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        let small = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, opts as CFDictionary) }
        guard let ci = small.map({ CIImage(cgImage: $0) }) ?? CIImage(data: data),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return detector.features(in: ci).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}

/// Camera session reading QR codes.
final class QRCamera: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    enum CamState: String { case starting, live, paused, denied, unsupported, busy, lost, error, off }

    struct Cam: Identifiable, Equatable {
        let id: String
        let name: String
        let position: AVCaptureDevice.Position
    }

    let session = AVCaptureSession()
    @Published var torch = false
    @Published var state: CamState = .off
    @Published private(set) var hasTorch = false
    @Published private(set) var cams: [Cam] = []
    @Published private(set) var currentID: String?
    var onCode: ((String) -> Void)?
    private var delivered = false
    private let queue = DispatchQueue(label: "tf.qr.camera")
    private var observers: [NSObjectProtocol] = []
    private static let rememberKey = "tf.scan.camera"

    var currentName: String? { cams.first { $0.id == currentID }?.name }
    /// Front and back both exist: the round button flips between them.
    var canFlip: Bool { cams.contains { $0.position == .front } && cams.contains { $0.position == .back } }

    override init() {
        super.init()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] n in
            guard self?.state != .unsupported, self?.state != .denied else { return } // no camera stays "no camera"
            let raw = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
            switch AVCaptureSession.InterruptionReason(rawValue: raw) {
            case .videoDeviceInUseByAnotherClient?: self?.state = .busy
            case .videoDeviceNotAvailableInBackground?: self?.state = .paused
            default: self?.state = .lost
            }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            if self?.session.isRunning == true { self?.state = .live }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
            guard self?.state != .unsupported, self?.state != .denied else { return }
            self?.state = .lost
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func start() {
        delivered = false
        state = .starting
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { if ok { self.configure() } else { self.state = .denied } }
            }
        default:
            state = .denied
        }
    }

    private func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
                                         mediaType: .video, position: .unspecified).devices
            .sorted { a, b in
                // back cameras first, the main (wide) one first among them
                if a.position != b.position { return a.position == .back }
                return a.deviceType == .builtInWideAngleCamera && b.deviceType != .builtInWideAngleCamera
            }
    }

    private func configure() {
        let devices = discover()
        cams = devices.map { Cam(id: $0.uniqueID, name: $0.localizedName, position: $0.position) }
        let remembered = currentID ?? UserDefaults.standard.string(forKey: Self.rememberKey)
        guard let device = devices.first(where: { $0.uniqueID == remembered })
                ?? devices.first(where: { $0.position == .back }) ?? devices.first else {
            state = .unsupported
            return
        }
        currentID = device.uniqueID
        hasTorch = device.hasTorch
        torch = false
        queue.async {
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            var ok = false
            if let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input)
                ok = true
            }
            if self.session.outputs.isEmpty {
                let out = AVCaptureMetadataOutput()
                if self.session.canAddOutput(out) {
                    self.session.addOutput(out)
                    out.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                    if out.availableMetadataObjectTypes.contains(.qr) { out.metadataObjectTypes = [.qr] }
                }
            }
            self.session.commitConfiguration()
            guard ok else { DispatchQueue.main.async { self.state = .busy }; return }
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            DispatchQueue.main.async {
                self.state = running ? .live : .error
                if running { ScanTiming.mark("tap to first frame (camera running)") }
            }
        }
    }

    /// Stops and lets the camera go (inputs removed), so the green dot goes off and reopening starts clean.
    func stop() {
        torch = false
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.commitConfiguration()
        }
    }

    /// The app left the screen: the camera goes off, and comes back only when asked.
    func pause() {
        guard state == .live || state == .starting else { return }
        stop()
        state = .paused
    }

    /// After a code that is not TRADEFLOR's: look again in a moment.
    func resume(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.delivered = false }
    }

    /// The person picked a camera: remembered for next time.
    func select(_ id: String) {
        UserDefaults.standard.set(id, forKey: Self.rememberKey)
        currentID = id
        delivered = false
        state = .starting
        configure()
    }

    /// Front ↔ back.
    func flip() {
        let pos = cams.first { $0.id == currentID }?.position ?? .back
        if let next = cams.first(where: { $0.position != pos }) { select(next.id) }
    }

    func toggleTorch() {
        // setting the torch without the lock (another app holds the camera) or while it is unavailable (too hot, camera not
        // running) raises an Objective-C exception: a crash. Both are checked first.
        guard let id = currentID, let device = AVCaptureDevice(uniqueID: id), device.hasTorch else { return }
        let on = !torch
        guard !on || (device.isTorchAvailable && device.isTorchModeSupported(.on)) else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
        torch = on
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        delivered = true // one decode per code: later callbacks are ignored while this one is handled
        ScanTiming.mark("tap to first decode")
        onCode?(code)
    }
}

/// The live camera picture (aspect fill).
struct QRPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// The cyan line sweeping the camera (website .sc-line, 2.4 s each way).
struct ScanSweep: View {
    @State private var down = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        GeometryReader { g in
            Capsule()
                .fill(LinearGradient(colors: [.clear, Theme.hex(0x8FF6FB), .white, Theme.hex(0x8FF6FB), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: g.size.width * 0.88, height: 2)
                .shadow(color: Theme.hex(0x35E6F2, 0.6), radius: 7)
                .position(x: g.size.width / 2, y: g.size.height * (reduce ? 0.5 : (down ? 0.86 : 0.12)))
                .animation(reduce ? nil : .easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: down)
                .onAppear { down = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
