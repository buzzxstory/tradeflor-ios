import SwiftUI

/// Start a chat: find someone by TRADEFLOR PIN or @username. A contact opens straight away; anyone else gets a
/// contact request first (same rules as the website). Incoming requests are listed here to accept or decline.
struct NewChatView: View {
    let onOpen: (ConversationSummary) -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var card: IdentityCard?
    @State private var searching = false
    @State private var notFound = false
    @State private var working = false
    @State private var info: String?
    @State private var requests: [ContactRequest] = []

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("new.hint")) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("new.placeholder", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { Task { await search() } }
                            .accessibilityIdentifier("new.query")
                        if searching { ProgressView() }
                    }
                }
                .listRowBackground(Theme.surface)

                if let card {
                    Section {
                        HStack(spacing: 12) {
                            Avatar(token: token, userID: card.user_id, avatarID: card.avatar_id.isEmpty ? nil : card.avatar_id,
                                   title: card.title)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.title).font(.headline).foregroundStyle(.white)
                                Text("@\(card.username) · \(card.pin)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        action(for: card)
                    }
                    .listRowBackground(Theme.surface)
                } else if notFound {
                    Section { Text("new.notfound").foregroundStyle(.secondary) }.listRowBackground(Theme.surface)
                }
                if let info {
                    Section { Text(info).foregroundStyle(Theme.accent) }.listRowBackground(Theme.surface)
                }

                if !requests.isEmpty {
                    Section(header: Text("new.requests")) {
                        ForEach(requests) { r in
                            HStack {
                                Text("@\(r.from_username)").foregroundStyle(.white)
                                Spacer()
                                Button { Task { await respond(r, accept: false) } } label: {
                                    Image(systemName: "xmark").frame(width: 34, height: 34).background(Color.white.opacity(0.12), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("new.decline"))
                                Button { Task { await respond(r, accept: true) } } label: {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.onAccent)
                                        .frame(width: 34, height: 34).background(Theme.accent, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("new.accept"))
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("new.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
            }
            .overlay { if working { ProgressView() } }
        }
        .task { requests = (try? await APIClient.shared.incomingRequests(token: token)) ?? [] }
    }

    @ViewBuilder private func action(for c: IdentityCard) -> some View {
        switch c.relation ?? "none" {
        case "self":
            Text("new.self").foregroundStyle(.secondary)
        case "contact":
            Button { Task { await open(c) } } label: { Label("new.message", systemImage: "bubble.left.fill") }
        case "requested":
            Label("new.requested", systemImage: "clock").foregroundStyle(.secondary)
        case "incoming":
            Button { Task { await acceptFrom(c) } } label: { Label("new.accept.request", systemImage: "person.badge.plus") }
        default:
            Button { Task { await connect(c) } } label: { Label("new.add", systemImage: "person.badge.plus") }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        notFound = false
        info = nil
        card = nil
        defer { searching = false }
        do { card = try await APIClient.shared.lookup(token: token, query: q) } catch { notFound = true }
    }

    private func open(_ c: IdentityCard) async {
        working = true
        defer { working = false }
        guard let id = try? await APIClient.shared.directConversation(token: token, with: c.user_id) else {
            info = NSLocalizedString("chat.action.failed", comment: "")
            return
        }
        let list = (try? await APIClient.shared.conversations(token: token)) ?? []
        if let s = list.first(where: { $0.conversation_id == id }) {
            dismiss()
            onOpen(s)
        } else {
            dismiss()
        }
    }

    private func connect(_ c: IdentityCard) async {
        working = true
        defer { working = false }
        do {
            try await APIClient.shared.connect(token: token, userID: c.user_id)
            info = NSLocalizedString("new.sent", comment: "")
            card = try? await APIClient.shared.lookup(token: token, query: c.username)
        } catch {
            info = NSLocalizedString("chat.action.failed", comment: "")
        }
    }

    private func acceptFrom(_ c: IdentityCard) async {
        if let r = requests.first(where: { $0.from_user_id == c.user_id }) {
            await respond(r, accept: true)
            card = try? await APIClient.shared.lookup(token: token, query: c.username)
        }
    }

    private func respond(_ r: ContactRequest, accept: Bool) async {
        working = true
        defer { working = false }
        if (try? await APIClient.shared.respond(token: token, requestID: r.id, accept: accept)) != nil {
            requests.removeAll { $0.id == r.id }
        }
    }
}
