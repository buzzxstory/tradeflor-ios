import SwiftUI
import Combine

/// Shared Notes feature switch (GET /notes/config): read once per sign-in; every entry point hides while it is off.
@MainActor
final class NotesConfig: ObservableObject {
    static let shared = NotesConfig()
    @Published private(set) var enabled = false
    private var askedFor = ""

    func load(token: String) {
        guard !token.isEmpty, askedFor != token else { return }
        askedFor = token
        Task {
            let on = await APIClient.shared.notesEnabled(token: token)
            if askedFor == token { enabled = on }
        }
    }

    nonisolated func forget() {
        Task { @MainActor in
            NotesConfig.shared.enabled = false
            NotesConfig.shared.askedFor = ""
        }
    }
}

/// A person who can be named in a note (the chat's people).
struct NotePerson: Identifiable, Hashable {
    let id: String
    let name: String
}

/// What opens the editor.
struct OpenNote: Identifiable {
    let id: String
    var initial: NoteState?
}

/// The notes of a chat (IOS-NOTES-001/002): list, search, filters, New note, empty state. Chat ⋮ → Shared notes.
struct NotesHub: View {
    let token: String
    let me: String
    let conversationID: String
    let isGroup: Bool
    /// owner/admin in a group (may choose "admins" when creating)
    let isAdmin: Bool
    let people: [NotePerson]
    @Environment(\.dismiss) private var dismiss

    @State private var notes: [SharedNote] = []
    @State private var filter = "all"
    @State private var query = ""
    @State private var loading = true
    @State private var offline = false
    @State private var unavailable = false
    @State private var banner: String?
    @State private var creating = false
    @State private var newTitle = ""
    @State private var open: OpenNote?
    @State private var policyFor: SharedNote?
    @State private var deleting: SharedNote?
    @State private var reloadTask: Task<Void, Never>?

    /// the last list read per chat (shown offline)
    @MainActor static var cache: [String: [SharedNote]] = [:]

