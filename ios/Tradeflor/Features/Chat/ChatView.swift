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
    /// Messages from others that came while I was up in the history, not yet scrolled into view (website d454d16).
    @State private var unseenBelow: [String] = []
    /// Of those, the ones that mention me: the "@" button above the arrow (groups).
    @State private var unseenMentions: [String] = []
    @State private var badgePop = false
    @State private var editing: Message?
    /// Photos and videos being sent: X cancels (website bcfeb0a).
    @State private var uploads: [String: Task<Message, Error>] = [:]
    @State private var cancelledUploads: Set<String> = []
    @State private var typingUser: String?
    /// Refreshed each minute, so "today" becomes "yesterday" at midnight.
    @State private var presenceNow = Date()
    @State private var unreadMarkID: String?
    @State private var unreadMarkCount = 0
    @State private var unreadMarkSet = false
    @State private var openedAtEnd = false
    /// "Select all" took the whole chat (every older page loaded first): Delete then also takes the call entries (web b9833d1).
    @State private var allPicked = false
    @State private var pickingAll = false
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
    @State private var pinsHidden = false
    @State private var outboxLoaded = false
    @State private var silentPost = false
    @State private var profileFor: MemberProfileRef?
    @State private var memberAvatars: [String: String] = [:]
    @State private var joinWaiting = 0
    /// Members whose names look like another member's (website nameSkeleton.ts).
    private var lookAlike: Set<String> { NameSkeleton.lookAlikeIDs(members) }
    @State private var groupStatus: StatusGroup?
    @State private var watchingGroupStatus = false
    @State private var addingGroupStatus = false
    @Environment(\.scenePhase) private var scenePhase
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
            if isGroup && !pins.isEmpty && !selecting && !pinsHidden { pinnedBar }
            if isGroup && isAdmin && joinWaiting > 0 && !selecting {
                Button { showInfo = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.plus").foregroundStyle(Theme.accent)
                        Text(joinWaiting == 1 ? NSLocalizedString("join.waiting.one", comment: "")
                             : String(format: NSLocalizedString("join.waiting.n", comment: ""), joinWaiting))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("· ").foregroundStyle(Theme.faint)
                        Text("join.review").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                        Spacer()
                    }
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(barColor)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderStrong).frame(height: 1) }
                }
                .buttonStyle(.plain)
            }
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
                        let lookIDs = lookAlike
                        let albums = Albums.runs(rows)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                            if i == 0 || !sameDay(rows[i - 1], m) {
                                DayDivider(date: m.date)
                            }
                            if m.id == unreadMarkID && unreadMarkCount > 0 {
                                UnreadDivider(count: unreadMarkCount).id("unread-mark")
                            }
                            if albums.hidden.contains(m.id) {
                                // drawn inside its album
                                Color.clear.frame(height: 0).id(m.id).onAppear { seen(m.id) }
                            } else {
                            let asGroup = isGroup && roleOf(m.sender_id) == "owner"
                            MessageRow(message: m, mine: m.sender_id == me, myID: me, peerName: chat.title,
                                       senderName: isGroup && (m.sender_id != me || asGroup)
                                           && (i == 0 || rows[i - 1].sender_id != m.sender_id)
                                           ? (asGroup ? chat.title : (memberNames[m.sender_id] ?? "")) : nil,
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
                                           roleTag: isGroup ? roleOf(m.sender_id) : nil,
                                           asGroup: asGroup,
                                           senderAvatar: isGroup && !asGroup && m.sender_id != me && (i == 0 || rows[i - 1].sender_id != m.sender_id)
                                               ? AnyView(Avatar(token: token, userID: m.sender_id, avatarID: memberAvatars[m.sender_id], title: memberNames[m.sender_id] ?? "?", size: 34))
                                               : nil,
                                           avatarSlot: isGroup && !asGroup,
                                           handle: lookIDs.contains(m.sender_id) ? members.first { $0.user_id == m.sender_id }?.username : nil,
                                           replySenderName: isGroup ? m.reply_sender_id.flatMap { memberNames[$0] } : nil,
                                           replyPhotoID: m.reply_to_id.flatMap { rid in messages.first { $0.id == rid && $0.kind == "image" && !$0.isDeleted }?.file_id },
                                           token: token),
                                       actions: MessageRowActions(
                                           copyLink: {
                                               UIPasteboard.general.string = "tradeflor://chat/\(chat.conversation_id)/message/\(m.id)"
                                               flash("chat.link.copied")
                                           },
                                           select: { selecting = true; selected = [m.id] },
                                           toggleSelect: {
                                               guard m.kind != "call" else { return } // a call entry goes with "Select all" only
                                               if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
                                               allPicked = false
                                           },
                                           pin: { on in Task { await setPin(m, on) } },
                                           report: { flash("chat.report.soon") },
                                           moreReactions: { reactTarget = m; showEmoji = true },
                                           comments: { commentsFor = m },
                                           save: m.file_id == nil ? nil : { Task { await saveAttachment(m) } },
                                           openSender: !isGroup || asGroup || m.sender_id == me ? nil : {
                                               if let u = members.first(where: { $0.user_id == m.sender_id }) {
                                                   profileFor = MemberProfileRef(userID: u.user_id, username: u.username)
                                               }
                                           },
                                           openReply: m.reply_to_id == nil ? nil : {
                                               if let id = m.reply_to_id, messages.contains(where: { $0.id == id }) {
                                                   searchText = ""
                                                   jumpTarget = id
                                               } else {
                                                   flash("chat.reply.notloaded")
                                               }
                                           },
                                           edit: canEdit(m) ? { startEdit(m) } : nil)) {
                                if let album = albums.at[m.id] {
                                    AlbumGrid(token: token, photos: album, mine: m.sender_id == me,
                                              state: m.sender_id == me ? receipt(album.last ?? m) : nil) { fid in viewing = ViewedPhoto(id: fid) }
                                } else {
                                    messageContent(m)
                                }
                            }
                            .id(m.id)
                            .onAppear { seen(m.id) }
                            }
                        }
                        ForEach(pending) { p in
                            Group {
                                if let img = p.image {
                                    // the picture at once, dimmed, with a ring and an X until it is sent (website bcfeb0a)
                                    PhotoBubble(mine: true, date: p.date, state: p.failed ? .failed : .sending, caption: "", size: img.size) {
                                        ZStack {
                                            Image(uiImage: img).resizable().scaledToFill()
                                            if !p.failed {
                                                Color.black.opacity(0.35)
                                                ZStack {
                                                    // fills with a chunked upload's progress; turns otherwise (ResumableUpload.swift)
                                                    UploadRing(key: p.id)
                                                    Button {
                                                        cancelledUploads.insert(p.id)
                                                        uploads[p.id]?.cancel()
                                                        pending.removeAll { $0.id == p.id }
                                                    } label: {
                                                        Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                                            .frame(width: 30, height: 30).background(Color.black.opacity(0.35), in: Circle())
                                                    }
                                                    .accessibilityLabel(Text("chat.upload.cancel"))
                                                    .offset(y: 40)
                                                }
                                                .frame(width: 52, height: 52)
                                            }
                                        }
                                        .overlay(alignment: .topLeading) {
                                            // "Uploading video · 42%", "12 MB / 30 MB", "1.2 MB/s · About 15 s left" (4 MB or more)
                                            if !p.failed {
                                                UploadStatusLines(key: p.id, what: p.video != nil ? "video" : "photo", boxed: true)
                                                    .allowsHitTesting(false)
                                            }
                                        }
                                    }
                                } else if p.video != nil || !p.docName.isEmpty {
                                    // a video without a cover, or a document: the bubble, then the upload's lines and the X
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Bubble(text: p.docName.isEmpty ? "🎬 " + NSLocalizedString("chat.video", comment: "") : "📎 " + p.docName,
                                               mine: true, date: p.date, state: p.failed ? .failed : .sending, faded: false)
                                        if !p.failed {
                                            HStack(alignment: .center, spacing: 8) {
                                                UploadStatusLines(key: p.id, what: p.docName.isEmpty ? "video" : "file", onDark: false)
                                                if uploads[p.id] != nil || (p.video?.isEmpty == true && p.file == nil) {
                                                    Button {
                                                        cancelledUploads.insert(p.id)
                                                        uploads[p.id]?.cancel()
                                                        pending.removeAll { $0.id == p.id }
                                                    } label: {
                                                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.text)
                                                            .frame(width: 26, height: 26).background(Theme.text.opacity(0.12), in: Circle())
                                                    }
                                                    .accessibilityLabel(Text("chat.upload.cancel"))
                                                }
                                            }
                                            .padding(.trailing, 6)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                } else if let ms = p.durationMs {
                                    Bubble(text: "🎤 " + VoiceBubble.length(Int64(ms)), mine: true, date: p.date,
                                           state: p.failed ? .failed : .sending, faded: false)
                                } else {
                                    Bubble(text: p.body, mine: true, date: p.date, state: p.failed ? .failed : .sending, faded: false)
                                }
                            }
                            .id(p.id)
                            .onTapGesture { if p.failed { Task { await deliver(p) } } }
                            .overlay(alignment: .bottomTrailing) {
                                if p.failed {
                                    // "Not sent · Retry" (website FailedBadge), with Delete in the menu
                                    Text("chat.notsent.retry").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.danger)
                                        .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.card, in: Capsule())
                                        .offset(y: 16)
                                        .allowsHitTesting(false)
                                }
                            }
                            .padding(.bottom, p.failed ? 18 : 0)
                            .contextMenu {
                                if p.failed {
                                    Button { Task { await deliver(p) } } label: { Label("chat.retry", systemImage: "arrow.clockwise") }
                                    Button(role: .destructive) {
                                        pending.removeAll { $0.id == p.id }
                                        if let f = p.file { try? FileManager.default.removeItem(at: f) } // this device's copy of a large file
                                    } label: { Label("chat.delete", systemImage: "trash") }
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { bottomVisible = true; unseenBelow = []; unseenMentions = [] }
                            .onDisappear { bottomVisible = false }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .overlay(alignment: .bottomTrailing) {
                    // WhatsApp's arrow (website d454d16): dark, light chevron; the count of others' new messages on its upper
                    // left, counting down as they come into view; in groups the "@" (next mention) stands above it
                    VStack(spacing: 10) {
                        if isGroup, let first = unseenMentions.first {
                            Button { withAnimation { proxy.scrollTo(first, anchor: .center) }; unseenMentions.removeFirst() } label: {
                                Text("@").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.hex(0x04222C))
                                    .frame(width: 42, height: 42).background(Theme.hex(0x00C6C4), in: Circle())
                            }
                            .accessibilityLabel(Text("chat.next.mention"))
                        }
                        if !bottomVisible && !messages.isEmpty {
                            Button {
                                unseenBelow = []
                                unseenMentions = []
                                scrollToBottom(proxy)
                            } label: {
                                Image(systemName: "chevron.down").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.hex(0xE9EDEF))
                                    .frame(width: 42, height: 42).background(Theme.hex(0x1B2A30), in: Circle())
                                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                                    .overlay(alignment: .topLeading) {
                                        if !unseenBelow.isEmpty {
                                            Text("\(unseenBelow.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.hex(0x04222C))
                                                .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20)
                                                .background(Theme.hex(0x00C6C4), in: Capsule())
                                                .scaleEffect(badgePop ? 1.2 : 1)
                                                .offset(x: -7, y: -7)
                                        }
                                    }
                            }
                            .accessibilityLabel(Text("chat.jump"))
                            .accessibilityValue(unseenBelow.isEmpty ? Text("") : Text("\(unseenBelow.count)"))
                        }
                    }
                    .padding(14)
                    .onChange(of: unseenBelow.count) { _ in
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { badgePop = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { withAnimation { badgePop = false } }
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
                .onChange(of: messages.last?.id) { _ in
                    if !openedAtEnd && !messages.isEmpty {
                        // the chat opens at its end (or at the unread line): again once pictures have taken their room
                        openedAtEnd = true
                        for d in [0.0, 0.35, 0.9, 1.6, 2.5] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                                if unreadMarkID != nil && unreadMarkCount > 0 { proxy.scrollTo("unread-mark", anchor: .top) }
                                else { proxy.scrollTo("bottom", anchor: .bottom) }
                            }
                        }
                        return
                    }
                    // at the end, new messages are simply followed; up in the history they are counted instead
                    if bottomVisible || messages.last?.sender_id == me { scrollToBottom(proxy) }
                }
                .onChange(of: unreadMarkID) { id in
                    if id != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { proxy.scrollTo("unread-mark", anchor: .top) } }
                }
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
        .environment(\.tfChatThemed, !(themeID.isEmpty || themeID == "tradeflor"))
        .toolbar(.hidden, for: .navigationBar)
        .task(id: chat.peer_id) {
            guard !isGroup, !chat.peer_id.isEmpty else { return }
            if let p = await APIClient.shared.presence(token: token, userID: chat.peer_id) { live.applyPresence(p, userID: chat.peer_id) }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                presenceNow = Date()
            }
        }
        .onReceive(live.typing) { t in
            guard t.conversation == chat.conversation_id, t.user != me else { return }
            peerTypingUntil = Date().addingTimeInterval(5)
            typingUser = t.user
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
        .sheet(item: $profileFor) { p in MemberProfileSheet(member: p).environmentObject(store) }
        .sheet(isPresented: $addingGroupStatus) {
            StatusCreatorSheet(onPosted: { Task { await loadGroupStatus() } }, groupID: chat.conversation_id, groupName: chat.title)
                .environmentObject(store)
        }
        .fullScreenCover(isPresented: $watchingGroupStatus) {
            if let g = groupStatus {
                StatusViewerScreen(groups: [g], startGroup: 0, token: token) { Task { await loadGroupStatus() } }
            }
        }
        .task { if isGroup { await loadGroupStatus() } }
        // join requests waiting: on open, when someone asks (live), and every minute
        .task {
            while isGroup && !Task.isCancelled {
                if isAdmin { await loadJoinWaiting() }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .onReceive(live.joinRequests) { d in if d["conversation_id"] == chat.conversation_id { Task { await loadJoinWaiting() } } }
        .onChange(of: showInfo) { open in if !open { Task { await loadJoinWaiting() } } }
        #if DEBUG
        // CI only: TF_CI_GROUP_INFO=1 opens Group Info over the group chat, for a screenshot
        .task {
            if isGroup, ProcessInfo.processInfo.environment["TF_CI_GROUP_INFO"] == "1" {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                showInfo = true
            }
            // CI only: TF_CI_MEMBER=1 opens a member's Contact info (the first member who is not me and not the owner)
            if isGroup, ProcessInfo.processInfo.environment["TF_CI_MEMBER"] == "1" {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if let m = members.first(where: { $0.user_id != me && roleOf($0.user_id) != "owner" }) {
                    profileFor = MemberProfileRef(userID: m.user_id, username: m.username)
                }
            }
        }
        #endif
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
            if isGroup { await loadPeople() }
            await loadMeta()
            themeID = await ChatThemeStore.load(token: token, conversationID: chat.conversation_id)
        }
        .task { await loadNewest() }
        // after a dropped connection or a return to the app: catch up so nothing sent meanwhile is missing
        .onReceive(live.opened) { _ in Task { await loadNewest(quiet: true) } }
        .onChange(of: scenePhase) { p in if p == .active { Task { await loadNewest(quiet: true) } } }
        // unsent messages are kept on the device and sent again when the chat opens (same idempotency key)
        .onChange(of: pending) { list in
            if outboxLoaded { OutboxStore.save(account: me, conversation: chat.conversation_id, list) }
        }
        .task {
            guard !outboxLoaded else { return }
            let saved = OutboxStore.load(account: me, conversation: chat.conversation_id).filter { s in !pending.contains { $0.id == s.id } }
            pending.append(contentsOf: saved)
            outboxLoaded = true
            for p in saved { await deliver(p) }
        }
        .onReceive(live.messages) { m in
            guard m.conversation_id == chat.conversation_id else { return }
            let isNew = !messages.contains { $0.id == m.id }
            merge([m])
            pending.removeAll { $0.id == m.client_key }
            if isNew && !bottomVisible && m.sender_id != me && m.kind != "notice" {
                unseenBelow.append(m.id)
                if isGroup && ChatEdit.mentions(m, me: me) { unseenMentions.append(m.id) }
            }
            if m.sender_id != me { Task { await markSeen() } }
        }
        .onReceive(live.hidden) { h in
            // hidden for me, or the chat cleared on any of my devices: those messages leave at once
            guard h.conversation == chat.conversation_id else { return }
            let gone = Set(h.ids)
            messages.removeAll { gone.contains($0.id) }
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
            if let e = editing {
                // the edit bar (website 86beee5): "Edit message" + the old text; Send saves, X cancels
                HStack(spacing: 8) {
                    Image(systemName: "pencil").foregroundStyle(Theme.accent)
                    Capsule().fill(Theme.accent).frame(width: 3, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("chat.edit.title").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        Text(e.body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { editing = nil; draft = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel(Text("chat.edit.cancel"))
                }
                .padding(.horizontal, 6)
            } else if let r = replyingTo {
                HStack(spacing: 8) {
                    Capsule().fill(Theme.accent).frame(width: 3, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.sender_id == me ? NSLocalizedString("chat.you", comment: "") : (isGroup ? memberNames[r.sender_id] ?? chat.title : chat.title))
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
        .background(barColor.ignoresSafeArea(edges: .bottom))
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
                           online: nil) // no dot on the header picture (website d4d2e77)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chat.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(subtitle ?? (isGroup ? String(format: NSLocalizedString("groups.members", comment: ""), memberCount) : ""))
                                .font(.system(size: 13)).foregroundStyle(peerTypingUntil != nil ? Theme.accent : Theme.faint).lineLimit(1)
                                .minimumScaleFactor(0.8)
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
                if isGroup, groupStatus != nil {
                    Button { watchingGroupStatus = true } label: { Label("gst.watch", systemImage: "circle.dashed") }
                }
                if isGroup && isAdmin {
                    Button { addingGroupStatus = true } label: { Label("gst.add", systemImage: "plus.circle.dashed") }
                }
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
        .background(barColor.ignoresSafeArea(edges: .top))
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
                        // polls are created by the owner and admins only (server release 3c3d2a8); every member still votes
                        if isAdmin { Button { showPoll = true } label: { Label("poll.new", systemImage: "chart.bar") } }
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
                    if isGroup && isAdmin {
                        // silent post (website GroupsView): kept as the control it will be once push notifications exist
                        Button {
                            silentPost.toggle()
                            flash(silentPost ? "silent.on" : "silent.off")
                        } label: { composerIcon(silentPost ? "bell.slash" : "bell") }
                        .accessibilityLabel(Text(LocalizedStringKey(silentPost ? "silent.on" : "silent.off")))
                    }
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 48)
                .background(themeID.isEmpty ? AnyShapeStyle(Theme.soulInput) : AnyShapeStyle(Theme.inputGradient),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
            Button { selecting = false; selected = []; allPicked = false } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 36, height: 44)
            }
            .accessibilityLabel(Text("select.cancel"))
            Text(String(format: NSLocalizedString("select.count", comment: ""), selected.count))
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            Button { Task { await selectAll() } } label: {
                if pickingAll { ProgressView().tint(Theme.accent) } else {
                    Text(LocalizedStringKey(allSelected ? "select.clear" : "select.all"))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
            .disabled(pickingAll)
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
        .background(barColor.ignoresSafeArea(edges: .top))
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
        .background(barColor.ignoresSafeArea(edges: .bottom))
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
        .background(barColor)
    }

    private var pinnedBar: some View {
        let p = pins[min(pinIndex, pins.count - 1)]
        return HStack(spacing: 4) {
            Button {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // hides the bar for this visit only (everyone, admins too); never unpins -- it shows again next time
            Button { withAnimation { pinsHidden = true } } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.faint).frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("pin.hide"))
        }
        .padding(.leading, 14).padding(.trailing, 4).frame(height: 50)
        .background(barColor)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderStrong).frame(height: 1) }
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

    /// Who is who in the group. Everyone may read the people who posted (GET /groups/{id}/senders, website listGroupSenders);
    /// only the owner and admins may read the whole member directory (/members), which adds those who never posted.
    private func loadPeople() async {
        var all: [String: GroupMemberFull] = [:]
        for p in (try? await APIClient.shared.list(GroupMemberFull.self, "groups/\(chat.conversation_id)/senders", token: token)) ?? [] { all[p.user_id] = p }
        for p in (try? await APIClient.shared.list(GroupMemberFull.self, "groups/\(chat.conversation_id)/admins", token: token)) ?? [] { all[p.user_id] = p }
        for p in (try? await APIClient.shared.list(GroupMemberFull.self, "groups/\(chat.conversation_id)/members", token: token)) ?? [] { all[p.user_id] = p }
        let list = Array(all.values)
        members = list.map { GroupMember(user_id: $0.user_id, username: $0.username, display_name: $0.display_name) }
        memberNames = Dictionary(list.map { ($0.user_id, $0.title) }, uniquingKeysWith: { a, _ in a })
        memberRoles = Dictionary(list.filter { $0.role != "member" }.map { ($0.user_id, $0.role) }, uniquingKeysWith: { a, _ in a })
        memberAvatars = Dictionary(list.compactMap { p in (p.avatar_id?.isEmpty == false) ? (p.user_id, p.avatar_id!) : nil }, uniquingKeysWith: { a, _ in a })
    }

    private func loadJoinWaiting() async {
        guard isGroup, isAdmin else { joinWaiting = 0; return }
        joinWaiting = await APIClient.shared.grpJoinRequests(token: token, id: chat.conversation_id).count
    }

    private func loadGroupStatus() async {
        let feed = (try? await APIClient.shared.statusFeed(token: token)) ?? []
        groupStatus = feed.first { $0.group_id == chat.conversation_id && !$0.posts.isEmpty }
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

    /// What a tap can select: every message, "This message was deleted" too; a call entry only goes with "Select all".
    private func selectable(_ m: Message) -> Bool { m.kind != "call" }

    private var allSelected: Bool {
        let every = messages.filter(selectable)
        return reachedStart && !every.isEmpty && every.allSatisfy { selected.contains($0.id) }
    }

    /// "Select all" (website b9833d1): the whole chat, not only what is on screen: every older page is loaded first.
    private func selectAll() async {
        if allSelected { selected = []; allPicked = false; return }
        guard !pickingAll else { return }
        var whole = reachedStart
        if !reachedStart {
            pickingAll = true
            flash("select.loading")
            whole = await loadAllOlder()
            pickingAll = false
        }
        selected = Set(messages.filter(selectable).map(\.id))
        allPicked = whole
        if !whole { flash("select.partial") }
    }

    /// Every older page, 200 at a time, until the start of what this account may see. false = stopped (offline…).
    private func loadAllOlder() async -> Bool {
        for _ in 0..<500 {
            guard let first = messages.first else { return true }
            if first.seq <= 1 { reachedStart = true; return true }
            guard let page = try? await APIClient.shared.messages(token: token, conversationID: chat.conversation_id,
                                                                  before: first.seq, limit: 200) else { return false }
            merge(page)
            // a short page is the start; a page of only deleted gaps still moves the anchor down
            if page.count < 200 { reachedStart = true; return true }
            if messages.first?.seq == first.seq { return false }
        }
        return false
    }

    /// Batches of 100 (the server's limit), 3 tries each; a batch that fails does not stop the others, every batch the
    /// server took leaves the screen at once, and what is left stays selected for Delete again (website b9833d1).
    private func deleteSelected(everyone: Bool) async {
        let asked = Set(deleteTargets.map(\.id))
        var ids = deleteTargets.map(\.id)
        // after "Select all" of the whole chat, the call entries go too: nothing is left behind
        if !everyone && allPicked && messages.filter(selectable).allSatisfy({ asked.contains($0.id) }) {
            ids += messages.filter { $0.kind == "call" && !asked.contains($0.id) }.map(\.id)
        }
        deleteTargets = []
        if ids.count > 100 { flashText(String(format: NSLocalizedString("select.deleting", comment: ""), ids.count)) }
        var failed: [String] = []
        var i = 0
        while i < ids.count {
            let chunk = Array(ids[i..<min(i + 100, ids.count)])
            i += 100
            var done = false
            for attempt in 0..<3 where !done {
                do {
                    if everyone { try await APIClient.shared.chDeleteBatch(token: token, ids: chunk) }
                    else { try await APIClient.shared.chHideBatch(token: token, ids: chunk) }
                    done = true
                } catch {
                    if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(600_000_000 * (attempt + 1))) }
                }
            }
            if done {
                if !everyone { let gone = Set(chunk); messages.removeAll { gone.contains($0.id) } }
            } else {
                failed += chunk
            }
        }
        if everyone { await loadNewest(quiet: true) }
        allPicked = false
        if failed.isEmpty {
            selecting = false
            selected = []
        } else {
            selected = Set(failed).intersection(Set(messages.map(\.id)))
            flash("select.some.failed")
        }
    }

    private func sendDocument(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // 4 MB or more: copied to this device's upload folder (never read into memory) and sent in chunks as a pending row
        // with progress, resumed after a drop and by Retry (same key)
        let size = ResumableUploader.fileSize(url)
        if size >= ResumableUploader.minBytes {
            if size > 25_000_000 { flash("attach.too.big"); return }
            let key = UUID().uuidString.lowercased()
            guard let kept = ResumableUploader.keepCopy(of: url, key: key) else { flash("chat.action.failed"); return }
            var p = PendingMessage(id: key, body: "", date: Date())
            p.file = kept
            p.docName = url.lastPathComponent
            p.docMime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            pending.append(p)
            await deliver(p)
            return
        }
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

    /// The header and message bar: the soul colour #01141B in the default chat (website --tf-chat-header-bg / footer-bg).
    private var barColor: Color { (themeID.isEmpty || themeID == "tradeflor") ? Theme.soul : Theme.header }

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
            if !unreadMarkSet && !page.isEmpty {
                // "N unread messages" where the unread start (website unreadMark.ts), once, when the chat opens
                unreadMarkSet = true
                unreadMarkCount = chat.unread_count
                unreadMarkID = UnreadMark.startID(messages, unread: chat.unread_count, me: me)
            }
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

    private func canEdit(_ m: Message) -> Bool { ChatEdit.canEdit(m, me: me) && canSend && !restricted }

    private func startEdit(_ m: Message) {
        replyingTo = nil
        editing = m
        draft = m.body
        composerFocused = true
    }

    private func saveEdit(_ m: Message, _ text: String) async {
        editing = nil
        draft = ""
        guard text != m.body else { return }
        do {
            merge([try await APIClient.shared.editMessage(token: token, messageID: m.id, body: text)])
        } catch APIError.refused(let why) {
            flashText(why.isEmpty ? NSLocalizedString("chat.edit.failed", comment: "") : why)
        } catch APIError.server(status: 409) {
            flash("chat.edit.late")
        } catch {
            flash("chat.edit.failed")
        }
    }

    private func flashText(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == text { toast = nil }
        }
    }

    /// A counted message came into view: one fewer on the arrow.
    private func seen(_ id: String) {
        if let i = unseenBelow.firstIndex(of: id) { unseenBelow.remove(at: i) }
    }

    private func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let e = editing { await saveEdit(e, text); return }
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
                       state: m.sender_id == me ? receipt(m) : nil, faded: false, edited: m.edited_at != nil)
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
            VoiceBubble(token: token, message: m, mine: m.sender_id == me, state: m.sender_id == me ? receipt(m) : nil,
                        avatarID: m.sender_id == me ? nil : (isGroup ? memberAvatars[m.sender_id] : chat.peer_avatar_id),
                        name: isGroup ? memberNames[m.sender_id] : (m.sender_id == me ? nil : chat.title))
        } else if m.kind == "file", let fid = m.file_id, (m.file_mime ?? "").hasPrefix("video/"), !m.isDeleted {
            VideoBubble(token: token, message: m, mine: m.sender_id == me, state: m.sender_id == me ? receipt(m) : nil) {
                watching = ViewedPhoto(id: fid)
            }
        } else if m.kind == "image", let fid = m.file_id, !m.isDeleted {
            PhotoBubble(mine: m.sender_id == me, date: m.date, state: m.sender_id == me ? receipt(m) : nil, caption: m.body, fileID: fid) {
                RemoteImage(token: token, fileID: fid)
            }
            .onTapGesture { viewing = ViewedPhoto(id: fid) }
        } else if m.kind == "file", m.file_id != nil, !m.isDeleted {
            FileBubble(message: m, mine: m.sender_id == me, state: m.sender_id == me ? receipt(m) : nil) {
                Task { await openDocument(m) }
            }
        } else {
            Bubble(text: displayText(m), mine: m.sender_id == me, date: m.date,
                   state: m.sender_id == me ? receipt(m) : nil, faded: m.isDeleted, edited: m.edited_at != nil && !m.isDeleted)
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
        if let until = peerTypingUntil, until > Date() {
            // groups: "<name> is typing…" (website 86beee5)
            if isGroup, let u = typingUser, let name = memberNames[u], !name.isEmpty {
                return String(format: NSLocalizedString("chat.typing.name", comment: ""), name)
            }
            return NSLocalizedString("chat.typing", comment: "")
        }
        if isGroup { return nil }
        // "online", "last seen today at 4:23 AM" … or nothing; never "Offline" (website lastSeen.ts)
        return live.presenceLine(chat.peer_id, now: presenceNow)
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
        // the cover first (mp4 removes the source when done): it shows at once, dimmed, while the video is prepared and sent
        let poster = await VideoPrep.poster(for: url)
        var placeholder = PendingMessage(id: key, body: caption.trimmingCharacters(in: .whitespacesAndNewlines), date: Date(), video: Data())
        placeholder.poster = poster
        placeholder.image = poster.flatMap { UIImage(data: $0) }
        pending.append(placeholder)
        guard let out = await VideoPrep.mp4(from: url) else {
            if let i = pending.firstIndex(where: { $0.id == key }) { pending[i].failed = true }
            problem = NSLocalizedString("chat.video.toolarge", comment: "")
            return
        }
        guard let i = pending.firstIndex(where: { $0.id == key }) else { return } // cancelled (the X) while it was prepared
        // written once to a file kept on this device: sent in chunks from it when 4 MB or more (resumed after a drop, and by
        // Retry or the outbox after a restart, same key); kept in memory only if the file cannot be written
        if let kept = ResumableUploader.keep(out.data, key: key, ext: "mp4") {
            pending[i].file = kept
        } else {
            pending[i].video = out.data
        }
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
        if let v = p.video, v.isEmpty, p.file == nil { return } // still being re-encoded, or the re-encode failed
        if uploads[p.id] != nil { return } // already going (a second tap, or the outbox and a retry at once)
        if let i = pending.firstIndex(where: { $0.id == p.id }) { pending[i].failed = false }
        do {
            let m: Message
            if let audio = p.audio, let ms = p.durationMs {
                m = try await APIClient.shared.sendVoice(token: token, conversationID: chat.conversation_id, audio: audio,
                                                         durationMs: ms, waveform: p.waveform, key: p.id)
            } else if p.video != nil || !p.docName.isEmpty {
                // a video or a document: 4 MB or more in chunks from its file (progress, resumed after a drop and by Retry with
                // the same key; an older server: the one request); smaller in one request, as before
                let conv = chat.conversation_id, tok = token
                let isVideo = p.video != nil
                let data = p.video.flatMap { $0.isEmpty ? nil : $0 }
                let t = Task { try await ResumableUploader.shared.send(token: tok, conversationID: conv, file: p.file, data: data,
                                                                       fileName: isVideo ? "video.mp4" : p.docName,
                                                                       mime: isVideo ? "video/mp4" : p.docMime,
                                                                       caption: p.body, key: p.id, replyTo: p.replyTo,
                                                                       poster: isVideo ? p.poster : nil) }
                uploads[p.id] = t
                defer { uploads[p.id] = nil }
                m = try await t.value
            } else if let jpeg = p.jpeg {
                // a photo is one request unless it is 4 MB or more (an HD photo): then in chunks too
                let conv = chat.conversation_id, tok = token
                let t = Task { try await ResumableUploader.shared.send(token: tok, conversationID: conv, file: nil, data: jpeg,
                                                                       fileName: "photo.jpg", mime: "image/jpeg",
                                                                       caption: p.body, key: p.id) }
                uploads[p.id] = t
                defer { uploads[p.id] = nil }
                m = try await t.value
            } else {
                m = try await APIClient.shared.sendText(token: token, conversationID: chat.conversation_id,
                                                        body: p.body, key: p.id, replyTo: p.replyTo)
            }
            merge([m])
            pending.removeAll { $0.id == p.id }
            if let f = p.file { try? FileManager.default.removeItem(at: f) } // sent: this device's copy is no longer needed
        } catch APIError.badCredentials {
            store.sessionExpired()
        } catch {
            if cancelledUploads.contains(p.id) { // X: dropped on purpose (the server was told to drop its chunks)
                cancelledUploads.remove(p.id)
                if let f = p.file { try? FileManager.default.removeItem(at: f) }
                return
            }
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
    /// A video's cover picture (one small JPEG frame), sent with it (website e0f0b7a).
    var poster: Data? = nil
    /// A video or document kept as a file on this device (ResumableUploader.folder): sent in chunks from it when 4 MB or
    /// more, resumed after a drop; kept by the outbox, so a restart resumes it with the same key. Removed once sent.
    /// (A video with a file has `video` set to empty Data: "a video".)
    var file: URL? = nil
    /// A document's own name and type (empty for every other kind).
    var docName = ""
    var docMime = ""
}

struct ViewedPhoto: Identifiable {
    let id: String // the file id
}

/// A photo message (website 063cc7e / 03f13cf): the picture on its own, no card, in a box that keeps its shape (the space
/// is kept before it loads); the time over the picture; a round forward arrow beside it. With a caption it keeps its card.
struct PhotoBubble<Content: View>: View {
    let mine: Bool
    let date: Date?
    let state: Bubble.Delivery?
    let caption: String
    var fileID: String? = nil
    /// The picture's own size when known here (a picture being sent).
    var size: CGSize? = nil
    @ViewBuilder let content: () -> Content
    @ObservedObject private var dims = MediaDims.shared
    @Environment(\.tfMediaForward) private var forward

    var body: some View {
        let box = MediaDims.box(size ?? fileID.flatMap { dims.size($0) })
        HStack(alignment: .center, spacing: 8) {
            if mine { Spacer(minLength: 0) }
            if mine, let forward { forwardButton(forward) }
            VStack(alignment: .trailing, spacing: 4) {
                content()
                    .frame(width: box.width, height: box.height)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: caption.isEmpty ? 12 : 10, style: .continuous))
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottomTrailing) {
                        if caption.isEmpty { MediaTimeChip(date: date, state: state).padding(6) }
                    }
                if !caption.isEmpty {
                    ZStack(alignment: .bottomTrailing) {
                        (Text(caption) + Text(Bubble.metaSpacer(date: date, ticks: state != nil, edited: false)).foregroundColor(.clear).font(.system(size: 11)))
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: box.width, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Bubble.meta(date: date, state: state, edited: false)
                    }
                    .padding(.horizontal, 6).padding(.bottom, 2)
                }
            }
            .padding(caption.isEmpty ? 0 : 3)
            .modifier(CaptionCard(on: !caption.isEmpty, mine: mine))
            if !mine, let forward { forwardButton(forward) }
            if !mine { Spacer(minLength: 0) }
        }
    }

    private func forwardButton(_ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                .frame(width: 32, height: 32).background(Theme.card.opacity(0.85), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("chat.forward"))
    }
}

