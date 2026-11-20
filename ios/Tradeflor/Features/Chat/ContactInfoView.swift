import SwiftUI

/// Contact info V3 (website features/profile/ContactInfo.tsx, 77-contact-info-v3.css, db83951), WhatsApp's order in TRADEFLOR's look:
/// back · "Contact info" · big picture (opens full screen) · name · About · TRADEFLOR PIN (copy) · badges · @username
/// · Chat · Voice · Search
/// · Media, links and docs (count) · Free up storage (this device's copy)
/// · Notifications · Chat theme · Save to Photos
/// · Disappearing messages · Lock chat · Restricted chat
/// · N groups in common
/// · Share contact · Add to Favorites · Add to list · Pin chat · Export chat · Clear chat · Block
/// No video call (calls are voice only), no phone number (private to its owner).
struct ContactInfoView: View {
    let chat: ConversationSummary
    var onSearch: (() -> Void)? = nil
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @ObservedObject private var calls = CallManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var profile: Profile?
    /// Screenshots blocked in this chat (both people).
    @State private var noShots = false

    private func setNoShots(_ on: Bool) async {
        let old = noShots
        noShots = on
        do {
            try await APIClient.shared.setNoScreenshots(token: token, conversationID: chat.conversation_id, on: on)
            LiveConnection.shared.changes.send(chat.conversation_id) // the open chat reads it at once
        } catch APIError.refused(let why) where !why.isEmpty {
            noShots = old
            flash(why)
        } catch {
            noShots = old
            // a server from before the feature refuses the field: say so instead of a switch that only flicks back
            flash(tr("shot.unavailable"))
        }
    }
    @State private var identity: IdentityDetail?
    @State private var disappear = 0
    @State private var restricted = false
    @State private var prefs: ConversationPrefs?
    @State private var theme = ""
    @State private var locked = false
    @State private var blocked = false
    @State private var mediaCount: Int?
    @State private var groups: [CommonGroup]?
    @State private var folders: [EditableFolder]?
    @State private var localCopy = LocalChatCopy.Copy()
    @State private var localBytes: Int64 = 0
    @State private var measuring = true
    @State private var busy = false
    @State private var confirmBlock = false
    @State private var confirmClear = false
    @State private var showMute = false
    @State private var showLock = false
    @State private var showAvatar = false
    @State private var share: CIV3Share?
    @State private var note: String?
    @State private var noteTask: Task<Void, Never>?

    private var token: String { store.session?.token ?? "" }
    private var name: String { profile.map { $0.display_name.isEmpty ? $0.username : $0.display_name } ?? chat.title }
    private var username: String { profile?.username ?? chat.peer_username }
    private var shareLink: String { "https://app.tradeflor.com/?id=\(identity?.pin ?? "")" }
    /// the full-size picture's version (the profile's, else the one the chat list knows)
    private var avatarID: String {
        if let a = profile?.avatar_id, !a.isEmpty { return a }
        return chat.peer_avatar_id ?? ""
    }
    private var favorite: Bool {
        (folders ?? []).contains { CIV3Folders.isFavorites($0) && $0.items.contains(chat.conversation_id) }
    }

    static let timers = [0, 86400, 604800, 7776000]
    static func timerKey(_ v: Int) -> String {
        switch v {
        case 86400: return "info.disappear.24h"
        case 604800: return "info.disappear.7d"
        case 7776000: return "info.disappear.90d"
        default: return "info.disappear.off"
        }
    }

