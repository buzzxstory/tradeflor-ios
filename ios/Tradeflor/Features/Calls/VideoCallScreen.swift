import SwiftUI
import UIKit
import WebRTC

/// One WebRTC video track drawn with Metal (RTCMTLVideoView), aspect-fill; the self-view of the front camera mirrored.
struct VideoTrackView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var mirrored = false
    /// The view itself, for Picture in Picture (the other person's picture only).
    var onView: ((UIView) -> Void)? = nil

    final class Coordinator { var track: RTCVideoTrack? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView(frame: .zero)
        v.videoContentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ v: RTCMTLVideoView, context: Context) {
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(v)
            track?.add(v)
            context.coordinator.track = track
        }
        v.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        if let onView { DispatchQueue.main.async { onView(v) } }
    }

    static func dismantleUIView(_ v: RTCMTLVideoView, coordinator: Coordinator) {
        // a hidden or closed view takes no more frames (IOS-VIDEO-011: nothing drawn that is not seen)
        coordinator.track?.remove(v)
        coordinator.track = nil
    }
}

/// The video call screen (IOS-VIDEO-003), in TRADEFLOR's colours: the other person's picture fills the screen (their photo
/// on navy while there is none), my own picture fills it while ringing out, then sits small in a corner I can drag; one
/// floating bar (microphone, camera, flip, speaker, end) that fades while the picture plays and comes back on a tap.
struct VideoCallScreen: View {
    @ObservedObject var calls: CallManager
    @ObservedObject var video: CallVideo
    let photo: UIImage?

    @State private var controlsShown = true
    @State private var fadeTask: Task<Void, Never>?
    @AppStorage("tf.video.selfCorner") private var corner = 1 // 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right
    @State private var drag: CGSize = .zero

