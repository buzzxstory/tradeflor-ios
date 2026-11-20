import SwiftUI

// Pieces of the Join requests card in Group Info (website .jr, 3c68bec): the pulsing count and one request row.

/// The waiting count: a cyan gradient pill with a ring that pulses outwards every 1.6 s (still with Reduce Motion).
struct JoinRequestCountBadge: View {
    let count: Int
    let animate: Bool
    @State private var pulse = false

    var body: some View {
        Text(verbatim: "\(count)").font(.system(size: 12, weight: .heavy)).foregroundStyle(Theme.hex(0x032229))
            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
            .background(LinearGradient(colors: [Theme.hex(0x2FF0F3), Theme.hex(0x08A8B8)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Capsule())
            .background {
                if animate {
                    Capsule().fill(Theme.hex(0x2FF0F3, pulse ? 0 : 0.55))
                        .padding(pulse ? -9 : 0)
                }
            }
            .onAppear {
                guard animate else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
            }
            .accessibilityLabel(Text(verbatim: "\(count)"))
    }
}

/// One request: avatar, name, "@user · when" (the time bold cyan while fresh), ✕ and ✓. A fresh request (under a minute old,
/// or arrived live) has a cyan wash and a 3 px cyan edge, and blinks three times when it appears.
struct JoinRequestRow: View {
    let token: String
    let request: GrpJoinRequest
    let now: Date
    let live: Bool
    let animate: Bool
    let decide: (Bool) -> Void
    @State private var flash = false
    @State private var blinked = false

    private var name: String { (request.display_name?.isEmpty == false ? request.display_name : nil) ?? request.username }
    private var created: Double {
        request.created_at > 100_000_000_000 ? Double(request.created_at) / 1000 : Double(request.created_at)
    }
    private var age: Double { max(0, now.timeIntervalSince1970 - created) }
    private var fresh: Bool { live || age < 60 }

    private var when: String {
        if age < 60 { return NSLocalizedString("gx.jr.now", comment: "") }
        if age < 3600 { return String(format: NSLocalizedString("gx.jr.min", comment: ""), Int(age / 60)) }
        if age < 86400 { return String(format: NSLocalizedString("gx.jr.h", comment: ""), Int(age / 3600)) }
        return Date(timeIntervalSince1970: created).formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        let muted = Theme.dyn(0x7F9AA7, 0x5F7686)
        let cyan = Theme.dyn(0x2FF0F3, 0x00B3C0)
        HStack(spacing: 11) {
            Avatar(token: token, userID: request.user_id, avatarID: nil, title: name, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 14.5, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                (Text("@" + request.username + " · ").foregroundColor(muted)
                 + (fresh ? Text(when).bold().foregroundColor(Theme.dyn(0x2FF0F3, 0x0097A5)) : Text(when).foregroundColor(muted)))
                    .font(.system(size: 12)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { decide(false) } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.dyn(0xFF8F8F, 0xD8404A))
                    .frame(width: 34, height: 34)
                    .background(Theme.hex(0xFF5A5A, 0.1), in: Circle())
                    .overlay(Circle().stroke(Theme.dyn(0xFF7878, 0xD8404A, 0.25, 0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("grp.decline") + Text(" " + name))
            Button { decide(true) } label: {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(Theme.hex(0x032229))
                    .frame(width: 34, height: 34)
                    .background(LinearGradient(colors: [cyan, Theme.hex(0x08A8B8)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                    .shadow(color: Theme.dyn(0x2FF0F3, 0x0097A5, 0.35, 0.22), radius: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("grp.approve") + Text(" " + name))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background {
            if fresh {
                ZStack {
                    LinearGradient(stops: [.init(color: Theme.dyn(0x2FF0F3, 0x00A8B5, 0.14, 0.12), location: 0),
                                           .init(color: Theme.dyn(0x2FF0F3, 0x00A8B5, 0.03, 0.03), location: 0.6),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                    Theme.dyn(0x2FF0F3, 0x00A8B5, flash ? 0.22 : 0.03, flash ? 0.16 : 0.03)
                }
            }
        }
        .overlay(alignment: .leading) {
            if fresh {
                RoundedRectangle(cornerRadius: 1.5).fill(cyan).frame(width: 3).padding(.vertical, 8)
                    .shadow(color: cyan, radius: 5)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.dyn(0x78BED2, 0xD3E1EA, 0.08, 1)).frame(height: 1) }
        .task(id: fresh) { await blink() }
    }

    /// Three soft flashes, 1.1 s each, once per row (website jr-flash); none with Reduce Motion.
    private func blink() async {
        guard fresh, animate, !blinked else { return }
        blinked = true
        for _ in 0..<3 {
            withAnimation(.easeInOut(duration: 0.55)) { flash = true }
            try? await Task.sleep(nanoseconds: 550_000_000)
            withAnimation(.easeInOut(duration: 0.55)) { flash = false }
            try? await Task.sleep(nanoseconds: 550_000_000)
            if Task.isCancelled { break }
        }
        flash = false
    }
}