private struct CaptionCard: ViewModifier {
    let on: Bool
    let mine: Bool
    func body(content: Content) -> some View {
        if on { content.tfBubble(mine: mine) } else { content }
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

/// A text message, WhatsApp-style (website 7e5a789 / ac11142 / fbe88d3): 15 pt text in a snug bubble at most 85% of the
/// screen wide; the time (and "Edited") sits inside the last line when it fits; a long message shows "Read more".
/// In groups the sender's name and the quoted message sit inside the top of the card (tfBubbleHead).
struct Bubble: View {
    enum Delivery { case sending, sent, delivered, read, failed }

    let text: String
    let mine: Bool
    let date: Date?
    let state: Delivery?
    let faded: Bool
    var edited = false
    @Environment(\.tfBubbleHead) private var head
    @Environment(\.openURL) private var parentOpen
    @State private var expanded = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func timeString(_ d: Date) -> String { time.string(from: d) }

    /// Invisible text as wide as the time line, at the end of the message: the time then sits in the last line when it
    /// fits, and on a line of its own when it does not.
    static func metaSpacer(date: Date?, ticks: Bool, edited: Bool) -> String {
        var s = "\u{2003}"
        if edited { s += NSLocalizedString("chat.edited", comment: "") + " " }
        if let date { s += timeString(date) }
        if ticks { s += "\u{2003}" }
        return " " + s
    }

    @ViewBuilder static func meta(date: Date?, state: Delivery?, edited: Bool) -> some View {
        HStack(spacing: 3) {
            if edited { Text("chat.edited").opacity(0.85) }
            if let date { Text(timeString(date)) }
            if let state { tickView(state) }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.muted.opacity(0.9))
        .padding(.bottom, -1)
    }

    var body: some View {
        let jumbo = faded ? 0 : TextLook.emojiCount(text)
        HStack {
            if mine { Spacer(minLength: 0) }
            if jumbo > 0 {
                // 1-3 emoji alone: large, without a bubble (website emoji.ts jumboClass)
                VStack(alignment: .trailing, spacing: 2) {
                    if let head { head }
                    Text(text).font(.system(size: jumbo == 1 ? 60 : (jumbo == 2 ? 48 : 40)))
                    HStack(spacing: 4) {
                        if edited { Text("chat.edited") }
                        if let date { Text(Self.time.string(from: date)) }
                        if let state { tick(state) }
                    }
                    .font(.caption2).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(Theme.card.opacity(0.7), in: Capsule())
                }
            } else {
                card
            }
            if !mine { Spacer(minLength: 0) }
        }
    }

    private var card: some View {
        let cut = faded || expanded ? nil : ReadMore.cut(text)
        let arabic = TextLook.isArabic(text)
        var shown = TextLook.linked(cut ?? text)
        if cut != nil {
            var more = AttributedString("… " + NSLocalizedString("chat.readmore", comment: ""))
            more.link = URL(string: "tfreadmore://open")
            more.foregroundColor = Theme.accent
            more.font = .system(size: 15, weight: .semibold)
            shown += more
        }
        return VStack(alignment: .leading, spacing: 4) {
            if let head { head }
            ZStack(alignment: .bottomTrailing) {
                (Text(shown) + Text(Self.metaSpacer(date: date, ticks: state != nil, edited: edited)).font(.system(size: 11)).foregroundColor(.clear))
                    .font(.system(size: 15))
                    .italic(faded)
                    .foregroundStyle(Theme.text)
                    .tint(Theme.accent)
                    .opacity(faded ? 0.7 : 1)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .multilineTextAlignment(arabic ? .trailing : .leading)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "tfreadmore" { withAnimation(.easeOut(duration: 0.15)) { expanded = true }; return .handled }
                        parentOpen(url)
                        return .handled
                    })
                Self.meta(date: date, state: state, edited: edited)
            }
            // an Arabic message reads right to left in its own bubble (website bidi.ts)
            .environment(\.layoutDirection, arabic ? .rightToLeft : .leftToRight)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6).padding(.bottom, 6)
        .tfBubble(mine: mine)
        .frame(maxWidth: UIScreen.main.bounds.width * 0.85, alignment: mine ? .trailing : .leading)
        .fixedSize(horizontal: false, vertical: true)
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


/// Message text helpers shared by the bubbles (website Linkify.tsx, bidi.ts, emoji.ts).
enum TextLook {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Every web address in the text is a link (Tradeflor links open inside the app).
    static func linked(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard let detector, text.contains(".") else { return out }
        for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = m.url, let r = Range(m.range, in: text),
                  let lo = AttributedString.Index(r.lowerBound, within: out), let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lo..<hi].link = url
            out[lo..<hi].underlineStyle = .single
        }
        return out
    }

