import SwiftUI
import AVFoundation
import PhotosUI
import CoreImage

/// The Flash Connect scanner (website FlashScanner.tsx): "Point your camera at a TRADEFLOR QR code", light, switch
/// camera, "Choose a QR image" and "Paste a TRADEFLOR link". Returns the first QR text it reads.
struct QRScannerView: View {
    let onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = QRCamera()
    @State private var pasted = ""
    @State private var picked: PhotosPickerItem?
    @State private var note: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            QRPreview(session: camera.session).ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    Button { camera.stop(); dismiss() } label: { circle("xmark") }
                        .accessibilityLabel(Text("fc.close.scanner"))
                    Spacer()
                    Button { camera.toggleTorch() } label: { circle(camera.torch ? "bolt.fill" : "bolt.slash") }
                        .accessibilityLabel(Text(camera.torch ? "fc.light.off" : "fc.light.on"))
                    Button { camera.switchCamera() } label: { circle("arrow.triangle.2.circlepath.camera") }
                        .accessibilityLabel(Text("fc.switch"))
                }
                Spacer()
                RoundedRectangle(cornerRadius: 24).stroke(Theme.accent, lineWidth: 3).frame(width: 240, height: 240)
                Text("fc.point").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                if let note = note ?? camera.problem {
                    Text(note).font(.system(size: 13)).foregroundStyle(Theme.gold).multilineTextAlignment(.center)
                }
                Spacer()
                PhotosPicker(selection: $picked, matching: .images) {
                    Label("fc.choose.image", systemImage: "photo").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 40).background(.ultraThinMaterial, in: Capsule())
                }
                HStack(spacing: 8) {
                    TextField("fc.paste", text: $pasted)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 44).background(.ultraThinMaterial, in: Capsule())
                    Button {
                        let t = pasted.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        camera.stop()
                        onResult(t)
                    } label: {
                        Image(systemName: "arrow.right").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.onAccent)
                            .frame(width: 44, height: 44).background(Theme.accent, in: Circle())
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            camera.onCode = { code in
                camera.stop()
                onResult(code)
            }
            camera.start()
        }
        .onDisappear { camera.stop() }
        .onChange(of: picked) { item in
            guard let item else { return }
            picked = nil
            Task {
                note = NSLocalizedString("fc.reading", comment: "")
                if let data = try? await item.loadTransferable(type: Data.self), let code = Self.decode(data) {
                    camera.stop()
                    onResult(code)
                } else {
                    note = NSLocalizedString("fc.noqr", comment: "")
                }
            }
        }
    }

    private func circle(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
    }

    /// Reads a QR code from a picture.
    static func decode(_ data: Data) -> String? {
        guard let ci = CIImage(data: data),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return detector.features(in: ci).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}

/// Camera session reading QR codes.
final class QRCamera: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    @Published var torch = false
    @Published var problem: String?
    var onCode: ((String) -> Void)?
    private var position: AVCaptureDevice.Position = .back
    private var delivered = false
    private let queue = DispatchQueue(label: "tf.qr.camera")

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                guard ok else { self.problem = NSLocalizedString("fc.nocamera", comment: ""); return }
                self.configure()
            }
        }
    }

    private func configure() {
        queue.async {
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.position),
               let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input)
            } else {
                DispatchQueue.main.async { self.problem = NSLocalizedString("fc.nocamera", comment: "") }
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
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func switchCamera() {
        position = position == .back ? .front : .back
        torch = false
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
