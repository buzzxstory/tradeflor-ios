import SwiftUI
import UIKit

/// The in-app call screen, laid out like WhatsApp's iOS voice call: the other person's photo blurred behind everything,
/// "End-to-end encrypted" at the top, the big round photo, name and status, and the dark translucent control panel at
/// the bottom (Speaker, Mute, End). An incoming call shows Decline / Accept. CallKit still shows the system screen on the
/// lock screen; this is the screen inside the app.
struct CallScreen: View {
    @ObservedObject var calls: CallManager
    @EnvironmentObject private var store: SessionStore
    @State private var photo: UIImage?

    private var token: String { store.session?.token ?? "" }
    private var live: Bool { calls.phase != .ended && calls.phase != .idle }

    var body: some View {
        ZStack {
            CallBackdrop(photo: photo)
            VStack(spacing: 0) {
                topBar
                header.padding(.top, 30)
                Spacer(minLength: 24)
                bottom
            }
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .animation(.easeInOut(duration: 0.25), value: calls.phase)
        .animation(.easeInOut(duration: 0.2), value: calls.reconnecting)
        .task(id: calls.peerID) {
            let img = await CallPhotoCache.shared.photo(token: token, userID: calls.peerID)
            withAnimation(.easeIn(duration: 0.3)) { photo = img }
        }
    }

    // MARK: top

    private var topBar: some View {
        HStack(spacing: 0) {
            Button {
                calls.showScreen = false
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("call.minimize"))
            .opacity(live ? 1 : 0)
            .disabled(!live)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                Text("call2.e2e").font(.footnote)
            }
            .foregroundStyle(Color.white.opacity(0.75))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            // keeps the encryption line centred (no add-participant: calls are one to one)
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    // MARK: who and status

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                if calls.phase == .outgoing || calls.phase == .incoming { PulseRings(size: 140) }
                photoCircle(size: 140)
            }
            .frame(width: 200, height: 170)
            .accessibilityHidden(true)
            Text(calls.peerName)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 28)
                .accessibilityAddTraits(.isHeader)
            status
                .font(.body)
                .foregroundStyle(Color.white.opacity(0.8))
            if calls.peerMuted && calls.phase == .active {
                Label("call.peer.muted", systemImage: "mic.slash.fill")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.black.opacity(0.3), in: Capsule())
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func photoCircle(size: CGFloat) -> some View {
        ZStack {
            Circle().fill(Theme.avatarGradient)
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else {
                Text(String(calls.peerName.prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(Theme.hex(0x08D9D9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }

    @ViewBuilder private var status: some View {
        switch calls.phase {
        case .outgoing:
            Text(LocalizedStringKey(calls.ringing ? "call.ringing" : "call.calling"))
        case .incoming:
            Text("call.incoming")
        case .connecting:
            Text("call.connecting")
        case .active:
            if calls.reconnecting {
                Text("call.reconnecting").foregroundStyle(Theme.hex(0xEFBE33))
            } else if let t = calls.connectedAt {
                CallClock(since: t)
            } else {
                Text("call.connecting")
            }
        case .ended, .idle:
            HStack(spacing: 4) {
                Text(LocalizedStringKey(Self.endedKey(calls.endReason)))
                if let d = calls.lastDuration, d >= 1 { Text("· " + CallClock.format(d)).monospacedDigit() }
            }
        }
    }

    static func endedKey(_ reason: String?) -> String {
        switch reason {
        case "busy": return "call.ended.busy"
        case "no_answer": return "call.ended.noanswer"
        case "declined": return "call.ended.declined"
        case "mic_denied": return "call.ended.mic"
        case "not_allowed": return "call.ended.notallowed"
        case "failed", "ice_timeout", "connection_lost": return "call.ended.failed"
        default: return "call.ended"
        }
    }

    // MARK: controls

    @ViewBuilder private var bottom: some View {
        if calls.phase == .incoming {
            incomingControls
        } else {
            panel
        }
    }

    /// WhatsApp's dark rounded sheet of round buttons. Video is left out: calls are voice only (server and website).
    private var panel: some View {
        HStack(spacing: 0) {
            CallToggleButton(icon: calls.speaker ? "speaker.wave.3.fill" : "speaker.wave.2.fill", label: "call.speaker",
                             on: calls.speaker) { calls.toggleSpeaker() }
                .frame(maxWidth: .infinity)
            CallToggleButton(icon: "mic.slash.fill", label: "call.mute", on: calls.muted) { calls.toggleMute() }
                .frame(maxWidth: .infinity)
            CallRoundButton(icon: "phone.down.fill", color: Theme.hex(0xF0525B), size: 60, label: "call.hangup") {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                calls.hangUp()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Theme.hex(0x04111E, 0.55)))
                .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 12)
        .opacity(live ? 1 : 0.45)
        .disabled(!live)
    }

    private var incomingControls: some View {
        VStack(spacing: 34) {
            Button {
                let conv = calls.conversation
                calls.decline()
                calls.showScreen = false
                if let conv { LocalNotifier.shared.tappedConversation = conv }
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "message.fill").font(.system(size: 20, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(Color.white.opacity(0.16), in: Circle())
                    Text("call2.message").font(.footnote)
                }
            }
            .buttonStyle(.plain)
            .opacity(calls.conversation == nil ? 0 : 1)
            .disabled(calls.conversation == nil)
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    CallRoundButton(icon: "phone.down.fill", color: Theme.hex(0xF0525B), size: 74, label: "call.decline") {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        calls.decline()
                    }
                    Text("call.decline").font(.subheadline).accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 8) {
                    CallRoundButton(icon: "phone.fill", color: Theme.hex(0x14C27A), size: 74, label: "call.accept") {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        calls.accept()
                    }
                    Text("call.accept").font(.subheadline).accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 30)
    }
}

/// A round toggle of the panel: translucent white when off, filled white with a dark glyph when on (WhatsApp's mute).
struct CallToggleButton: View {
    let icon: String
    let label: LocalizedStringKey
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(on ? Theme.hex(0x04111E) : Color.white)
                .frame(width: 60, height: 60)
                .background(on ? Color.white : Color.white.opacity(0.16), in: Circle())
                .animation(.easeInOut(duration: 0.15), value: on)
        }
        .buttonStyle(CallPressStyle())
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct CallRoundButton: View {
    let icon: String
    let color: Color
    var size: CGFloat = 64
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color, in: Circle())
                .shadow(color: color.opacity(0.4), radius: 12, y: 5)
        }
        .buttonStyle(CallPressStyle())
        .accessibilityLabel(Text(label))
    }
}

private struct CallPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The background: the person's photo enlarged, heavily blurred and dimmed; without a photo the brand's navy with a teal glow.
struct CallBackdrop: View {
    let photo: UIImage?

    var body: some View {
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: [Theme.hex(0x0A3445), Theme.hex(0x04111E), Theme.hex(0x020A12)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Theme.hex(0x08D9D9, 0.22), Color.clear], center: UnitPoint(x: 0.5, y: 0.28),
                               startRadius: 0, endRadius: max(g.size.width, 1))
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                        .blur(radius: 60, opaque: true)
                        .overlay(Color.black.opacity(0.5))
                        .transition(.opacity)
                }
                LinearGradient(colors: [Color.black.opacity(0.25), Color.clear, Color.black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Soft rings breathing out of the photo while the call rings.
private struct PulseRings: View {
    let size: CGFloat
    @State private var go = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(Theme.hex(0x08D9D9, 0.5), lineWidth: 2)
                    .frame(width: size, height: size)
                    .scaleEffect(go ? 1.35 : 1)
                    .opacity(go ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(Double(i) * 0.9), value: go)
            }
        }
        .onAppear { go = true }
    }
}
