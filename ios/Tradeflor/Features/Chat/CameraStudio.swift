import AVFoundation
import AVKit
import SwiftUI

// The camera behind the composer's camera button (desktop/src/features/camera/CameraStudio.tsx): PHOTO, VIDEO and VIDEO NOTE.
// Nothing leaves the phone before Send on the review screen. Light, front/back, zoom 1x/2x/3x, gallery; video up to 1:30.

@MainActor
final class CameraModel: NSObject, ObservableObject {
    enum Phase { case starting, ready, recording, denied, failed }

    @Published var phase: Phase = .starting
    @Published var front = false
    @Published var torch = false
    @Published var zoom: CGFloat = 1
    @Published var elapsed: TimeInterval = 0
    @Published var photo: UIImage?
    @Published var videoURL: URL?
    @Published var flash = false

    let session = AVCaptureSession()
    private let photoOut = AVCapturePhotoOutput()
    private let movieOut = AVCaptureMovieFileOutput()
    private var input: AVCaptureDeviceInput?
    private var audioIn: AVCaptureDeviceInput?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "tf.camera")
    nonisolated static let maxVideo: TimeInterval = 90

    var device: AVCaptureDevice? { input?.device }
    var hasTorch: Bool { device?.hasTorch ?? false }
    var maxZoom: CGFloat { min(device?.activeFormat.videoMaxZoomFactor ?? 1, 3) }

    func open(video: Bool) async {
        phase = .starting
        guard await AVCaptureDevice.requestAccess(for: .video) else { phase = .denied; return }
        let mic = video ? await AVCaptureDevice.requestAccess(for: .audio) : false
        let front = self.front
        let session = self.session, photoOut = self.photoOut, movieOut = self.movieOut
        let oldIn = input, oldAudio = audioIn
        let result: (AVCaptureDeviceInput?, AVCaptureDeviceInput?) = await withCheckedContinuation { cont in
            queue.async {
                session.beginConfiguration()
                session.sessionPreset = video ? .high : .photo
                if let oldIn { session.removeInput(oldIn) }
                if let oldAudio { session.removeInput(oldAudio) }
                var newIn: AVCaptureDeviceInput?
                var newAudio: AVCaptureDeviceInput?
                if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
                   let i = try? AVCaptureDeviceInput(device: dev), session.canAddInput(i) {
                    session.addInput(i)
                    newIn = i
                }
                if mic, let a = AVCaptureDevice.default(for: .audio), let ai = try? AVCaptureDeviceInput(device: a), session.canAddInput(ai) {
                    session.addInput(ai)
                    newAudio = ai
                }
                if !session.outputs.contains(photoOut), session.canAddOutput(photoOut) { session.addOutput(photoOut) }
                if !session.outputs.contains(movieOut), session.canAddOutput(movieOut) { session.addOutput(movieOut) }
                movieOut.maxRecordedDuration = CMTime(seconds: CameraModel.maxVideo, preferredTimescale: 600)
                for c in [movieOut.connection(with: .video), photoOut.connection(with: .video)].compactMap({ $0 }) where c.isVideoOrientationSupported {
                    c.videoOrientation = .portrait
                }
                session.commitConfiguration()
                if !session.isRunning { session.startRunning() }
                cont.resume(returning: (newIn, newAudio))
            }
        }
        input = result.0
        audioIn = result.1
        zoom = 1
        torch = false
        phase = input == nil ? .failed : .ready
    }

    func stop() {
        timer?.invalidate()
        if movieOut.isRecording { movieOut.stopRecording() }
        let s = session
        queue.async { if s.isRunning { s.stopRunning() } }
    }

    func flip(video: Bool) async {
        front.toggle()
        await open(video: video)
    }

    func toggleTorch() {
        guard let d = device, d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
        torch.toggle()
        d.torchMode = torch ? .on : .off
        d.unlockForConfiguration()
    }

    func cycleZoom() {
        guard let d = device else { return }
        let steps: [CGFloat] = [1, 2, 3].filter { $0 <= max(1, maxZoom) }
        let i = steps.firstIndex(where: { abs($0 - zoom) < 0.05 }) ?? 0
        let next = steps[(i + 1) % steps.count]
        guard (try? d.lockForConfiguration()) != nil else { return }
        d.ramp(toVideoZoomFactor: next, withRate: 8)
        d.unlockForConfiguration()
        zoom = next
    }

    func takePhoto() {
        guard phase == .ready else { return }
        let settings = AVCapturePhotoSettings()
        photoOut.capturePhoto(with: settings, delegate: self)
        flash = true
        Task { try? await Task.sleep(nanoseconds: 120_000_000); flash = false }
    }

    func toggleRecording() {
        if movieOut.isRecording {
            movieOut.stopRecording()
            return
        }
        guard phase == .ready else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cam-\(UUID().uuidString).mov")
        movieOut.startRecording(to: url, recordingDelegate: self)
        phase = .recording
        elapsed = 0
        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Date().timeIntervalSince(start) }
        }
    }

    func discard() {
        if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
        photo = nil
        videoURL = nil
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let img = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        Task { @MainActor in if let img { self.photo = img } }
    }
}

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let ok = FileManager.default.fileExists(atPath: outputFileURL.path)
        Task { @MainActor in
            self.timer?.invalidate()
            self.phase = .ready
            if ok { self.videoURL = outputFileURL }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

struct CameraStudio: View {
    enum Mode: String, CaseIterable { case photo, video, note }

    var allowNote = true
    let onPhoto: (UIImage) -> Void
    let onVideo: (URL) -> Void
    var onNote: (() -> Void)?
    var onGallery: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var cam = CameraModel()
    @State private var mode: Mode = .photo
    @State private var reviewPlayer: AVPlayer?

    private var reviewing: Bool { cam.photo != nil || cam.videoURL != nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let img = cam.photo {
                Image(uiImage: img).resizable().scaledToFit().ignoresSafeArea()
            } else if let p = reviewPlayer {
                VideoPlayer(player: p).ignoresSafeArea()
            } else {
                CameraPreview(session: cam.session).ignoresSafeArea()
                if cam.flash { Color.white.ignoresSafeArea().transition(.opacity) }
                if cam.phase == .denied || cam.phase == .failed {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.7))
                        Text(LocalizedStringKey(cam.phase == .denied ? "cam.denied" : "cam.failed"))
                            .multilineTextAlignment(.center).foregroundStyle(.white).padding(.horizontal, 30)
                        if cam.phase == .denied {
                            Button("cam.settings") {
                                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                            }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                        }
                    }
                }
            }
            VStack {
                topBar
                Spacer()
                if reviewing { reviewBar } else { bottomBar }
            }
        }
        .statusBarHidden()
        .task { await cam.open(video: mode == .video) }
        .onDisappear { cam.stop(); reviewPlayer?.pause() }
        .onChange(of: scenePhase) { p in
            if p == .background { cam.stop() } else if p == .active && !reviewing { Task { await cam.open(video: mode == .video) } }
        }
        .onChange(of: cam.videoURL) { u in
            reviewPlayer = u.map { AVPlayer(url: $0) }
            reviewPlayer?.play()
        }
    }

    private func round(_ icon: String, on: Bool = false) -> some View {
        Image(systemName: icon).font(.system(size: 18, weight: .semibold))
            .foregroundStyle(on ? Color.black : .white)
            .frame(width: 44, height: 44)
            .background(on ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(Color.black.opacity(0.45)), in: Circle())
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { round("xmark") }.accessibilityLabel(Text("cam.close"))
            Spacer()
            if cam.phase == .recording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("\(VoiceBubble.length(Int64(cam.elapsed * 1000))) / 1:30").monospacedDigit()
                }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 32).background(.black.opacity(0.5), in: Capsule())
            }
            Spacer()
            if !reviewing {
                if cam.hasTorch {
                    Button { cam.toggleTorch() } label: { round(cam.torch ? "bolt.fill" : "bolt.slash", on: cam.torch) }
                        .accessibilityLabel(Text(LocalizedStringKey(cam.torch ? "cam.light.off" : "cam.light.on")))
                }
                Button { Task { await cam.flip(video: mode == .video) } } label: { round("arrow.triangle.2.circlepath.camera") }
                    .disabled(cam.phase == .recording)
                    .accessibilityLabel(Text("cam.flip"))
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 18) {
            HStack(spacing: 22) {
                ForEach(Mode.allCases.filter { $0 != .note || allowNote }, id: \.self) { m in
                    Button {
                        guard cam.phase != .recording, m != mode else { return }
                        if m == .note { dismiss(); onNote?(); return }
                        mode = m
                        Task { await cam.open(video: m == .video) }
                    } label: {
                        Text(LocalizedStringKey("cam.mode." + m.rawValue))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(mode == m ? Color.yellow : .white.opacity(0.85))
                    }
                    .accessibilityAddTraits(mode == m ? .isSelected : [])
                }
            }
            HStack {
                if let onGallery {
                    Button { dismiss(); onGallery() } label: { round("photo.on.rectangle") }
                        .disabled(cam.phase == .recording)
                        .accessibilityLabel(Text("cam.gallery"))
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
                Spacer()
                Button {
                    if mode == .photo { cam.takePhoto() } else { cam.toggleRecording() }
                } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 5).frame(width: 78, height: 78)
                        if mode == .photo {
                            Circle().fill(.white).frame(width: 64, height: 64)
                        } else if cam.phase == .recording {
                            RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                        } else {
                            Circle().fill(.red).frame(width: 64, height: 64)
                        }
                    }
                }
                .disabled(cam.phase != .ready && cam.phase != .recording)
                .accessibilityLabel(Text(LocalizedStringKey(mode == .photo ? "cam.shoot" : (cam.phase == .recording ? "cam.stop" : "cam.record"))))
                Spacer()
                Button { cam.cycleZoom() } label: {
                    Text("\(cam.zoom, specifier: "%.0f")×").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel(Text(String(format: NSLocalizedString("cam.zoom", comment: ""), Int(cam.zoom))))
            }
            .padding(.horizontal, 30)
        }
        .padding(.bottom, 24)
    }

    private var reviewBar: some View {
        HStack {
            Button {
                reviewPlayer?.pause()
                reviewPlayer = nil
                cam.discard()
                Task { await cam.open(video: mode == .video) }
            } label: {
                Text(LocalizedStringKey(cam.photo != nil ? "cam.retake" : "cam.again"))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 20).frame(height: 46).background(.black.opacity(0.5), in: Capsule())
            }
            Spacer()
            Button {
                reviewPlayer?.pause()
                if let img = cam.photo { onPhoto(img) } else if let u = cam.videoURL { onVideo(u) }
                dismiss()
            } label: {
                Image(systemName: "paperplane.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 58, height: 58).background(Theme.sendGradient, in: Circle())
            }
            .accessibilityLabel(Text(LocalizedStringKey(cam.photo != nil ? "cam.send.photo" : "cam.send.video")))
        }
        .padding(.horizontal, 24).padding(.bottom, 28)
    }
}
