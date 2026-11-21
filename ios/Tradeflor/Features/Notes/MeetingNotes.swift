import SwiftUI

/// The chat card of a call's published notebook (IOS-NOTES-008): "Meeting notes", the title (or "Call notes"/"Video call notes"),
/// the length, the counts, and Open notes. Message kind "meeting_notes", payload in message.signal; it cannot be forwarded.
struct MeetingNotesCardView: View {
    let card: MeetingNotesCard
    let mine: Bool
    let date: Date?
    let onOpen: () -> Void

    private var title: String {
        if let t = card.title, !t.trimmingCharacters(in: .whitespaces).isEmpty { return t }
        return NSLocalizedString(card.video == true ? "notes.card.video" : "notes.card.call", comment: "")
    }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                Label("notes.card.head", systemImage: "note.text").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                Text(verbatim: title).font(.headline).foregroundStyle(Theme.text).lineLimit(2)
                    .multilineTextAlignment(NoteText.isRTL(title) ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: NoteText.isRTL(title) ? .trailing : .leading)
                HStack(spacing: 10) {
                    if card.duration_ms > 0 { Label(NoteRules.meetingDuration(card.duration_ms), systemImage: card.video == true ? "video" : "phone") }
                    if card.tasks > 0 {
                        Label(String(format: NSLocalizedString("notes.progress", comment: ""), card.tasks_done, card.tasks), systemImage: "checklist")
                    }
                    if card.decisions > 0 { Label("\(card.decisions)", systemImage: "checkmark.seal") }
                }
                .font(.caption).foregroundStyle(Theme.muted)
                Button(action: onOpen) {
                    Text("notes.card.open").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 40)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(.plain)
                if let date { Text(date, style: .time).font(.caption2).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .trailing) }
            }
            .padding(12)
            .frame(width: 260)
            .background(Theme.soulCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.soulCardBorder, lineWidth: 1))
            .accessibilityElement(children: .contain)
            if !mine { Spacer(minLength: 40) }
        }
    }
}

/// The call screen's Notebook control (IOS-NOTES-006/007). Opening it never ends, holds or mutes the call: it only asks the
/// server for the call's notebook and shows it in a sheet over the call (video: half height, the picture stays visible).
struct CallNotebookButton<L: View>: View {
    @ObservedObject var calls: CallManager
    @ObservedObject private var config = NotesConfig.shared
    let video: Bool
    @ViewBuilder let label: () -> L
    @State private var open: OpenNote?
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        if config.enabled {
            Button {
                Task { await openNotebook() }
            } label: { label() }
            .disabled(busy || calls.notebookContext == nil)
            .opacity(calls.notebookContext == nil ? 0.4 : 1)
            .accessibilityLabel(Text("notes.notebook"))
            .sheet(item: $open) { o in
                if let ctx = calls.notebookContext ?? lastContext {
                    NoteEditorScreen(token: ctx.token, me: ctx.me, noteID: o.id, initial: o.initial, people: people(ctx.me), isGroup: false,
                                     backToCall: { open = nil })
                        .presentationDetents(video ? [.medium, .large] : [.large])
                        .tfNotebookBackground(video)
                }
            }
            .alert(Text("notes.notebook.failed"), isPresented: $failed) { Button("notes.ok", role: .cancel) {} }
        }
    }

    @State private var lastContext: (token: String, me: String, callID: String)?

    private func people(_ me: String) -> [NotePerson] {
        var p = [NotePerson(id: me, name: NSLocalizedString("chat.you", comment: ""))]
        if let id = calls.peerID, !id.isEmpty { p.append(NotePerson(id: id, name: calls.peerName)) }
        return p
    }

    private func openNotebook() async {
        guard let ctx = calls.notebookContext else { return }
        busy = true
        defer { busy = false }
        lastContext = ctx
        do {
            let st = try await APIClient.shared.openCallNotebook(token: ctx.token, callID: ctx.callID)
            open = OpenNote(id: st.note.id, initial: st)
        } catch {
            failed = true
        }
    }
}

private extension View {
    /// iOS 16.4+: the call's picture behind a half-height notebook still takes taps.
    @ViewBuilder func tfNotebookBackground(_ on: Bool) -> some View {
        if on {
            if #available(iOS 16.4, *) { self.presentationBackgroundInteraction(.enabled(upThrough: .medium)) } else { self }
        } else { self }
    }
}