    static func isArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
    }

    /// 1-3 emoji and nothing else: how many; otherwise 0.
    static func emojiCount(_ text: String) -> Int {
        let chars = text.filter { !$0.isWhitespace }
        guard !chars.isEmpty, chars.count <= 3 else { return 0 }
        for c in chars {
            guard let f = c.unicodeScalars.first else { return 0 }
            let isEmoji = f.properties.isEmojiPresentation || (f.properties.isEmoji && c.unicodeScalars.count > 1)
            if !isEmoji { return 0 }
        }
        return chars.count
    }
}


/// Names that look alike (accents, case, spacing, look-alike letters and digits) map to the same skeleton.
enum NameSkeleton {
    static func skeleton(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        let map: [Character: Character] = ["0": "o", "1": "l", "i": "l", "|": "l", "3": "e", "5": "s", "$": "s", "@": "a", "4": "a",
                                           "\u{0430}": "a", "\u{0435}": "e", "\u{043E}": "o", "\u{0440}": "p", "\u{0441}": "c", "\u{0445}": "x"]
        return String(folded.compactMap { c -> Character? in
            if c.isWhitespace || c == "_" || c == "." || c == "-" { return nil }
            return map[c] ?? c
        })
    }

    static func lookAlikeIDs(_ members: [GroupMember]) -> Set<String> {
        var byKey: [String: [String]] = [:]
        for m in members { byKey[skeleton(m.title), default: []].append(m.user_id) }
        return Set(byKey.values.filter { $0.count > 1 }.flatMap { $0 })
    }
}
