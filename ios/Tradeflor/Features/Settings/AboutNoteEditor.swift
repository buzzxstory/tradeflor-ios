import SwiftUI

/// The note editor (WhatsApp's About sheet, in TRADEFLOR's look): the line with its emoji, how long it stays, who sees it,
/// suggestions for a trader's day, and a live preview of the bubble over my own picture.
struct AboutNoteEditor: View {
    let token: String
    let userID: String
    let avatarID: String?
    let name: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var notes = NoteStore.shared
    @State private var text = ""
    @State private var emoji = "🟢"
    @State private var duration: NoteDuration = .day
    @State private var audience: NoteAudience = .contacts
    @State private var showEmoji = false
    @State private var busy = false
    @State private var problem: String?
    @FocusState private var typing: Bool

    static let maxLength = 60
    private static let emojis = ["🟢", "⏳", "📈", "📉", "🧠", "💼", "🤝", "😴", "✈️", "💪", "🌙", "☕️", "🎧", "📚", "🕌", "🏖️",
                                 "🔥", "🚀", "💎", "🎯", "🍽️", "🚗", "🏠", "❤️"]
    private static let suggestions: [(String, String)] = [
        ("🟢", "note.s.available"), ("⏳", "note.s.busy"), ("📈", "note.s.trading"), ("🧠", "note.s.charts"),
        ("💼", "note.s.work"), ("🤝", "note.s.meeting"), ("😴", "note.s.sleeping"), ("✈️", "note.s.traveling"),
        ("💪", "note.s.gym"), ("🌙", "note.s.away"),
    ]

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var preview: AboutNote { AboutNote(text: trimmed, emoji: emoji, audience: audience.rawValue, set_at: nil, expires_at: nil) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field
                    if showEmoji { emojiGrid }
                    chips
                    suggestionsCard
                    previewCard
                    if notes.mine?.isLive() == true { clearButton }
                    if let problem {
                        Text(problem).font(.system(size: 13)).foregroundStyle(Theme.danger).frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .clipped()
        }
        .background(SettingsBackground())
        .onAppear {
            if let n = notes.mine, n.isLive() {
                text = n.text
                emoji = n.emoji.isEmpty ? "🟢" : n.emoji
                audience = NoteAudience(rawValue: n.audience ?? "") ?? .contacts
            }
            typing = true
        }
        .tfColorScheme()
    }