    private func tr(_ key: String) -> String { NSLocalizedString(key, comment: "") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    tiles
                    mediaCard
                    settingsCard
                    privacyCard
                    if let g = groups, !g.isEmpty { groupsCard(g) }
                    actionsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 36)
            }
            .clipped() // the bar and status bar show the page itself: rows stop under them, never a band of another colour
            .buttonStyle(.plain)
            .background(Starfield())
            .navigationTitle(Text("info.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.backward").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("chat.back"))
                }
            }
            .alert(Text(verbatim: String(format: tr("ci.block.confirm"), name)), isPresented: $confirmBlock) {
                Button("grp.cancel", role: .cancel) {}
                Button("ci.block", role: .destructive) { Task { await block() } }
            } message: {
                Text("ci.block.msg")
            }
            .sheet(isPresented: $showMute) {
                MuteSheet(conversationID: chat.conversation_id, name: name) { Task { await loadPrefs() } }
                    .tfColorScheme()
            }
            .sheet(isPresented: $showLock) {
                LockChatSheet(conversationID: chat.conversation_id, name: name, locked: locked) { Task { await loadLock() } }
                    .tfColorScheme()
            }
        }
        .alert(Text("civ3.clear.confirm"), isPresented: $confirmClear) {
            Button("grp.cancel", role: .cancel) {}
            Button("civ3.clear", role: .destructive) { Task { await clearChat() } }
        } message: {
            Text(verbatim: String(format: tr("civ3.clear.msg"), name))
        }
        .sheet(item: $share) { s in ActivityShare(items: s.items) }
        .fullScreenCover(isPresented: $showAvatar) {
            ContactPictureViewer(token: token, userID: chat.peer_id, avatarID: avatarID, name: name)
        }
        .overlay(alignment: .bottom) {
            if let note {
                Text(verbatim: note)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeOut(duration: 0.18), value: note)
        .task { await load() }
        // their note changed while this page is open (live "note" event): the bubble follows at once
        .onReceive(NoteStore.shared.$others) { all in
            if let entry = all[chat.peer_id], profile != nil { profile?.note = entry }
        }
    }

    // MARK: top

    private var hero: some View {
        VStack(spacing: 6) {
            Button {
                if !avatarID.isEmpty { showAvatar = true }
            } label: {
                Avatar(token: token, userID: chat.peer_id, avatarID: avatarID.isEmpty ? nil : avatarID, title: name, size: 132)
                    .padding(4)
                    .overlay(Circle().stroke(Theme.dyn(0x35E6F2, 0x00A8B5, 0.75, 0.7), lineWidth: 2))
                    .shadow(color: Theme.dyn(0x35E6F2, 0x0B5E68, 0.18, 0.14), radius: 9)
                    // their note (WhatsApp's About note) as a bubble over the picture, while it lasts
                    .overlay(alignment: .top) {
                        if let n = profile?.note, n.isLive() { NoteBubble(note: n).offset(y: -30) }
                    }
            }
            .buttonStyle(.plain)
            .padding(.top, profile?.note?.isLive() == true ? 34 : 0) // room for the note bubble over the picture
            .accessibilityLabel(Text(verbatim: String(format: tr("civ3.picture.view"), name)))
            Text(verbatim: name)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            about
            if let id = identity, !id.pin.isEmpty { pinPill(id.pin) }
            if let id = identity { badges(id) }
            Text(verbatim: handleLine)
                .font(.system(size: 13.5))
                .foregroundStyle(CIV3.handle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    /// Blocked · their About · else the presence line ("online", "last seen …") · else nothing (website d4d2e77).
    @ViewBuilder private var about: some View {
        if blocked {
            aboutLine(tr("ci.blocked"), online: false)
        } else if let bio = profile?.bio.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
            aboutLine(bio, online: false)
        } else if let line = live.presenceLine(chat.peer_id) {
            aboutLine(line, online: live.online.contains(chat.peer_id))
        }
    }

    private func aboutLine(_ text: String, online: Bool) -> some View {
        HStack(spacing: 8) {
            if online { Circle().fill(Theme.dyn(0x22D68A, 0x0FB57F)).frame(width: 9, height: 9) }
            Text(verbatim: text).font(.system(size: 16)).foregroundStyle(CIV3.about).multilineTextAlignment(.center)
        }
    }

    private func pinPill(_ pin: String) -> some View {
        Button {
            UIPasteboard.general.string = pin
            flash(tr("ci.copied.pin"))
        } label: {
            HStack(spacing: 14) {
                Text("ci.pin").font(.system(size: 13.5)).tracking(0.5).foregroundStyle(Theme.dyn(0xB8CCD5, 0x3C5668))
                Text(verbatim: pin)
                    .font(.system(size: 26, weight: .heavy).monospacedDigit())
                    .foregroundStyle(CIV3.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .environment(\.layoutDirection, .leftToRight)
                Image(systemName: "doc.on.doc").font(.system(size: 19)).foregroundStyle(CIV3.cyan)
            }
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .frame(height: 48)
            .background(CIV3.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.dyn(0x35E6F2, 0xA6E3E7, 0.4, 1), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(format: tr("civ3.pin.copy"), pin)))
        .accessibilityAddTraits(.isButton)
    }

    /// Early member · PIN class · country (website Badges + CountryMark).
    @ViewBuilder private func badges(_ id: IdentityDetail) -> some View {
        let cls = id.pin_class ?? ""
        let cc = (id.country ?? "").trimmingCharacters(in: .whitespaces)
        if !cls.isEmpty || id.early_member == true || !cc.isEmpty {
            HStack(spacing: 6) {
                if !cls.isEmpty {
                    badge(Text(LocalizedStringKey("id.class." + cls)), icon: IdentityCardFace.classIcon(cls), color: IdentityTone.tone(cls))
                }
                if id.early_member == true {
                    badge(Text("set.early"), icon: "star", color: Theme.dyn(0x9FE9EA, 0x0097A5))
                }
                if !cc.isEmpty {
                    HStack(spacing: 5) {
                        if cc.count == 2 && cc.lowercased() != "il" {
                            Text(verbatim: IdentityCardFace.flag(cc)).font(.system(size: 15))
                        } else {
                            Image(systemName: "globe").font(.system(size: 12))
                        }
                        if cc.lowercased() != "il" {
                            Text(verbatim: Locale.current.localizedString(forRegionCode: cc.uppercased()) ?? cc.uppercased())
                                .font(.system(size: 12.5))
                        }
                    }
                    .foregroundStyle(CIV3.about)
                    .lineLimit(1)
                }
            }
            .padding(.top, 4)
        }
    }

    private func badge(_ title: Text, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .bold))
            title.font(.system(size: 11.5, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
    }

    /// "@username · Member since 2026"
    private var handleLine: String {
        guard let year = memberYear else { return "@" + username }
        return "@" + username + " · " + String(format: tr("ci.member.since"), year)
    }

    private var memberYear: String? {
        guard let v = identity?.member_since, v > 0 else { return nil }
        if v < 10_000 { return String(v) } // already a year
        guard let d = serverDate(v) else { return nil }
        return String(Calendar(identifier: .gregorian).component(.year, from: d))
    }

    // MARK: quick tiles

    private var tiles: some View {
        HStack(spacing: 10) {
            CIV3Tile(icon: "bubble.left", title: tr("civ3.chat")) { dismiss() }
            if calls.enabled && !blocked {
                CIV3Tile(icon: "phone", title: tr("ci.voice")) {
                    dismiss()
                    calls.start(conversationID: chat.conversation_id, peerName: name, peerID: chat.peer_id)
                }
            }
            if onSearch != nil {
                CIV3Tile(icon: "magnifyingglass", title: tr("ci.search")) {
                    dismiss()
                    onSearch?()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: cards

    private var mediaCard: some View {
        CIV3Card {
            NavigationLink {
                CIV3MediaPage(token: token, conversationID: chat.conversation_id)
            } label: {
                CIV3Row(icon: "photo.on.rectangle", title: tr("ci.media"), value: mediaCount.map { $0.formatted() })
            }
            CIV3Divider()
            NavigationLink {
                CIV3StoragePage(bytes: $localBytes, measuring: $measuring) { clearLocalCopy() }
            } label: {
                CIV3Row(icon: "internaldrive", title: tr("civ3.storage"), value: measuring ? nil : CIV3.bytes(localBytes))
            }
        }
    }

    private var settingsCard: some View {
        CIV3Card {
            Button { showMute = true } label: {
                CIV3Row(icon: "bell", title: tr("ci.notifications"),
                        value: MuteSheet.label(mutedUntil: prefs?.muted_until) ?? tr("ci.on"))
            }
            CIV3Divider()
            NavigationLink { ChatThemePicker(conversationID: chat.conversation_id, selected: $theme) } label: {
                CIV3Row(icon: "paintpalette", title: tr("ci.theme"), value: ChatThemeStyle.item(theme).name)
            }
            CIV3Divider()
            NavigationLink { SaveToPhotosPage(restricted: restricted) } label: {
                CIV3Row(icon: "square.and.arrow.down", title: tr("ci.save"), value: restricted ? tr("ci.off") : nil)
            }
        }
    }

    private var privacyCard: some View {
        CIV3Card {
            NavigationLink { DisappearingPage(conversationID: chat.conversation_id, value: $disappear) } label: {
                CIV3Row(icon: "timer", title: tr("info.disappear"), value: tr(Self.timerKey(disappear)))
            }
            CIV3Divider()
            Button { showLock = true } label: {
                CIV3Row(icon: "lock", title: tr("ci.lock"), subtitle: tr("ci.lock.sub"), toggle: locked)
            }
            .accessibilityValue(Text(verbatim: tr(locked ? "ci.on" : "ci.off")))
            CIV3Divider()
            // Block screenshots: on for both people in this chat (ScreenGuard)
            Button { Task { await setNoShots(!noShots) } } label: {
                CIV3Row(icon: "camera.metering.none", title: tr("shot.row"), subtitle: tr("shot.row.sub"), toggle: noShots)
            }
            .accessibilityValue(Text(verbatim: tr(noShots ? "ci.on" : "ci.off")))
            CIV3Divider()
            NavigationLink { RestrictedPage(conversationID: chat.conversation_id, on: $restricted) } label: {
                CIV3Row(icon: "checkmark.shield", title: tr("ci.restricted"), subtitle: tr("ci.restricted.sub"),
                        value: tr(restricted ? "ci.on" : "ci.off"))
            }
        }
    }

    private func groupsCard(_ list: [CommonGroup]) -> some View {
        CIV3Card {
            NavigationLink {
                CIV3GroupsPage(token: token, groups: list, name: name) { g in openGroup(g) }
            } label: {
                CIV3Row(icon: "person.3", title: list.count == 1 ? tr("civ3.groups.one") : String(format: tr("civ3.groups.n"), list.count))
            }
        }
    }

    private var actionsCard: some View {
        CIV3Card {
            if identity != nil {
                Button { Task { await shareContact() } } label: {
                    CIV3Row(icon: "square.and.arrow.up", title: tr("ci.share.contact"), chevron: false)
                }
                CIV3Divider()
            }
            if folders != nil {
                Button { Task { await toggleFavorite() } } label: {
                    CIV3Row(icon: favorite ? "heart.fill" : "heart", title: tr(favorite ? "civ3.fav.remove" : "civ3.fav.add"), chevron: false)
                }
                .disabled(busy)
                CIV3Divider()
                NavigationLink {
                    CIV3ListsPage(token: token, conversationID: chat.conversation_id, folders: $folders) { flash($0) }
                } label: {
                    CIV3Row(icon: "text.badge.plus", title: tr("civ3.list"), chevron: false)
                }
                CIV3Divider()
            }
            Button { Task { await togglePin() } } label: {
                CIV3Row(icon: "pin", title: tr((prefs?.pinned ?? false) ? "ci.unpin" : "ci.pinchat"), chevron: false)
            }
            .disabled(busy)
            CIV3Divider()
            Button { Task { await exportChat() } } label: {
                CIV3Row(icon: "arrow.up.doc", title: tr("civ3.export"), chevron: false)
            }
            .disabled(busy)
            CIV3Divider()
            Button { confirmClear = true } label: {
                CIV3Row(icon: "trash", title: tr("civ3.clear"), danger: true, chevron: false)
            }
            CIV3Divider()
            Button {
                if blocked { Task { await unblock() } } else { confirmBlock = true }
            } label: {
                CIV3Row(icon: "nosign", title: String(format: tr(blocked ? "ci.unblock.name" : "ci.block.name"), name), danger: true, chevron: false)
            }
            .disabled(busy)
        }
    }

    private func flash(_ text: String) {
        noteTask?.cancel()
        note = text
        noteTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if !Task.isCancelled { note = nil }
        }
    }

    // MARK: data

    private func load() async {
        async let p = APIClient.shared.userProfile(token: token, userID: chat.peer_id)
        async let i = APIClient.shared.ctIdentity(token: token, userID: chat.peer_id)
        async let s = APIClient.shared.chatSettings(token: token, conversationID: chat.conversation_id)
        async let b = APIClient.shared.blocked(token: token)
        async let st = APIClient.shared.grpMediaStats(token: token, conversationID: chat.conversation_id)
        async let cg = APIClient.shared.civ3CommonGroups(token: token, userID: chat.peer_id)
        async let fd = FolderStore.load(token: token)
        profile = try? await p
        identity = try? await i
        if let set = try? await s {
            disappear = set.disappear_secs
            restricted = set.restricted
            noShots = set.blocksScreenshots
        }
        blocked = ((try? await b) ?? []).contains(chat.peer_id)
        if let m = await st {
            mediaCount = (m.photos ?? 0) + (m.videos ?? 0) + (m.files ?? 0) + (m.links ?? 0)
        }
        groups = try? await cg
        folders = (try? await fd)?.1
        theme = await ChatThemeStore.load(token: token, conversationID: chat.conversation_id)
        await loadPrefs()
        await loadLock()
        await measureLocalCopy()
    }

    private func loadPrefs() async {
        prefs = ((try? await APIClient.shared.prefs(token: token)) ?? []).first { $0.conversation_id == chat.conversation_id }
    }

    private func loadLock() async {
        locked = (try? await APIClient.shared.ctLockState(token: token))?.isLocked(chat.conversation_id) ?? false
    }

    private func measureLocalCopy() async {
        measuring = true
        let copy = await LocalChatCopy.measure(token: token, conversationID: chat.conversation_id)
        localCopy = copy
        localBytes = copy.bytes
        measuring = false
    }

    /// Free up storage: only this device's copy; nothing on the account changes.
    private func clearLocalCopy() {
        // against the chat's attachments listed again now, not only what the page measured earlier (that can still be empty)
        Task {
            let fresh = await LocalChatCopy.measure(token: token, conversationID: chat.conversation_id)
            LocalChatCopy.clear(localCopy)
            LocalChatCopy.clear(fresh)
            localCopy = LocalChatCopy.Copy()
            localBytes = 0
            flash(tr("civ3.storage.cleared"))
            await measureLocalCopy()
        }
    }

    private func togglePin() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await APIClient.shared.setPrefs(token: token, conversationID: chat.conversation_id, pinned: !(prefs?.pinned ?? false))
        } catch {
            flash(tr("chat.action.failed"))
        }
        await loadPrefs()
    }

    private func toggleFavorite() async {
        guard !busy else { return }
        let on = !favorite
        busy = true
        defer { busy = false }
        do {
            folders = try await CIV3Folders.setFavorite(token: token, conversationID: chat.conversation_id, on: on)
            flash(tr(on ? "civ3.fav.added" : "civ3.fav.removed"))
        } catch {
            flash(tr("settings.failed"))
        }
    }

    private func openGroup(_ g: CommonGroup) {
        dismiss()
        LocalNotifier.shared.tappedConversation = g.id
    }

    /// The identity card as a picture, with the link (Settings › My Identity's Share Card, for this person).
    @MainActor private func shareContact() async {
        guard let id = identity else { return }
        var picture: UIImage?
        if let a = id.avatar_id, !a.isEmpty, let d = await APIClient.shared.avatar(token: token, userID: id.user_id, avatarID: a) {
            picture = UIImage(data: d)
        }
        let card = StIdentity(user_id: id.user_id, username: id.username, display_name: id.display_name ?? "", pin: id.pin,
                              early_member: id.early_member, original_pin_length: nil, member_since: id.member_since,
                              username_change_available_at: nil, avatar_id: id.avatar_id, pin_class: id.pin_class, country: id.country)
        let renderer = ImageRenderer(content: IdentityCardFace(id: card, link: shareLink, avatar: picture, beam: false)
            .frame(width: 380).padding(16).background(Theme.hex(0x02090E)))
        renderer.scale = 3
        var items: [Any] = []
        if let img = renderer.uiImage { items.append(img) }
        if let url = URL(string: shareLink) { items.append(url) }
        if !items.isEmpty { share = CIV3Share(items: items) }
    }

    private func exportChat() async {
        guard !busy else { return }
        if restricted {
            flash(tr("civ3.export.restricted"))
            return
        }
        busy = true
        defer { busy = false }
        flash(tr("civ3.export.preparing"))
        let me = store.session?.userID ?? ""
        let myName = store.session?.username ?? ""
        let peer = chat.peer_id
        let peerName = name
        do {
            let (url, n) = try await ChatExporter.export(token: token, conversationID: chat.conversation_id, title: peerName,
                                                         nameOf: { $0 == peer ? peerName : ($0 == me ? myName : $0) }, me: myName)
            flash(String(format: tr("civ3.export.done"), n))
            share = CIV3Share(items: [url])
        } catch {
            flash(tr("civ3.export.failed"))
        }
    }

    /// Clear chat: every message leaves my view on all my devices (the open chat drops them on the live "hidden" event);
    /// the other person keeps theirs; the chat stays listed. Then this device's copy goes too.
    private func clearChat() async {
        do {
            // listed before the server clears the chat (afterwards its index of shared items is empty)
            let fresh = await LocalChatCopy.measure(token: token, conversationID: chat.conversation_id)
            let n = try await APIClient.shared.civ3ClearChat(token: token, conversationID: chat.conversation_id)
            LocalChatCopy.clear(fresh)
            LocalChatCopy.clear(localCopy)
            localCopy = LocalChatCopy.Copy()
            localBytes = 0
            mediaCount = 0
            flash(n > 0 ? String(format: tr("civ3.clear.done"), n) : tr("civ3.clear.empty"))
        } catch ClearChatError.notMember {
            flash(tr("civ3.clear.notmember"))
        } catch {
            flash(tr("civ3.clear.failed"))
        }
    }

    private func block() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await APIClient.shared.block(token: token, userID: chat.peer_id)
            blocked = true
        } catch {
            flash(tr("chat.action.failed"))
        }
    }

    private func unblock() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if (try? await APIClient.shared.unblock(token: token, userID: chat.peer_id)) != nil {
            blocked = false
        } else {
            flash(tr("chat.action.failed"))
        }
    }
}

