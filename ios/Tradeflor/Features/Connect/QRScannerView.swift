import SwiftUI
import AVFoundation
import PhotosUI
import CoreImage

/// Scan & Connect (website FlashScanner.tsx, 9256375): "Scan a TRADEFLOR code to connect instantly." Rear camera first,
/// Switch Camera, Scan from Photo (pictures only, up to 15 MB, read on the phone), Enter Connect Link, and My Connect Code.
/// Only TRADEFLOR codes are handed on (FlashTarget.parse); anything else says so and the camera keeps looking.
/// The camera stops when the scanner closes, when the app leaves the screen and as soon as a code is read.
struct QRScannerView: View {
    var onMutual: (() -> Void)? = nil
    let onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var camera = QRCamera()
    @State private var pasted = ""
    @State private var paste = false
    @State private var picked: PhotosPickerItem?
    @State private var note: String?
    @FocusState private var pasteFocused: Bool

    static let maxPhoto = 15 * 1024 * 1024

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            QRPreview(session: camera.session).ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Button { close() } label: { circle("xmark") }
                        .accessibilityLabel(Text("fc.close.scanner"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sc.scan.title").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        Text("sc.scan.hint").font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer()
                }
                Spacer()
                scanFrame
                if let note {
                    Text(note).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.gold).multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.45), in: Capsule())
                }
                Spacer()
                if paste { pasteField }
                footer
            }
            .padding(20)
        }
        .onAppear {
            camera.onCode = { code in
                if FlashTarget.parse(code) != nil {
                    camera.stop()
                    onResult(code)
                } else {
                    note = NSLocalizedString("sc.not.ours", comment: "")
                    camera.resume(after: 1.5)
                }
            }
            camera.start()
        }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { p in
            if p == .background { camera.pause() }
        }
        .onChange(of: picked) { item in
            guard let item else { return }
            picked = nil
            Task { await readPhoto(item) }
        }
    }

    // MARK: the frame and its states

    private var scanFrame: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { k in
                ScanCorner().stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 40, height: 40)
                    .rotationEffect(.degrees(Double(k) * 90))
                    .offset(x: (k == 0 || k == 3 ? -1 : 1) * 110, y: (k < 2 ? -1 : 1) * 110)
            }
            if camera.state == .live {
                ScanLine().frame(width: 220, height: 220)
            } else {
                VStack(spacing: 12) {
                    if camera.state == .starting { ProgressView().tint(.white) }
                    Text(LocalizedStringKey("sc.cam." + camera.state.rawValue)).font(.system(size: 14)).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    switch camera.state {
                    case .denied:
                        smallButton("sc.cam.settings") { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }
                    case .paused, .error:
                        smallButton("sc.cam.on") { camera.start() }
                    case .busy, .lost:
                        smallButton("mc.tryagain") { camera.start() }
                    default:
                        EmptyView()
                    }
                }
                .padding(16)
                .frame(width: 236)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .frame(width: 260, height: 260)
        .accessibilityElement(children: .contain)
    }

    private func smallButton(_ key: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(key)).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 16).frame(height: 38).background(Theme.accent, in: Capsule())
        }
    }

    // MARK: Enter Connect Link

    private var pasteField: some View {
        HStack(spacing: 8) {
            TextField("", text: $pasted, prompt: Text("sc.paste.ph").foregroundColor(.white.opacity(0.55)))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.go)
                .foregroundStyle(.white).focused($pasteFocused)
                .onSubmit { openPasted() }
                .padding(.horizontal, 14).frame(height: 44).background(.ultraThinMaterial, in: Capsule())
                .accessibilityLabel(Text("sc.paste.label"))
            Button { openPasted() } label: {
                Text("sc.open").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 16).frame(height: 44).background(Theme.accent, in: Capsule())
            }
            .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func openPasted() {
        let t = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard FlashTarget.parse(t) != nil else { note = NSLocalizedString("sc.not.ours", comment: ""); return }
        pasteFocused = false
        camera.stop()
        onResult(t)
    }

    // MARK: footer: light, Switch Camera, Scan from Photo, Enter Connect Link, My Connect Code

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if camera.hasTorch {
                    Button { camera.toggleTorch() } label: { circle(camera.torch ? "flashlight.on.fill" : "flashlight.off.fill", on: camera.torch) }
                        .accessibilityLabel(Text(camera.torch ? "fc.light.off" : "fc.light.on"))
                }
                if camera.canSwitch {
                    Button { camera.switchCamera() } label: { pill("arrow.triangle.2.circlepath.camera", "sc.switch") }
                }
                PhotosPicker(selection: $picked, matching: .images) { pill("photo", "sc.photo") }
                    .accessibilityIdentifier("sc.photo")
            }
            HStack(spacing: 10) {
                Button {
                    paste.toggle()
                    pasteFocused = paste
                } label: { pill("link", "sc.enter.link", on: paste) }
                if let onMutual {
                    Button {
                        camera.stop()
                        onMutual()
                    } label: { pill("hand.raised", "mc.title") }
                }
            }
        }
    }

    private func circle(_ name: String, on: Bool = false) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .semibold)).foregroundStyle(on ? Theme.onAccent : .white)
            .frame(width: 44, height: 44)
            .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
    }

    private func pill(_ icon: String, _ key: String, on: Bool = false) -> some View {
        Label(LocalizedStringKey(key), systemImage: icon).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            .foregroundStyle(on ? Theme.onAccent : .white)
            .padding(.horizontal, 14).frame(height: 42)
            .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
    }

    private func close() {
        camera.stop()
        dismiss()
    }

    private func readPhoto(_ item: PhotosPickerItem) async {
        note = NSLocalizedString("sc.reading", comment: "")
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            note = NSLocalizedString("sc.photo.type", comment: "")
            return
        }
        if data.count > Self.maxPhoto { note = NSLocalizedString("sc.photo.big", comment: ""); return }
        guard let code = Self.decode(data) else { note = NSLocalizedString("sc.photo.none", comment: ""); return }
        guard FlashTarget.parse(code) != nil else { note = NSLocalizedString("sc.not.ours", comment: ""); return }
        note = nil
        camera.stop()
        onResult(code)
    }

    /// Reads a QR code from a picture, on the phone.
    static func decode(_ data: Data) -> String? {
        guard let ci = CIImage(data: data),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return detector.features(in: ci).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}

