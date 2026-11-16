import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// One conversation: history (newest page first, older pages on demand), live incoming messages, and sending text.
struct ChatView: View {
    let chat: ConversationSummary
    var canSend = true

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @State private var messages: [Message] = []
    @State private var pending: [PendingMessage] = []
    @State private var loading = true
    @State private var loadingOlder = false
    @State private var reachedStart = false
    @State private var problem: String?
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var picked: [PhotosPickerItem] = []
    @State private var reviewing: MediaBatch?
    @State private var showCamera = false
    @State private var viewing: ViewedPhoto?
    @State private var watching: ViewedPhoto?
    @StateObject private var recorder = VoiceRecorder()
    @State private var locked = false
    @State private var replyingTo: Message?
    @State private var forwarding: Message?
    @State private var peerTypingUntil: Date?
    @State private var lastTypingSent = Date.distantPast
    @State private var confirmBlock = false
    @State private var showInfo = false
    @State private var showSchedule = false
    @State private var showNoteRecorder = false
    @ObservedObject private var location = LocationSharer.shared
    @State private var memberNames: [String: String] = [:]
    private var isGroup: Bool { chat.conversation_id.hasPrefix("grp_") }
    @ObservedObject private var calls = CallManager.shared
    @State private var showUnlock = false
    // web parity: select mode, in-chat search, delete dialog, polls/signals/comments, attach sheets, group meta
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var searchOpen = false
    @State private var searchText = ""
    @State private var searchIndex = 0
    @State private var deleteTargets: [Message] = []
    @State private var showDelete = false
    @State private var showPoll = false
    @State private var showSignal = false
    @State private var commentsFor: Message?
    @State private var showEmoji = false
    @State private var showLocationSheet = false
    @State private var showPhotoPicker = false
    @State private var showDocPicker = false
    @State private var showMute = false
    @State private var muted = false
    @State private var restricted = false
    @State private var myRole = "member"
    @State private var groupCanSendMedia = true
    @State private var groupCanSignals = false
    @State private var groupComments = false
    @State private var memberCount = 0
    @State private var pins: [GroupPinRef] = []
    @State private var pinIndex = 0
    @State private var members: [GroupMember] = []
    @State private var bottomVisible = true
    @State private var newWhileAway = 0
    @State private var confirmLeave = false
    @State private var confirmDeleteGroup = false
    @State private var exportURL: URL?
    @State private var toast: String?
    @State private var reactTarget: Message?
    @State private var memberRoles: [String: String] = [:]
    @State private var jumpTarget: String?
    @State private var themeID = ""
    @State private var focusDoc: FocusDoc?
    @State private var openDoc: LocalDoc?
    @State private var openingDoc = false
    // hold-to-record voice: press = record, release = send, slide left = cancel, slide up = lock (hands free)
    @State private var micPressed = false
    @State private var holdRec = false
    @State private var holdReleased = false
    @State private var holdDrag: CGSize = .zero
    @State private var focusPages: [Message] = []
    @State private var focusShowAll = false
    @State private var showFocus = false
    private var focusOn: Bool { isGroup && (focusDoc?.focus.active ?? false) && !focusShowAll }
    /// What the list shows: everything, or (Smart Focus) the server's filtered history plus matching live messages.
    private var shown: [Message] {
        guard focusOn, let f = focusDoc?.focus else { return messages }
        var byID: [String: Message] = [:]
        for m in focusPages { byID[m.id] = m }
        for m in messages where byID[m.id] != nil || f.matches(m, me: me, roleOf: { memberRoles[$0] }) { byID[m.id] = m }
        return byID.values.sorted { $0.seq < $1.seq }
    }
    private var isAdmin: Bool { myRole == "owner" || myRole == "admin" }
    private var searchHits: [Message] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return messages.filter { !$0.isDeleted && $0.body.localizedCaseInsensitiveContains(q) }
    }

    @Environment(\.dismiss) private var dismissView
    private let pageSize = 50
    private var me: String { store.session?.userID ?? "" }
    private var token: String { store.session?.token ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            if selecting { selectHead } else { topBar }
            if searchOpen { searchBar }
            if isGroup && (focusDoc?.focus.active ?? false) && !selecting {
                FocusBanner(showingAll: focusShowAll, onToggle: { focusShowAll.toggle() }, onEdit: { showFocus = true })
            }
            if isGroup && !pins.isEmpty && !selecting { pinnedBar }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if !reachedStart && !messages.isEmpty {
                            Button {
                                Task { await loadOlder() }
                            } label: {
                                if loadingOlder { ProgressView() } else { Text("chat.older").font(.footnote) }
                            }
                            .padding(.vertical, 8)
                        }
                        let rows = shown
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                            if i == 0 || !sameDay(rows[i - 1], m) {
                                DayDivider(date: m.date)
                            }
                            MessageRow(message: m, mine: m.sender_id == me, myID: me, peerName: chat.title,
                                       senderName: isGroup && m.sender_id != me
                                           && (i == 0 || messages[i - 1].sender_id != m.sender_id)
                                           ? (memberNames[m.sender_id] ?? "") : nil,
                                       onReply: { replyingTo = m; composerFocused = true },
                                       onReact: { e in Task { await react(m, e) } },
                                       onCopy: { UIPasteboard.general.string = displayText(m); flash("chat.copied") },
                                       onForward: { forwarding = m },
                                       onDelete: { _ in deleteTargets = [m]; showDelete = true },
                                       options: MessageRowOptions(
                                           isGroup: isGroup, restricted: restricted, canPin: isGroup && isAdmin,
                                           pinned: pins.contains { $0.message_id == m.id },
                                           selecting: selecting, selected: selected.contains(m.id),
                                           highlighted: searchOpen && searchHits.indices.contains(searchIndex) && searchHits[searchIndex].id == m.id,
                                           roleTag: isGroup ? roleOf(m.sender_id) : nil),
                                       actions: MessageRowActions(
                                           copyLink: {
                                               UIPasteboard.general.string = "tradeflor://chat/\(chat.conversation_id)/message/\(m.id)"
                                               flash("chat.link.copied")
                                           },
                                           select: { selecting = true; selected = [m.id] },
                                           toggleSelect: { if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) } },
                                           pin: { on in Task { await setPin(m, on) } },
                                           report: { flash("chat.report.soon") },
                                           moreReactions: { reactTarget = m; showEmoji = true },
                                           comments: { commentsFor = m },
                                           save: m.file_id == nil ? nil : { Task { await saveAttachment(m) } })) {
                                messageContent(m)
                            }
                            .id(m.id)
                        }
                        ForEach(pending) { p in
                            Group {
                                if let img = p.image {
                                    PhotoBubble(mine: true, date: p.date, state: p.failed ? .failed : .sending, caption: "") {
                                        Image(uiImage: img).resizable().scaledToFill()
                                    }
                                } else if p.video != nil {
                                    Bubble(text: "🎬 " + NSLocalizedString("chat.video", comment: ""), mine: true, date: p.date,
                                           state: p.failed ? .failed : .sending, faded: false)
                                } else if let ms = p.durationMs {
                                    Bubble(text: "🎤 " + VoiceBubble.length(Int64(ms)), mine: true, date: p.date,
                                           state: p.failed ? .failed : .sending, faded: false)
                                } else {
                                    Bubble(text: p.body, mine: true, date: p.date, state: p.failed ? .failed : .sending, faded: false)
                                }
                            }
                            .id(p.id)
                            .onTapGesture { if p.failed { Task { await deliver(p) } } }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { bottomVisible = true; newWhileAway = 0 }
                            .onDisappear { bottomVisible = false }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .overlay(alignment: .bottomTrailing) {
                    if !bottomVisible && !messages.isEmpty {
                        Button { scrollToBottom(proxy) } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "chevron.down").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                                    .frame(width: 42, height: 42).background(Theme.card, in: Circle())
                                    .overlay(Circle().stroke(Theme.borderStrong, lineWidth: 1))
                                if newWhileAway > 0 {
                                    Text("\(newWhileAway)").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.onAccent)
                                        .padding(.horizontal, 5).frame(minHeight: 18).background(Theme.accent, in: Capsule()).offset(x: 4, y: -4)
                                }
                            }
                        }
                        .padding(14)
                        .accessibilityLabel(Text("chat.jump"))
                    }
                }
                .overlay(alignment: .top) {
                    if let toast {
                        Text(toast).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8).background(Theme.card, in: Capsule())
                            .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1)).padding(.top, 10)
                    }
                }
                .onChange(of: jumpTarget) { t in
                    if let t { withAnimation { proxy.scrollTo(t, anchor: .center) }; jumpTarget = nil }
                }
                .onChange(of: searchIndex) { _ in
                    if searchHits.indices.contains(searchIndex) { withAnimation { proxy.scrollTo(searchHits[searchIndex].id, anchor: .center) } }
                }
                .onChange(of: searchText) { _ in
                    searchIndex = max(0, searchHits.count - 1)
                    if let last = searchHits.last { withAnimation { proxy.scrollTo(last.id, anchor: .center) } }
                }
                .overlay {
                    if loading && messages.isEmpty {
                        ProgressView()
                    } else if locked && messages.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
                            Text("lock.chat.locked").foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button { showUnlock = true } label: {
                                Text("lock.unlock").bold().padding(.horizontal, 28).padding(.vertical, 12)
                                    .foregroundStyle(Theme.onAccent).background(Theme.accent, in: Capsule())
                            }
                            .accessibilityIdentifier("lock.open")
                        }
                        .padding()
                    } else if let problem, messages.isEmpty {
                        Text(problem).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    } else if !loading && messages.isEmpty && pending.isEmpty && canSend {
                        VStack(spacing: 10) {
                            Text("chat.empty.title").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                            Text("chat.empty.sub").font(.system(size: 13)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
                            Button {
                                draft = "👋"
                                Task { await sendDraft() }
                            } label: { Text("👋").font(.system(size: 54)) }
                            .accessibilityLabel(Text("chat.greet"))
                        }
                        .padding(24)
                        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.borderStrong, lineWidth: 1))
                        .padding(30)
                    }
                }
                .onChange(of: messages.last?.id) { _ in scrollToBottom(proxy) }
                .onChange(of: pending.count) { _ in scrollToBottom(proxy) }
                .onChange(of: composerFocused) { f in if f { scrollToBottom(proxy) } }
            }
            if selecting {
                selectBar
            } else if canSend {
                composer
            } else {
                Text("group.readonly").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 14).background(.bar)
            }
        }
        .background(ChatThemeStyle.background(themeID).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(live.typing) { t in
            guard t.conversation == chat.conversation_id, t.user != me else { return }
            peerTypingUntil = Date().addingTimeInterval(5)
            Task {
                try? await Task.sleep(nanoseconds: 5_200_000_000)
                if let u = peerTypingUntil, u <= Date() { peerTypingUntil = nil }
            }
        }
        .confirmationDialog(Text(String(format: NSLocalizedString("chat.block.confirm", comment: ""), chat.title)),
                            isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("chat.block", role: .destructive) {
                Task {
                    do { try await APIClient.shared.block(token: token, userID: chat.peer_id) } catch {
                        problem = NSLocalizedString("chat.action.failed", comment: "")
                    }
                }
            }
        }
        .sheet(isPresented: $showInfo, onDismiss: {
            Task {
                themeID = await ChatThemeStore.load(token: token, conversationID: chat.conversation_id)
                await loadMeta()
            }
        }) {
            if isGroup {
                GroupInfoView(groupID: chat.conversation_id).environmentObject(store).environmentObject(live)
            } else {
                ContactInfoView(chat: chat, onSearch: { showInfo = false; searchOpen = true })
                    .environmentObject(store).environmentObject(live)
            }
        }
        .sheet(isPresented: $showSchedule) { ScheduleSheet(chat: chat, initialText: draft) }
        .fullScreenCover(item: $openDoc) { d in DocumentPreview(url: d.url).ignoresSafeArea() }
        .sheet(isPresented: $showFocus) {
            if let doc = focusDoc {
                SmartFocusSheet(groupID: chat.conversation_id, members: members, me: me, initial: doc) { saved in
                    focusDoc = saved
                    focusShowAll = false
                    Task { await loadFocusPages() }
                }
                .environmentObject(store)
            }
        }
        .fullScreenCover(isPresented: $showNoteRecorder) {
            VideoNoteRecorder { url in Task { await sendVideoNote(url) } }.ignoresSafeArea()
        }
        .alert(Text("location.denied"), isPresented: $location.denied) {
            Button("chat.settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
            Button("chat.close", role: .cancel) {}
        }
        .sheet(item: $forwarding) { m in
            ForwardSheet(token: token, message: m) { forwarding = nil }
        }
        .sheet(isPresented: $showPoll) {
            PollComposer { q, opts, multi in
                do {
                    let m = try await APIClient.shared.chCreatePoll(token: token, groupID: chat.conversation_id, question: q, options: opts, multiple: multi)
                    merge([m])
                    return nil
                } catch APIError.refused(let why) { return why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why
                } catch { return NSLocalizedString("chat.action.failed", comment: "") }
            }
        }
        .sheet(isPresented: $showSignal) {
            SignalComposer { sym, dir, entry, sl, tp in
                do {
                    let m = try await APIClient.shared.chSendSignal(token: token, conversationID: chat.conversation_id, symbol: sym,
                                                                     direction: dir, entry: entry, stopLoss: sl, takeProfit: tp)
                    merge([m])
                    return nil
                } catch APIError.refused(let why) { return why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why
                } catch { return NSLocalizedString("chat.action.failed", comment: "") }
            }
        }
        .sheet(item: $commentsFor) { m in
            CommentsSheet(token: token, groupID: chat.conversation_id, postID: m.id, me: me, isAdmin: isAdmin, names: memberNames)
        }
        .sheet(isPresented: $showEmoji) {
            EmojiPickerSheet { e in
                if let t = reactTarget {
                    reactTarget = nil
                    showEmoji = false
                    Task { await react(t, e) }
                } else {
                    draft += e
                }
            }
        }
        .sheet(isPresented: $showLocationSheet) {
            ShareLocationSheet { minutes in location.start(token: token, conversationID: chat.conversation_id, minutes: minutes) }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $picked, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showDocPicker, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result { Task { await sendDocument(url) } }
        }
        .confirmationDialog(Text(LocalizedStringKey(deleteTargets.count > 1 ? "chat.delete.many" : "chat.delete.one")),
                            isPresented: $showDelete, titleVisibility: .visible) {
            if !deleteTargets.isEmpty && deleteTargets.allSatisfy({ $0.sender_id == me }) {
                Button("chat.unsend", role: .destructive) { Task { await deleteSelected(everyone: true) } }
            }
            Button("chat.delete.me", role: .destructive) { Task { await deleteSelected(everyone: false) } }
        }
        .confirmationDialog(Text("mute.title"), isPresented: $showMute, titleVisibility: .visible) {
            Button("mute.8h") { Task { await mute(seconds: 8 * 3600) } }
            Button("mute.1d") { Task { await mute(seconds: 86400) } }
            Button("mute.1w") { Task { await mute(seconds: 7 * 86400) } }
            Button("mute.always") { Task { await mute(seconds: -1) } }
        }
        .confirmationDialog(Text(LocalizedStringKey(myRole == "owner" ? "group.owner.leave" : "group.leave.confirm")),
                            isPresented: $confirmLeave, titleVisibility: .visible) {
            if myRole != "owner" {
                Button("group.leave", role: .destructive) {
                    Task {
                        try? await APIClient.shared.removeGroupMember(token: token, id: chat.conversation_id, userID: "")
                        dismissView()
                    }
                }
            }
        }
        .confirmationDialog(Text("group.delete.confirm"), isPresented: $confirmDeleteGroup, titleVisibility: .visible) {
            Button("group.delete", role: .destructive) {
                Task {
                    _ = try? await APIClient.shared.postJSON("groups/\(chat.conversation_id)/delete", token: token, body: [:])
                    dismissView()
                }
            }
        }
        .sheet(item: Binding(get: { exportURL.map { ExportFile(url: $0) } }, set: { if $0 == nil { exportURL = nil } })) { f in
            ShareLink(item: f.url) { Label("group.export", systemImage: "square.and.arrow.up") }
                .padding(30)
                .presentationDetents([.height(160)])
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar) // full height for the conversation, like other messengers
        .task {
            if isGroup, let list = try? await APIClient.shared.groupMembers(token: token, groupID: chat.conversation_id) {
                members = list
                memberNames = Dictionary(list.map { ($0.user_id, $0.title) }, uniquingKeysWith: { a, _ in a })
            }
            await loadMeta()
            themeID = await ChatThemeStore.load(token: token, conversationID: chat.conversation_id)
        }
        .task { await loadNewest() }
        .onReceive(live.messages) { m in
            guard m.conversation_id == chat.conversation_id else { return }
            merge([m])
            pending.removeAll { $0.id == m.client_key }
            if !bottomVisible && m.sender_id != me { newWhileAway += 1 }
            if m.sender_id != me { Task { await markSeen() } }
        }
        .onReceive(live.changes) { id in
            guard id == chat.conversation_id else { return }
            Task { await loadNewest(quiet: true) }
        }
        .onChange(of: picked) { items in
            guard !items.isEmpty else { return }
            picked = []
            // review full screen first: a caption each, add / remove, HD (website MediaSendSheet)
            Task {
                let drafts = await MediaDrafts.load(items)
                if !drafts.isEmpty { reviewing = MediaBatch(items: drafts) }
            }
        }
        .fullScreenCover(item: $reviewing) { batch in
            MediaSendSheet(items: batch.items, title: chat.title) { drafts, hd in
                Task {
                    for d in drafts {
                        if let url = d.videoURL { await sendVideo(url, caption: d.caption) }
                        else if let img = d.image { await sendPhoto(img, caption: d.caption, hd: hd) }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraStudio(allowNote: true,
                         onPhoto: { img in Task { await sendPhoto(img) } },
                         onVideo: { url in Task { await sendVideo(url) } },
                         onNote: { Task { try? await Task.sleep(nanoseconds: 700_000_000); showNoteRecorder = true } },
                         onGallery: { Task { try? await Task.sleep(nanoseconds: 700_000_000); showPhotoPicker = true } })
        }
        .fullScreenCover(item: $viewing) { v in
            PhotoViewer(token: token, fileID: v.id)
        }
        .sheet(isPresented: $showUnlock) {
            UnlockSheet(token: token) { Task { await loadNewest() } }
                .presentationDetents([.large])
        }
        .fullScreenCover(item: $watching) { v in
            VideoScreen(token: token, fileID: v.id)
        }
        .onAppear {
            LocalNotifier.shared.openConversation = chat.conversation_id
            LocalNotifier.shared.clear(conversation: chat.conversation_id)
        }
        .onDisappear {
            if LocalNotifier.shared.openConversation == chat.conversation_id { LocalNotifier.shared.openConversation = nil }
            VoicePlayer.shared.stop()
            if recorder.recording { recorder.cancel() }
        }
        .alert(Text("chat.mic.denied"), isPresented: $recorder.denied) {
            Button("chat.settings") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
            Button("chat.close", role: .cancel) {}
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let r = replyingTo {
                HStack(spacing: 8) {
                    Capsule().fill(Theme.accent).frame(width: 3, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.sender_id == me ? NSLocalizedString("chat.you", comment: "") : chat.title)
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        Text(displayText(r)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { replyingTo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel(Text("chat.close"))
                }
                .padding(.horizontal, 6)
            }
            composerBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.header.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderStrong).frame(height: 1) }
    }

    /// The website's conversation header (.topbar): back, avatar with the online dot, name, status line, and the
    /// call / search / more buttons.
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismissView() } label: {
                Image(systemName: "chevron.backward").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 44)
            }
            .accessibilityLabel(Text("chat.back"))
            Button { showInfo = true } label: {
                HStack(spacing: 10) {
                    Avatar(token: token, userID: chat.peer_id, avatarID: chat.peer_avatar_id, title: chat.title,
                           groupID: isGroup ? chat.conversation_id : nil, size: 40,
                           online: isGroup ? nil : live.online.contains(chat.peer_id))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chat.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        HStack(spacing: 4) {
                            if !isGroup {
                                Circle().fill(live.online.contains(chat.peer_id) ? Theme.online : Theme.faint.opacity(0.6)).frame(width: 6, height: 6)
                            }
                            Text(subtitle ?? (isGroup ? String(format: NSLocalizedString("groups.members", comment: ""), memberCount)
                                                       : NSLocalizedString("chat.offline", comment: "")))
                                .font(.system(size: 13)).foregroundStyle(peerTypingUntil != nil ? Theme.accent : Theme.faint).lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.info")
            Spacer(minLength: 4)
            if calls.enabled && chat.conversation_id.hasPrefix("dm_") {
                Button { calls.start(conversationID: chat.conversation_id, peerName: chat.title, peerID: chat.peer_id) } label: {
                    Image(systemName: "phone").font(.system(size: 18)).foregroundStyle(Theme.muted).frame(width: 36, height: 44)
                }
                .disabled(calls.phase != .idle)
                .accessibilityLabel(Text("call.voice"))
            }
            Button { searchOpen.toggle(); searchText = "" } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(Theme.muted).frame(width: 34, height: 44)
            }
            .accessibilityLabel(Text("chat.search"))
            Menu {
                if isGroup { Button { showInfo = true } label: { Label("group.info", systemImage: "info.circle") } }
                if isGroup && focusDoc != nil { Button { showFocus = true } label: { Label("focus.title", systemImage: "scope") } }
                Button { showSchedule = true } label: { Label("chat.scheduled", systemImage: "clock") }
                if muted {
                    Button { Task { await mute(seconds: 0) } } label: { Label("chats.unmute", systemImage: "bell") }
                } else {
                    Button { showMute = true } label: { Label("chat.mute.menu", systemImage: "bell.slash") }
                }
                if isGroup {
                    Button { Task { await exportHistory() } } label: { Label("group.export", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { confirmLeave = true } label: { Label("group.leave", systemImage: "rectangle.portrait.and.arrow.right") }
                    if myRole == "owner" {
                        Button(role: .destructive) { confirmDeleteGroup = true } label: { Label("group.delete", systemImage: "trash") }
                    }
                } else {
                    Button(role: .destructive) { confirmBlock = true } label: {
                        Label(String(format: NSLocalizedString("chat.block.name", comment: ""), chat.title), systemImage: "hand.raised.fill")
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 36, height: 44)
            }
            .accessibilityLabel(Text("chat.more"))
        }
        .padding(.horizontal, 10)
        .frame(height: 60)
        .background(Theme.header.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderStrong).frame(height: 1) }
    }

    static let quickEmoji = ["😀", "😂", "😍", "🥰", "😎", "🤔", "😢", "😡", "👍", "👏", "🙏", "🔥", "❤️", "💯", "🎉", "📈", "📉", "💰", "✅", "👋"]

    private var composerBar: some View {
        Group {
            if recorder.recording && !holdRec {
                RecordingBar(recorder: recorder, onCancel: { recorder.cancel() }, onSend: { Task { await sendVoice() } })
            } else {
                typingBar
            }
        }
    }

    private var draftIsEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var mentionQuery: String? {
        guard isGroup, let at = draft.lastIndex(of: "@") else { return nil }
        let after = draft[draft.index(after: at)...]
        if after.contains(" ") || after.contains("\n") { return nil }
        if at != draft.startIndex, !(draft[draft.index(before: at)].isWhitespace) { return nil }
        return String(after).lowercased()
    }

    private var mentionMatches: [GroupMember] {
        guard let q = mentionQuery else { return [] }
        return Array(members.filter { $0.user_id != me && (q.isEmpty || $0.username.lowercased().hasPrefix(q) || $0.title.lowercased().hasPrefix(q)) }.prefix(6))
    }

    private var typingBar: some View {
        VStack(spacing: 6) {
            if !mentionMatches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("chat.mention").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.faint).padding(.horizontal, 12).padding(.top, 8)
                    ForEach(mentionMatches) { m in
                        Button {
                            if let at = draft.lastIndex(of: "@") { draft = String(draft[..<at]) + "@" + m.username + " " }
                        } label: {
                            HStack(spacing: 8) {
                                Avatar(token: token, userID: m.user_id, avatarID: nil, title: m.title, size: 28)
                                Text(m.title).foregroundStyle(Theme.text)
                                Text("@" + m.username).font(.system(size: 12)).foregroundStyle(Theme.faint)
                                Spacer()
                                if let r = roleOf(m.user_id) { Text(LocalizedStringKey("group.role." + r)).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderStrong, lineWidth: 1))
            }
            HStack(alignment: .center, spacing: 8) {
                if holdRec {
                    holdStrip
                } else {
                Menu {
                    if isGroup {
                        Button { showPoll = true } label: { Label("poll.new", systemImage: "chart.bar") }
                        if groupCanSignals { Button { showSignal = true } label: { Label("signal.new", systemImage: "chart.line.uptrend.xyaxis") } }
                    }
                    if !isGroup || groupCanSendMedia {
                        Button { showPhotoPicker = true } label: { Label("attach.photo", systemImage: "photo.on.rectangle") }
                        Button { showDocPicker = true } label: { Label("attach.document", systemImage: "doc") }
                    }
                    Button { showLocationSheet = true } label: { Label("location.live", systemImage: "location") }
                    if CameraPicker.isAvailable && (!isGroup || groupCanSendMedia) {
                        Button { showNoteRecorder = true } label: { Label("note.record", systemImage: "video.circle") }
                    }
                    Button { showSchedule = true } label: { Label("schedule.title", systemImage: "clock") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.text)
                        .frame(width: 40, height: 40).background(Theme.inputGradient, in: Circle())
                        .overlay(Circle().stroke(Theme.hex(0x1C8CB2, 0.85), lineWidth: 1.5))
                }
                .accessibilityLabel(Text("attach.title"))
                HStack(alignment: .center, spacing: 0) {
                    if !isGroup || groupCanSendMedia {
                        Button { showDocPicker = true } label: { composerIcon("paperclip") }
                            .accessibilityLabel(Text("attach.document"))
                    }
                    Button { showLocationSheet = true } label: { composerIcon("mappin.and.ellipse") }
                        .accessibilityLabel(Text("location.share"))
                    TextField(LocalizedStringKey(isGroup ? "chat.placeholder.group" : "chat.placeholder"), text: $draft, axis: .vertical)
                        .onChange(of: draft) { v in
                            guard !v.isEmpty, Date().timeIntervalSince(lastTypingSent) > 3 else { return }
                            lastTypingSent = Date()
                            live.sendTyping(conversationID: chat.conversation_id)
                        }
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier("chat.composer")
                    Button { reactTarget = nil; showEmoji = true } label: { composerIcon("face.smiling") }
                        .accessibilityLabel(Text("chat.emoji"))
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 48)
                .background(Theme.inputGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(composerFocused ? Theme.borderActive : Theme.hex(0x1C8CB2, 0.85), lineWidth: 1.5))
                .shadow(color: Theme.hex(0x00BEDC, 0.12), radius: 6)
                if draftIsEmpty && CameraPicker.isAvailable && (!isGroup || groupCanSendMedia) {
                    Button { showCamera = true } label: { composerIcon("camera") }
                        .accessibilityLabel(Text("chat.camera"))
                }
                }
                if draftIsEmpty {
                    micButton
                } else {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.hex(0xF4FBFD))
                    .frame(width: 48, height: 48)
                    .background(Theme.sendGradient, in: Circle())
                    .shadow(color: Theme.hex(0x00C8DC, 0.28), radius: 9, y: 4)
                    .contentShape(Circle())
                    .onTapGesture {
                        if draftIsEmpty {
                            VoicePlayer.shared.stop()
                            Task { await recorder.start() }
                        } else {
                            Task { await sendDraft() }
                        }
                    }
                    .onLongPressGesture(minimumDuration: 0.45) {
                        // hold Send = schedule (the website's "hold or right-click to schedule")
                        if !draftIsEmpty { showSchedule = true }
                    }
                    .accessibilityLabel(Text(draftIsEmpty ? "chat.voice.record" : "chat.send"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier(draftIsEmpty ? "chat.mic" : "chat.send")
                }
            }
        }
    }

    private var holdStrip: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 9, height: 9)
                .opacity(Int(recorder.elapsed * 2) % 2 == 0 ? 1 : 0.3)
            Text(VoiceBubble.length(Int64(recorder.elapsed * 1000))).monospacedDigit().foregroundStyle(Theme.text)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("chat.voice.slide")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.muted)
            .opacity(max(0.25, 1 + Double(holdDrag.width) / 140))
            .offset(x: max(-80, holdDrag.width * 0.6))
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(Theme.inputGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.red.opacity(0.6), lineWidth: 1.5))
    }

    private var micButton: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Theme.hex(0xF4FBFD))
            .frame(width: 48, height: 48)
            .background(holdRec ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.sendGradient), in: Circle())
            .shadow(color: Theme.hex(0x00C8DC, 0.28), radius: 9, y: 4)
            .scaleEffect(holdRec ? 1.35 : 1)
            .offset(x: holdRec ? max(-60, holdDrag.width * 0.4) : 0, y: holdRec ? max(-60, holdDrag.height * 0.4) : 0)
            .overlay(alignment: .top) {
                if holdRec {
                    VStack(spacing: 4) {
                        Image(systemName: holdDrag.height < -50 ? "lock.fill" : "lock.open")
                        Image(systemName: "chevron.up")
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.vertical, 10).padding(.horizontal, 8)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
                    .offset(y: -96)
                    .accessibilityLabel(Text("chat.voice.lock"))
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: holdRec)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !micPressed {
                            micPressed = true
                            holdReleased = false
                            holdDrag = .zero
                            VoicePlayer.shared.stop()
                            Task {
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                guard micPressed, !holdReleased else { return }
                                holdRec = true
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                await recorder.start()
                                // released (or cancelled) while the microphone was starting
                                if holdReleased || !holdRec { recorder.cancel(); holdRec = false }
                            }
                            return
                        }
                        guard holdRec else { return }
                        holdDrag = CGSize(width: min(0, v.translation.width), height: min(0, v.translation.height))
                        if holdDrag.width < -120 {
                            // slide left: cancel
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            recorder.cancel()
                            endHold()
                        } else if holdDrag.height < -90 {
                            // slide up: lock, keep recording hands free (the bar with delete / send)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            endHold()
                        }
                    }
                    .onEnded { _ in
                        guard micPressed else { return }
                        micPressed = false
                        if holdReleased { return } // already cancelled or locked while dragging
                        let wasHolding = holdRec
                        holdReleased = true
                        if wasHolding {
                            let long = recorder.elapsed >= 0.6
                            holdRec = false
                            holdDrag = .zero
                            if recorder.recording {
                                if long { Task { await sendVoice() } } else { recorder.cancel(); flash("chat.voice.hold") }
                            }
                        } else {
                            // a quick tap: record hands free (stop with the bar's send / delete)
                            Task { await recorder.start() }
                        }
                    }
            )
            .accessibilityLabel(Text("chat.voice.record"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { Task { await recorder.start() } }
            .accessibilityIdentifier("chat.mic")
    }

    /// Leaves hold mode without touching the recording (cancelled or locked by the caller).
    private func endHold() {
        holdRec = false
        holdDrag = .zero
        holdReleased = true
    }

    // MARK: web parity helpers

    private var selectHead: some View {
        HStack(spacing: 12) {
            Button { selecting = false; selected = [] } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 36, height: 44)
            }
            .accessibilityLabel(Text("select.cancel"))
            Text(String(format: NSLocalizedString("select.count", comment: ""), selected.count))
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            Button {
                if selected.count == messages.filter({ !$0.isDeleted }).count { selected = [] }
                else { selected = Set(messages.filter { !$0.isDeleted }.map(\.id)) }
            } label: {
                Text(LocalizedStringKey(selected.count == messages.filter({ !$0.isDeleted }).count ? "select.clear" : "select.all"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
        .background(Theme.header.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderStrong).frame(height: 1) }
    }

    private var selectBar: some View {
        let chosen = messages.filter { selected.contains($0.id) }
        let canCopy = chosen.contains { $0.kind == "text" && !$0.isDeleted }
        return HStack {
            Button {
                if let first = chosen.first { forwarding = first }
                selecting = false
            } label: { Label("chat.forward", systemImage: "arrowshape.turn.up.right") }
            .disabled(chosen.isEmpty || restricted)
            Spacer()
            Button {
                UIPasteboard.general.string = chosen.filter { $0.kind == "text" }.map(\.body).joined(separator: "\n")
                selecting = false
                selected = []
                flash("chat.copied")
            } label: { Label("chat.copy", systemImage: "doc.on.doc") }
            .disabled(!canCopy || restricted)
            Spacer()
            Button(role: .destructive) {
                deleteTargets = chosen
                showDelete = true
            } label: { Label("chat.delete", systemImage: "trash") }
            .disabled(chosen.isEmpty)
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(Theme.header.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderStrong).frame(height: 1) }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            SearchPill(placeholder: LocalizedStringKey(String(format: NSLocalizedString("chat.search.in", comment: ""), chat.title)), text: $searchText)
            Text(searchHits.isEmpty ? "0/0" : "\(searchIndex + 1)/\(searchHits.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.faint)
            Button { if searchIndex > 0 { searchIndex -= 1 } } label: { Image(systemName: "chevron.up") }
                .disabled(searchIndex <= 0).accessibilityLabel(Text("search.prev"))
            Button { if searchIndex < searchHits.count - 1 { searchIndex += 1 } } label: { Image(systemName: "chevron.down") }
                .disabled(searchIndex >= searchHits.count - 1).accessibilityLabel(Text("search.next"))
            Button { searchOpen = false; searchText = "" } label: { Image(systemName: "xmark") }
                .accessibilityLabel(Text("search.close"))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.header)
    }

    private var pinnedBar: some View {
        let p = pins[min(pinIndex, pins.count - 1)]
        return Button {
            pinIndex = (pinIndex + 1) % max(pins.count, 1)
            if let m = messages.first(where: { $0.id == p.message_id }) { searchText = ""; jumpTarget = m.id }
        } label: {
            HStack(spacing: 10) {
                Rectangle().fill(Theme.accent).frame(width: 3, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pins.count > 1 ? String(format: NSLocalizedString("pin.n.of", comment: ""), pinIndex + 1, pins.count)
                                        : NSLocalizedString("pin.one", comment: ""))
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                    Text(p.text.isEmpty ? NSLocalizedString("pin." + p.kind, comment: "") : p.text)
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                Image(systemName: "pin.fill").foregroundStyle(Theme.accent).rotationEffect(.degrees(45))
            }
            .padding(.horizontal, 14).frame(height: 50)
            .background(Theme.header)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderStrong).frame(height: 1) }
        }
        .buttonStyle(.plain)
    }

    private func roleOf(_ userID: String) -> String? {
        memberRoles[userID]
    }

    private func flash(_ key: String) {
        toast = NSLocalizedString(key, comment: "")
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            toast = nil
        }
    }

    private func loadMeta() async {
        if isGroup {
            let g = await APIClient.shared.chGroupRole(token: token, groupID: chat.conversation_id)
            myRole = g.role
            groupCanSendMedia = g.canSendMedia
            groupCanSignals = g.canPostSignals
            groupComments = g.comments
            memberCount = g.memberCount
            pins = await APIClient.shared.chGroupPins(token: token, groupID: chat.conversation_id)
            if let full = try? await APIClient.shared.list(GroupMemberFull.self, "groups/\(chat.conversation_id)/members", token: token) {
                memberRoles = Dictionary(full.filter { $0.role != "member" }.map { ($0.user_id, $0.role) }, uniquingKeysWith: { a, _ in a })
            }
            if let doc = try? await APIClient.shared.getFocus(token: token, groupID: chat.conversation_id) {
                focusDoc = doc
                await loadFocusPages()
            }
        } else if let st = try? await APIClient.shared.chatSettings(token: token, conversationID: chat.conversation_id) {
            restricted = st.restricted
        }
        if let prefs = try? await APIClient.shared.prefs(token: token), let mine = prefs.first(where: { $0.conversation_id == chat.conversation_id }) {
            muted = mine.muted
        }
    }

    private func loadFocusPages() async {
        guard let f = focusDoc?.focus, f.active else { focusPages = []; return }
        focusPages = await APIClient.shared.focusPage(token: token, groupID: chat.conversation_id, limit: 200)
    }

    private func setPin(_ m: Message, _ on: Bool) async {
        do {
            try await APIClient.shared.chPin(token: token, groupID: chat.conversation_id, messageID: m.id, pin: on)
            pins = await APIClient.shared.chGroupPins(token: token, groupID: chat.conversation_id)
        } catch { flash("chat.action.failed") }
    }

    /// seconds: > 0 mute for that long, -1 always, 0 unmute.
    private func mute(seconds: Int) async {
        do {
            if seconds == 0 { try await APIClient.shared.setPrefs(token: token, conversationID: chat.conversation_id, unmute: true) }
            else if seconds < 0 { try await APIClient.shared.setPrefs(token: token, conversationID: chat.conversation_id, muteForever: true) }
            else { try await APIClient.shared.setPrefs(token: token, conversationID: chat.conversation_id, muteSeconds: seconds) }
            muted = seconds != 0
        } catch { flash("chat.action.failed") }
    }

    private func deleteSelected(everyone: Bool) async {
        let ids = deleteTargets.map(\.id)
        deleteTargets = []
        selecting = false
        selected = []
        do {
            if everyone {
                try await APIClient.shared.chDeleteBatch(token: token, ids: ids)
                await loadNewest(quiet: true)
            } else {
                try await APIClient.shared.chHideBatch(token: token, ids: ids)
                messages.removeAll { ids.contains($0.id) }
            }
        } catch { flash("chat.action.failed") }
    }

    private func sendDocument(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { flash("chat.action.failed"); return }
        if data.count > 25_000_000 { flash("attach.too.big"); return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        do {
            let m = try await APIClient.shared.chSendDocument(token: token, conversationID: chat.conversation_id, data: data,
                                                             fileName: url.lastPathComponent, mime: mime, caption: "", key: UUID().uuidString.lowercased())
            merge([m])
        } catch APIError.refused(let why) {
            toast = why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why
        } catch { flash("chat.action.failed") }
    }

    /// Export Chat History: every page as plain text, shared as a .txt file.
    private func exportHistory() async {
        var all: [Message] = messages
        var before = messages.first?.seq
        while let b = before, let page = try? await APIClient.shared.messages(token: token, conversationID: chat.conversation_id, before: b, limit: 200), !page.isEmpty {
            all = page + all
            before = page.first?.seq
            if page.count < 200 { break }
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let lines = all.map { m in "[\(m.date.map { f.string(from: $0) } ?? "")] \(memberNames[m.sender_id] ?? (m.sender_id == me ? "Me" : m.sender_id)): \(displayText(m))" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(chat.title)-chat.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        exportURL = url
    }

    private func composerIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 19)).foregroundStyle(Theme.muted).frame(width: 34, height: 40)
    }

    // MARK: loading

    private func loadNewest(quiet: Bool = false) async {
        if !quiet { loading = true }
        defer { loading = false }
        do {
            let page = try await APIClient.shared.messages(token: token, conversationID: chat.conversation_id, limit: pageSize)
            if messages.isEmpty { reachedStart = page.count < pageSize }
            merge(page)
            problem = nil
            locked = false
            await markSeen()
        } catch APIError.badCredentials {
            store.sessionExpired()
        } catch APIError.locked {
            locked = true
            if !showUnlock && BiometricPIN.isSaved { showUnlock = true } // Face ID straight away
        } catch {
            if messages.isEmpty { problem = NSLocalizedString("chats.error", comment: "") }
        }
    }

    private func loadOlder() async {
        guard !loadingOlder, let first = messages.first else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        if let page = try? await APIClient.shared.messages(token: token, conversationID: chat.conversation_id,
                                                           before: first.seq, limit: pageSize) {
            reachedStart = page.count < pageSize
            merge(page)
        }
    }

    /// Adds or replaces by id, kept in server order (seq).
    private func merge(_ incoming: [Message]) {
        guard !incoming.isEmpty else { return }
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for m in incoming { byID[m.id] = m }
        let now = Int64(Date().timeIntervalSince1970)
        // disappearing messages leave once their time is up (the server erases them too)
        let next = byID.values.filter { ($0.expires_at ?? 0) == 0 || ($0.expires_at ?? 0) > now }.sorted { $0.seq < $1.seq }
        if next != messages { messages = next }
    }

    // MARK: sending

    private func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        var p = PendingMessage(id: UUID().uuidString.lowercased(), body: text, date: Date())
        p.replyTo = replyingTo?.id ?? ""
        replyingTo = nil
        pending.append(p)
        await deliver(p)
    }

    // MARK: message actions

    @ViewBuilder private func messageContent(_ m: Message) -> some View {
        if m.kind == "poll" && !m.isDeleted {
            PollCard(message: m, me: me, canVote: canSend) { opts in
                Task {
                    if let updated = try? await APIClient.shared.chVote(token: token, messageID: m.id, options: opts) { merge([updated]) }
                }
            }
            .frame(maxWidth: .infinity, alignment: m.sender_id == me ? .trailing : .leading)
        } else if let sig = SignalInfo(m), !m.isDeleted {
            SignalCard(info: sig).frame(maxWidth: .infinity, alignment: m.sender_id == me ? .trailing : .leading)
        } else if m.kind == "call" {
            CallEntryRow(message: m, me: me, onCallBack: calls.enabled && !isGroup ? {
                calls.start(conversationID: chat.conversation_id, peerName: chat.title, peerID: chat.peer_id)
            } : nil)
        } else if m.kind == "text", !m.isDeleted, let url = LinkPreviewCard.firstURL(in: m.body) {
            VStack(alignment: m.sender_id == me ? .trailing : .leading, spacing: 4) {
                Bubble(text: displayText(m), mine: m.sender_id == me, date: m.date,
                       state: m.sender_id == me ? receipt(m) : nil, faded: false)
                LinkPreviewCard(token: token, url: url)
            }
            .frame(maxWidth: .infinity, alignment: m.sender_id == me ? .trailing : .leading)
        } else if m.kind == "notice" {
            Text(noticeText(m)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 5).background(Theme.surface, in: Capsule())
                .frame(maxWidth: .infinity)
        } else if m.kind == "location", !m.isDeleted {
            LocationCard(token: token, message: m, mine: m.sender_id == me)
        } else if VideoNotePrep.isNote(m), let fid = m.file_id, !m.isDeleted {
            VideoNoteBubble(token: token, message: m, mine: m.sender_id == me) { watching = ViewedPhoto(id: fid) }
        } else if m.kind == "voice", m.audio_id != nil, !m.isDeleted {
            VoiceBubble(token: token, message: m, mine: m.sender_id == me, state: m.sender_id == me ? receipt(m) : nil)
        } else if m.kind == "file", let fid = m.file_id, (m.file_mime ?? "").hasPrefix("video/"), !m.isDeleted {
            VideoBubble(token: token, message: m, mine: m.sender_id == me, state: m.sender_id == me ? receipt(m) : nil) {
                watching = ViewedPhoto(id: fid)
            }
        } else if m.kind == "image", let fid = m.file_id, !m.isDeleted {
            PhotoBubble(mine: m.sender_id == me, date: m.date, state: m.sender_id == me ? receipt(m) : nil, caption: m.body) {
                RemoteImage(token: token, fileID: fid)
            }
            .onTapGesture { viewing = ViewedPhoto(id: fid) }
        } else if m.kind == "file", m.file_id != nil, !m.isDeleted {
            FileBubble(message: m, mine: m.sender_id == me, state: m.sender_id == me ? receipt(m) : nil) {
                Task { await openDocument(m) }
            }
        } else {
            Bubble(text: displayText(m), mine: m.sender_id == me, date: m.date,
                   state: m.sender_id == me ? receipt(m) : nil, faded: m.isDeleted)
        }
    }

    private func openDocument(_ m: Message) async {
        guard let fid = m.file_id, !openingDoc else { return }
        openingDoc = true
        defer { openingDoc = false }
        flash("file.opening")
        if let url = await MediaSaver.localFile(token: token, fileID: fid, name: m.file_name) { openDoc = LocalDoc(url: url) } else { flash("file.failed") }
    }

    /// Save As...: photos and videos go to Photos; documents open in Quick Look (Save to Files / share from there).
    private func saveAttachment(_ m: Message) async {
        guard let fid = m.file_id else { return }
        let video = (m.file_mime ?? "").hasPrefix("video/") || VideoNotePrep.isNote(m)
        if m.kind == "image" || video {
            let r = await MediaSaver.saveToPhotos(token: token, fileID: fid, video: video)
            flash(r == .saved ? "media.saved" : (r == .denied ? "media.denied" : "media.failed"))
        } else {
            await openDocument(m)
        }
    }

    /// Read receipts: a private chat marks everything read; a group records the newest seq I have seen.
    private func markSeen() async {
        if isGroup {
            if let last = messages.last { await APIClient.shared.markGroupRead(token: token, groupID: chat.conversation_id, seq: last.seq) }
        } else {
            await APIClient.shared.markRead(token: token, conversationID: chat.conversation_id)
        }
    }

    private func react(_ m: Message, _ emoji: String) async {
        if let updated = try? await APIClient.shared.react(token: token, messageID: m.id, emoji: emoji) { merge([updated]) }
    }

    private func delete(_ m: Message, everyone: Bool) async {
        do {
            if everyone {
                merge([try await APIClient.shared.deleteMessage(token: token, messageID: m.id)])
            } else {
                try await APIClient.shared.hideMessage(token: token, messageID: m.id)
                messages.removeAll { $0.id == m.id }
            }
        } catch {
            problem = NSLocalizedString("chat.action.failed", comment: "")
        }
    }

    private var subtitle: String? {
        if let until = peerTypingUntil, until > Date() { return NSLocalizedString("chat.typing", comment: "") }
        if live.online.contains(chat.peer_id) { return NSLocalizedString("chat.online", comment: "") }
        return nil
    }

    private func sendVoice() async {
        guard let rec = recorder.finish() else { return }
        let p = PendingMessage(id: UUID().uuidString.lowercased(), body: "", date: Date(),
                               audio: rec.data, durationMs: rec.durationMs, waveform: rec.waveform)
        pending.append(p)
        await deliver(p)
    }

    private func sendVideoNote(_ url: URL) async {
        let key = UUID().uuidString.lowercased()
        pending.append(PendingMessage(id: key, body: "", date: Date(), video: Data()))
        guard let out = await VideoNotePrep.square(from: url) else {
            if let i = pending.firstIndex(where: { $0.id == key }) { pending[i].failed = true }
            return
        }
        do {
            let m = try await APIClient.shared.sendImage(token: token, conversationID: chat.conversation_id, jpeg: out.data,
                                                         caption: "", key: key, fileName: VideoNotePrep.fileName(ms: out.ms),
                                                         mime: "video/mp4")
            merge([m])
            pending.removeAll { $0.id == key }
        } catch {
            if let i = pending.firstIndex(where: { $0.id == key }) { pending[i].failed = true }
        }
    }

    /// "notice" messages: chat setting changes (disappearing messages, restricted chat), shown centred.
    private func noticeText(_ m: Message) -> String {
        guard let s = m.signal, let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return m.body }
        if (o["event"] as? String) == "disappearing" {
            let secs = (o["secs"] as? Int) ?? 0
            return secs == 0 ? NSLocalizedString("notice.disappear.off", comment: "")
                : String(format: NSLocalizedString("notice.disappear.on", comment: ""),
                         NSLocalizedString(ContactInfoView.timerKey(secs), comment: ""))
        }
        return m.body.isEmpty ? NSLocalizedString("notice.changed", comment: "") : m.body
    }

    private func sendVideo(_ url: URL, caption: String = "") async {
        let key = UUID().uuidString.lowercased()
        let placeholder = PendingMessage(id: key, body: caption.trimmingCharacters(in: .whitespacesAndNewlines), date: Date(), video: Data())
        pending.append(placeholder) // shows "sending video" while it is re-encoded
        guard let out = await VideoPrep.mp4(from: url) else {
            if let i = pending.firstIndex(where: { $0.id == key }) { pending[i].failed = true }
            problem = NSLocalizedString("chat.video.toolarge", comment: "")
            return
        }
        if let i = pending.firstIndex(where: { $0.id == key }) { pending[i].video = out.data }
        if let p = pending.first(where: { $0.id == key }) { await deliver(p) }
    }

    private func sendPhoto(_ img: UIImage, caption: String = "", hd: Bool = false) async {
        // Encoding a 12 MP photo takes a moment: off the main thread.
        let encoded = await Task.detached(priority: .userInitiated) { ImagePrep.jpeg(from: img, hd: hd) }.value
        guard let jpeg = encoded else { return }
        let preview = UIImage(data: jpeg) ?? img
        let p = PendingMessage(id: UUID().uuidString.lowercased(), body: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                               date: Date(), image: preview, jpeg: jpeg)
        pending.append(p)
        await deliver(p)
    }

    /// Same idempotency key on every retry, so a message that did reach the server is never stored twice.
    private func deliver(_ p: PendingMessage) async {
        if let v = p.video, v.isEmpty { return } // still being re-encoded, or the re-encode failed
        if let i = pending.firstIndex(where: { $0.id == p.id }) { pending[i].failed = false }
        do {
            let m: Message
            if let audio = p.audio, let ms = p.durationMs {
                m = try await APIClient.shared.sendVoice(token: token, conversationID: chat.conversation_id, audio: audio,
                                                         durationMs: ms, waveform: p.waveform, key: p.id)
            } else if let video = p.video, !video.isEmpty {
                m = try await APIClient.shared.sendImage(token: token, conversationID: chat.conversation_id, jpeg: video,
                                                         caption: p.body, key: p.id, fileName: "video.mp4", mime: "video/mp4")
            } else if let jpeg = p.jpeg {
                m = try await APIClient.shared.sendImage(token: token, conversationID: chat.conversation_id,
                                                         jpeg: jpeg, caption: p.body, key: p.id)
            } else {
                m = try await APIClient.shared.sendText(token: token, conversationID: chat.conversation_id,
                                                        body: p.body, key: p.id, replyTo: p.replyTo)
            }
            merge([m])
            pending.removeAll { $0.id == p.id }
        } catch APIError.badCredentials {
            store.sessionExpired()
        } catch {
            if let i = pending.firstIndex(where: { $0.id == p.id }) { pending[i].failed = true }
            if case let .refused(why)? = error as? APIError, !why.isEmpty { problem = why }
        }
    }

    // MARK: display

    private func displayText(_ m: Message) -> String {
        if m.isDeleted { return NSLocalizedString("chat.deleted", comment: "") }
        switch m.kind {
        case "text": return m.body
        case "voice": return "🎤 " + NSLocalizedString("chats.kind.voice", comment: "")
        case "image": return "🖼 " + NSLocalizedString("chats.kind.image", comment: "")
        case "file": return "📎 " + (m.file_name ?? NSLocalizedString("chats.kind.file", comment: ""))
        default: return m.body.isEmpty ? NSLocalizedString("chat.unsupported", comment: "") : m.body
        }
    }

    private func receipt(_ m: Message) -> Bubble.Delivery {
        if (m.read_at ?? 0) > 0 { return .read }
        if (m.delivered_at ?? 0) > 0 { return .delivered }
        return .sent
    }

    private func sameDay(_ a: Message, _ b: Message) -> Bool {
        guard let x = a.date, let y = b.date else { return true }
        return Calendar.current.isDate(x, inSameDayAs: y)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

struct PendingMessage: Identifiable, Equatable {
    let id: String // also the idempotency key
    let body: String
    let date: Date
    var image: UIImage? = nil
    var jpeg: Data? = nil
    var audio: Data? = nil
    var video: Data? = nil
    var replyTo = ""
    var durationMs: Int? = nil
    var waveform: [Double] = []
    var failed = false
}

struct ViewedPhoto: Identifiable {
    let id: String // the file id
}

/// A photo message: the picture (rounded square), an optional caption, time and ticks.
struct PhotoBubble<Content: View>: View {
    let mine: Bool
    let date: Date?
    let state: Bubble.Delivery?
    let caption: String
    @ViewBuilder let content: () -> Content

    private static var time: DateFormatter {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: .trailing, spacing: 4) {
                content()
                    .frame(width: 240, height: 240)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                if !caption.isEmpty {
                    Text(caption)
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: 240, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    if let date { Text(Self.time.string(from: date)) }
                    if let state { Bubble.tickView(state) }
                }
                .font(.caption2)
                .foregroundStyle(Theme.muted.opacity(0.85))
                .padding(.trailing, 4)
            }
            .padding(4)
            .tfBubble(mine: mine)
            if !mine { Spacer(minLength: 48) }
        }
    }
}

