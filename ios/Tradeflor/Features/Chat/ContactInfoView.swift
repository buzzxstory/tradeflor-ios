import SwiftUI

/// Contact info (website ContactInfo.tsx): hero, Voice / Search / Share, About, Media, links and docs, Notifications,
/// Chat theme, Disappearing messages, Lock chat, Restricted chat, contact details with the TRADEFLOR PIN, Pin chat,
/// Share contact and Block.
struct ContactInfoView: View {
    let chat: ConversationSummary
    var onSearch: (() -> Void)? = nil
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @Environment(\.dismiss) private var dismiss
    @State private var profile: Profile?
    @State private var identity: IdentityDetail?
    @State private var disappear = 0
    @State private var restricted = false
    @State private var prefs: ConversationPrefs?
    @State private var theme = ""
    @State private var locked = false
    @State private var blocked = false
    @State private var tab = "media"
    @State private var media: [Message] = []
    @State private var viewing: ViewedPhoto?
    @State private var problem: String?
    @State private var confirmBlock = false
    @State private var showMute = false
    @State private var showLock = false
    @State private var copied: String?
    @State private var showAvatar = false

    private var token: String { store.session?.token ?? "" }
    private var name: String { profile.map { $0.display_name.isEmpty ? $0.username : $0.display_name } ?? chat.title }
    private var username: String { profile?.username ?? chat.peer_username }
    private var shareLink: String { "https://app.tradeflor.com/?id=\(identity?.pin ?? "")" }

