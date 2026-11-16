import SwiftUI

/// The in-app call screen (CallKit also shows the system one on the lock screen and in the status bar).
struct CallScreen: View {
    @ObservedObject var calls: CallManager
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.surface, Theme.ground], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    Button { calls.showScreen = false } label: {
                        Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(Color.white.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel(Text("call.minimize"))
                    .opacity(calls.phase == .ended || calls.phase == .idle ? 0 : 1)
                    Spacer()
                    Label("call.voice", systemImage: "phone.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.top, 8)
                Spacer().frame(height: 30)
                Group {
                    if let pid = calls.peerID {
                        Avatar(token: store.session?.token ?? "", userID: pid, avatarID: nil, title: calls.peerName, size: 120)
                    } else {
                        Circle()
                            .fill(Theme.surface)
                            .frame(width: 120, height: 120)
                            .overlay(Text(String(calls.peerName.prefix(1)).uppercased()).font(.system(size: 48, weight: .bold))
                                .foregroundStyle(Theme.accent))
                    }
                }
                .overlay(Circle().stroke(Theme.accent.opacity(calls.phase == .active ? 0.9 : 0.3), lineWidth: 3).padding(-4))
                .shadow(color: Theme.accent.opacity(calls.phase == .outgoing || calls.phase == .incoming ? 0.45 : 0), radius: 18)
                Text(calls.peerName).font(.title.weight(.semibold)).foregroundStyle(.white)
                status
                if calls.peerMuted && calls.phase == .active {
                    Label("call.peer.muted", systemImage: "mic.slash.fill").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                controls.padding(.bottom, 50)
            }
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder private var status: some View {
        switch calls.phase {
        case .outgoing: Text(LocalizedStringKey(calls.ringing ? "call.ringing" : "call.calling")).foregroundStyle(.secondary)
        case .incoming: Text("call.incoming").foregroundStyle(.secondary)
        case .connecting: Text("call.connecting").foregroundStyle(.secondary)
        case .active:
            if calls.reconnecting {
                Label("call.reconnecting", systemImage: "wifi.exclamationmark").foregroundStyle(Color.orange)
            } else if let t = calls.connectedAt {
                Text(t, style: .timer).monospacedDigit().foregroundStyle(.secondary)
            }
        case .ended, .idle:
            Text(LocalizedStringKey(Self.endedKey(calls.endReason))).foregroundStyle(.secondary)
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

    @ViewBuilder private var controls: some View {
        if calls.phase == .incoming {
            HStack(spacing: 70) {
                roundButton("phone.down.fill", color: .red, label: "call.decline") { calls.decline() }
                roundButton("phone.fill", color: .green, label: "call.accept") { calls.accept() }
            }
        } else if calls.phase != .ended && calls.phase != .idle {
            HStack(spacing: 34) {
                toggleButton(calls.muted ? "mic.slash.fill" : "mic.fill", on: calls.muted, label: "call.mute") { calls.toggleMute() }
                roundButton("phone.down.fill", color: .red, label: "call.hangup") { calls.hangUp() }
                toggleButton("speaker.wave.2.fill", on: calls.speaker, label: "call.speaker") { calls.toggleSpeaker() }
            }
        }
    }

    private func roundButton(_ icon: String, color: Color, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 74, height: 74).background(color, in: Circle())
        }
        .accessibilityLabel(Text(label))
    }

    private func toggleButton(_ icon: String, on: Bool, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 24, weight: .semibold))
                .foregroundStyle(on ? Theme.onAccent : .white)
                .frame(width: 64, height: 64)
                .background(on ? Theme.accent : Color.white.opacity(0.15), in: Circle())
        }
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
