import SwiftUI

/// Contacts V3 (website ContactsPanel.tsx + 78-contacts-v3.css, the owner's mockup of 2026-11-17): Find -> Add -> Chat.
///   - the TRADEFLOR mark, "Contacts", "Find, add, and chat with traders", a Scan QR button;
///   - one search field: a name filters MY contacts as you type; a PIN (digits) or an @username is looked up exactly on the
///     server (debounced 400 ms, an older answer never replaces a newer one, one neutral "not found");
///   - shortcuts Scan QR · Add by PIN · Add by Username (the last two only focus the same field);
///   - a found person: picture, name, @username, PIN and ONE button: "Add & Chat" (saves them in my contacts and opens the
///     chat in one server call), "Message" when already in my contacts, "This is you" for me;
///   - My Contacts: compact rows (picture, name, @username, About); a tap opens the chat; a voice-call button; a ⋯ menu
///     (Message, Remove from contacts for people I only saved, Block);
///   - Requests (the older request flow) only when there are some.
/// The list follows the server's "contact" event (a contact saved or removed on any of my devices).
struct ContactsPanel: View {
    let onOpen: (ConversationSummary) -> Void
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var calls = CallManager.shared
    @ObservedObject private var profiles = ContactProfiles.shared

    private enum Found { case searching, nomatch, error(String), found(IdentityDetail) }
    private struct Problem { let text: String; var retry: (() -> Void)? = nil }
    private enum ConfirmKind { case block, remove }
    private struct Confirm { let kind: ConfirmKind; let userID: String; let name: String }

    @State private var query = ""
    @State private var hint = "" // "" | pin | username
    @State private var found: Found?
    @State private var scanned: IdentityDetail? // a public identity read from a QR (its code is not typed in the field)
    @State private var seq = 0
    @State private var lookupTask: Task<Void, Never>?
    @State private var adding = "" // "" | adding | opening
    @State private var problem: Problem?
    @State private var contacts: [ContactEntry] = []
    @State private var incoming: [ContactRequest] = []
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var confirm: Confirm?
    @State private var showScanner = false
    /// Chats opened from here stay above Contacts: Back from the chat returns to Contacts (search and scroll kept),
    /// Back from Contacts goes where it was opened from (web ea10bd9).
    @State private var chatPath: [ConversationSummary] = []
    @State private var scanTarget: FlashTarget?
    @State private var opening = false
    /// Requests being answered / a block or remove on its way: their buttons wait (a double tap sent them twice).
    @State private var answering: Set<String> = []
    @State private var confirming = false
    @FocusState private var fieldFocused: Bool

    init(onOpen: @escaping (ConversationSummary) -> Void) {
        self.onOpen = onOpen
    }

    private var token: String { store.session?.token ?? "" }
    private var parsed: ContactQuery? { ContactQuery.parse(query) }

    private func nameOf(_ c: ContactEntry) -> String {
        if let a = c.alias, !a.isEmpty { return a }
        if let p = profiles.profile(c.user_id), !p.display_name.isEmpty { return p.display_name }
        return c.username
    }

    private var shown: [ContactEntry] {
        let list = contacts.sorted { nameOf($0).localizedCaseInsensitiveCompare(nameOf($1)) == .orderedAscending }
        guard let p = parsed else { return list }
        // the name, nickname or @username; Arabic letter forms, tashkeel, accents and case do not matter
        let needle = ListSearch.needle(p.value)
        return list.filter { ListSearch.matches(needle, nameOf($0), $0.username, $0.alias ?? "") }
    }

    private var card: IdentityDetail? {
        if let scanned { return scanned }
        if case .found(let c)? = found { return c }
        return nil
    }

