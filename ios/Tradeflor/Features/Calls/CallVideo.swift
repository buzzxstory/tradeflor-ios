import AVFoundation
import Combine
import UIKit
import WebRTC
import os

/// Video call diagnostics (Console: subsystem com.tradeflor.ios, category video): capture start / stop, and once a second
/// for the first 30 s of a video call what the picture really does (audit T1-T3, T11: measured, not estimated).
private let videoLog = Logger(subsystem: "com.tradeflor.ios", category: "video")

/// The picture of a 1-to-1 call (VIDEO_CALL_PROTOCOL.md, IOS-VIDEO-001…008): the camera, its track and the other person's
/// picture, on the same peer connection as the voice. CallManager owns the call and asks this object at fixed points:
/// - caller: the camera goes on a video line in the first offer (sendrecv);
/// - callee: the camera goes on the offered video line in the answer, or the line is answered recvonly (sound only);
/// - camera off = no track on the sender and the capture stopped, nothing renegotiated; flip = another camera, same track;
/// - camera on later: the existing line gets the track (sendrecv if it was recvonly) or a new line is added: one
///   renegotiation, which either side may start (perfect negotiation decides a collision).
/// The other person's camera state is only what the server says (call.peer_media.camera, *_camera in summaries).
@MainActor
final class CallVideo: ObservableObject {
    /// This call is a video call (a video invite, or a camera turned on by either side during it).
    @Published private(set) var isVideo = false
    /// My camera is on and sending.
    @Published private(set) var cameraOn = false
    /// The other person's camera, as the server last said.
    @Published private(set) var peerCamera = false
    /// The front camera is the one in use (the self-view is mirrored only then).
    @Published private(set) var front = true
    /// My picture, for the self-view.
    @Published private(set) var localTrack: RTCVideoTrack?
    /// The other person's picture.
    @Published private(set) var remoteTrack: RTCVideoTrack?
    /// Something to tell the person (camera permission denied, camera taken by another app, phone too hot).
    @Published var note: String?

    private let factory: RTCPeerConnectionFactory
    private var source: RTCVideoSource?
    private var capturer: RTCCameraVideoCapturer?
    /// Bumped by every stop: a capture start that completes after the call ended (or the camera went off) is stopped at once.
    private(set) var generation = 0
    /// The camera was on when the app went to the background: it comes back in front.
    private var resumeInFront = false
    /// A renegotiation is wanted for the picture (camera on mid-call): the callee may offer then.
    var wantsOffer = false
    private var thermal: AnyCancellable?

