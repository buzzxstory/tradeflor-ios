import AVFoundation
import Combine
import SwiftUI
import UIKit

/// The phone during a call, like WhatsApp: the screen goes dark at the ear (proximity sensor) while the earpiece is in
/// use, and never dims or locks by itself while a call rings or runs.
@MainActor
final class CallDeviceGuard {
    static let shared = CallDeviceGuard()
    private var subs = Set<AnyCancellable>()
    private var holdingIdle = false
    private var proximity = false

    func watch(_ calls: CallManager) {
        subs.removeAll()
        calls.$phase.combineLatest(calls.$speaker)
            .receive(on: DispatchQueue.main) // not RunLoop.main: held back while a list scrolls
            .sink { [weak self] phase, speaker in self?.apply(phase: phase, speaker: speaker) }
            .store(in: &subs)
        // AirPods / headphones / a car connect or leave: the screen must not blank against the cheek for them
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak calls] _ in
                guard let self, let calls else { return }
                self.apply(phase: calls.phase, speaker: calls.speaker)
            }
            .store(in: &subs)
    }

    private func apply(phase: CallManager.Phase, speaker: Bool) {
        let live = phase == .outgoing || phase == .connecting || phase == .active
        let keepAwake = live || phase == .incoming
        // only on a change: other screens (a video playing) may hold the idle timer themselves
        if keepAwake != holdingIdle {
            holdingIdle = keepAwake
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
        let external = AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones, .headsetMic, .usbAudio, .carAudio].contains($0.portType)
        }
        let wantProximity = live && !speaker && !external
        if wantProximity != proximity {
            proximity = wantProximity
            UIDevice.current.isProximityMonitoringEnabled = wantProximity
        }
    }
}

/// A call's running time as WhatsApp shows it: 00:42, 12:07, 1:02:33 (tabular digits, so it does not jiggle).
struct CallClock: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            Text(Self.format(ctx.date.timeIntervalSince(since))).monospacedDigit()
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}

/// The colours of the return-to-call bar: the app's own deep teal with a turquoise edge (the flat green of the system bar
/// clashed with every screen), the status bar area in the same colour.
enum CallBarLook {
    static let ground = LinearGradient(colors: [Theme.dyn(0x06404B, 0xDDF6F7), Theme.dyn(0x032C37, 0xEAF9FA)],
                                       startPoint: .top, endPoint: .bottom)
    static let top = Theme.dyn(0x06404B, 0xDDF6F7)
    static let edge = Theme.dyn(0x08D9D9, 0x0097A5, 0.45, 0.45)
    static let ink = Theme.dyn(0xFFFFFF, 0x0F2533)
    static let accent = Theme.dyn(0x2FE6E6, 0x007F8C)
}

/// A soft turquoise pulse: the call is live.
private struct CallPulse: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().fill(CallBarLook.accent.opacity(0.35)).frame(width: 16, height: 16).scaleEffect(on ? 1 : 0.5).opacity(on ? 0 : 1)
            Circle().fill(CallBarLook.accent).frame(width: 7, height: 7)
        }
        .frame(width: 16, height: 16)
        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } }
        .accessibilityHidden(true)
    }
}

/// The "Tap to return to call" bar shown above the app while a call runs and its screen is minimized.
/// Drop-in for the inline bar in RootView's `.safeAreaInset(edge: .top)`.
struct CallReturnBar: View {
    @ObservedObject var calls: CallManager

    var body: some View {
        if !calls.showScreen && calls.lineInUse {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                calls.showScreen = true
            } label: {
                HStack(spacing: 8) {
                    CallPulse()
                    Image(systemName: calls.muted ? "mic.slash.fill" : "phone.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CallBarLook.accent)
                    Text(calls.peerName).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 8)
                    Group {
                        if calls.phase == .active, calls.reconnecting {
                            Text("call.reconnecting")
                        } else if calls.phase == .active, let t = calls.connectedAt {
                            CallClock(since: t)
                        } else {
                            Text("call.return")
                        }
                    }
                    .lineLimit(1)
                    .monospacedDigit()
                    .foregroundStyle(CallBarLook.accent)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(CallBarLook.accent)
                }
                .font(.subheadline)
                .foregroundStyle(CallBarLook.ink)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(CallBarLook.ground)
                .overlay(alignment: .bottom) { Rectangle().fill(CallBarLook.edge).frame(height: 1) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(calls.peerName))
            .accessibilityHint(Text("call.return"))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Puts the app below the call bar: the bar fills the status bar area and its own row, the screens start under it.
struct CallBarSpace: ViewModifier {
    @ObservedObject var calls: CallManager

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if !calls.showScreen && calls.lineInUse {
                CallReturnBar(calls: calls)
                    .background(CallBarLook.top.ignoresSafeArea(edges: .top))
            }
            content
        }
        .animation(.easeOut(duration: 0.2), value: !calls.showScreen && calls.lineInUse)
    }
}

/// The other person's profile photo for the call screen (the big avatar and the blurred background), kept for the session.
@MainActor
final class CallPhotoCache {
    static let shared = CallPhotoCache()
    /// A few pictures at most (it was a dictionary that only grew, of full-size pictures).
    private let images: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 8
        return c
    }()
    private var avatarIDs: [String: String] = [:]

    func photo(token: String, userID: String?) async -> UIImage? {
        guard let userID, !userID.isEmpty, !token.isEmpty else { return nil }
        // the person's latest picture (AvatarBook) wins: a photo changed since the last call is never the old one again
        if let known = AvatarBook.shared.ids[userID] { avatarIDs[userID] = known }
        if avatarIDs[userID] == nil, let list = try? await APIClient.shared.conversations(token: token) {
            for c in list { avatarIDs[c.peer_id] = c.peer_avatar_id ?? "" }
        }
        guard let aid = avatarIDs[userID], !aid.isEmpty else { return nil } // no picture (or removed): the letter
        let key = userID + "/" + aid
        if let i = images.object(forKey: key as NSString) { return i }
        // decoded off the main thread at the size of the big photo (at most 290 pt): UIImage(data:) decoded the full
        // picture on the main thread just as the call screen came up. The blurred background needs no more detail.
        let pixels = 290 * UIScreen.main.scale
        guard let data = await APIClient.shared.avatar(token: token, userID: userID, avatarID: aid),
              let img = await AvatarImages.decode(data, maxPixels: pixels) else { return nil }
        images.setObject(img, forKey: key as NSString)
        return img
    }
}
