import AVKit
import UIKit
import WebRTC

/// Picture in Picture for a video call (IOS-VIDEO-009): swiping home keeps the other person's picture in a floating window;
/// a tap on it returns to the call. iOS gives video calls PiP through AVPictureInPictureVideoCallViewController with frames
/// drawn into an AVSampleBufferDisplayLayer (a WebRTC view does not get PiP by itself). Only the other person's picture:
/// my camera stops in the background (no multitasking-camera entitlement).
@MainActor
final class CallPiP: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = CallPiP()

    private var controller: AVPictureInPictureController?
    private var renderer: SampleBufferRenderer?
    private weak var track: RTCVideoTrack?
    private weak var source: UIView?

    /// The video call screen shows the other person's picture in `view`: PiP is prepared on it (started by iOS itself when
    /// the app goes to the background).
    func attach(source view: UIView, track: RTCVideoTrack?) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard let track else { detach(); return }
        if source === view, self.track === track, controller != nil { return }
        detach()
        let content = AVPictureInPictureVideoCallViewController()
        content.preferredContentSize = CGSize(width: 1080, height: 1920)
        // a view that fills the window and follows its size (a bare sublayer kept the first frame: a cropped piece)
        let host = PiPPictureView(frame: content.view.bounds)
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.view.addSubview(host)
        let r = SampleBufferRenderer(view: host)
        r.onSize = { [weak content] size in
            DispatchQueue.main.async { content?.preferredContentSize = size }
        }
        track.add(r)
        let src = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: view, contentViewController: content)
        let c = AVPictureInPictureController(contentSource: src)
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.delegate = self
        controller = c
        renderer = r
        self.track = track
        source = view
    }

    /// The call ended or its picture went: no floating window any more.
    func detach() {
        if let r = renderer { track?.remove(r) }
        controller?.stopPictureInPicture()
        controller = nil
        renderer = nil
        track = nil
        source = nil
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        // a tap on the floating window: back to the call screen
        Task { @MainActor in
            CallManager.shared.showScreen = true
            done(true)
        }
    }
}

/// Draws WebRTC frames into an AVSampleBufferDisplayLayer for PiP. Hardware-decoded frames (H.264 through VideoToolbox)
/// are CVPixelBuffers and go in as they are; other frames are skipped (the window keeps the last picture).
final class SampleBufferRenderer: NSObject, RTCVideoRenderer {
    private weak var view: PiPPictureView?
    private let layer: AVSampleBufferDisplayLayer
    var onSize: ((CGSize) -> Void)?
    private var lastSize: CGSize = .zero
    private var lastRotation: RTCVideoRotation = ._0

    init(view: PiPPictureView) {
        self.view = view
        layer = view.picture.displayLayer
        super.init()
    }

    func setSize(_ size: CGSize) {
        guard size != lastSize, size.width > 0, size.height > 0 else { return }
        lastSize = size
        onSize?(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let cv = frame.buffer as? RTCCVPixelBuffer else { return }
        // phones send portrait pictures unrotated with an orientation mark: the view is turned to match
        if frame.rotation != lastRotation {
            lastRotation = frame.rotation
            let rotation = frame.rotation
            DispatchQueue.main.async { [weak view] in view?.rotation = rotation }
        }
        let pixel = cv.pixelBuffer
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                           formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
    }
}

/// The PiP window's content: the picture view, sized and turned for the frame's rotation.
final class PiPPictureView: UIView {
    let picture = SampleBufferView()
    var rotation: RTCVideoRotation = ._0 { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        picture.displayLayer.videoGravity = .resizeAspect
        addSubview(picture)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let sideways = rotation == ._90 || rotation == ._270
        picture.transform = .identity
        picture.bounds = CGRect(x: 0, y: 0, width: sideways ? bounds.height : bounds.width, height: sideways ? bounds.width : bounds.height)
        picture.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let angle: CGFloat
        switch rotation {
        case ._90: angle = .pi / 2
        case ._180: angle = .pi
        case ._270: angle = -.pi / 2
        default: angle = 0
        }
        picture.transform = CGAffineTransform(rotationAngle: angle)
    }
}

/// A view whose own layer is the sample-buffer display layer (it resizes with the view).
final class SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}