/// One corner of the scan frame (top-left; rotated for the others).
private struct ScanCorner: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 10))
        p.addQuadCurve(to: CGPoint(x: r.minX + 10, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// The moving line while the camera looks (website .fc-scan__line).
private struct ScanLine: View {
    @State private var down = false
    var body: some View {
        GeometryReader { g in
            Rectangle()
                .fill(LinearGradient(colors: [.clear, Theme.accent, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 2)
                .shadow(color: Theme.accent, radius: 6)
                .offset(y: down ? g.size.height - 2 : 0)
                .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: down)
                .onAppear { down = true }
        }
        .accessibilityHidden(true)
    }
}

/// Camera session reading QR codes. States as on the website: starting, live, paused (app left the screen), denied,
/// unsupported (no camera), busy (another app has it), lost (disconnected / failed while running), error.
final class QRCamera: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    enum CamState: String { case starting, live, paused, denied, unsupported, busy, lost, error }

    let session = AVCaptureSession()
    @Published var torch = false
    @Published var state: CamState = .starting
    @Published private(set) var hasTorch = false
    @Published private(set) var canSwitch = false
    var onCode: ((String) -> Void)?
    private var position: AVCaptureDevice.Position = .back
    private var delivered = false
    private let queue = DispatchQueue(label: "tf.qr.camera")
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] n in
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

    private func configure() {
        let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        canSwitch = back != nil && front != nil
        if position == .back && back == nil { position = .front }
        guard let device = position == .back ? back : front else { state = .unsupported; return }
        hasTorch = position == .back && device.hasTorch
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
            DispatchQueue.main.async { self.state = running ? .live : .error }
        }
    }

    func stop() {
        torch = false
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
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

    func switchCamera() {
        position = position == .back ? .front : .back
        torch = false
        delivered = false
        state = .starting
        configure()
    }

    func toggleTorch() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = torch ? .off : .on
        device.unlockForConfiguration()
        torch.toggle()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        delivered = true
        onCode?(code)
    }
}

/// The live camera picture.
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
