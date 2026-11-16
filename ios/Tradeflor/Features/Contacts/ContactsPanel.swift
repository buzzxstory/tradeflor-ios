import SwiftUI

/// Contacts (website ContactsPanel.tsx + AddContact.tsx): "Find by" PIN | Username | Scan QR on top, then the tabs
/// Contacts (n) | Requests (n). A contact opens its chat; requests are accepted or declined here.
struct ContactsPanel: View {
    let onOpen: (ConversationSummary) -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "pin" // pin | username | scan
    @State private var query = ""
    @State private var card: IdentityDetail?
    @State private var findState = "" // "" | searching | notfound | self
    @State private var sendState = "" // "" | busy | sent | failed
    @State private var tab = "contacts"
    @State private var contacts: [ContactEntry] = []
    @State private var incoming: [ContactRequest] = []
    @State private var sent: [SentContactRequest] = []
    @State private var filter = ""
    @State private var blockTarget: (id: String, name: String)?
    @State private var showScanner = false
    @State private var opening = false

    private var token: String { store.session?.token ?? "" }
    private var shownContacts: [ContactEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? contacts : contacts.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.username.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("ct.lead").font(.system(size: 13)).foregroundStyle(Theme.faint)
                    finder
                    HStack(spacing: 7) {
                        FilterChip(title: String(format: NSLocalizedString("ct.tab.contacts", comment: ""), contacts.count), selected: tab == "contacts") { tab = "contacts" }
                        FilterChip(title: String(format: NSLocalizedString("ct.tab.requests", comment: ""), incoming.count), selected: tab == "requests") { tab = "requests" }
                        Spacer()
                    }
                    if tab == "contacts" { contactsList } else { requestsList }
                }
                .padding(16)
            }
            .background(Theme.panelGradient.ignoresSafeArea())
            .navigationTitle(Text(incoming.isEmpty ? NSLocalizedString("ct.title", comment: "")
                                  : String(format: NSLocalizedString("ct.title.waiting", comment: ""), incoming.count)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.header, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
            .overlay { if opening { ProgressView().tint(Theme.accent) } }
            .confirmationDialog(Text(String(format: NSLocalizedString("ci.block.confirm", comment: ""), blockTarget?.name ?? "")),
                                isPresented: Binding(get: { blockTarget != nil }, set: { if !$0 { blockTarget = nil } }), titleVisibility: .visible) {
                Button("ci.block", role: .destructive) {
                    if let b = blockTarget { Task { await block(b.id) } }
                }
            } message: { Text("ci.block.msg") }
            .fullScreenCover(isPresented: $showScanner) {
                QRScannerView { text in
                    showScanner = false
                    Task { await handleScanned(text) }
                }
            }
        }
        .task { await load() }
    }

    // MARK: find

    private var finder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ct.findby").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint)
            Picker("ct.findby", selection: $mode) {
                Text("ct.mode.pin").tag("pin")
                Text("ct.mode.username").tag("username")
                Text("ct.mode.scan").tag("scan")
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { m in
                card = nil
                findState = ""
                if m == "scan" { showScanner = true }
            }
            if mode != "scan" {
                HStack(spacing: 8) {
                    HStack {
                        Image(systemName: mode == "pin" ? "number" : "at").foregroundStyle(Theme.faint)
                        TextField(LocalizedStringKey(mode == "pin" ? "ct.ph.pin" : "ct.ph.username"), text: $query)
                            .keyboardType(mode == "pin" ? .numberPad : .default)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .foregroundStyle(Theme.text)
                            .onSubmit { Task { await find() } }
                    }
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(Theme.inputGradient, in: Capsule())
                    .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
                    Button { Task { await find() } } label: {
                        Text(findState == "searching" ? NSLocalizedString("ct.searching", comment: "") : NSLocalizedString("ct.find", comment: ""))
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 18).frame(height: 44).background(Theme.accent, in: Capsule())
                    }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || findState == "searching")
                }
            }
            if findState == "notfound" { Text("ct.nomatch").font(.system(size: 13)).foregroundStyle(Theme.faint) }
            if findState == "self" { Text("ct.self").font(.system(size: 13)).foregroundStyle(Theme.faint) }
            if let c = card { resultCard(c) }
        }
        .padding(14)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderStrong, lineWidth: 1))
    }

    private func resultCard(_ c: IdentityDetail) -> some View {
        HStack(spacing: 12) {
            Avatar(token: token, userID: c.user_id, avatarID: c.avatar_id, title: c.title, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                Text("@\(c.username) · \(c.pin)").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            Spacer()
            if c.relation == "contact" {
                Button { Task { await open(c.user_id) } } label: { pill(NSLocalizedString("ct.message", comment: "")) }
            } else {
                Button { Task { await connect(c) } } label: {
                    pill(sendState == "busy" ? NSLocalizedString("ct.sending", comment: "")
                         : (sendState == "sent" || c.relation == "requested") ? NSLocalizedString("ct.sent", comment: "")
                         : c.relation == "incoming" ? NSLocalizedString("ct.accept.their", comment: "")
                         : NSLocalizedString("ct.send", comment: ""))
                }
                .disabled(sendState == "busy" || sendState == "sent" || c.relation == "requested")
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func pill(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onAccent).lineLimit(1)
            .padding(.horizontal, 12).frame(height: 32).background(Theme.accent, in: Capsule())
    }

    // MARK: lists

    @ViewBuilder private var contactsList: some View {
        if contacts.count > 6 { SearchPill(placeholder: "ct.search", text: $filter) }
        if contacts.isEmpty {
            Text("ct.none").font(.system(size: 13)).foregroundStyle(Theme.faint).padding(.top, 10)
        } else {
            TFCard {
                ForEach(Array(shownContacts.enumerated()), id: \.element.id) { i, c in
                    HStack(spacing: 12) {
                        Button { Task { await open(c.user_id) } } label: {
                            HStack(spacing: 12) {
                                Avatar(token: token, userID: c.user_id, avatarID: nil, title: c.title, size: 42)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                    Text("@" + c.username).font(.system(size: 12)).foregroundStyle(Theme.faint)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        Menu {
                            Button { Task { await open(c.user_id) } } label: { Label("ct.message", systemImage: "bubble.left") }
                            Button(role: .destructive) { blockTarget = (c.user_id, c.title) } label: { Label("ci.block", systemImage: "hand.raised") }
                        } label: { Image(systemName: "ellipsis").foregroundStyle(Theme.faint).frame(width: 32, height: 32) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    if i < shownContacts.count - 1 { Rectangle().fill(Theme.rowRule).frame(height: 1).padding(.leading, 66) }
                }
            }
        }
    }

    @ViewBuilder private var requestsList: some View {
        if incoming.isEmpty && sent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("ct.req.none").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text("ct.req.none.sub").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            .padding(.top, 10)
        }
        if !incoming.isEmpty {
            TFCard {
                ForEach(incoming) { r in
                    HStack(spacing: 10) {
                        Avatar(token: token, userID: r.from_user_id, avatarID: nil, title: r.from_username, size: 42)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.from_username).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(String(format: NSLocalizedString("ct.wants", comment: ""), r.from_username)).font(.system(size: 12)).foregroundStyle(Theme.faint)
                        }
                        Spacer()
                        Button { Task { await respond(r, accept: false) } } label: {
                            Text("new.decline").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                                .padding(.horizontal, 10).frame(height: 30).overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        Button { Task { await respond(r, accept: true) } } label: { pill(NSLocalizedString("new.accept", comment: "")) }
                            .buttonStyle(.plain)
                    }
                    .padding(12)
                    .contextMenu {
                        Button(role: .destructive) { blockTarget = (r.from_user_id, r.from_username) } label: { Label("ci.block", systemImage: "hand.raised") }
                    }
                }
            }
        }
        if !sent.isEmpty {
            TFSectionLabel(text: NSLocalizedString("ct.sent.list", comment: ""))
            TFCard {
                ForEach(sent) { r in
                    HStack {
                        Text("@" + r.to_username).font(.system(size: 14)).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "clock").foregroundStyle(Theme.faint)
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: actions

    private func load() async {
        async let c = APIClient.shared.ctContacts(token: token)
        async let i = APIClient.shared.incomingRequests(token: token)
        async let s = APIClient.shared.ctSentRequests(token: token)
        contacts = (try? await c) ?? contacts
        incoming = (try? await i) ?? incoming
        sent = (try? await s) ?? sent
    }

    private func find() async {
        let q = query.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@#"))
        guard !q.isEmpty else { return }
        findState = "searching"
        sendState = ""
        card = nil
        do {
            let c = mode == "pin" ? try await APIClient.shared.ctLookup(token: token, pin: q)
                                  : try await APIClient.shared.ctLookup(token: token, username: q)
            if c.relation == "self" { findState = "self" } else { card = c; findState = "" }
        } catch {
            findState = "notfound"
        }
    }

    private func handleScanned(_ text: String) async {
        mode = "pin"
        switch FlashTarget.parse(text) {
        case .some(.user(let code)):
            if let c = try? await APIClient.shared.ctResolveCode(token: token, code: code) { card = c } else { findState = "notfound" }
        case .some(.pin(let p)):
            query = p
            await find()
        case .some(.username(let u)):
            mode = "username"
            query = u
            await find()
        default:
            findState = "notfound"
        }
    }

    private func connect(_ c: IdentityDetail) async {
        sendState = "busy"
        if c.relation == "incoming", let r = incoming.first(where: { $0.from_user_id == c.user_id }) {
            await respond(r, accept: true)
            await open(c.user_id)
            return
        }
        do {
            try await APIClient.shared.ctConnect(token: token, userID: c.user_id)
            sendState = "sent"
            await load()
        } catch {
            sendState = "failed"
        }
    }

    private func respond(_ r: ContactRequest, accept: Bool) async {
        if (try? await APIClient.shared.respond(token: token, requestID: r.id, accept: accept)) != nil {
            incoming.removeAll { $0.id == r.id }
            await load()
        }
    }

    private func block(_ userID: String) async {
        try? await APIClient.shared.block(token: token, userID: userID)
        blockTarget = nil
        await load()
    }

    private func open(_ userID: String) async {
        opening = true
        defer { opening = false }
        if let s = await APIClient.shared.ctOpenChat(token: token, userID: userID) {
            dismiss()
            onOpen(s)
        }
    }
}