    var body: some View {
        NavigationStack(path: $chatPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    searchField
                    if query.isEmpty { scanRow }
                    foundSection
                    if let problem { problemLine(problem) }
                    if !incoming.isEmpty && query.isEmpty { requestsSection }
                    contactsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(CV3.background)
            .toolbar(.hidden, for: .navigationBar)
            .overlay { if opening { ProgressView().tint(Theme.accent) } }
            .navigationDestination(for: ConversationSummary.self) { c in ChatView(chat: c) }
            .navigationDestination(isPresented: Binding(get: { scanTarget != nil }, set: { if !$0 { scanTarget = nil } })) {
                if let t = scanTarget {
                    // Mutual Connect, an event or a group invitation keep their own flows (FlashConnectView.swift)
                    ScanResultView(target: t, onOpen: { c in
                        scanTarget = nil
                        openHere(c)
                    }, onDone: { scanTarget = nil })
                }
            }
            .confirmationDialog(Text(confirmTitle), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible) {
                if let c = confirm {
                    Button(LocalizedStringKey(c.kind == .block ? "ci.block" : "group.remove"), role: .destructive) {
                        Task { await runConfirm(c) }
                    }
                }
            } message: {
                if let c = confirm {
                    Text(c.kind == .block ? String(format: NSLocalizedString("cv4.block.msg", comment: ""), c.name)
                                          : NSLocalizedString("cv3.remove.msg", comment: ""))
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                ScanConnectScreen(initial: .scan, onOpen: { c in
                    showScanner = false
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000) // after the cover has gone
                        openHere(c)
                    }
                }) { text in
                    showScanner = false
                    Task { await handleScanned(text) }
                }
                .environmentObject(store)
                .environmentObject(live)
            }
        }
        .task { await load() }
        .onReceive(live.contactsChanged) { _ in Task { await load() } }
        .onChange(of: query) { _ in queryChanged() }
        .onDisappear { lookupTask?.cancel() }
    }

    // MARK: header, field, tiles

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            roundButton("chevron.backward", ghost: true, label: "chat.back") { dismiss() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image("BrandFlower").resizable().scaledToFit().frame(width: 26, height: 26)
                    Text(verbatim: "TRADEFLOR").font(.system(size: 14, weight: .bold)).tracking(2.5).foregroundStyle(CV3.title)
                }
                .padding(.bottom, 6)
                .accessibilityHidden(true)
                Text("ct.title").font(.system(size: 28, weight: .heavy)).foregroundStyle(CV3.title)
                    .accessibilityAddTraits(.isHeader)
                Text("cv3.subtitle").font(.system(size: 15)).foregroundStyle(CV3.sub).multilineTextAlignment(.center).padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            roundButton("qrcode.viewfinder", ghost: false, label: "fc.scan") { ScanTiming.tapped(); showScanner = true }
        }
    }

    private func roundButton(_ icon: String, ghost: Bool, label: LocalizedStringKey, size: CGFloat = 44,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(ghost ? CV3.title : CV3.cyan)
                .frame(width: size, height: size)
                .background(CV3.round, in: Circle())
                .overlay(Circle().stroke(ghost ? CV3.ghostBorder : CV3.roundBorder, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private var placeholder: LocalizedStringKey {
        hint == "pin" ? "cv3.ph.pin" : hint == "username" ? "cv3.ph.username" : "cv3.search.ph"
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(CV3.sub)
            TextField("", text: $query, prompt: Text(placeholder).foregroundColor(CV3.muted))
                .font(.system(size: 16.5))
                .foregroundStyle(CV3.title)
                .keyboardType(hint == "pin" ? .numberPad : .default)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($fieldFocused)
                .accessibilityLabel(Text("cv3.search.ph"))
                .accessibilityIdentifier("contacts.search")
            if !query.isEmpty {
                Button {
                    query = ""
                    hint = ""
                    scanned = nil
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(CV3.sub)
                        .frame(width: 30, height: 30).background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("cv3.clear"))
            }
        }
        .padding(.leading, 18).padding(.trailing, 12)
        .frame(height: 54)
        .background(CV3.field, in: Capsule())
        .overlay(Capsule().stroke(fieldFocused ? CV3.cyan : CV3.fieldBorder, lineWidth: 1))
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            tile("qrcode.viewfinder", "fc.scan", "cv3.tile.scan.sub") { ScanTiming.tapped(); showScanner = true }
            tile("person.badge.plus", "cv3.tile.pin", "cv3.tile.pin.sub") { focusFor("pin") }
            tile("at", "cv3.tile.username", "cv3.tile.username.sub") { focusFor("username") }
        }
    }

    /// One "Scan QR" row under the field (web ea10bd9: the PIN / Username tiles are gone, the one field does both).
    private var scanRow: some View {
        Button { ScanTiming.tapped(); showScanner = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder").font(.system(size: 20, weight: .semibold)).foregroundStyle(CV3.cyan)
                    .frame(width: 40, height: 40).background(CV3.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("fc.scan").font(.system(size: 15.5, weight: .semibold)).foregroundStyle(CV3.title)
                    Text("cv3.tile.scan.sub").font(.system(size: 12.5)).foregroundStyle(CV3.muted)
                }
                Spacer()
                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(CV3.muted)
            }
            .padding(.horizontal, 12).frame(minHeight: 60)
            .background(CV3.tile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(CV3.tileBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("contacts.scan")
    }

    /// The chat opens inside Contacts (Back = Contacts); the chat list is refreshed for when Contacts closes.
    private func openHere(_ c: ConversationSummary) {
        if chatPath.last?.conversation_id != c.conversation_id { chatPath.append(c) }
    }

    private func tile(_ icon: String, _ title: LocalizedStringKey, _ sub: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 26)).foregroundStyle(CV3.cyan).padding(.bottom, 4)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(CV3.title)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
                Text(sub).font(.system(size: 12.5)).foregroundStyle(CV3.muted).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 6).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(CV3.tile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(CV3.tileBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func focusFor(_ h: String) {
        hint = h
        scanned = nil
        query = h == "username" ? "@" : ""
        fieldFocused = true
    }

    // MARK: the person found

    @ViewBuilder private var foundSection: some View {
        if let c = card {
            foundCard(c)
        } else if let f = found {
            switch f {
            case .searching:
                Text("ct.searching").font(.system(size: 14.5)).foregroundStyle(CV3.muted)
            case .nomatch where hideNoMatch:
                // a plain name ("john") is also tried as a username; when it finds no one but my own contacts match, the
                // "no one found" line under the field contradicted the list below it
                EmptyView()
            case .nomatch:
                Text(String(format: NSLocalizedString("cv3.nomatch", comment: ""), query.trimmingCharacters(in: .whitespaces)))
                    .font(.system(size: 14.5)).foregroundStyle(CV3.muted)
            case .error(let text):
                problemLine(Problem(text: text, retry: { queryChanged() }))
            case .found:
                EmptyView()
            }
        }
    }

    /// A plain word (no "@", not a PIN) that the server did not know as a username, while my own contacts match it.
    private var hideNoMatch: Bool {
        guard case .username? = parsed else { return false }
        return !query.trimmingCharacters(in: .whitespaces).hasPrefix("@") && !shown.isEmpty
    }

    private func isSaved(_ c: IdentityDetail) -> Bool {
        c.relation == "contact" || c.saved == true || contacts.contains { $0.user_id == c.user_id }
    }

    private func foundCard(_ c: IdentityDetail) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Avatar(token: token, userID: c.user_id, avatarID: c.avatar_id, title: c.title, size: 64)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(CV3.title).lineLimit(1)
                    Text("@" + c.username).font(.system(size: 14.5)).foregroundStyle(CV3.small).lineLimit(1)
                    if !c.pin.isEmpty {
                        Text(String(format: NSLocalizedString("cv3.pin", comment: ""), c.pin))
                            .font(.system(size: 14.5, weight: .semibold)).foregroundStyle(CV3.cyan).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if c.relation == "self" {
                Text("cv3.you").font(.system(size: 14.5)).foregroundStyle(CV3.muted).frame(maxWidth: .infinity, alignment: .leading)
            } else if isSaved(c) {
                Button { Task { await open(c.user_id) } } label: {
                    CV3.primaryLabel(NSLocalizedString("ct.message", comment: ""), icon: "bubble.left", wide: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("contacts.message")
            } else {
                Button { Task { await addAndChat(c) } } label: {
                    CV3.primaryLabel(NSLocalizedString(adding == "adding" ? "cv3.adding" : adding == "opening" ? "cv3.opening" : "cv3.add",
                                                       comment: ""), wide: true)
                        .opacity(adding.isEmpty ? 1 : 0.7)
                }
                .buttonStyle(.plain)
                .disabled(!adding.isEmpty)
                .accessibilityIdentifier("contacts.add")
            }
        }
        .padding(14)
        .background(CV3.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(CV3.cardBorder, lineWidth: 1))
    }

    private func problemLine(_ p: Problem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(p.text).font(.system(size: 14.5)).foregroundStyle(CV3.error)
            if let retry = p.retry {
                Button(action: retry) {
                    Text("chat.retry").font(.system(size: 14.5, weight: .semibold)).underline().foregroundStyle(CV3.cyan)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: requests and my contacts

    private func sectionTitle(_ title: LocalizedStringKey, count: Int, hot: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 21, weight: .bold)).foregroundStyle(CV3.title)
            if hot {
                Text("\(count)").font(.system(size: 12.5, weight: .heavy)).foregroundStyle(CV3.onCyan)
                    .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22).background(CV3.cyan, in: Capsule())
            } else {
                Text("\(count)").font(.system(size: 17, weight: .medium)).foregroundStyle(CV3.muted)
            }
        }
        .padding(.horizontal, 2).padding(.top, 4)
    }

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("cv3.requests", count: incoming.count, hot: true).padding(.bottom, 8)
            ForEach(Array(incoming.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Rectangle().fill(CV3.rule).frame(height: 1) }
                HStack(spacing: 10) {
                    HStack(spacing: 14) {
                        let rp = profiles.profile(r.from_user_id)
                        let rname = (rp?.display_name.isEmpty == false ? rp?.display_name : nil) ?? r.from_username
                        Avatar(token: token, userID: r.from_user_id, avatarID: rp?.avatar_id.isEmpty == false ? rp?.avatar_id : nil, title: rname, size: 52)
                            .task { await profiles.load(token: token, userID: r.from_user_id) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rname).font(.system(size: 17, weight: .semibold)).foregroundStyle(CV3.title).lineLimit(1)
                            Text(String(format: NSLocalizedString("ct.wants", comment: ""), r.from_username))
                                .font(.system(size: 14)).foregroundStyle(CV3.small).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    Button { Task { await respond(r, accept: true) } } label: {
                        Label("new.accept", systemImage: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(CV3.onCyan)
                            .padding(.horizontal, 12).frame(height: 34).background(CV3.cyan, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(answering.contains(r.id))
                    Button { Task { await respond(r, accept: false) } } label: {
                        Text("new.decline").font(.system(size: 14, weight: .semibold)).foregroundStyle(CV3.title)
                            .padding(.horizontal, 12).frame(height: 34).overlay(Capsule().stroke(CV3.ghostBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(answering.contains(r.id))
                }
                .padding(.vertical, 10)
                .contextMenu {
                    Button(role: .destructive) { confirm = Confirm(kind: .block, userID: r.from_user_id, name: r.from_username) } label: { Label("ci.block", systemImage: "hand.raised") }
                }
            }
        }
    }

    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("cv3.mycontacts", count: contacts.count, hot: false).padding(.bottom, 8)
            let list = shown
            if loadFailed && contacts.isEmpty {
                problemLine(Problem(text: NSLocalizedString("cv3.err.load", comment: ""), retry: { Task { await load() } }))
            } else if !loaded && list.isEmpty {
                ProgressView().tint(CV3.cyan).frame(maxWidth: .infinity).padding(.vertical, 12)
            } else if loaded && list.isEmpty {
                Text(LocalizedStringKey(parsed == nil ? "cv3.none" : "cv3.nomatch.local")).font(.system(size: 14.5)).foregroundStyle(CV3.muted)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Rectangle().fill(CV3.rule).frame(height: 1) }
                        contactRow(c)
                    }
                }
                .accessibilityIdentifier("contacts.list")
            }
        }
    }

    private func contactRow(_ c: ContactEntry) -> some View {
        let name = nameOf(c)
        let p = profiles.profile(c.user_id)
        let avatarID = p.flatMap { $0.avatar_id.isEmpty ? nil : $0.avatar_id }
        return HStack(spacing: 10) {
            Button { Task { await open(c.user_id) } } label: {
                HStack(spacing: 14) {
                    Avatar(token: token, userID: c.user_id, avatarID: avatarID, title: name, size: 52)
                        .id(avatarID ?? "") // the picture arrives with the profile
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(CV3.title).lineLimit(1)
                        Text("@" + c.username).font(.system(size: 14.5)).foregroundStyle(CV3.small).lineLimit(1)
                        if let bio = p?.bio.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
                            Text(bio).font(.system(size: 14.5)).foregroundStyle(CV3.about).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if calls.enabled {
                roundButton("phone", ghost: false, label: "call.voice") { Task { await call(c) } }
            }
            Menu {
                Button { Task { await open(c.user_id) } } label: { Label("ct.message", systemImage: "bubble.left") }
                if c.mutual == false {
                    Button { confirm = Confirm(kind: .remove, userID: c.user_id, name: name) } label: { Label("cv3.remove", systemImage: "person.badge.minus") }
                }
                Button(role: .destructive) { confirm = Confirm(kind: .block, userID: c.user_id, name: name) } label: { Label("ci.block", systemImage: "nosign") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(CV3.title)
                    .rotationEffect(.degrees(90))
                    .frame(width: 44, height: 44)
                    .background(CV3.round, in: Circle())
                    .overlay(Circle().stroke(CV3.ghostBorder, lineWidth: 1))
                    .contentShape(Circle())
            }
            .accessibilityLabel(Text("chat.more"))
        }
        .padding(.vertical, 10)
        .task { await profiles.load(token: token, userID: c.user_id) }
    }

    private var confirmTitle: String {
        guard let c = confirm else { return "" }
        return String(format: NSLocalizedString(c.kind == .block ? "ci.block.confirm" : "cv3.remove.confirm", comment: ""), c.name)
    }

    // MARK: actions

    private func load() async {
        async let c = APIClient.shared.ctContacts(token: token)
        async let i = APIClient.shared.incomingRequests(token: token)
        if let list = try? await c {
            contacts = list
            loadFailed = false
        } else {
            loadFailed = true // said with a retry; it showed "no contacts yet" before
        }
        incoming = (try? await i) ?? incoming
        loaded = true
    }

    /// A PIN or an @username is looked up on the server (debounced 400 ms; an older answer never replaces a newer one).
    private func queryChanged() {
        if hint == "pin" {
            let digits = String(query.filter(\.isNumber).prefix(12))
            if digits != query { query = digits; return } // onChange runs again with the cleaned text
        }
        problem = nil
        if !query.isEmpty { scanned = nil }
        lookupTask?.cancel()
        seq += 1
        let my = seq
        guard let p = parsed, !p.isName else {
            found = nil
            return
        }
        found = .searching
        let tok = token
        lookupTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, my == seq else { return }
            do {
                let c: IdentityDetail
                switch p {
                case .pin(let v): c = try await APIClient.shared.ctLookup(token: tok, pin: v)
                default: c = try await APIClient.shared.ctLookup(token: tok, username: p.value)
                }
                guard my == seq else { return }
                found = .found(c)
            } catch {
                guard my == seq else { return }
                switch error {
                case APIError.server(status: 404), APIError.server(status: 400), APIError.refused, APIError.decoding:
                    found = .nomatch
                case APIError.rateLimited:
                    found = .error(NSLocalizedString("cv3.err.search.rate", comment: ""))
                default:
                    found = .error(NSLocalizedString("cv3.err.search", comment: ""))
                }
            }
        }
    }

    /// Add & Chat: one server call saves the contact and gives the chat; then the chat opens (no extra step).
    private func addAndChat(_ c: IdentityDetail) async {
        guard adding.isEmpty else { return }
        problem = nil
        adding = "adding"
        let out = await AddAndChat.run(token: token, userID: c.user_id)
        let retry: () -> Void = { Task { await addAndChat(c) } }
        switch out {
        case .opened(let s):
            adding = ""
            openHere(s)
        case .savedNoChat:
            adding = ""
            await load()
            problem = Problem(text: NSLocalizedString("cv3.err.chat", comment: ""), retry: retry)
        case .failed(let message, let canRetry):
            adding = ""
            problem = Problem(text: message, retry: canRetry ? retry : nil)
        }
    }

    private func handleScanned(_ text: String) async {
        guard let t = FlashTarget.parse(text) else {
            problem = Problem(text: NSLocalizedString("fc.notours", comment: ""))
            return
        }
        problem = nil
        switch t {
        case .pin(let p):
            hint = ""
            query = p
        case .username(let u):
            hint = ""
            query = "@" + u
        case .user(let code):
            // a public identity (My QR): its card, with the same "Add & Chat"
            hint = ""
            if !query.isEmpty { query = "" }
            scanned = nil
            do {
                scanned = try await APIClient.shared.ctResolveCode(token: token, code: code)
            } catch {
                problem = Problem(text: NSLocalizedString("fc.nomatch", comment: ""))
            }
        case .mutual, .meet, .group:
            // pushed once the scanner's cover has gone (a push during its dismissal could be dropped)
            try? await Task.sleep(nanoseconds: 450_000_000)
            scanTarget = t
        }
    }

    private func call(_ c: ContactEntry) async {
        guard !opening else { return }
        opening = true
        defer { opening = false }
        guard let chat = await APIClient.shared.ctOpenChat(token: token, userID: c.user_id) else {
            problem = Problem(text: NSLocalizedString("ci.call.failed", comment: ""))
            return
        }
        calls.start(conversationID: chat.conversation_id, peerName: nameOf(c), peerID: c.user_id)
    }

    private func runConfirm(_ c: Confirm) async {
        confirm = nil
        guard !confirming else { return }
        confirming = true
        defer { confirming = false }
        problem = nil
        do {
            switch c.kind {
            case .block: try await APIClient.shared.block(token: token, userID: c.userID)
            case .remove: try await APIClient.shared.ctUnsave(token: token, userID: c.userID)
            }
        } catch {
            // it did not happen: say so (it was silent and the person simply stayed in the list)
            problem = Problem(text: NSLocalizedString("settings.failed", comment: ""))
        }
        await load()
    }

    private func respond(_ r: ContactRequest, accept: Bool) async {
        guard !answering.contains(r.id) else { return }
        answering.insert(r.id)
        defer { answering.remove(r.id) }
        if (try? await APIClient.shared.respond(token: token, requestID: r.id, accept: accept)) != nil {
            incoming.removeAll { $0.id == r.id }
        } else {
            problem = Problem(text: NSLocalizedString("settings.failed", comment: ""))
        }
        await load()
    }

    private func open(_ userID: String) async {
        guard !opening else { return } // a double tap opened the chat request twice
        opening = true
        defer { opening = false }
        if let s = await APIClient.shared.ctOpenChat(token: token, userID: userID) {
            openHere(s)
        } else {
            problem = Problem(text: NSLocalizedString("ci.failed", comment: ""))
        }
    }
}