    // MARK: parts

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .background(Theme.dyn(0x0A3440, 0xFFFFFF, 0.9, 1), in: Circle())
                    .overlay(Circle().stroke(Theme.dyn(0x35E6F2, 0x00A8B5, 0.25, 0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("chat.close"))
            Spacer()
            Text("note.title").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
            Spacer()
            Button { Task { await save() } } label: {
                ZStack {
                    if busy { ProgressView().tint(.white) } else {
                        Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: [Theme.hex(0x2FE6E6), Theme.hex(0x0097A5)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: Circle())
                .shadow(color: Theme.hex(0x08D9D9).opacity(0.35), radius: 8, y: 3)
                .opacity(trimmed.isEmpty && emoji.isEmpty ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(busy || (trimmed.isEmpty && emoji.isEmpty))
            .accessibilityLabel(Text("note.save"))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.18)) { showEmoji.toggle() } } label: {
                Text(emoji.isEmpty ? "🙂" : emoji).font(.system(size: 24))
                    .frame(width: 48, height: 48)
                    .background(Theme.dyn(0x08D9D9, 0x00A8B5, 0.12, 0.12), in: Circle())
                    .overlay(Circle().stroke(Theme.dyn(0x35E6F2, 0x00A8B5, showEmoji ? 0.7 : 0.25, 0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("note.emoji"))
            TextField(text: $text, prompt: Text("note.placeholder").foregroundColor(Theme.faint)) { EmptyView() }
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.text)
                .focused($typing)
                .submitLabel(.done)
                .onSubmit { Task { await save() } }
                .onChange(of: text) { t in if t.count > Self.maxLength { text = String(t.prefix(Self.maxLength)) } }
            Text("\(Self.maxLength - text.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(text.count > Self.maxLength - 10 ? Theme.dyn(0xF0B46A, 0xB86E12) : Theme.faint)
        }
        .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 8)
        .background(Theme.dyn(0x062F3A, 0xFFFFFF, 0.9, 1), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Theme.dyn(0x35E6F2, 0x00A8B5, 0.3, 0.35), lineWidth: 1))
    }

    private var emojiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
            ForEach(Self.emojis, id: \.self) { e in
                Button {
                    emoji = e
                    withAnimation(.easeOut(duration: 0.18)) { showEmoji = false }
                } label: {
                    Text(e).font(.system(size: 24)).frame(maxWidth: .infinity, minHeight: 40)
                        .background(e == emoji ? Theme.dyn(0x08D9D9, 0x00A8B5, 0.18, 0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .sCardChrome()
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var chips: some View {
        HStack(spacing: 10) {
            Menu {
                Picker(selection: $duration) {
                    ForEach(NoteDuration.allCases) { d in Text(d.label).tag(d) }
                } label: { EmptyView() }
            } label: { chip(icon: "clock", text: duration.label) }
            Menu {
                Picker(selection: $audience) {
                    ForEach(NoteAudience.allCases) { a in Label { Text(a.label) } icon: { Image(systemName: a.icon) }.tag(a) }
                } label: { EmptyView() }
            } label: { chip(icon: audience.icon, text: audience.label) }
            Spacer(minLength: 0)
        }
    }

    private func chip(icon: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(SetUI.accent)
            Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 14).frame(height: 40)
        .background(Theme.dyn(0x062F3A, 0xFFFFFF, 0.9, 1), in: Capsule())
        .overlay(Capsule().stroke(Theme.dyn(0x35E6F2, 0x00A8B5, 0.3, 0.35), lineWidth: 1))
    }

    private var suggestionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("note.suggestions").font(.system(size: 13, weight: .bold)).foregroundStyle(SetUI.sub).textCase(.uppercase)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(Self.suggestions.enumerated()), id: \.offset) { i, s in
                    Button {
                        emoji = s.0
                        text = NSLocalizedString(s.1, comment: "")
                    } label: {
                        HStack(spacing: 14) {
                            Text(s.0).font(.system(size: 22)).frame(width: 30)
                            Text(LocalizedStringKey(s.1)).font(.system(size: 16)).foregroundStyle(Theme.text)
                            Spacer()
                            if text == NSLocalizedString(s.1, comment: "") {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(SetUI.accent)
                            }
                        }
                        .padding(.horizontal, 16).frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < Self.suggestions.count - 1 {
                        Rectangle().fill(SetUI.edge).frame(height: 1).padding(.leading, 60)
                    }
                }
            }
            .sCardChrome()
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("note.preview").font(.system(size: 13, weight: .bold)).foregroundStyle(SetUI.sub).textCase(.uppercase)
                .padding(.leading, 4)
            VStack(spacing: 6) {
                if !(trimmed.isEmpty && emoji.isEmpty) { NoteBubble(note: preview) }
                Avatar(token: token, userID: userID, avatarID: avatarID, title: name, size: 84)
                    .overlay(Circle().strokeBorder(Theme.dyn(0x08D9D9, 0x00939F, 0.45, 0.5), lineWidth: 2))
                Text(verbatim: name).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    Image(systemName: audience.icon)
                    Text(audience.label)
                    Text("·")
                    Image(systemName: "clock")
                    Text(duration.label)
                }
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(SetUI.sub)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background { SettingsSweep(peak: 0.28, tail: 0.08, share: 0.55).opacity(0.8) }
            .sCardChrome()
            .animation(.easeOut(duration: 0.18), value: trimmed + emoji)
        }
    }

    private var clearButton: some View {
        Button {
            Task { await clear() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                Text("note.clear")
            }
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.danger)
            .frame(maxWidth: .infinity, minHeight: 50)
            .sCardChrome(border: Theme.danger.opacity(0.35))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    // MARK: actions

    private func save() async {
        guard !busy, !(trimmed.isEmpty && emoji.isEmpty) else { return }
        busy = true
        problem = nil
        defer { busy = false }
        do {
            let n = try await APIClient.shared.setNote(token: token, text: trimmed, emoji: emoji, duration: duration, audience: audience)
            notes.set(n)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch APIError.server(let s) where s == 404 || s == 405 {
            problem = NSLocalizedString("note.unavailable", comment: "")
        } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why
        } catch {
            problem = NSLocalizedString("chat.action.failed", comment: "")
        }
    }

    private func clear() async {
        busy = true
        defer { busy = false }
        do {
            try await APIClient.shared.clearNote(token: token)
            notes.set(nil)
            dismiss()
        } catch {
            problem = NSLocalizedString("chat.action.failed", comment: "")
        }
    }
}