private struct DayDivider: View {
    let date: Date?
    private static let f: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        if let date {
            Text(DayLabel.text(date))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.surface, in: Capsule())
                .padding(.vertical, 6)
        }
    }
}

struct Bubble: View {
    enum Delivery { case sending, sent, delivered, read, failed }

    let text: String
    let mine: Bool
    let date: Date?
    let state: Delivery?
    let faded: Bool

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: .trailing, spacing: 3) {
                Text(text)
                    .font(.body)
                    .italic(faded)
                    .foregroundStyle(Theme.text)
                    .opacity(faded ? 0.7 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 4) {
                    if let date { Text(Self.time.string(from: date)) }
                    if let state { tick(state) }
                }
                .font(.caption2)
                .foregroundStyle(Theme.muted.opacity(0.85))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .tfBubble(mine: mine)
            .fixedSize(horizontal: false, vertical: true)
            if !mine { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder private func tick(_ s: Delivery) -> some View { Self.tickView(s) }

    @ViewBuilder static func tickView(_ s: Delivery) -> some View {
        switch s {
        case .sending: Image(systemName: "clock")
        case .sent: Image(systemName: "checkmark")
        case .delivered: Image(systemName: "checkmark.circle")
        case .read: Image(systemName: "checkmark.circle.fill")
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}


struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