    private static let filters: [(String, String)] = [("all", "notes.f.all"), ("pinned", "notes.f.pinned"), ("tasks", "notes.f.tasks"),
                                                       ("meetings", "notes.f.meetings")]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("notes.filter", selection: $filter) {
                    ForEach(Self.filters, id: \.0) { f in Text(LocalizedStringKey(f.1)).tag(f.0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)
                if offline {
                    Label("notes.offline", systemImage: "wifi.slash").font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.gold).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                if let banner {
                    Text(banner).font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal, 16).padding(.vertical, 4)
                        .onTapGesture { self.banner = nil }
                }
                content
            }
            .background(Theme.soul.ignoresSafeArea())
            .navigationTitle(Text("notes.title"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("notes.search"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel(Text("notes.close"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { newTitle = ""; creating = true } label: { Image(systemName: "square.and.pencil").frame(width: 44, height: 44) }
                        .accessibilityLabel(Text("notes.new"))
                        .disabled(unavailable)
                }
            }
            .toolbarBackground(Theme.soul, for: .navigationBar)
        }
        .tint(Theme.accent)
        .task { await reload() }
        .onChange(of: filter) { _ in Task { await reload() } }
        .onChange(of: query) { _ in scheduleReload() }
        .onReceive(LiveConnection.shared.notesChanged.filter { $0 == conversationID }.receive(on: RunLoop.main)) { _ in scheduleReload() }
        .alert(Text("notes.new"), isPresented: $creating) {
            TextField(NSLocalizedString("notes.title.placeholder", comment: ""), text: $newTitle)
            Button("notes.create") { Task { await create() } }
            Button("notes.cancel", role: .cancel) {}
        }
        .confirmationDialog(Text("notes.delete.q"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("notes.delete", role: .destructive) { if let n = deleting { Task { await delete(n) } } }
        } message: { Text("notes.delete.msg") }
        .fullScreenCover(item: $open, onDismiss: { Task { await reload() } }) { o in
            NoteEditorScreen(token: token, me: me, noteID: o.id, initial: o.initial, people: people, isGroup: isGroup)
        }
        .sheet(item: $policyFor) { n in
            NotePolicySheet(token: token, note: n, people: people, isAdmin: isAdmin) { updated in
                if let i = notes.firstIndex(where: { $0.id == updated.id }) { notes[i] = updated }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if unavailable {
            empty("notes.unavailable", "lock")
        } else if loading && notes.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if notes.isEmpty {
            VStack(spacing: 14) {
                empty(query.isEmpty ? "notes.empty" : "notes.nomatch", "note.text")
                if query.isEmpty {
                    Button { newTitle = ""; creating = true } label: {
                        Label("notes.new", systemImage: "plus").font(.body.weight(.semibold)).padding(.horizontal, 18).frame(minHeight: 44)
                            .background(Theme.accent, in: Capsule()).foregroundStyle(Theme.onAccent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(notes) { n in
                        Button { open = OpenNote(id: n.id) } label: { NoteCard(note: n, people: people, me: me) }
                            .buttonStyle(.plain)
                            .contextMenu { menu(n) }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .refreshable { await reload() }
        }
    }

    private func empty(_ key: String, _ icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(Theme.accent)
            Text(LocalizedStringKey(key)).font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .padding(30)
    }

    @ViewBuilder private func menu(_ n: SharedNote) -> some View {
        if n.can_edit {
            Button { Task { await pin(n) } } label: {
                Label(n.isPinned ? "notes.unpin" : "notes.pin", systemImage: n.isPinned ? "pin.slash" : "pin")
            }
        }
        if isGroup && n.can_manage {
            Button { policyFor = n } label: { Label("notes.policy", systemImage: "person.2.badge.gearshape") }
        }
        if n.can_manage || n.creator_id == me {
            Button(role: .destructive) { deleting = n } label: { Label("notes.delete", systemImage: "trash") }
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { await reload() }
        }
    }

    private func reload() async {
        let q = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let key = conversationID + "|" + filter + "|" + q
        if notes.isEmpty, let c = Self.cache[key] { notes = c }
        do {
            let list = try await APIClient.shared.listNotes(token: token, conversationID: conversationID, filter: filter == "all" ? "" : filter, q: q)
            Self.cache[key] = list
            notes = list
            offline = false
            unavailable = false
        } catch let e as NoteHTTPError {
            switch e.status {
            case 0, 429, 500...: offline = e.status == 0
            case 404: unavailable = true
            case 423: banner = NSLocalizedString("notes.locked", comment: "")
            default: banner = NSLocalizedString("notes.error", comment: "")
            }
        } catch {}
        loading = false
    }

    private func create() async {
        let title = String(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        do {
            let st = try await APIClient.shared.createNote(token: token, conversationID: conversationID, title: title)
            notes.insert(st.note, at: 0)
            open = OpenNote(id: st.note.id, initial: st)
        } catch let e as NoteHTTPError {
            banner = NSLocalizedString(e.status == 0 ? "notes.offline" : "notes.error", comment: "")
        } catch {}
    }

    private func pin(_ n: SharedNote) async {
        if let u = try? await APIClient.shared.pinNote(token: token, noteID: n.id, pinned: !n.isPinned),
           let i = notes.firstIndex(where: { $0.id == n.id }) {
            notes[i] = u
            await reload()
        }
    }

    private func delete(_ n: SharedNote) async {
        do {
            try await APIClient.shared.deleteNote(token: token, noteID: n.id)
            notes.removeAll { $0.id == n.id }
        } catch {
            banner = NSLocalizedString("notes.error", comment: "")
        }
    }
}

/// One note in the list: title, badges, 2-line preview, "time · name", progress.
struct NoteCard: View {
    let note: SharedNote
    let people: [NotePerson]
    let me: String

    private var who: String {
        let id = note.updated_by ?? note.creator_id
        if id == me { return NSLocalizedString("chat.you", comment: "") }
        return people.first { $0.id == id }?.name ?? ""
    }

    private var progress: (done: Int, total: Int)? {
        if note.tasks > 0 { return (note.tasks_done, note.tasks) }
        if note.checks > 0 { return (note.checks_done, note.checks) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if note.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Theme.accent) }
                Text(verbatim: note.title.isEmpty ? NSLocalizedString(note.isMeeting ? "notes.meeting.untitled" : "notes.untitled", comment: "") : note.title)
                    .font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                if note.isMeeting { badge("notes.badge.meeting", "phone") }
                if !note.can_edit { badge("notes.badge.readonly", "eye") }
            }
            if let p = note.preview, !p.isEmpty {
                Text(verbatim: p).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(2).multilineTextAlignment(.leading)
            }
            HStack(spacing: 4) {
                Text(Date(timeIntervalSince1970: Double(note.updated_at) / 1000), style: .relative)
                if !who.isEmpty { Text(verbatim: "· " + who) }
            }
            .font(.caption).foregroundStyle(Theme.faint)
            if let p = progress {
                HStack(spacing: 8) {
                    ProgressView(value: Double(p.done), total: Double(max(1, p.total))).tint(Theme.accent)
                    Text(verbatim: String(format: NSLocalizedString("notes.progress", comment: ""), p.done, p.total))
                        .font(.caption2).foregroundStyle(Theme.faint)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soulCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.soulCardBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func badge(_ key: String, _ icon: String) -> some View {
        Label(LocalizedStringKey(key), systemImage: icon).font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
            .padding(.horizontal, 7).padding(.vertical, 3).background(Theme.active, in: Capsule())
    }
}

/// "Who can edit" for a group note (owner/admin or creator): everyone, admins, or chosen people.
struct NotePolicySheet: View {
    let token: String
    let note: SharedNote
    let people: [NotePerson]
    let isAdmin: Bool
    let onSaved: (SharedNote) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var policy = "everyone"
    @State private var editors = Set<String>()
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("notes.policy", selection: $policy) {
                    Text("notes.policy.everyone").tag("everyone")
                    if isAdmin { Text("notes.policy.admins").tag("admins") }
                    Text("notes.policy.selected").tag("selected")
                }
                .pickerStyle(.inline)
                if policy == "selected" {
                    Section {
                        ForEach(people) { p in
                            Button {
                                if editors.contains(p.id) { editors.remove(p.id) } else { editors.insert(p.id) }
                            } label: {
                                HStack {
                                    Text(verbatim: p.name).foregroundStyle(Theme.text)
                                    Spacer()
                                    if editors.contains(p.id) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                }
                                .frame(minHeight: 44)
                            }
                        }
                    }
                }
                if let error { Text(verbatim: error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle(Text("notes.policy"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("notes.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("notes.save") { Task { await save() } }.disabled(saving) }
            }
        }
        .onAppear {
            policy = note.edit_policy
            editors = Set(note.editors ?? [])
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let n = try await APIClient.shared.setNotePolicy(token: token, noteID: note.id, policy: policy, editors: policy == "selected" ? Array(editors) : [])
            onSaved(n)
            dismiss()
        } catch let e as NoteHTTPError {
            error = NSLocalizedString(e.status == 403 ? "notes.policy.denied" : "notes.error", comment: "")
        } catch {}
    }
}