    static let timers = [0, 86400, 604800, 7776000]
    static func timerKey(_ v: Int) -> String {
        switch v {
        case 86400: return "info.disappear.24h"
        case 604800: return "info.disappear.7d"
        case 7776000: return "info.disappear.90d"
        default: return "info.disappear.off"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    actions
                    if let bio = profile?.bio, !bio.isEmpty {
                        TFCard {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("ci.about").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint)
                                Text(bio).font(.system(size: 15)).foregroundStyle(Theme.text)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        }
                    }
                    mediaCard
                    TFCard {
                        Button { showMute = true } label: {
                            TFRow(icon: "bell", title: NSLocalizedString("ci.notifications", comment: ""),
                                  trailing: MuteSheet.label(mutedUntil: prefs?.muted_until) ?? NSLocalizedString("ci.on", comment: ""))
                        }
                        line
                        NavigationLink { ChatThemePicker(conversationID: chat.conversation_id, selected: $theme) } label: {
                            TFRow(icon: "paintpalette", title: NSLocalizedString("ci.theme", comment: ""), trailing: ChatThemeStyle.item(theme).name)
                        }
                        line
                        NavigationLink { SaveToPhotosPage(restricted: restricted) } label: {
                            TFRow(icon: "square.and.arrow.down", title: NSLocalizedString("ci.save", comment: ""))
                        }
                    }
                    TFCard {
                        NavigationLink { DisappearingPage(conversationID: chat.conversation_id, value: $disappear) } label: {
                            TFRow(icon: "timer", title: NSLocalizedString("info.disappear", comment: ""),
                                  trailing: NSLocalizedString(Self.timerKey(disappear), comment: ""))
                        }
                        line
                        Button { showLock = true } label: {
                            TFRow(icon: "lock", title: NSLocalizedString("ci.lock", comment: ""), subtitle: NSLocalizedString("ci.lock.sub", comment: ""),
                                  trailing: NSLocalizedString(locked ? "ci.on" : "ci.off", comment: ""))
                        }
                        line
                        NavigationLink { RestrictedPage(conversationID: chat.conversation_id, on: $restricted) } label: {
                            TFRow(icon: "hand.raised", title: NSLocalizedString("ci.restricted", comment: ""), subtitle: NSLocalizedString("ci.restricted.sub", comment: ""),
                                  trailing: NSLocalizedString(restricted ? "ci.on" : "ci.off", comment: ""))
                        }
                    }
                    if let id = identity { details(id) }
                    TFCard {
                        Button { Task { await togglePin() } } label: {
                            TFRow(icon: "pin", title: NSLocalizedString((prefs?.pinned ?? false) ? "ci.unpin" : "ci.pinchat", comment: ""), showChevron: false)
                        }
                        line
                        ShareLink(item: shareLink) {
                            TFRow(icon: "square.and.arrow.up", title: NSLocalizedString("ci.share.contact", comment: ""), showChevron: false)
                        }
                    }
                    Button {
                        if blocked { Task { await unblock() } } else { confirmBlock = true }
                    } label: {
                        TFRow(icon: "hand.raised.fill", title: String(format: NSLocalizedString(blocked ? "ci.unblock.name" : "ci.block.name", comment: ""), name),
                              tint: Theme.danger, showChevron: false)
                            .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.danger.opacity(0.35), lineWidth: 1))
                    }
                    if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger) }
                }
                .padding(16)
            }
            .buttonStyle(.plain)
            .background(Starfield())
            .navigationTitle(Text("info.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.header, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
            .fullScreenCover(item: $viewing) { v in PhotoViewer(token: token, fileID: v.id) }
            .fullScreenCover(isPresented: $showAvatar) {
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    Avatar(token: token, userID: chat.peer_id, avatarID: profile?.avatar_id, title: name, size: 320)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Button { showAvatar = false } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
                    }
                    .padding()
                }
            }
            .sheet(isPresented: $showMute) { MuteSheet(conversationID: chat.conversation_id, name: name) { Task { await loadPrefs() } } }
            .sheet(isPresented: $showLock) {
                LockChatSheet(conversationID: chat.conversation_id, name: name, locked: locked) { Task { await loadLock() } }
            }
            .confirmationDialog(Text(String(format: NSLocalizedString("ci.block.confirm", comment: ""), name)),
                                isPresented: $confirmBlock, titleVisibility: .visible) {
                Button("ci.block", role: .destructive) { Task { await block() } }
            } message: { Text("ci.block.msg") }
            .overlay(alignment: .bottom) {
                if let copied {
                    Text(copied).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 14).padding(.vertical, 8).background(Theme.card, in: Capsule())
                        .padding(.bottom, 30)
                }
            }
        }
        .task { await load() }
    }

    private var line: some View { Rectangle().fill(Theme.rowRule).frame(height: 1).padding(.leading, 50) }

    private var hero: some View {
        VStack(spacing: 6) {
            Button {
                if let a = profile?.avatar_id, !a.isEmpty { showAvatar = true }
            } label: {
                Avatar(token: token, userID: chat.peer_id, avatarID: (profile?.avatar_id.isEmpty ?? true) ? chat.peer_avatar_id : profile?.avatar_id,
                       title: name, size: 96)
            }
            Text(name).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
            Button {
                UIPasteboard.general.string = "@" + username
                flash(NSLocalizedString("ci.copied.username", comment: ""))
            } label: { Text("@" + username).font(.system(size: 14)).foregroundStyle(Theme.accent) }
            Text(LocalizedStringKey(blocked ? "ci.blocked" : (live.online.contains(chat.peer_id) ? "ci.online" : "ci.lastseen")))
                .font(.system(size: 13)).foregroundStyle(live.online.contains(chat.peer_id) && !blocked ? Theme.online : Theme.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            actionButton("phone", "ci.voice") {
                dismiss()
                CallManager.shared.start(conversationID: chat.conversation_id, peerName: name, peerID: chat.peer_id)
            }
            .disabled(!CallManager.shared.enabled || blocked)
            actionButton("magnifyingglass", "ci.search") {
                dismiss()
                onSearch?()
            }
            ShareLink(item: shareLink) { actionLabel("square.and.arrow.up", "ci.share") }
        }
    }

    private func actionButton(_ icon: String, _ key: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(icon, key) }
    }

    private func actionLabel(_ icon: String, _ key: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.accent)
            Text(LocalizedStringKey(key)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderStrong, lineWidth: 1))
    }

    private var mediaCard: some View {
        TFCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("ci.media").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    ForEach(["media", "files", "voice", "links"], id: \.self) { c in
                        FilterChip(title: NSLocalizedString("ci.tab." + c, comment: ""), selected: tab == c) {
                            tab = c
                            Task { await loadMedia() }
                        }
                    }
                }
                if media.isEmpty {
                    Text("ci.media.none").font(.system(size: 12)).foregroundStyle(Theme.faint)
                } else if tab == "media" {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                        ForEach(media.filter { $0.file_id != nil }) { m in
                            RemoteImage(token: token, fileID: m.file_id ?? "")
                                .frame(height: 96).clipped().contentShape(Rectangle())
                                .onTapGesture { viewing = ViewedPhoto(id: m.file_id ?? "") }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(media) { m in
                            HStack(spacing: 8) {
                                Image(systemName: tab == "voice" ? "waveform" : (tab == "links" ? "link" : "doc"))
                                    .foregroundStyle(Theme.accent)
                                Text(tab == "files" ? (m.file_name ?? m.body) : (tab == "voice" ? VoiceBubble.length(m.duration_ms ?? 0) : m.body))
                                    .font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer()
                                if let d = m.date { Text(d, style: .date).font(.system(size: 11)).foregroundStyle(Theme.faint) }
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func details(_ id: IdentityDetail) -> some View {
        TFCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("ci.pin").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint)
                HStack {
                    Text(id.pin).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                        .environment(\.layoutDirection, .leftToRight)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = id.pin
                        flash(NSLocalizedString("ci.copied.pin", comment: ""))
                    } label: {
                        Label("ci.copy.pin", systemImage: "doc.on.doc").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10).frame(height: 30).overlay(Capsule().stroke(Theme.borderActive, lineWidth: 1))
                    }
                }
                if let since = id.member_since, since > 0 {
                    Text(String(format: NSLocalizedString("ci.member.since", comment: ""),
                                Date(timeIntervalSince1970: Double(since > 100_000_000_000 ? since / 1000 : since))
                                    .formatted(date: .abbreviated, time: .omitted)))
                        .font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
                HStack(spacing: 6) {
                    if id.early_member == true {
                        Text("ci.early").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.gold)
                            .padding(.horizontal, 8).frame(height: 22).overlay(Capsule().stroke(Theme.gold.opacity(0.6), lineWidth: 1))
                    }
                    if let c = id.country, !c.isEmpty {
                        Text("\(CalendarView.flag(c)) \(Locale.current.localizedString(forRegionCode: c) ?? c)")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private func flash(_ text: String) {
        copied = text
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = nil
        }
    }

    // MARK: data

    private func load() async {
        async let p = APIClient.shared.userProfile(token: token, userID: chat.peer_id)
        async let i = APIClient.shared.ctIdentity(token: token, userID: chat.peer_id)
        async let s = APIClient.shared.chatSettings(token: token, conversationID: chat.conversation_id)
        async let b = APIClient.shared.blocked(token: token)
        profile = try? await p
        identity = try? await i
        if let st = try? await s {
            disappear = st.disappear_secs
            restricted = st.restricted
        }
        blocked = ((try? await b) ?? []).contains(chat.peer_id)
        theme = await ChatThemeStore.load(token: token, conversationID: chat.conversation_id)
        await loadPrefs()
        await loadLock()
        await loadMedia()
    }

    private func loadPrefs() async {
        prefs = ((try? await APIClient.shared.prefs(token: token)) ?? []).first { $0.conversation_id == chat.conversation_id }
    }

    private func loadLock() async {
        locked = (try? await APIClient.shared.ctLockState(token: token))?.isLocked(chat.conversation_id) ?? false
    }

    private func loadMedia() async {
        media = (try? await APIClient.shared.ctMedia(token: token, conversationID: chat.conversation_id, category: tab)) ?? []
    }

    private func togglePin() async {
        try? await APIClient.shared.setPrefs(token: token, conversationID: chat.conversation_id, pinned: !(prefs?.pinned ?? false))
        await loadPrefs()
    }

    private func block() async {
        do {
            try await APIClient.shared.block(token: token, userID: chat.peer_id)
            blocked = true
        } catch {
            problem = NSLocalizedString("chat.action.failed", comment: "")
        }
    }

    private func unblock() async {
        if (try? await APIClient.shared.unblock(token: token, userID: chat.peer_id)) != nil { blocked = false }
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
                        HStack { Spacer(); if busy { ProgressView() } else { Text("schedule.add").bold() }; Spacer() }
                    }
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .listRowBackground(Theme.surface)
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) }.listRowBackground(Theme.surface) }
                if !items.isEmpty {
                    Section(header: Text("schedule.list")) {
                        ForEach(items) { s in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.body).foregroundStyle(.white).lineLimit(2)
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
                                        Label("schedule.now", systemImage: "paperplane")
                                    }
                                    .tint(Theme.accent)
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
        await act {
            try await APIClient.shared.schedule(token: token, conversationID: chat.conversation_id,
                                                body: text.trimmingCharacters(in: .whitespacesAndNewlines), at: when, repeatRule: repeatRule)
            text = ""
        }
    }
}