/// "Disappearing messages": the shared message timer (24 hours / 7 days / 90 days / Off).
struct DisappearingPage: View {
    let conversationID: String
    @Binding var value: Int
    @EnvironmentObject private var store: SessionStore
    @State private var problem: String?

    var body: some View {
        SettingsPage(title: NSLocalizedString("info.disappear", comment: "")) {
            TFSectionLabel(text: NSLocalizedString("ci.timer", comment: ""))
            TFCard {
                ForEach(ContactInfoView.timers, id: \.self) { v in
                    Button { Task { await set(v) } } label: {
                        HStack {
                            Text(LocalizedStringKey(ContactInfoView.timerKey(v))).font(.system(size: 15)).foregroundStyle(Theme.text)
                            Spacer()
                            if value == v { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                        .padding(14).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("ci.timer.f1").font(.system(size: 12)).foregroundStyle(Theme.faint)
            Text("ci.timer.f2").font(.system(size: 12)).foregroundStyle(Theme.faint)
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
    }

    private func set(_ v: Int) async {
        do {
            try await APIClient.shared.setDisappearing(token: store.session?.token ?? "", conversationID: conversationID, seconds: v)
            value = v
        } catch {
            problem = NSLocalizedString("ci.save.failed", comment: "")
        }
    }
}

/// "Restricted chat": no forwarding, copying or saving, for both people.
struct RestrictedPage: View {
    let conversationID: String
    @Binding var on: Bool
    @EnvironmentObject private var store: SessionStore
    @State private var problem: String?

    var body: some View {
        SettingsPage(title: NSLocalizedString("ci.restricted", comment: "")) {
            TFCard {
                Toggle(isOn: Binding(get: { on }, set: { v in Task { await set(v) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ci.restricted").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(LocalizedStringKey(on ? "ci.restricted.on" : "ci.restricted.off")).font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                }
                .tint(Theme.accent)
                .padding(14)
            }
            Text("ci.restricted.sub").font(.system(size: 12)).foregroundStyle(Theme.faint)
            Text("ci.restricted.f1").font(.system(size: 12)).foregroundStyle(Theme.faint)
            Text("ci.restricted.f2").font(.system(size: 12)).foregroundStyle(Theme.faint)
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
    }

    private func set(_ v: Bool) async {
        do {
            try await APIClient.shared.ctSetRestricted(token: store.session?.token ?? "", conversationID: conversationID, on: v)
            on = v
        } catch {
            problem = NSLocalizedString("ci.save.failed", comment: "")
        }
    }
}

/// "Save to Photos" on a phone is informational: open a photo and tap Save to Photos.
struct SaveToPhotosPage: View {
    let restricted: Bool
    var body: some View {
        SettingsPage(title: NSLocalizedString("ci.save", comment: "")) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 18)).foregroundStyle(Theme.accent)
                Text(LocalizedStringKey(restricted ? "ci.save.restricted" : "ci.save.phone")).font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
        }
    }
}

/// Schedule a text message for later (once, daily or weekly), and see / cancel / send now the ones already planned.
struct ScheduleSheet: View {
    let chat: ConversationSummary
    let initialText: String
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var when = Date().addingTimeInterval(3600)
    @State private var repeatRule = "none"
    @State private var items: [ScheduledMessage] = []
    @State private var editingID: String?
    @State private var busy = false
    @State private var error: String?

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("chat.placeholder", text: $text, axis: .vertical).lineLimit(2...6)
                    DatePicker("schedule.when", selection: $when, in: Date().addingTimeInterval(90)...Date().addingTimeInterval(365 * 86400))
                    Picker("schedule.repeat", selection: $repeatRule) {
                        Text("schedule.once").tag("none")
                        Text("schedule.daily").tag("daily")
                        Text("schedule.weekly").tag("weekly")
                    }
                    Button { Task { await add() } } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text(LocalizedStringKey(editingID == nil ? "schedule.add" : "schedule.save")).bold() }; Spacer() }
                    }
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if editingID != nil {
                        Button("schedule.edit.cancel") { editingID = nil; text = ""; repeatRule = "none" }
                    }
                } header: {
                    if editingID != nil { Text("schedule.editing") }
                }
                .listRowBackground(Theme.surface)
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) }.listRowBackground(Theme.surface) }
                if !items.isEmpty {
                    Section(header: Text("schedule.list")) {
                        ForEach(items) { s in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.body).foregroundStyle(Theme.text).lineLimit(2)
                                HStack {
                                    Text(s.date, style: .date)
                                    Text(s.date, style: .time)
                                    if let r = s.repeat_rule, r != "none" { Text(LocalizedStringKey("schedule." + r)) }
                                    Spacer()
                                    Text(LocalizedStringKey("schedule.status." + s.status)).foregroundStyle(Theme.accent)
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                if s.status == "pending" || s.status == "failed" {
                                    Button(role: .destructive) { Task { await act { try await APIClient.shared.cancelScheduled(token: token, id: s.id) } } } label: {
                                        Label("schedule.cancel", systemImage: "xmark")
                                    }
                                    Button { Task { await act { try await APIClient.shared.sendScheduledNow(token: token, id: s.id) } } } label: {
                                        Label(LocalizedStringKey(s.status == "failed" ? "schedule.retry" : "schedule.now"), systemImage: "paperplane")
                                    }
                                    .tint(Theme.accent)
                                    Button {
                                        editingID = s.id
                                        text = s.body
                                        when = max(s.date, Date().addingTimeInterval(120))
                                        repeatRule = s.repeat_rule ?? "none"
                                    } label: { Label("schedule.edit", systemImage: "pencil") }
                                    .tint(.orange)
                                }
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("schedule.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .task {
            text = initialText
            await reload()
        }
    }

    private func reload() async {
        items = (try? await APIClient.shared.scheduled(token: token, conversationID: chat.conversation_id)) ?? items
    }

    private func act(_ work: () async throws -> Void) async {
        do { try await work() } catch APIError.refused(let why) { error = why } catch {
            self.error = NSLocalizedString("chat.action.failed", comment: "")
        }
        await reload()
    }

    private func add() async {
        busy = true
        error = nil
        defer { busy = false }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        await act {
            if let id = editingID {
                try await APIClient.shared.editScheduled(token: token, id: id, body: body, at: when, repeatRule: repeatRule)
            } else {
                try await APIClient.shared.schedule(token: token, conversationID: chat.conversation_id, body: body, at: when, repeatRule: repeatRule)
            }
            text = ""
            editingID = nil
        }
    }
}
