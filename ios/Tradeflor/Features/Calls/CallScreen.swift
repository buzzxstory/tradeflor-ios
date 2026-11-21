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
        // a video call (a video invite, or a camera turned on by either side) has its own screen
        CallKindSwitch(video: calls.video, voice: voiceBody) { VideoCallScreen(calls: calls, video: calls.video, photo: photo) }
            .task(id: calls.peerID) {
                let img = await CallPhotoCache.shared.photo(token: token, userID: calls.peerID)
                withAnimation(.easeIn(duration: 0.3)) { photo = img }
            }
    }

    private var voiceBody: some View {
        ZStack {
            CallBackdrop(photo: photo)
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                hero
                Spacer(minLength: 12)
                bottom
            }
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .animation(.easeInOut(duration: 0.25), value: calls.phase)
        .animation(.easeInOut(duration: 0.2), value: calls.reconnecting)
    }

    // MARK: top

    /// Like WhatsApp's call screen: minimize at the left, the name and the status centred at the top.
    private var topBar: some View {
        HStack(alignment: .top, spacing: 0) {
            Button {
                calls.showScreen = false
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.35), in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel(Text("call.minimize"))
            .opacity(live ? 1 : 0)
            .disabled(!live)
            Spacer(minLength: 8)
            titleBlock.padding(.top, 2)
            Spacer(minLength: 8)
            // keeps the name centred (no add-participant: calls are one to one)
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text(calls.peerName)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            status
                .font(.callout)
                .foregroundStyle(Color.white.opacity(0.8))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: the big photo

    private var hero: some View {
        let size = min(UIScreen.main.bounds.width * 0.54, 290)
        return VStack(spacing: 16) {
            ZStack {
                if live { CallAura(size: size, ripples: calls.phase != .active) }
                photoCircle(size: size)
            }
            .frame(width: size * 1.7, height: size * 1.7)
            .accessibilityHidden(true)
            if calls.peerMuted && calls.phase == .active {
                Label("call.peer.muted", systemImage: "mic.slash.fill")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.black.opacity(0.3), in: Capsule())
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                Text("call2.e2e").font(.footnote)
            }
            .foregroundStyle(Color.white.opacity(0.6))
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
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
            // the exact cause, small, when the call never connected (so a failure can be told apart)
            if calls.lastDuration == nil || (calls.lastDuration ?? 0) < 1, let r = calls.endReason,
               !["declined", "busy", "no_answer", "hangup", "canceled", "completed"].contains(r) {
                Text(r).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.white.opacity(0.45)).padding(.top, 4)
            }
            // the microphone is off for Tradeflor: one tap to where it is turned on
            if calls.endReason == "mic_denied" {
                Button {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                } label: {
                    Text("chat.settings").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 18).frame(minHeight: 44)
                }
                .padding(.top, 4)
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
        case "rate_limited": return "call3.ended.ratelimited"
        case "already_in_call": return "call3.ended.inacall"
        case "answered_elsewhere": return "call3.ended.elsewhere"
        case "canceled", "hangup_before_media": return "call3.ended.canceled"
        case "connection_lost": return "call3.ended.lost"
        case "ice_failed", "ice_timeout": return "call3.ended.noconnect"
        case "not_found", "invalid", "stale", "offline", "system_end": return "call.ended.failed"
        case "failed", "negotiation_failed": return "call.ended.failed"
        case nil, "hangup", "completed", "blocked": return "call.ended"
        default: return "call.ended.failed"
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

    /// WhatsApp's dark rounded sheet: Speaker, Message and Mute on the first row, End under them, each with its name.
    /// Camera turns the voice call into a video call (IOS-VIDEO-005); More and Share are left out: a button must do something.
    private var panel: some View {
        VStack(spacing: 22) {
            HStack(spacing: 0) {
                labelled("call.speaker") {
                    CallToggleButton(icon: calls.speaker ? "speaker.wave.3.fill" : "speaker.wave.2.fill", label: "call.speaker",
                                     on: calls.speaker) { calls.toggleSpeaker() }
                }
                labelled("call2.message") {
                    CallToggleButton(icon: "message.fill", label: "call2.message", on: false) {
                        let conv = calls.conversation
                        calls.showScreen = false
                        if let conv { LocalNotifier.shared.tappedConversation = conv }
                    }
                    .opacity(calls.conversation == nil ? 0.4 : 1)
                    .disabled(calls.conversation == nil)
                }
                labelled("call.mute") {
                    CallToggleButton(icon: "mic.slash.fill", label: "call.mute", on: calls.muted) { calls.toggleMute() }
                }
                labelled("vc.camera") {
                    CallToggleButton(icon: "video.fill", label: "vc.camera", on: false) { calls.toggleCamera() }
                        .opacity(calls.phase == .active ? 1 : 0.4)
                        .disabled(calls.phase != .active)
                }
            }
            CallNotebookButton(calls: calls, video: false) {
                Label("notes.notebook", systemImage: "note.text").font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18).frame(minHeight: 44)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .foregroundStyle(.white)
            }
            labelled("call.hangup") {
                CallRoundButton(icon: "phone.down.fill", color: Theme.hex(0xF0525B), size: 64, label: "call.hangup") {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    calls.hangUp()
                }
            }
        }
        .padding(.vertical, 22)
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

    private func labelled<B: View>(_ title: LocalizedStringKey, @ViewBuilder _ button: () -> B) -> some View {
        VStack(spacing: 8) {
            button()
            Text(title).font(.footnote).foregroundStyle(Color.white.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
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

/// Around the photo: a soft teal glow that breathes, a slowly turning gradient ring, and (while it rings or connects) three
/// ripples spreading out. Calmer once the call is on.
private struct CallAura: View {
    let size: CGFloat
    let ripples: Bool
    @State private var go = false
    @State private var spin = false
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.hex(0x08D9D9, 0.35), Color.clear], center: .center,
                                     startRadius: size * 0.4, endRadius: size * 0.85))
                .frame(width: size * 1.7, height: size * 1.7)
                .scaleEffect(breathe ? 1.06 : 0.94)
                .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: breathe)
            if ripples {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(Theme.hex(0x08D9D9, 0.55), lineWidth: 2)
                        .frame(width: size, height: size)
                        .scaleEffect(go ? 1.6 : 1)
                        .opacity(go ? 0 : 0.8)
                        .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8), value: go)
                }
            }
            Circle()
                .strokeBorder(AngularGradient(colors: [Theme.hex(0x08D9D9), Theme.hex(0x14D99A), Theme.hex(0x08D9D9, 0.05), Theme.hex(0x08D9D9)],
                                              center: .center), lineWidth: 4)
                .frame(width: size + 18, height: size + 18)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 5).repeatForever(autoreverses: false), value: spin)
        }
        .onAppear { go = true; spin = true; breathe = true }
    }
}


/// The voice screen or the video screen, following the call's video state (an ObservableObject of its own).
private struct CallKindSwitch<Voice: View, Video: View>: View {
    @ObservedObject var video: CallVideo
    let voice: Voice
    @ViewBuilder let videoScreen: () -> Video

    init(video: CallVideo, voice: Voice, @ViewBuilder _ videoScreen: @escaping () -> Video) {
        self.video = video
        self.voice = voice
        self.videoScreen = videoScreen
    }

    var body: some View {
        if video.isVideo { videoScreen() } else { voice }
    }
}
