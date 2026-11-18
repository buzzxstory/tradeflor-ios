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
    }

    private func apply(phase: CallManager.Phase, speaker: Bool) {
        let live = phase == .outgoing || phase == .connecting || phase == .active
        let keepAwake = live || phase == .incoming
        // only on a change: other screens (a video playing) may hold the idle timer themselves
        if keepAwake != holdingIdle {
            holdingIdle = keepAwake
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
        let wantProximity = live && !speaker
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

/// The green "Tap to return to call" bar shown above the app while a call runs and its screen is minimized.
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
                    Image(systemName: calls.muted ? "mic.slash.fill" : "phone.fill")
                        .font(.system(size: 13, weight: .semibold))
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
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(Theme.hex(0x14C27A))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(calls.peerName))
            .accessibilityHint(Text("call.return"))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// The other person's profile photo for the call screen (the big avatar and the blurred background), kept for the session.
@MainActor
final class CallPhotoCache {
    static let shared = CallPhotoCache()
    private var images: [String: UIImage] = [:]
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
        if let i = images[key] { return i }
        guard let data = await APIClient.shared.avatar(token: token, userID: userID, avatarID: aid),
              let img = UIImage(data: data) else { return nil }
        images[key] = img
        return img
    }
}
