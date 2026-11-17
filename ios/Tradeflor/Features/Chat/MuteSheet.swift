import SwiftUI

/// "Mute notifications for…" (website MuteSheet.tsx): 8 hours, 1 day, 1 week, Custom… (up to one year), Always.
/// Messages still arrive and stay unread; only alerts stop.
struct MuteSheet: View {
    let conversationID: String
    let name: String
    let onDone: () -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var custom = false
    @State private var until = Date().addingTimeInterval(3600 * 24)
    @State private var busy = false
    @State private var failed = false

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("mute.title").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                Text(String(format: NSLocalizedString("mute.sub", comment: ""), name))
                    .font(.system(size: 13)).foregroundStyle(Theme.faint)
                if custom {
                    DatePicker("mute.until", selection: $until, in: Date().addingTimeInterval(60)...Date().addingTimeInterval(366 * 86400))
                        .datePickerStyle(.graphical)
                        .tint(Theme.accent)
                    Text("mute.custom.hint").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    HStack {
                        Button("mute.back") { custom = false }.foregroundStyle(Theme.muted)
                        Spacer()
                        Button { Task { await apply(seconds: Int(until.timeIntervalSinceNow)) } } label: {
                            Text("mute.mute").bold().foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 22).frame(height: 40).background(Theme.accent, in: Capsule())
                        }
                    }
                } else {
                    TFCard {
                        option("mute.8h") { await apply(seconds: 8 * 3600) }
                        line
                        option("mute.1d") { await apply(seconds: 86400) }
                        line
                        option("mute.1w") { await apply(seconds: 7 * 86400) }
                        line
                        Button { custom = true } label: { TFRow(icon: "calendar", title: NSLocalizedString("mute.custom", comment: "")) }
                            .buttonStyle(.plain)
                        line
                        option("mute.always") { await apply(forever: true) }
                    }
                }
                if failed { Text("ci.save.failed").font(.system(size: 12)).foregroundStyle(Theme.danger) }
                Spacer()
            }
            .disabled(busy) // one choice at a time: a second tap while it saves is ignored
            .padding(16)
            .background(Theme.panelGradient.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("mute.cancel") { dismiss() } } }
            .overlay { if busy { ProgressView().tint(Theme.accent) } }
        }
        .presentationDetents([.medium, .large])
    }

    private var line: some View { Rectangle().fill(Theme.rowRule).frame(height: 1).padding(.leading, 50) }

    private func option(_ key: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            TFRow(icon: "bell.slash", title: NSLocalizedString(key, comment: ""), showChevron: false)
        }
        .buttonStyle(.plain)
    }

    private func apply(seconds: Int = 0, forever: Bool = false) async {
        guard !busy else { return }
        busy = true
        failed = false
        defer { busy = false }
        do {
            try await APIClient.shared.setPrefs(token: token, conversationID: conversationID,
                                                muteSeconds: max(0, seconds), muteForever: forever)
            onDone()
            dismiss()
        } catch {
            failed = true
        }
    }

    /// "Muted until Sat 14 Nov, 18:30" / "Muted" (forever is stored as a far-future time).
    static func label(mutedUntil: Int64?) -> String? {
        guard let u = mutedUntil, u > Int64(Date().timeIntervalSince1970) else { return nil }
        if u > 4_000_000_000 { return NSLocalizedString("mute.muted", comment: "") }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMMHHmm")
        return String(format: NSLocalizedString("mute.until.label", comment: ""), f.string(from: Date(timeIntervalSince1970: Double(u))))
    }
}