    private var live: Bool { calls.phase != .ended && calls.phase != .idle }
    private var remoteShows: Bool { video.peerCamera && video.remoteTrack != nil && calls.phase == .active }
    /// Ringing out (or connecting) with my camera on: my own picture fills the screen.
    private var selfFullScreen: Bool { !remoteShows && video.cameraOn && (calls.phase == .outgoing || calls.phase == .connecting) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop
                if remoteShows {
                    // the floating window when the app goes to the background (IOS-VIDEO-009)
                    VideoTrackView(track: video.remoteTrack, onView: { CallPiP.shared.attach(source: $0, track: video.remoteTrack) })
                        .ignoresSafeArea()
                        .onDisappear { CallPiP.shared.detach() }
                } else if selfFullScreen {
                    VideoTrackView(track: video.localTrack, mirrored: video.front).ignoresSafeArea()
                } else {
                    avatar
                }
                if video.cameraOn && !selfFullScreen {
                    selfView(in: geo)
                }
                VStack(spacing: 0) {
                    topBar
                    tags.padding(.top, 8)
                    Spacer()
                    if let n = video.note {
                        Text(n).font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.black.opacity(0.5), in: Capsule()).padding(.bottom, 10)
                            .onTapGesture { video.note = nil }
                    }
                    if calls.phase == .incoming { incomingControls } else { controlBar }
                }
                .opacity(controlsShown || calls.phase != .active ? 1 : 0)
                // faded controls take no taps: a tap on the picture brings them back, it never hangs up
                .allowsHitTesting(controlsShown || calls.phase != .active)
                .animation(.easeInOut(duration: 0.25), value: controlsShown)
            }
            .contentShape(Rectangle())
            .onTapGesture { showControls() }
        }
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .onAppear { showControls() }
        .onChange(of: calls.phase) { _ in showControls() }
    }

    // MARK: picture

    private var backdrop: some View {
        LinearGradient(colors: [Theme.hex(0x062A3A), Theme.hex(0x020C14)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
    }

    private var avatar: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.avatarGradient)
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFill()
                } else {
                    Text(String(calls.peerName.prefix(1)).uppercased()).font(.system(size: 64, weight: .bold))
                        .foregroundStyle(Theme.hex(0x08D9D9))
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.hex(0x2FE6E6, 0.35), lineWidth: 2))
            .shadow(color: Theme.hex(0x08D9D9, 0.25), radius: 24)
            if calls.phase == .active && !video.peerCamera {
                Label("vc.peer.camera.off", systemImage: "video.slash.fill").font(.footnote.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .accessibilityHidden(true)
    }

    /// My own picture, small, in a corner of the safe area I can drag it to (remembered).
    private func selfView(in geo: GeometryProxy) -> some View {
        let w: CGFloat = 108, h: CGFloat = 160, margin: CGFloat = 14
        let top = geo.safeAreaInsets.top + 70, bottom = geo.safeAreaInsets.bottom + 150
        let left = margin + w / 2, right = geo.size.width - margin - w / 2
        let points = [CGPoint(x: left, y: top + h / 2), CGPoint(x: right, y: top + h / 2),
                      CGPoint(x: left, y: geo.size.height - bottom - h / 2), CGPoint(x: right, y: geo.size.height - bottom - h / 2)]
        let p = points[max(0, min(3, corner))]
        return VideoTrackView(track: video.localTrack, mirrored: video.front)
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .position(x: p.x + drag.width, y: p.y + drag.height)
            .gesture(DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { v in
                    let end = CGPoint(x: p.x + v.translation.width, y: p.y + v.translation.height)
                    let nearest = points.indices.min { a, b in
                        hypot(points[a].x - end.x, points[a].y - end.y) < hypot(points[b].x - end.x, points[b].y - end.y)
                    } ?? corner
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { corner = nearest; drag = .zero }
                })
            .accessibilityLabel(Text("vc.self"))
    }

    // MARK: chrome

    private var topBar: some View {
        HStack(alignment: .top) {
            Button { calls.showScreen = false } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44).background(Color.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel(Text("call.minimize"))
            .opacity(live ? 1 : 0).disabled(!live)
            Spacer(minLength: 8)
            VStack(spacing: 3) {
                Text(calls.peerName).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                status.font(.callout).foregroundStyle(Color.white.opacity(0.85))
            }
            .shadow(color: .black.opacity(0.5), radius: 4)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            CallNotebookButton(calls: calls, video: true) {
                Image(systemName: "note.text").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44).background(Color.black.opacity(0.4), in: Circle())
            }
            .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    @ViewBuilder private var status: some View {
        switch calls.phase {
        case .outgoing: Text(LocalizedStringKey(calls.ringing ? "call.ringing" : "call.calling"))
        case .incoming: Text("vc.incoming")
        case .connecting: Text("call.connecting")
        case .active:
            if calls.reconnecting { Text("call.reconnecting").foregroundStyle(Theme.hex(0xEFBE33)) }
            else if let t = calls.connectedAt { CallClock(since: t) } else { Text("call.connecting") }
        case .ended, .idle:
            Text(LocalizedStringKey(CallScreen.endedKey(calls.endReason)))
        }
    }

    @ViewBuilder private var tags: some View {
        if calls.phase == .active {
            HStack(spacing: 8) {
                if calls.peerMuted { tag("mic.slash.fill", String(format: NSLocalizedString("vc.peer.muted", comment: ""), calls.peerName)) }
                if !video.peerCamera { tag("video.slash.fill", String(format: NSLocalizedString("vc.peer.camoff", comment: ""), calls.peerName)) }
            }
        }
    }

    private func tag(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.caption.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.black.opacity(0.45), in: Capsule())
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            round(calls.muted ? "mic.slash.fill" : "mic.fill", "call.mute", on: calls.muted) { calls.toggleMute() }
            round(video.cameraOn ? "video.fill" : "video.slash.fill", "vc.camera", on: !video.cameraOn) { calls.toggleCamera() }
            round("arrow.triangle.2.circlepath.camera", "vc.flip", on: false) { calls.flipCamera() }
                .opacity(video.cameraOn ? 1 : 0.4).disabled(!video.cameraOn)
            round(calls.speaker ? "speaker.wave.3.fill" : "speaker.wave.2.fill", "call.speaker", on: calls.speaker) { calls.toggleSpeaker() }
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                calls.hangUp()
            } label: {
                Image(systemName: "phone.down.fill").font(.system(size: 22, weight: .semibold))
                    .frame(width: 58, height: 58).background(Theme.hex(0xF0525B), in: Circle())
            }
            .accessibilityLabel(Text("call.hangup"))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(
            Capsule(style: .continuous).fill(.ultraThinMaterial)
                .overlay(Capsule(style: .continuous).fill(Theme.hex(0x04111E, 0.55)))
                .overlay(Capsule(style: .continuous).stroke(Theme.hex(0x2FE6E6, 0.25), lineWidth: 1))
        )
        .environment(\.colorScheme, .dark)
        .padding(.bottom, 20)
        .opacity(live ? 1 : 0.45).disabled(!live)
    }

    private func round(_ icon: String, _ label: LocalizedStringKey, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
            showControls()
        } label: {
            Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                .foregroundStyle(on ? Theme.hex(0x04222C) : .white)
                .frame(width: 50, height: 50)
                .background(on ? Color.white : Color.white.opacity(0.16), in: Circle())
        }
        .accessibilityLabel(Text(label))
    }

    private var incomingControls: some View {
        VStack(spacing: 22) {
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    CallRoundButton(icon: "phone.down.fill", color: Theme.hex(0xF0525B), size: 72, label: "call.decline") {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        calls.decline()
                    }
                    Text("call.decline").font(.subheadline).accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 8) {
                    CallRoundButton(icon: "video.fill", color: Theme.hex(0x14C27A), size: 72, label: "vc.accept") {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        calls.accept(withVideo: true)
                    }
                    Text("vc.accept").font(.subheadline).accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                calls.accept(withVideo: false)
            } label: {
                Label("vc.accept.audio", systemImage: "phone.fill").font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18).frame(minHeight: 44)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24).padding(.bottom, 30)
    }

    /// The controls come back and fade again after 4.5 s while the other person's picture plays (never while connecting).
    private func showControls() {
        controlsShown = true
        fadeTask?.cancel()
        fadeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled, calls.phase == .active, remoteShows else { return }
            controlsShown = false
        }
    }
}