    init(factory: RTCPeerConnectionFactory) {
        self.factory = factory
        thermal = NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.thermalChanged() }
    }

    // MARK: call lifecycle

    /// A new call starts: nothing of the last one remains.
    func reset() {
        stopCapture()
        isVideo = false
        cameraOn = false
        peerCamera = false
        front = true
        localTrack = nil
        remoteTrack = nil
        source = nil
        capturer = nil
        wantsOffer = false
        resumeInFront = false
        note = nil
    }

    /// From a call summary (call.incoming, call.accepted, call.sync.call): video flag and the other person's camera.
    func applySummary(_ d: [String: Any], iAmCaller: Bool) {
        if (d["video"] as? Bool) == true { isVideo = true }
        let key = iAmCaller ? "callee_camera" : "caller_camera"
        if let c = d[key] as? Bool { peerCamera = c } else if d["video"] != nil || d["caller_camera"] != nil || d["callee_camera"] != nil {
            // the live summary omits a camera that is off
            peerCamera = false
        }
    }

    /// call.peer_media: both of that person's states. An older server sends no camera: the shown state stays.
    func applyPeerMedia(_ d: [String: Any]) {
        guard let c = d["camera"] as? Bool else { return }
        peerCamera = c
        if c { isVideo = true }
    }

    /// Marks the call as a video call before the camera opens (the caller's choice, an incoming video invite).
    func markVideo() { isVideo = true }

    // MARK: camera

    /// Camera permission, asked once; false when refused (the call goes on with sound, with a note).
    func cameraAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Opens the camera (front) and makes my track. False when the camera cannot be used.
    @discardableResult
    func openCamera() async -> Bool {
        // read before the permission prompt: a call that ended (or another that began) while it was up bumped it
        let gen = generation
        guard await cameraAllowed() else {
            note = NSLocalizedString("vc.camera.denied", comment: "")
            return false
        }
        guard gen == generation else { return false }
        if source == nil {
            let s = factory.videoSource()
            source = s
            capturer = RTCCameraVideoCapturer(delegate: s)
            localTrack = factory.videoTrack(with: s, trackId: "cam")
        }
        let ok = await startCapture()
        if ok { cameraOn = true; isVideo = true }
        return ok
    }

    private func device(front: Bool) -> AVCaptureDevice? {
        let want: AVCaptureDevice.Position = front ? .front : .back
        return RTCCameraVideoCapturer.captureDevices().first { $0.position == want } ?? RTCCameraVideoCapturer.captureDevices().first
    }

    /// The format closest to 1280x720 (640x360 when the phone is hot) and a frame rate up to 30 (24 when hot).
    nonisolated static func pickFormat(_ formats: [(width: Int32, height: Int32, maxFps: Double)], hot: Bool) -> Int? {
        let target: (Int32, Int32) = hot ? (640, 360) : (1280, 720)
        var best: Int?
        var bestScore = Int64.max
        for (i, f) in formats.enumerated() {
            let score = Int64(abs(f.width - target.0)) * Int64(abs(f.width - target.0)) + Int64(abs(f.height - target.1)) * Int64(abs(f.height - target.1))
            if score < bestScore { bestScore = score; best = i }
        }
        return best
    }

    private func startCapture() async -> Bool {
        guard let capturer, let dev = device(front: front) else { return false }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: dev)
        let hot = ProcessInfo.processInfo.thermalState == .serious
        let dims = formats.map { f -> (width: Int32, height: Int32, maxFps: Double) in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return (d.width, d.height, f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
        }
        guard let i = Self.pickFormat(dims, hot: hot) else { return false }
        let fps = Int(min(hot ? 24 : 30, dims[i].maxFps))
        let gen = generation
        videoLog.info("capture start \(dims[i].width)x\(dims[i].height)@\(fps) \(self.front ? "front" : "back", privacy: .public) (generation \(gen, privacy: .public))")
        return await withCheckedContinuation { cont in
            capturer.startCapture(with: dev, format: formats[i], fps: fps) { [weak self] err in
                Task { @MainActor in
                    guard let self else { cont.resume(returning: false); return }
                    // the call ended (or the camera went off) while the camera was starting: stopped at once
                    if gen != self.generation { capturer.stopCapture(); cont.resume(returning: false); return }
                    cont.resume(returning: err == nil)
                }
            }
        }
    }

    /// Stops the capture at once: the green camera dot goes off.
    func stopCapture() {
        generation += 1
        if capturer != nil { videoLog.info("capture stop (generation \(self.generation, privacy: .public))") }
        capturer?.stopCapture()
    }

    // MARK: diagnostics

    /// Once a second for 30 s: my outbound picture (size, frames per second, why it is limited, which encoder) and the
    /// incoming one (size, fps, frames decoded, which decoder). Read in Console, filter "video".
    func logStatsForAWhile(_ pc: RTCPeerConnection, callID: String) {
        Task { @MainActor [weak self, weak pc] in
            for second in 1...30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let pc, self.isVideo else { return }
                pc.statistics { report in
                    var line = "call \(callID.prefix(8)) t=\(second)s"
                    for s in report.statistics.values {
                        let v = s.values
                        func f(_ k: String) -> String { v[k].map { "\($0)" } ?? "-" }
                        if s.type == "outbound-rtp", f("kind") == "video" {
                            line += " out=" + f("frameWidth") + "x" + f("frameHeight") + "@" + f("framesPerSecond")
                            line += " limit=" + f("qualityLimitationReason") + " enc=" + f("encoderImplementation")
                        } else if s.type == "inbound-rtp", f("kind") == "video" {
                            line += " in=" + f("frameWidth") + "x" + f("frameHeight") + "@" + f("framesPerSecond")
                            line += " decoded=" + f("framesDecoded") + " dec=" + f("decoderImplementation")
                        }
                    }
                    videoLog.info("\(line, privacy: .public)")
                }
            }
        }
    }

    /// Flip: the other camera on the same track, nothing renegotiated.
    func flip() async {
        guard cameraOn else { return }
        front.toggle()
        stopCapture()
        _ = await startCapture()
    }

    // MARK: the peer connection

    private func videoTransceiver(_ pc: RTCPeerConnection) -> RTCRtpTransceiver? {
        pc.transceivers.first { $0.mediaType == .video }
    }

    /// Caller of a video call: a video line with my camera, in the first offer.
    func attachForOffer(_ pc: RTCPeerConnection) {
        guard isVideo, let track = localTrack, cameraOn, videoTransceiver(pc) == nil else { return }
        let i = RTCRtpTransceiverInit()
        i.direction = .sendRecv
        i.streamIds = ["tf"]
        if let t = pc.addTransceiver(with: track, init: i) { tune(t.sender) }
    }

    /// Callee, after the caller's offer is applied: my camera on the offered video line (sendrecv), or the line answered
    /// recvonly (sound only: I still see the caller).
    func attachForAnswer(_ pc: RTCPeerConnection) {
        guard let t = videoTransceiver(pc) else { return }
        var err: NSError?
        if cameraOn, let track = localTrack {
            t.sender.track = track
            t.sender.streamIds = ["tf"]
            t.setDirection(.sendRecv, error: &err)
            tune(t.sender)
        } else if t.direction != .sendRecv {
            t.setDirection(.recvOnly, error: &err)
        }
    }

    /// Camera on or off during the call. Returns true when a renegotiation follows (a new line, or recvonly → sendrecv).
    @discardableResult
    func setCamera(_ on: Bool, pc: RTCPeerConnection?) async -> Bool {
        if !on {
            cameraOn = false
            if let pc, let t = videoTransceiver(pc) { t.sender.track = nil }
            stopCapture()
            return false
        }
        guard await openCamera(), let track = localTrack else { return false }
        guard let pc else { return false }
        var err: NSError?
        if let t = videoTransceiver(pc) {
            t.sender.track = track
            t.sender.streamIds = ["tf"]
            tune(t.sender)
            if t.direction != .sendRecv {
                wantsOffer = true
                t.setDirection(.sendRecv, error: &err)
                return true
            }
            return false
        }
        wantsOffer = true
        let i = RTCRtpTransceiverInit()
        i.direction = .sendRecv
        i.streamIds = ["tf"]
        if let t = pc.addTransceiver(with: track, init: i) { tune(t.sender) }
        return true
    }

    /// 2.5 Mbit/s and 30 fps at most for my picture (IOS-VIDEO-001).
    private func tune(_ sender: RTCRtpSender) {
        let p = sender.parameters
        for e in p.encodings {
            e.maxBitrateBps = NSNumber(value: 2_500_000)
            e.maxFramerate = NSNumber(value: 30)
        }
        sender.parameters = p
    }

    /// The other person's picture arrived (a video receiver).
    func remoteArrived(_ track: RTCVideoTrack) { remoteTrack = track }

    /// The other person's picture is here (for tests and the screen, without WebRTC types).
    var hasRemotePicture: Bool { remoteTrack != nil }

    #if DEBUG
    /// Unit tests: a video part on the app's own factory (no WebRTC type in the test).
    static func forTests() -> CallVideo { CallVideo(factory: CallManager.factory) }

    /// Unit tests: the SDP of a caller's video offer (one audio and one video line), made with a plain source (no camera).
    static func probeOfferSDP() async throws -> String {
        let f = CallManager.factory
        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        guard let pc = f.peerConnection(with: cfg, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
                                        delegate: nil) else { return "" }
        defer { pc.close() }
        pc.add(f.audioTrack(with: f.audioSource(with: nil), trackId: "mic"), streamIds: ["tf"])
        let i = RTCRtpTransceiverInit()
        i.direction = .sendRecv
        _ = pc.addTransceiver(with: f.videoTrack(with: f.videoSource(), trackId: "cam"), init: i)
        return try await pc.tfOffer().sdp
    }
    #endif

    // MARK: background and heat

    /// The app leaves the screen: iOS stops the camera anyway; it is stopped here and the other side is told.
    /// Returns true when the camera state changed (call.media to send).
    func enteredBackground(pc: RTCPeerConnection?) -> Bool {
        guard cameraOn else { return false }
        resumeInFront = true
        cameraOn = false
        if let pc, let t = videoTransceiver(pc) { t.sender.track = nil }
        stopCapture()
        return true
    }

    /// Back in front: the camera comes back if it was on. Returns true when it did (call.media to send).
    func enteredForeground(pc: RTCPeerConnection?) async -> Bool {
        guard resumeInFront else { return false }
        resumeInFront = false
        return await setCamera(true, pc: pc) || cameraOn
    }

    private func thermalChanged() {
        switch ProcessInfo.processInfo.thermalState {
        case .critical where cameraOn:
            note = NSLocalizedString("vc.too.hot", comment: "")
            NotificationCenter.default.post(name: .tfCallCameraOffByHeat, object: nil)
        case .serious where cameraOn:
            // a smaller format at the next start; restart now so it takes effect
            Task { stopCapture(); _ = await startCapture() }
        default:
            break
        }
    }
}

extension Notification.Name {
    /// The phone is too hot: the call manager turns the camera off and tells the other side.
    static let tfCallCameraOffByHeat = Notification.Name("tf.call.cameraOffByHeat")
}
