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
    /// What is being typed lives in its own box, watched only by the text field: a key press no longer redraws the
    /// whole chat (that made typing lag). The chat hears only when the box turns empty / not empty, or an @mention starts.
    @State private var box = DraftBox()
    @State private var draftEmpty = true
    @State private var mentionQ: String?
    private var draft: String {
        get { box.text }
        nonmutating set { box.text = newValue }
    }
    @FocusState private var composerFocused: Bool
    @State private var picked: [PhotosPickerItem] = []
    @State private var reviewing: MediaBatch?
    @State private var showCamera = false
    @State private var viewing: ViewedPhoto?
    @State private var watching: ViewedPhoto?
    // the running time and levels stay in recorder.meter: only the recording strip redraws 10 times a second, not the chat
    @StateObject private var recorder = VoiceRecorder(mirrorsMeter: false)
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
    /// The message bar's height: the emoji panel sits just above it.
    @State private var composerHeight: CGFloat = 60
    @State private var showLocationSheet = false
    @State private var showPhotoPicker = false
    @State private var showDocPicker = false
    @State private var showMute = false
    @State private var muted = false
    @State private var restricted = false
    @State private var myRole = "member"
    @State private var groupCanSendMedia = true
    @State private var groupCanSignals = false
    @State private var groupCanReact = true
    /// Former members (left / removed), from the admins' member list.
    @State private var formerIDs: Set<String> = []
    /// The server's latest answer about writing here (nil until read): wins over `canSend` from the list.
    @State private var liveCanSend: Bool?
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
    /// The list stays hidden while it opens at its end, so the pictures it holds take their real size first (a photo or
    /// video never seen has no size yet, and rows grew under the reader: the "jump"). Shown at once after 0.7 s at most.
    @State private var revealed = false
    /// I scrolled up to read: nothing pulls me back to the end by itself.
    @State private var userScrolledUp = false
    /// When the chat settled at its end: older pages load by themselves only after this (no jump while opening).
    @State private var openedAtTime = Date.distantFuture
    /// Text and voice waiting to leave, in writing order (one at a time per conversation).
    @State private var sendQueue: [String] = []
    @State private var queueRunning = false
    /// The chat screen is not on screen: its line stops sending (OutboxFlusher takes over from the saved outbox).
    @State private var gone = false
    /// Server errors (5xx) seen per queued message: after five it is "Not sent" and the line goes on.
    @State private var serverRetries: [String: Int] = [:]
    /// Admin removed / banned me, or the group was deleted, while this chat was open.
    @State private var removedFromGroup = false
    /// The line's wait (rate limit / offline): Retry cuts it short (web lane.wake()).
    @State private var queueWait: Task<Void, Never>?
    /// Photos / videos / documents: automatic retries on a passing error (web: files keep their own timer).
    @State private var fileRetries: [String: Int] = [:]
    /// Group typing: everyone typing now, each with their own 3.5 s timer (web 86beee5).
    @State private var typingUsers: [String: Date] = [:]
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
    /// Members whose names look like another member's (website nameSkeleton.ts); worked out when the members load (it folded every name on every redraw).
    @State private var lookAlike: Set<String> = []
    /// Photo messages by id (their file), for the small picture in a reply to a photo.
    private var replyPhotoIDs: [String: String] {
        var out: [String: String] = [:]
        for x in messages where x.kind == "image" && !x.isDeleted { if let f = x.file_id { out[x.id] = f } }
        return out
    }
    @State private var groupStatus: StatusGroup?
    @State private var watchingGroupStatus = false
    @State private var addingGroupStatus = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var openingDoc = false
    /// The pending rows last seen: the list follows to the end only when one is added (a sent one leaving must not
    /// pull me down while I read the history).
    @State private var pendingCountSeen = 0
    /// Group Info left or deleted this group: the chat closes once the sheet has gone.
    @State private var groupGone = false
    // hold-to-record voice: press = record, release = send, slide left = cancel, slide up = lock (hands free)
    @State private var micPressed = false
    @State private var holdRec = false
    @State private var holdReleased = false
    @State private var holdDrag: CGSize = .zero
    @State private var focusPages: [Message] = []
    @State private var focusShowAll = false
    @State private var showFocus = false
    /// A burst of incoming messages sends one read receipt, and a burst of changes reloads the page once.
    @State private var seenTask: Task<Void, Never>?
    @State private var changeReload: Task<Void, Never>?
    private var focusOn: Bool { isGroup && (focusDoc?.focus.active ?? false) && !focusShowAll }
    /// What the list shows: everything, or (Smart Focus) the server's filtered history plus matching live messages.
    private var shown: [Message] {
        LocationCardTwin.removing(from: shownAll)
    }
    private var shownAll: [Message] {
        guard focusOn, let f = focusDoc?.focus else { return messages }
        var byID: [String: Message] = [:]
        for m in focusPages { byID[m.id] = m }
        for m in messages where byID[m.id] != nil || f.matches(m, me: me, roleOf: { memberRoles[$0] }) { byID[m.id] = m }
        return byID.values.sorted { $0.seq < $1.seq }
    }
    private var isAdmin: Bool { myRole == "owner" || myRole == "admin" }
    /// Whether the message bar shows: the group's current answer once read, else what the list said.
    private var canPost: Bool { liveCanSend ?? canSend }
    private var searchHits: [Message] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return messages.filter { !$0.isDeleted && $0.body.localizedCaseInsensitiveContains(q) }
    }

    @Environment(\.dismiss) private var dismissView
    private let pageSize = 50
    private var me: String { store.session?.userID ?? "" }
    private var token: String { store.session?.token ?? "" }

    // `body` is split into small pieces: as one expression (the list, its overlays and every sheet) the compiler could
    // no longer type-check it in reasonable time. Behaviour is the same as when it was one chain.
    var body: some View {
        // erased between the stages: the whole chain as one type could be too deep for the Swift runtime to build
        // (the same stack-overflow crash as Group Info, crash report 2026-11-18 13:34)
        chatTail2(chatTail(AnyView(chatMiddle2(chatMiddle(AnyView(chatHead2(chatHead(AnyView(chatColumn)))))))))
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            chatHeader
            ScrollViewReader { proxy in
                messageScroll(proxy)
            }
            chatFooter
        }
    }

    @ViewBuilder private var chatHeader: some View {
        topBar
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
    }

    /// The messages: the scroll view, its overlays (arrow, toast, empty / locked states) and how it follows new messages.
    private func messageScroll(_ proxy: ScrollViewProxy) -> some View {
        settling(scrollChrome(messageScrollView(proxy), proxy), proxy)
    }

    private func messageScrollView(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            messageStack(proxy)
        }
        .opacity(revealed ? 1 : 0)
        .task {
            // at most 0.7 s hidden, as the web (useHistoryScroll settleOpen): then shown already at the end
            try? await Task.sleep(nanoseconds: 700_000_000)
            revealed = true
        }
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(TapGesture().onEnded { if TabChrome.shared.keyboard { TabChrome.dismissKeyboard() } })
    }

    private func messageStack(_ proxy: ScrollViewProxy) -> some View {
        LazyVStack(spacing: 6) {
            if !reachedStart && !messages.isEmpty {
                // reaching the top loads the page before, as WhatsApp does (the button stays for VoiceOver)
                Button {
                    Task { await loadOlder(proxy) }
                } label: {
                    if loadingOlder { ProgressView() } else { Text("chat.older").font(.footnote) }
                }
                .padding(.vertical, 8)
                .onAppear {
                    guard openedAtEnd, !loadingOlder, !bottomVisible,
                          Date().timeIntervalSince(openedAtTime) > 1.5 else { return }
                    userScrolledUp = true
                    Task { await loadOlder(proxy) }
                }
            }
            let rows = shown
            let lookIDs = lookAlike
            let albums = Albums.runs(rows, isGroup: isGroup)
            // worked out once per redraw, not once per row (each was a pass over every message)
            let hits = searchOpen ? searchHits : []
            let hitID: String? = hits.indices.contains(searchIndex) ? hits[searchIndex].id : nil
            let replyPhotos = replyPhotoIDs
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                messageRow(m, i, rows, albums, lookIDs, hitID, replyPhotos)
            }
            ForEach(pending) { p in
                pendingRow(p)
            }
            Color.clear.frame(height: 1).id("bottom")
                .onAppear { bottomVisible = true; userScrolledUp = false; unseenBelow = []; unseenMentions = [] }
                .onDisappear { bottomVisible = false }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    /// One message (with the day label and the unread line above it when they belong there).
    @ViewBuilder private func messageRow(_ m: Message, _ i: Int, _ rows: [Message], _ albums: Albums.Runs,
                                         _ lookIDs: Set<String>, _ hitID: String?, _ replyPhotos: [String: String]) -> some View {
        if i == 0 || !sameDay(rows[i - 1], m) {
            DayDivider(date: m.date)
        }
        if m.id == unreadMarkID && unreadMarkCount > 0 {
            UnreadDivider(count: unreadMarkCount).id("unread-mark")
        }
        if albums.hidden.contains(m.id) {
            // drawn inside its album
            Color.clear.frame(height: 0).id(m.id).onAppear { if !unseenBelow.isEmpty { seen(m.id) } }
        } else {
            let asGroup = isGroup && roleOf(m.sender_id) == "owner"
            MessageRow(message: m, mine: m.sender_id == me, myID: me, peerName: chat.title,
                       senderName: isGroup && (m.sender_id != me || asGroup) && newBlock(rows, i)
                           ? (asGroup ? chat.title : (memberNames[m.sender_id] ?? "")) : nil,
                       onReply: { replyingTo = m; composerFocused = true },
                       onReact: { e in Task { await react(m, e) } },
                       onCopy: { UIPasteboard.general.string = displayText(m); flash("chat.copied") },
                       onForward: { forwarding = m },
                       onDelete: { _ in deleteTargets = [m]; showDelete = true },
                       options: rowOptions(m, i, rows, albums, lookIDs, hitID, replyPhotos, asGroup: asGroup),
                       actions: rowActions(m, albums, asGroup: asGroup)) {
                rowContent(m, albums)
            }
            .id(m.id)
            .onAppear { if !unseenBelow.isEmpty { seen(m.id) } }
        }
    }

    private func rowOptions(_ m: Message, _ i: Int, _ rows: [Message], _ albums: Albums.Runs, _ lookIDs: Set<String>,
                            _ hitID: String?, _ replyPhotos: [String: String], asGroup: Bool) -> MessageRowOptions {
        let showAvatar = isGroup && !asGroup && m.sender_id != me && newBlock(rows, i)
        let avatar: AnyView? = showAvatar
            ? AnyView(Avatar(token: token, userID: m.sender_id, avatarID: memberAvatars[m.sender_id], title: memberNames[m.sender_id] ?? "?", size: 34))
            : nil
        let handle: String? = lookIDs.contains(m.sender_id) ? members.first(where: { $0.user_id == m.sender_id })?.username : nil
        return MessageRowOptions(
            isGroup: isGroup, restricted: restricted, canPin: isGroup && isAdmin,
            pinned: pins.contains { $0.message_id == m.id },
            selecting: selecting, selected: selected.contains(m.id),
            highlighted: hitID == m.id,
            roleTag: isGroup ? roleOf(m.sender_id) : nil,
            asGroup: asGroup,
            senderAvatar: avatar,
            avatarSlot: isGroup && !asGroup,
            handle: handle,
            replySenderName: isGroup ? m.reply_sender_id.flatMap { memberNames[$0] } : nil,
            replyPhotoID: m.reply_to_id.flatMap { replyPhotos[$0] },
            token: token,
            // an album: each photo opens its own menu (the row's would win the long press)
            ownMenu: albums.at[m.id] == nil)
    }

    private func rowActions(_ m: Message, _ albums: Albums.Runs, asGroup: Bool) -> MessageRowActions {
        MessageRowActions(
            copyLink: {
                UIPasteboard.general.string = "tradeflor://chat/\(chat.conversation_id)/message/\(m.id)"
                flash("chat.link.copied")
            },
            select: { selecting = true; selected = [m.id] },
            toggleSelect: {
                guard m.kind != "call" else { return } // a call entry goes with "Select all" only
                // an album is selected (and unselected) with all its photos
                let ids = albums.at[m.id]?.map(\.id) ?? [m.id]
                if selected.contains(m.id) { ids.forEach { selected.remove($0) } } else { ids.forEach { selected.insert($0) } }
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
            edit: canEdit(m) ? { startEdit(m) } : nil)
    }

    @ViewBuilder private func rowContent(_ m: Message, _ albums: Albums.Runs) -> some View {
        if let album = albums.at[m.id] {
            AlbumGrid(token: token, photos: album, mine: m.sender_id == me,
                      state: m.sender_id == me ? receipt(album.last ?? m) : nil,
                      me: me,
                      actions: AlbumTileActions(
                          reply: { p in replyingTo = p; composerFocused = true },
                          react: { p, e in Task { await react(p, e) } },
                          forward: restricted ? nil : { p in forwarding = p },
                          save: restricted ? nil : { p in Task { await saveAttachment(p) } },
                          delete: { p in deleteTargets = [p]; showDelete = true },
                          select: { p in selecting = true; selected = Set(album.map(\.id)) })) { fid in
                viewing = ViewedPhoto(id: fid, messageID: album.first(where: { $0.file_id == fid })?.id)
            }
        } else {
            messageContent(m)
        }
    }

    /// A message on its way (dimmed, with its upload progress and X), or one that failed (Retry / Delete).
    private func pendingRow(_ p: PendingMessage) -> some View {
        Group {
            if p.missing {
                MissingMediaBubble()
            } else if let img = p.image {
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
        .onTapGesture {
            if p.missing { pending.removeAll { $0.id == p.id } } // nothing to send: a tap removes the note
            else if p.failed { Task { await deliver(p, retry: true) } }
        }
        .overlay(alignment: .bottomTrailing) {
            if p.failed && !p.missing {
                // "Not sent · Retry" (website FailedBadge), with Delete in the menu
                Text("chat.notsent.retry").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.danger)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.card, in: Capsule())
                    .offset(y: 16)
                    .allowsHitTesting(false)
            }
        }
        .padding(.bottom, p.failed && !p.missing ? 18 : 0)
        .contextMenu {
            if p.missing {
                Button(role: .destructive) { pending.removeAll { $0.id == p.id } } label: { Label("chat.delete", systemImage: "trash") }
            } else if p.failed {
                Button { Task { await deliver(p, retry: true) } } label: { Label("chat.retry", systemImage: "arrow.clockwise") }
                Button(role: .destructive) {
                    pending.removeAll { $0.id == p.id }
                    if let f = p.file { try? FileManager.default.removeItem(at: f) } // this device's copy of a large file
                } label: { Label("chat.delete", systemImage: "trash") }
            }
        }
    }

    private func scrollChrome<V: View>(_ v: V, _ proxy: ScrollViewProxy) -> some View {
        v
            .overlay(alignment: .bottomTrailing) { jumpArrows(proxy) }
            .overlay(alignment: .top) { toastOverlay }
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
            .overlay { emptyOverlay }
    }

    /// WhatsApp's jump arrow and, in groups, the "@" for the next mention.
    private func jumpArrows(_ proxy: ScrollViewProxy) -> some View {
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
                                Text(unseenBelow.count > 99 ? "99+" : "\(unseenBelow.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.hex(0x04222C))
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

    @ViewBuilder private var toastOverlay: some View {
        if let toast {
            Text(toast).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                .padding(.horizontal, 14).padding(.vertical, 8).background(Theme.card, in: Capsule())
                .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1)).padding(.top, 10)
        }
    }

    @ViewBuilder private var emptyOverlay: some View {
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
        } else if !loading && messages.isEmpty && pending.isEmpty && canPost {
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

    /// Where the list stands when the chat opens, and how it follows new and pending messages.
    private func settling<V: View>(_ v: V, _ proxy: ScrollViewProxy) -> some View {
        v
            .onChange(of: messages.last?.id) { _ in
                if !openedAtEnd && !messages.isEmpty {
                    // the chat opens at its end (or at the unread line): again once pictures have taken their room
                    openedAtEnd = true
                    openedAtTime = Date()
                    let hasMark = unreadMarkID != nil && unreadMarkCount > 0
                    if hasMark { proxy.scrollTo("unread-mark", anchor: .top) } else { proxy.scrollTo("bottom", anchor: .bottom) }
                    if !hasMark {
                        for d in [0.35, 0.9, 1.6] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                                // pictures took their room: settle on the end again, but only if I haven't scrolled away
                                if !userScrolledUp { proxy.scrollTo("bottom", anchor: .bottom) }
                            }
                        }
                    }
                    return
                }
                // at the end, new messages are simply followed; up in the history they are counted instead
                // only while the end is on screen: a message arriving while I read up in the history never moves the list
                if bottomVisible { scrollToBottom(proxy) }
            }
            // the composer grew a line while I am at the end: keep the end in view, without an animation that fights the typing
            .onChange(of: min(6, draft.components(separatedBy: "\n").count)) { _ in
                guard bottomVisible else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // while the chat is still opening, anything added above (the server's page after the copy kept on this
            // phone, the unread line, a day label) must not push the end out of view: settle on it again
            .onChange(of: messages.count) { _ in
                guard openedAtEnd, !userScrolledUp, unreadMarkID == nil || unreadMarkCount == 0,
                      Date().timeIntervalSince(openedAtTime) < 2.5 else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: unreadMarkID) { id in
                if id != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { proxy.scrollTo("unread-mark", anchor: .top) } }
            }
            .onChange(of: pending.count) { n in
                // something I just sent goes to the end; one that left (sent, cancelled) never moves the list
                let added = n > pendingCountSeen
                pendingCountSeen = n
                if added || bottomVisible { scrollToBottom(proxy) }
            }
            // focusing the composer moves to the end only when the end is already on screen (never while reading history)
            .onChange(of: composerFocused) { f in if f && bottomVisible { scrollToBottom(proxy) } }
    }

    @ViewBuilder private var chatFooter: some View {
        if selecting {
            selectBar
        } else if canPost {
            composer
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { composerHeight = g.size.height }
                        .onChange(of: g.size.height) { composerHeight = $0 }
                })
        } else {
            Text(LocalizedStringKey(removedFromGroup ? "group.removed" : "group.readonly")).font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(barColor.ignoresSafeArea(edges: .bottom))
        }
    }

    private func chatHead<V: View>(_ v: V) -> some View {
        v
        .background(ChatThemeStyle.background(themeID).ignoresSafeArea())
        .environment(\.tfChatThemed, !(themeID.isEmpty || themeID == "tradeflor"))
        .messageMenuHost()
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
            let until = Date().addingTimeInterval(isGroup ? 3.5 : 5)
            peerTypingUntil = until
            typingUser = t.user
            typingUsers[t.user] = until
            Task {
                try? await Task.sleep(nanoseconds: UInt64((isGroup ? 3.6 : 5.2) * 1_000_000_000))
                let now = Date()
                typingUsers = typingUsers.filter { $0.value > now }
                if let u = peerTypingUntil, u <= now { peerTypingUntil = nil }
            }
        }
        .confirmationDialog(Text(String(format: NSLocalizedString("chat.block.confirm", comment: ""), chat.title)),
                            isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("chat.block", role: .destructive) {
                Task {
                    // `problem` only shows on an empty chat: the toast is what the user sees here
                    do {
                        try await APIClient.shared.block(token: token, userID: chat.peer_id)
                        flash("chat.blocked.done")
                    } catch {
                        flash("chat.action.failed")
                    }
                }
            }
        }
    }

    private func chatHead2<V: View>(_ v: V) -> some View {
        v
        .sheet(isPresented: $showInfo, onDismiss: {
            // left or deleted from Group Info: back to the list (the group is no longer mine to read)
            if groupGone { dismissView(); return }
            Task {
                themeID = await ChatThemeStore.load(token: token, conversationID: chat.conversation_id)
                await loadMeta()
            }
        }) {
            if isGroup {
                GroupInfoView(groupID: chat.conversation_id, onGone: { groupGone = true })
                    .environmentObject(store).environmentObject(live)
            } else {
                ContactInfoView(chat: chat, onSearch: { showInfo = false; searchOpen = true })
                    .environmentObject(store).environmentObject(live)
            }
        }
        .sheet(isPresented: $showSchedule) { ScheduleSheet(chat: chat, initialText: draft) }
        .sheet(item: $profileFor) { p in MemberProfileSheet(member: p).environmentObject(store) }
        .fullScreenCover(isPresented: $addingGroupStatus) {
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
            var first = true
            while isGroup && !Task.isCancelled {
                // the app's live connection does not pass on group changes (rights, pins): read them again every minute,
                // so a chat closed or opened by an admin, a mute or a new pin shows without leaving the chat
                if !first, await refreshRights() {
                    pins = await APIClient.shared.chGroupPins(token: token, groupID: chat.conversation_id)
                }
                first = false
                if isAdmin { await loadJoinWaiting() }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .onReceive(live.joinRequests) { d in if d["conversation_id"] == chat.conversation_id { Task { await loadJoinWaiting() } } }
        // the server says this group changed (rights, pins, members): re-read at once instead of waiting for the minute
        .onReceive(NotificationCenter.default.publisher(for: .tfStatusChanged)) { _ in if isGroup { Task { await loadGroupStatus() } } }
        .onReceive(live.groupChanged) { id in
            guard isGroup, id == chat.conversation_id else { return }
            Task {
                if await refreshRights() { pins = await APIClient.shared.chGroupPins(token: token, groupID: chat.conversation_id) }
            }
        }
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
    }

    private func chatMiddle<V: View>(_ v: V) -> some View {
        v
        .fullScreenCover(item: $openDoc) { d in DocumentPreview(url: d.url).ignoresSafeArea() }
        .sheet(isPresented: $showFocus) {
            if let doc = focusDoc {
                SmartFocusSheet(groupID: chat.conversation_id, members: members, me: me, initial: doc, roles: memberRoles) { saved in
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
        .overlay { emojiLayer }
        .sheet(isPresented: $showLocationSheet) {
            ShareLocationSheet { minutes in location.start(token: token, conversationID: chat.conversation_id, minutes: minutes) }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $picked, maxSelectionCount: 30, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showDocPicker, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result { Task { await sendDocument(url) } }
        }
    }

    private func chatMiddle2<V: View>(_ v: V) -> some View {
        v
        .confirmationDialog(Text(LocalizedStringKey(deleteTargets.count > 1 ? "chat.delete.many" : "chat.delete.one")),
                            isPresented: $showDelete, titleVisibility: .visible) {
            if deleteTargets.contains(where: { $0.sender_id == me && !$0.isDeleted && $0.kind != "call" }) {
                Button("chat.unsend", role: .destructive) { Task { await deleteSelected(everyone: true) } }
            }
            // the group's owner and admins may delete other people's messages for everyone (server deleteOne, audited;
            // website confirmDelete othersForAll)
            if isGroup && isAdmin && deleteTargets.contains(where: { $0.sender_id != me && !$0.isDeleted && $0.kind != "call" }) {
                Button("grp.delete.others", role: .destructive) { Task { await deleteSelected(everyone: true, others: true) } }
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
                        // the chat closes only once the server has let me go; otherwise I stay and see why
                        do {
                            try await APIClient.shared.removeGroupMember(token: token, id: chat.conversation_id, userID: "")
                            dismissView()
                        } catch APIError.refused(let why) {
                            flashText(why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why)
                        } catch {
                            flash("chat.action.failed")
                        }
                    }
                }
            }
        }
        .confirmationDialog(Text("group.delete.confirm"), isPresented: $confirmDeleteGroup, titleVisibility: .visible) {
            Button("group.delete", role: .destructive) {
                Task {
                    do {
                        _ = try await APIClient.shared.postJSON("groups/\(chat.conversation_id)/delete", token: token, body: [:])
                        dismissView()
                    } catch APIError.refused(let why) {
                        flashText(why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why)
                    } catch {
                        flash("chat.action.failed")
                    }
                }
            }
        }
        .sheet(item: Binding(get: { exportURL.map { ExportFile(url: $0) } }, set: { if $0 == nil { exportURL = nil } })) { f in
            // the system share sheet itself (a ShareLink alone in a 160 pt sheet crashed the app when it opened)
            ActivityShare(items: [f.url]).ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar) // full height for the conversation, like other messengers
    }

    private func chatTail<V: View>(_ v: V) -> some View {
        v
        .task {
            if isGroup { await loadPeople() }
            await loadMeta()
            themeID = await ChatThemeStore.load(token: token, conversationID: chat.conversation_id)
        }
        .task {
            // the messages this chat showed last time (this app session, memory only): on screen at once, as in WhatsApp
            if messages.isEmpty, let seen = ChatMemo.get(chat.conversation_id), !seen.isEmpty { merge(seen) }
            await loadNewest()
        }
        // after a dropped connection or a return to the app: catch up so nothing sent meanwhile is missing
        .onReceive(live.opened) { _ in
            queueWait?.cancel() // the connection is back: a waiting line tries now
            Task { await loadNewest(quiet: true) }
        }
        .onChange(of: scenePhase) { p in
            if p == .active { Task { await loadNewest(quiet: true) } }
            if p == .background { saveDraft() }
        }
        // unsent messages are kept on the device and sent again when the chat opens (same idempotency key)
        .onChange(of: pending) { list in
            if outboxLoaded { OutboxStore.save(account: me, conversation: chat.conversation_id, list) }
        }
        .task {
            guard !outboxLoaded else { return }
            let saved = OutboxStore.load(account: me, conversation: chat.conversation_id).filter { s in !pending.contains { $0.id == s.id } }
            pending.append(contentsOf: saved)
            outboxLoaded = true
            // texts and voice first, in writing order; a long upload never holds them back
            // (what the server refused for good stays "Not sent": Retry sends it, opening the chat does not)
            for p in saved.sorted(by: { $0.date < $1.date }) where isLine(p) && !p.refused { sendQueue.append(p.id) }
            for p in saved where !isLine(p) && !p.refused { Task { await deliver(p) } }
            await runQueue()
        }
        .onReceive(live.messages) { m in
            guard m.conversation_id == chat.conversation_id, !locked, !m.isSealed else { return } // a locked chat shows nothing until it is unlocked
            let isNew = !messages.contains { $0.id == m.id }
            merge([m])
            pending.removeAll { $0.id == m.client_key }
            if isNew && !bottomVisible && m.sender_id != me && m.kind != "notice" {
                unseenBelow.append(m.id)
                if isGroup && ChatEdit.mentions(m, me: me) { unseenMentions.append(m.id) }
            }
            if m.sender_id != me { markSeenSoon() }
        }
        .onReceive(live.hidden) { h in
            // hidden for me, or the chat cleared on any of my devices: those messages leave at once
            guard h.conversation == chat.conversation_id else { return }
            let gone = Set(h.ids)
            messages.removeAll { gone.contains($0.id) }
        }
        .onReceive(live.changes) { id in
            guard id == chat.conversation_id else { return }
            // a burst of receipts / reactions is one page fetch, not one each
            changeReload?.cancel()
            changeReload = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
                await loadNewest(quiet: true)
            }
        }
    }

    private func chatTail2<V: View>(_ v: V) -> some View {
        v
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
                    // every preview shows at once (in order), then they leave side by side
                    var ready: [PendingMessage] = []
                    for d in drafts {
                        if let url = d.videoURL { Task { await sendVideo(url, caption: d.caption) } }
                        else if let img = d.image, let p = await preparePhoto(img, caption: d.caption, hd: hd) { ready.append(p) }
                    }
                    for p in ready { Task { await deliver(p) } }
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
            mediaViewer(v)
        }
        .sheet(isPresented: $showUnlock) {
            UnlockSheet(token: token) { Task { await loadNewest() } }
                .presentationDetents([.large])
        }
        .fullScreenCover(item: $watching) { v in
            mediaViewer(v)
        }
        .onAppear {
            TabChrome.shared.conversationOpened() // the dock steps aside inside a conversation (web: one region at a time)
            box.onEmptyChange = { e in draftEmpty = e }
            box.onMentionChange = { q in mentionQ = q }
            LocalNotifier.shared.openConversation = chat.conversation_id
            LocalNotifier.shared.clear(conversation: chat.conversation_id)
            gone = false
            // back on this chat (pushed screen closed): the line that stopped sending goes on
            if !sendQueue.isEmpty && !queueRunning { Task { await runQueue() } }
            // what was typed and not sent when this chat was left
            if box.text.isEmpty {
                let kept = ChatDrafts.get(account: me, conversation: chat.conversation_id)
                if !kept.isEmpty { box.text = kept }
            }
        }
        .onDisappear {
            if !locked && !messages.isEmpty { ChatMemo.put(chat.conversation_id, Array(messages.suffix(80))) }
            TabChrome.shared.conversationClosed()
            if LocalNotifier.shared.openConversation == chat.conversation_id { LocalNotifier.shared.openConversation = nil }
            saveDraft()
            // this screen stops sending; what is still waiting is sent from the saved outbox
            gone = true
            queueWait?.cancel()
            OutboxFlusher.shared.flushSoon()
            VoicePlayer.shared.stop()
            if recorder.recording { recorder.cancel() }
        }
        .onChange(of: recorder.notice) { n in
            if let n { flash(n); recorder.notice = nil }
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
                .disabled(calls.lineInUse)
                .accessibilityLabel(Text("call.voice"))
            }
            Button { searchOpen.toggle(); searchText = "" } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(Theme.muted).frame(width: 34, height: 44)
            }
            .accessibilityLabel(Text("chat.search"))
            ChatHeaderMenu(items: headerMenuItems) {
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

    private var headerMenuItems: [ChatMenuItem] {
        var items: [ChatMenuItem] = []
        if isGroup {
            items.append(ChatMenuItem("group.info", systemImage: "info.circle") { showInfo = true })
            if groupStatus != nil { items.append(ChatMenuItem("gst.watch", systemImage: "circle.dashed") { watchingGroupStatus = true }) }
            if isAdmin { items.append(ChatMenuItem("gst.add", systemImage: "plus.circle.dashed") { addingGroupStatus = true }) }
        }
        let muteItem = muted
            ? ChatMenuItem("chats.unmute", systemImage: "bell") { Task { await mute(seconds: 0) } }
            : ChatMenuItem("chat.mute.menu", systemImage: "bell.slash") { showMute = true }
        let scheduledItem = ChatMenuItem("chat.scheduled", systemImage: "calendar") { showSchedule = true }
        if isGroup {
            items.append(muteItem)
            items.append(scheduledItem)
            if focusDoc != nil { items.append(ChatMenuItem("focus.title", systemImage: "scope") { showFocus = true }) }
            items.append(ChatMenuItem("group.export", systemImage: "arrow.down.to.line") { Task { await exportHistory() } })
            items.append(ChatMenuItem("group.leave", systemImage: "rectangle.portrait.and.arrow.right", destructive: true) { confirmLeave = true })
            if myRole == "owner" { items.append(ChatMenuItem("group.delete", systemImage: "trash", destructive: true) { confirmDeleteGroup = true }) }
        } else {
            items.append(scheduledItem)
            items.append(muteItem)
            items.append(ChatMenuItem(verbatim: String(format: NSLocalizedString("chat.block.name", comment: ""), chat.title),
                                      id: "chat.block", systemImage: "nosign", destructive: true) { confirmBlock = true })
        }
        return items
    }

    private var attachMenuItems: [ChatMenuItem] {
        let media = !isGroup || groupCanSendMedia
        var items: [ChatMenuItem] = []
        if media {
            items.append(ChatMenuItem("attach.photo", systemImage: "photo", tint: .photo) { showPhotoPicker = true })
            items.append(ChatMenuItem("attach.document", systemImage: "doc", tint: .document) { showDocPicker = true })
        }
        items.append(ChatMenuItem("location.live", systemImage: "mappin", tint: .location) { showLocationSheet = true })
        if CameraPicker.isAvailable && media {
            items.append(ChatMenuItem("note.record", systemImage: "video.fill", tint: .note) { showNoteRecorder = true })
        }
        if isGroup {
            // anyone who may write may start a poll (server POST /groups/{id}/polls: the send gate; website: can_send)
            items.append(ChatMenuItem("poll.new", systemImage: "chart.bar", tint: .poll) { showPoll = true })
            if groupCanSignals { items.append(ChatMenuItem("signal.new", systemImage: "chart.line.uptrend.xyaxis", tint: .signal) { showSignal = true }) }
        }
        items.append(ChatMenuItem("schedule.title", systemImage: "clock", tint: .schedule) { showSchedule = true })
        return items
    }

    /// The emoji picker (web EmojiPicker): above the message bar for typing, centred for a reaction; a tap outside closes.
    @ViewBuilder private var emojiLayer: some View {
        if showEmoji {
            if let t = reactTarget {
                EmojiFloating(single: true, onPick: { e in
                    reactTarget = nil
                    showEmoji = false
                    Task { await react(t, e) }
                }, onClose: { reactTarget = nil; showEmoji = false })
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.001).onTapGesture { showEmoji = false }
                        EmojiPanel(bodyHeight: max(150, min(300, geo.size.height - composerHeight - 150)),
                                   onPick: { e in draft += e }, onClose: { showEmoji = false })
                            .padding(.horizontal, 8)
                            .padding(.bottom, composerHeight + 6)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private var draftIsEmpty: Bool { draftEmpty }

    private var mentionQuery: String? { isGroup ? mentionQ : nil }

    private var mentionMatches: [GroupMember] {
        guard let q = mentionQuery else { return [] }
        return Array(members.filter { $0.user_id != me && !formerIDs.contains($0.user_id) && (q.isEmpty || $0.username.lowercased().hasPrefix(q) || $0.title.lowercased().hasPrefix(q)) }.prefix(6))
    }

    /// The @ suggestions float above the bar as an overlay: they take no room in the composer, so the list does not move.
    @ViewBuilder private var mentionPanel: some View {
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
    }

    private var typingBar: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                if holdRec {
                    holdStrip
                } else {
                ChatAttachMenu(items: attachMenuItems) {
                    Image(systemName: "plus").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.text)
                        .frame(width: 40, height: 40).background(Theme.inputGradient, in: Circle())
                        .overlay(Circle().stroke(Theme.hex(0x1C8CB2, 0.85), lineWidth: 1.5))
                }
                .accessibilityLabel(Text("attach.title"))
                HStack(alignment: .center, spacing: 0) {
                    // not in a group: the + menu already has Document, and the text field needs the room (375 pt screen, admin)
                    if !isGroup {
                        Button { showDocPicker = true } label: { composerIcon("paperclip") }
                            .accessibilityLabel(Text("attach.document"))
                    }
                    DraftField(box: box, placeholder: LocalizedStringKey(isGroup ? "chat.placeholder.group" : "chat.placeholder"),
                               focus: $composerFocused) {
                        guard editing == nil, Date().timeIntervalSince(lastTypingSent) > 3 else { return }
                        lastTypingSent = Date()
                        live.sendTyping(conversationID: chat.conversation_id)
                    }
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
                if draftIsEmpty && CameraPicker.isAvailable && (!isGroup || groupCanSendMedia) && !(isGroup && composerFocused) {
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
        .overlay(alignment: .top) { mentionPanel.alignmentGuide(.top) { d in d[.bottom] + 6 } }
    }

    private var holdStrip: some View {
        HStack(spacing: 10) {
            HoldClock(meter: recorder.meter)
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
        return HStack(spacing: 14) {
            Button { selecting = false; selected = []; allPicked = false } label: {
                Image(systemName: "xmark").font(.system(size: 20, weight: .regular)).foregroundStyle(Theme.muted)
                    .frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(Text("select.cancel"))
            Text(String(format: NSLocalizedString("select.count", comment: ""), selected.count))
                .font(.system(size: 18)).foregroundStyle(Theme.text).lineLimit(1)
            // everything in the chat (loaded by pages first), as before
            Button { Task { await selectAll() } } label: {
                if pickingAll { ProgressView().tint(Theme.accent) } else {
                    Text(LocalizedStringKey(allSelected ? "select.clear" : "select.all"))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
            .disabled(pickingAll)
            Spacer(minLength: 4)
            Button {
                if let first = chosen.first { forwarding = first }
                selecting = false
                selected = []
                allPicked = false
            } label: { Image(systemName: "arrowshape.turn.up.right").font(.system(size: 21)).frame(width: 44, height: 44) }
            .disabled(chosen.isEmpty || restricted)
            .accessibilityLabel(Text("chat.forward"))
            Button {
                UIPasteboard.general.string = chosen.filter { $0.kind == "text" }.map(\.body).joined(separator: "\n")
                selecting = false
                selected = []
                flash("chat.copied")
            } label: { Image(systemName: "doc.on.doc").font(.system(size: 21)).frame(width: 44, height: 44) }
            .disabled(!canCopy || restricted)
            .accessibilityLabel(Text("chat.copy"))
            Button {
                deleteTargets = chosen
                showDelete = true
            } label: { Image(systemName: "trash").font(.system(size: 21)).frame(width: 44, height: 44) }
            .disabled(chosen.isEmpty)
            .accessibilityLabel(Text("chat.delete"))
        }
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 12)
        .frame(height: 60)
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
        // a pin removed meanwhile (the list got shorter): never "3/2"
        let at = min(pinIndex, pins.count - 1)
        let p = pins[at]
        return HStack(spacing: 4) {
            Button {
                pinIndex = (at + 1) % max(pins.count, 1)
                if let m = messages.first(where: { $0.id == p.message_id }) { searchText = ""; jumpTarget = m.id }
                else { flash("chat.reply.notloaded") } // older than what is loaded: said, not a tap that does nothing
            } label: {
                HStack(spacing: 10) {
                    Rectangle().fill(Theme.accent).frame(width: 3, height: 32)
                    // the pinned photo's thumbnail (retried after a refused first try, web 4ceceea), or the kind's icon
                    if p.kind == "image", let fid = p.file_id, !fid.isEmpty {
                        RemoteImage(token: token, fileID: fid).frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 6)).id(fid)
                    } else if let icon = ["file": "doc", "voice": "mic", "poll": "chart.bar", "signal": "chart.line.uptrend.xyaxis",
                                          "location": "location"][p.kind] {
                        Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pins.count > 1 ? String(format: NSLocalizedString("pin.n.of", comment: ""), at + 1, pins.count)
                                            : NSLocalizedString("pin.one", comment: ""))
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                        // the thumbnail already says it is a photo: no leading picture sign
                        Text(p.text.isEmpty ? NSLocalizedString("pin." + p.kind, comment: "")
                                            : (p.file_id != nil && p.kind == "image" ? p.text.replacingOccurrences(of: "^[🖼📷]\\s*", with: "", options: .regularExpression) : p.text))
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
        let text = NSLocalizedString(key, comment: "")
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if toast == text { toast = nil } // a newer note keeps its own time on screen
        }
    }

    private func loadMeta() async {
        if isGroup {
            await refreshRights()
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

    /// What I may do in this group now (GET /groups/{id}): the role, writing, media, signals, reactions. The list's `can_send`
    /// was only true when the list was read: an admin closing the chat (or muting me, or opening it again) changes it.
    /// A read that fails keeps what is known.
    @discardableResult
    private func refreshRights() async -> Bool {
        let g = await APIClient.shared.chGroupRole(token: token, groupID: chat.conversation_id)
        if g.gone {
            // removed, banned, or the group deleted: no composer, nothing waiting to be sent, nothing remembered
            removedFromGroup = true
            liveCanSend = false
            pending.removeAll()
            sendQueue.removeAll()
            OutboxStore.clear(account: me, conversation: chat.conversation_id)
            ChatMemo.drop(chat.conversation_id)
            return false
        }
        guard g.ok else { return false }
        removedFromGroup = false
        myRole = g.role
        liveCanSend = g.canSend
        groupCanSendMedia = g.canSendMedia
        groupCanSignals = g.canPostSignals
        groupCanReact = g.canReact
        groupComments = g.comments
        memberCount = g.memberCount
        return true
    }

    /// Who is who in the group. Everyone may read the people who posted (GET /groups/{id}/senders, website listGroupSenders);
    /// only the owner and admins may read the whole member directory (/members), which adds those who never posted.
    private func loadPeople() async {
        var all: [String: GroupMemberFull] = [:]
        for p in (try? await APIClient.shared.list(GroupMemberFull.self, "groups/\(chat.conversation_id)/senders", token: token)) ?? [] { all[p.user_id] = p }
        for p in (try? await APIClient.shared.list(GroupMemberFull.self, "groups/\(chat.conversation_id)/admins", token: token)) ?? [] { all[p.user_id] = p }
        for p in (try? await APIClient.shared.list(GroupMemberFull.self, "groups/\(chat.conversation_id)/members", token: token)) ?? [] { all[p.user_id] = p }
        let list = Array(all.values)
        // people who left or were removed keep their names on old messages, but are not offered for "@"
        formerIDs = Set(list.filter { $0.active == false }.map(\.user_id))
        members = list.map { GroupMember(user_id: $0.user_id, username: $0.username, display_name: $0.display_name) }
        lookAlike = NameSkeleton.lookAlikeIDs(members)
        memberNames = Dictionary(list.map { ($0.user_id, $0.title) }, uniquingKeysWith: { a, _ in a })
        memberRoles = Dictionary(list.filter { $0.role != "member" }.map { ($0.user_id, $0.role) }, uniquingKeysWith: { a, _ in a })
        memberAvatars = Dictionary(list.compactMap { p in (p.avatar_id?.isEmpty == false) ? (p.user_id, p.avatar_id!) : nil }, uniquingKeysWith: { a, _ in a })
    }

    private func loadJoinWaiting() async {
        guard isGroup, isAdmin else { joinWaiting = 0; return }
        joinWaiting = await APIClient.shared.grpJoinRequests(token: token, id: chat.conversation_id).count
    }

    private func loadGroupStatus() async {
        guard let feed = try? await APIClient.shared.statusFeed(token: token) else { return } // a failed read keeps what is shown
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

    /// A group's sender line and picture start again after another sender, a 5-minute pause or a new day (web fda47e1).
    private func newBlock(_ rows: [Message], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let a = rows[i - 1], b = rows[i]
        return a.sender_id != b.sender_id || ChatEdit.secs(b.created_at) - ChatEdit.secs(a.created_at) > 300 || !sameDay(a, b)
            || a.kind == "notice" || a.kind == "call"
    }

    private func transient(_ error: Error) -> Bool {
        if error is URLError { return true }
        switch error as? APIError {
        case .rateLimited?, .network?: return true
        case .server(let status)?: return status >= 500
        default: return false
        }
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
    /// Batches of 100, 3 tries each; returns the ids that could not be done.
    private func inBatches(_ ids: [String], _ op: ([String]) async throws -> Void) async -> [String] {
        var failed: [String] = []
        var i = 0
        while i < ids.count {
            let chunk = Array(ids[i..<min(i + 100, ids.count)])
            i += 100
            var done = false
            for attempt in 0..<3 where !done {
                do { try await op(chunk); done = true } catch {
                    if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(600_000_000 * (attempt + 1))) }
                }
            }
            if !done { failed += chunk }
        }
        return failed
    }

    private func deleteSelected(everyone: Bool, others: Bool = false) async {
        let targets = deleteTargets
        let asked = Set(targets.map(\.id))
        var ids = targets.map(\.id)
        // after "Select all" of the whole chat, the call entries go too: nothing is left behind
        if allPicked && messages.filter(selectable).allSatisfy({ asked.contains($0.id) }) {
            ids += messages.filter { $0.kind == "call" && !asked.contains($0.id) }.map(\.id)
        }
        deleteTargets = []
        if ids.count > 100 { flashText(String(format: NSLocalizedString("select.deleting", comment: ""), ids.count)) }
        var failed: [String] = []
        if everyone {
            // unsend only my own messages that are still there; then everything chosen leaves my view too (web b9833d1)
            // (an admin's "for everyone" takes the others' messages too; one the server refuses still leaves my view below)
            let mine = targets.filter { ($0.sender_id == me || (others && isGroup && isAdmin)) && !$0.isDeleted && $0.kind != "call" }.map(\.id)
            failed += await inBatches(mine) { try await APIClient.shared.chDeleteBatch(token: token, ids: $0) }
        }
        let hideFailed = await inBatches(ids.filter { !failed.contains($0) }) { chunk in
            try await APIClient.shared.chHideBatch(token: token, ids: chunk)
            let gone = Set(chunk)
            messages.removeAll { gone.contains($0.id) } // every batch the server took leaves the screen at once
        }
        failed += hideFailed
        let done = ids.count - Set(failed).count
        if done > 0 && failed.isEmpty {
            flashText(done == 1 ? NSLocalizedString("select.deleted.one", comment: "")
                                : String(format: NSLocalizedString("select.deleted.n", comment: ""), done))
        }
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
            // a timed toast (it was set without one and stayed on screen for good)
            flashText(why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why)
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
        // a file name without "/" ":" and other characters a file name can't hold
        let safe = chat.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "chat" : safe)-chat-history.txt")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
        } catch {
            flash("chat.action.failed")
        }
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
            var page = try await APIClient.shared.messages(token: token, conversationID: chat.conversation_id, limit: pageSize)
            // messages came in while this phone was away (a dropped connection, a long time in the background): when the newest
            // page does not reach back to the last one on screen, the pages in between are fetched too, so no hole stays
            if let known = messages.last?.seq, let oldest = page.map(\.seq).min(), oldest > known + 1 {
                var cursor = oldest
                var met = false
                for _ in 0..<10 {
                    let older = try await APIClient.shared.messages(token: token, conversationID: chat.conversation_id,
                                                                    before: cursor, limit: pageSize)
                    guard let low = older.map(\.seq).min() else { met = true; break } // nothing older: the range is whole
                    page = older + page
                    cursor = low
                    if low <= known + 1 { met = true; break }
                }
                if !met {
                    // too long a gap: start again from the newest messages (older ones load as the reader scrolls up)
                    messages = []
                    reachedStart = false
                }
            }
            if messages.isEmpty {
                // the start of the chat only when the page reaches message 1 or is empty (a page can hold fewer messages when one
                // could not be read: that alone does not mean the start)
                reachedStart = page.isEmpty || (page.map(\.seq).min() ?? 2) <= 1
            }
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
            // a locked chat never shows what this phone remembered
            ChatMemo.drop(chat.conversation_id)
            messages = []
            locked = true
            if !showUnlock && BiometricPIN.isSaved { showUnlock = true } // Face ID straight away
        } catch {
            if messages.isEmpty { problem = NSLocalizedString("chats.error", comment: "") }
        }
    }

    private func loadOlder(_ proxy: ScrollViewProxy? = nil) async {
        guard !loadingOlder, let first = messages.first else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        if let page = try? await APIClient.shared.messages(token: token, conversationID: chat.conversation_id,
                                                           before: first.seq, limit: pageSize) {
            // only an empty page above means the start (a page may hold fewer messages when one could not be read)
            reachedStart = page.isEmpty
            merge(page)
            // the page goes above what I was reading: keep that message where it was (no jump)
            if let proxy, !bottomVisible {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    /// Adds or replaces by id, kept in server order (seq).
    private func merge(_ incoming: [Message]) {
        let incoming = incoming.filter { !$0.isSealed } // a stub of a locked chat is never shown or kept
        guard !incoming.isEmpty else { return }
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for m in incoming { byID[m.id] = m }
        let now = Int64(Date().timeIntervalSince1970)
        // disappearing messages leave once their time is up (the server erases them too)
        let next = byID.values.filter { ($0.expires_at ?? 0) == 0 || ($0.expires_at ?? 0) > now }.sorted { $0.seq < $1.seq }
        if next != messages { messages = next }
        // a message that came back from the server (a reload, the live socket) is no longer "sending"
        if !pending.isEmpty {
            let keys = Set(incoming.compactMap { $0.client_key })
            if !keys.isEmpty { pending.removeAll { keys.contains($0.id) } }
        }
    }

    // MARK: sending

    private func canEdit(_ m: Message) -> Bool { ChatEdit.canEdit(m, me: me) && canPost && !restricted }

    private func startEdit(_ m: Message) {
        replyingTo = nil
        editing = m
        draft = m.body
        composerFocused = true
    }

    /// The server refuses a text over 16000 bytes (413): said before sending, with what was typed kept.
    private static let maxTextBytes = 16000

    private func saveEdit(_ m: Message, _ text: String) async {
        if text.utf8.count > Self.maxTextBytes { flash("chat.toolong"); return } // stays in the field to be shortened
        editing = nil
        draft = ""
        guard text != m.body else { return }
        var ok = false
        defer { if !ok && draft.isEmpty && editing == nil { draft = text } } // a failed edit keeps what was typed
        do {
            merge([try await APIClient.shared.editMessage(token: token, messageID: m.id, body: text,
                                                          mentions: isGroup ? MentionsBuilder.build(text, members: members) : [])])
        ok = true
        } catch APIError.refused(let why) {
            flashText(why.isEmpty ? NSLocalizedString("chat.edit.failed", comment: "") : why)
        } catch APIError.server(status: 409) {
            flash("chat.edit.late")
        } catch {
            flash("chat.edit.failed")
        }
    }

    /// Keeps what is typed (not a message being edited, not a locked chat) for the next time this chat opens.
    private func saveDraft() {
        guard !locked, !me.isEmpty else { return }
        ChatDrafts.set(account: me, conversation: chat.conversation_id, editing == nil ? draft : "")
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
        if text.utf8.count > Self.maxTextBytes { flash("chat.toolong"); return } // not sent, not cleared: shorten it or split it
        if let e = editing { await saveEdit(e, text); return }
        unreadMarkID = nil // the "N unread messages" line goes once I write here (web 5b6f8e1)
        draft = ""
        ChatDrafts.set(account: me, conversation: chat.conversation_id, "")
        var p = PendingMessage(id: UUID().uuidString.lowercased(), body: text, date: Date())
        p.replyTo = replyingTo?.id ?? ""
        replyingTo = nil
        pending.append(p)
        await deliver(p)
    }

    // MARK: message actions

    @ViewBuilder private func messageContent(_ m: Message) -> some View {
        if m.kind == "poll" && !m.isDeleted {
            PollCard(message: m, me: me, canVote: canPost || (isGroup && groupCanReact)) { opts in
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
            VideoNoteBubble(token: token, message: m, mine: m.sender_id == me) { watching = ViewedPhoto(id: fid, messageID: m.id) }
        } else if m.kind == "voice", m.audio_id != nil, !m.isDeleted {
            VoiceBubble(token: token, message: m, mine: m.sender_id == me, state: m.sender_id == me ? receipt(m) : nil,
                        avatarID: m.sender_id == me ? nil : (isGroup ? memberAvatars[m.sender_id] : chat.peer_avatar_id),
                        name: isGroup ? memberNames[m.sender_id] : (m.sender_id == me ? nil : chat.title))
        } else if m.kind == "file", let fid = m.file_id, (m.file_mime ?? "").hasPrefix("video/"), !m.isDeleted {
            VideoBubble(token: token, message: m, mine: m.sender_id == me, state: m.sender_id == me ? receipt(m) : nil) {
                watching = ViewedPhoto(id: fid, messageID: m.id)
            }
        } else if m.kind == "image", let fid = m.file_id, !m.isDeleted {
            PhotoBubble(mine: m.sender_id == me, date: m.date, state: m.sender_id == me ? receipt(m) : nil, caption: m.body, fileID: fid) {
                RemoteImage(token: token, fileID: fid)
            }
            .onTapGesture { viewing = ViewedPhoto(id: fid, messageID: m.id) }
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

    /// The chat's photos and videos, oldest first, for the full-screen viewer (its strip and its sideways swipe).
    private var viewerItems: [MediaViewerItem] {
        messages.compactMap { m in
            guard !m.isDeleted, let fid = m.file_id else { return nil }
            let video = (m.kind == "file" && (m.file_mime ?? "").hasPrefix("video/")) || VideoNotePrep.isNote(m)
            guard m.kind == "image" || video else { return nil }
            let mine = m.sender_id == me
            let sender = mine ? NSLocalizedString("chat.you", comment: "")
                : (isGroup ? (memberNames[m.sender_id] ?? chat.title) : chat.title)
            return MediaViewerItem(fileID: fid, video: video, message: m, mine: mine, sender: sender)
        }
    }

    /// The WhatsApp-style viewer (MediaViewer.swift) on this message, with the chat's own actions.
    @MainActor private func mediaViewer(_ v: ViewedPhoto) -> some View {
        var items = viewerItems
        if !items.contains(where: { $0.id == v.messageID || $0.fileID == v.id }) {
            // not in the loaded list (should not happen): show just this file
            items = [MediaViewerItem(fileID: v.id, video: watching?.id == v.id)]
        }
        return MediaViewer(
            token: token, items: items, startID: v.messageID ?? v.id, me: me,
            actions: MediaViewerActions(
                forward: !restricted,
                reply: canPost ? { m in replyingTo = m; composerFocused = true } : nil,
                showInChat: { m in searchText = ""; jumpTarget = m.id },
                delete: { m in deleteTargets = [m]; showDelete = true },
                react: { m, e in Task { await react(m, e) } }))
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
    /// Read receipts for incoming messages, at most one per 0.8 s burst.
    private func markSeenSoon() {
        seenTask?.cancel()
        seenTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }
            guard scenePhase == .active else { return } // not looking: no blue ticks
            await markSeen()
        }
    }

    private func markSeen() async {
        if isGroup {
            if let last = messages.last { await APIClient.shared.markGroupRead(token: token, groupID: chat.conversation_id, seq: last.seq) }
        } else {
            await APIClient.shared.markRead(token: token, conversationID: chat.conversation_id)
        }
    }

    private func react(_ m: Message, _ emoji: String) async {
        do {
            merge([try await APIClient.shared.react(token: token, messageID: m.id, emoji: emoji)])
        } catch APIError.refused(let why) {
            // e.g. reactions turned off in this group: said, instead of a tap that does nothing
            flashText(why.isEmpty || why == "forbidden" ? NSLocalizedString("chat.action.failed", comment: "") : why)
        } catch {
            flash("chat.action.failed")
        }
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
            if isGroup {
                let now = Date()
                let names = typingUsers.filter { $0.value > now }.keys.sorted()
                    .map { id in members.first { $0.user_id == id }?.username ?? memberNames[id] ?? "" }.filter { !$0.isEmpty }
                switch names.count {
                case 0: break
                case 1: return String(format: NSLocalizedString("chat.typing.name", comment: ""), names[0])
                case 2: return String(format: NSLocalizedString("chat.typing.two", comment: ""), names[0], names[1])
                default: return String(format: NSLocalizedString("chat.typing.many", comment: ""), names.count)
                }
                if let u = typingUser, let name = memberNames[u], !name.isEmpty {
                    return String(format: NSLocalizedString("chat.typing.name", comment: ""), name)
                }
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
        replyingTo = nil // a voice note carries no reply: the bar goes, the next text does not inherit it
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
        let outcome = await VideoPrep.export(from: url)
        guard case .ok(let vdata, let vseconds) = outcome else {
            if let i = pending.firstIndex(where: { $0.id == key }) { pending[i].failed = true }
            if case .failed = outcome { flash("chat.video.exportfailed") } else { flash("chat.video.toolarge") } // `problem` only shows on an empty chat
            return
        }
        let out = (data: vdata, seconds: vseconds)
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
        if let p = await preparePhoto(img, caption: caption, hd: hd) { await deliver(p) }
    }

    /// The photo's pending row, shown at once (dimmed, with its ring), ready to be sent.
    private func preparePhoto(_ img: UIImage, caption: String, hd: Bool) async -> PendingMessage? {
        // Encoding a 12 MP photo takes a moment: off the main thread.
        // The bubble shows a copy of at most 1000 px: an HD photo decoded at 4096 px is ~48 MB for each bubble.
        let encoded = await Task.detached(priority: .userInitiated) { () -> (Data, UIImage?)? in
            guard let full = ImagePrep.jpeg(from: img, hd: hd) else { return nil }
            return (full, ImagePrep.jpeg(from: img, maxSide: 1000, startQuality: 0.8).flatMap { UIImage(data: $0) })
        }.value
        guard let enc = encoded else { return nil }
        let jpeg = enc.0
        let preview = enc.1 ?? img
        let p = PendingMessage(id: UUID().uuidString.lowercased(), body: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                               date: Date(), image: preview, jpeg: jpeg)
        pending.append(p)
        return p
    }

    /// Same idempotency key on every retry, so a message that did reach the server is never stored twice.
    private enum SendOutcome { case sent, wait, failed }

    /// Text and voice are "lines": they leave one at a time per conversation, in the order they were written, so fast
    /// typing arrives in order (web 582418a). Photos, videos and documents keep their own uploads.
    private func isLine(_ p: PendingMessage) -> Bool {
        p.audio != nil || (p.jpeg == nil && p.video == nil && p.docName.isEmpty && p.file == nil)
    }

    private func deliver(_ p: PendingMessage, retry: Bool = false) async {
        if isLine(p) {
            if !sendQueue.contains(p.id) { sendQueue.append(p.id) }
            // millisecond order of writing, not of tapping Retry
            let order = Dictionary(pending.map { ($0.id, $0.date) }, uniquingKeysWith: { a, _ in a })
            sendQueue.sort { (order[$0] ?? .distantFuture) < (order[$1] ?? .distantFuture) }
            if let i = pending.firstIndex(where: { $0.id == p.id }) { pending[i].failed = false; pending[i].refused = false }
            // only the Retry button cuts a wait short (a new message does not: the server's Retry-After still stands)
            if retry && queueRunning { queueWait?.cancel() }
            await runQueue()
        } else {
            _ = await sendOne(p, queued: false)
        }
    }

    /// One line for the whole conversation: on a rate limit or no connection everything waits together (back off 1 → 30 s)
    /// and resumes in order, instead of each message retrying on its own timer.
    private func runQueue() async {
        guard !queueRunning else { return }
        queueRunning = true
        defer { queueRunning = false }
        var backoff: UInt64 = 1
        while let id = sendQueue.first, !gone, !Task.isCancelled {
            guard let p = pending.first(where: { $0.id == id }) else { sendQueue.removeFirst(); continue }
            let outcome = await sendOne(p, queued: true)
            // the screen went away meanwhile (a cancelled request looks like a lost connection): nothing is dropped, the
            // message stays in the saved outbox for OutboxFlusher
            if gone || Task.isCancelled { return }
            switch outcome {
            case .sent, .failed:
                sendQueue.removeAll { $0 == id }
                backoff = 1
            case .wait:
                // never sooner than the server's Retry-After; a little jitter so devices don't retry together
                let after = APIClient.shared.lastRetryAfter
                APIClient.shared.lastRetryAfter = 0
                let secs = max(after, Double(backoff) * Double.random(in: 0.8...1.2))
                let t = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000)) }
                queueWait = t
                await t.value
                queueWait = nil
                if gone || Task.isCancelled { return }
                backoff = min(backoff * 2, 30)
            }
        }
    }

    private func sendOne(_ p: PendingMessage, queued: Bool) async -> SendOutcome {
        if let v = p.video, v.isEmpty, p.file == nil { return .failed } // still being re-encoded, or the re-encode failed
        if uploads[p.id] != nil { return .failed } // already going (a second tap, or the outbox and a retry at once)
        if let i = pending.firstIndex(where: { $0.id == p.id }) { pending[i].failed = false; pending[i].refused = false }
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
                let mentions = isGroup ? MentionsBuilder.build(p.body, members: members) : []
                if mentions.isEmpty {
                    m = try await APIClient.shared.sendText(token: token, conversationID: chat.conversation_id,
                                                            body: p.body, key: p.id, replyTo: p.replyTo)
                } else {
                    m = try await APIClient.shared.chSendText(token: token, conversationID: chat.conversation_id, body: p.body,
                                                              replyTo: p.replyTo, mentions: mentions, key: p.id)
                }
            }
            // a sent photo shows from my own copy at once, at its shape (web seedPhoto)
            if let fid = m.file_id, let jpeg = p.jpeg {
                // the bubble's copy is the small preview, not the full (HD) JPEG
                APIClient.shared.seedFile(fileID: fid, data: p.image?.jpegData(compressionQuality: 0.8) ?? jpeg)
                if let img = p.image { MediaDims.shared.set(fid, img.size) }
            }
            merge([m])
            pending.removeAll { $0.id == p.id }
            fileRetries[p.id] = nil
            serverRetries[p.id] = nil
            if let f = p.file { try? FileManager.default.removeItem(at: f) } // sent: this device's copy is no longer needed
            return .sent
        } catch APIError.badCredentials {
            store.sessionExpired()
            return .failed
        } catch {
            if cancelledUploads.contains(p.id) { // X: dropped on purpose (the server was told to drop its chunks)
                cancelledUploads.remove(p.id)
                if let f = p.file { try? FileManager.default.removeItem(at: f) }
                return .failed
            }
            // a line waits (rate limit, no connection, the server busy) and keeps its place; the same key makes it safe
            if queued, let a = error as? APIError {
                switch a {
                case .rateLimited, .network: return .wait
                case .server(let status) where status >= 500:
                    // a server that keeps failing for this one message must not hold every later message back
                    let n = (serverRetries[p.id] ?? 0) + 1
                    serverRetries[p.id] = n
                    if n < 5 { return .wait }
                default: break
                }
            }
            if queued, (error as? URLError) != nil { return .wait }
            if !queued && transient(error) && (fileRetries[p.id] ?? 0) < 4 {
                // a photo / video / document on a passing error: tried again by itself (4, 8, 16, 30 s), same key
                let n = fileRetries[p.id] ?? 0
                fileRetries[p.id] = n + 1
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(min(30, 4 << n)) * 1_000_000_000)
                    if let again = pending.first(where: { $0.id == p.id }), !cancelledUploads.contains(p.id) { await deliver(again) }
                }
                return .wait
            }
            if let i = pending.firstIndex(where: { $0.id == p.id }) {
                pending[i].failed = true
                // refused for good (not a passing error): kept as "Not sent", opening the chat never sends it again by itself
                if !transient(error) { pending[i].refused = true }
            }
            if case let .refused(why)? = error as? APIError, !why.isEmpty {
                problem = why
                flashText(why) // why it was not sent, also when the chat already has messages
            }
            return .failed
        }
    }

    // MARK: display

    private func displayText(_ m: Message) -> String {
        if m.isDeleted { return NSLocalizedString("chat.deleted", comment: "") }
        switch m.kind {
        case "text": return m.body
        case "voice": return "🎤 " + NSLocalizedString("chats.kind.voice", comment: "")
        case "image": return m.body.isEmpty ? "📷 " + NSLocalizedString("chats.kind.image", comment: "") : "📷 " + m.body
        case "file":
            let mime = m.file_mime ?? ""
            if VideoNotePrep.isNote(m) { return NSLocalizedString("note.video", comment: "") }
            if mime.hasPrefix("video/") { return m.body.isEmpty ? "🎬 " + NSLocalizedString("chats.kind.video", comment: "") : "🎬 " + m.body }
            if mime.hasPrefix("audio/") { return m.body.isEmpty ? "🎵 " + NSLocalizedString("chats.kind.audio", comment: "") : "🎵 " + m.body }
            return "📄 " + (m.file_name ?? NSLocalizedString("chats.kind.file", comment: ""))
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

/// The blinking dot and running time of a hold-to-record note (watches only the recorder's meter).
private struct HoldClock: View {
    @ObservedObject var meter: VoiceMeter

    var body: some View {
        Circle().fill(Color.red).frame(width: 9, height: 9)
            .opacity(Int(meter.elapsed * 2) % 2 == 0 ? 1 : 0.3)
        Text(VoiceBubble.length(Int64(meter.elapsed * 1000))).monospacedDigit().foregroundStyle(Theme.text)
    }
}

/// The note for a pending photo / video / document whose file is gone from this phone.
struct MissingMediaBubble: View {
    var body: some View {
        HStack {
            Spacer(minLength: 48)
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("chat.media.missing").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("chat.media.missing.tap").font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .tfBubble(mine: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
    /// The server refused it for good (kept in the saved outbox as such).
    var refused = false
    /// A photo, video or document whose file is no longer on this phone (cleaned up, storage freed): it cannot be sent. It shows
    /// as a note with "Tap to remove" instead of vanishing without a word.
    var missing = false
}

struct ViewedPhoto: Identifiable {
    let id: String // the file id
    /// The message it belongs to, when known (the full-screen viewer opens on that message).
    var messageID: String? = nil
}

/// A photo or a video message, as WhatsApp iOS draws it: the media fills its bubble edge to edge inside a 3 pt bubble
/// rim, in a box with the media's own shape (MediaDims.box, the same rule for photos and videos; the space is kept before
/// it loads and the box never changes while the row is on screen). The time and ticks sit bottom-right over a soft dark
/// gradient; a video adds its length bottom-left and a round play button in the middle. A caption goes under the media
/// inside the same bubble. The round forward button sits outside the bubble, on its outer side, centred on it.
struct PhotoBubble<Content: View>: View {
    let mine: Bool
    let date: Date?
    let state: Bubble.Delivery?
    let caption: String
    var fileID: String? = nil
    /// The picture's own size when known here (a picture being sent, a video's cover).
    var size: CGSize? = nil
    /// A video: the play button and the length chip are drawn over it.
    var video = false
    var seconds: Double? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.tfMediaForward) private var forward
    /// The box chosen the first time this bubble is drawn: it never changes afterwards while it is on screen.
    @State private var frozen: CGSize?

    static var innerRadius: CGFloat { 13 }

    var body: some View {
        let box = frozen ?? MediaDims.box(size ?? fileID.flatMap { MediaDims.shared.size($0) })
        HStack(alignment: .center, spacing: 10) {
            if mine { Spacer(minLength: 0) }
            if mine, let forward { forwardButton(forward) }
            VStack(alignment: .leading, spacing: 0) {
                media(box)
                if !caption.isEmpty {
                    ZStack(alignment: .bottomTrailing) {
                        (Text(caption) + Text(Bubble.metaSpacer(date: date, ticks: state != nil, edited: false)).foregroundColor(.clear).font(.system(size: 11)))
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: box.width - 12, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Bubble.meta(date: date, state: state, edited: false)
                    }
                    .padding(.horizontal, 6).padding(.top, 5).padding(.bottom, 3)
                    .frame(width: box.width, alignment: .leading)
                }
            }
            .padding(3)
            .tfBubble(mine: mine)
            .onAppear { if frozen == nil { frozen = box } }
            if !mine, let forward { forwardButton(forward) }
            if !mine { Spacer(minLength: 0) }
        }
    }

    private func media(_ box: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.innerRadius, style: .continuous)
        return ZStack {
            content()
                .frame(width: box.width, height: box.height)
                .clipped()
            // the soft shade under the time / the length (WhatsApp), never over the whole picture
            if caption.isEmpty || video {
                LinearGradient(colors: [.clear, .black.opacity(0.42)], startPoint: .top, endPoint: .bottom)
                    .frame(height: min(54, box.height * 0.4))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }
            if video {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.leading, 3)
                    .frame(width: 56, height: 56)
                    .background(Color.black.opacity(0.42), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .allowsHitTesting(false)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if video {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill").font(.system(size: 10, weight: .semibold))
                        if let seconds { Text(RemoteMedia.clock(seconds)).monospacedDigit() }
                    }
                }
                Spacer(minLength: 4)
                if caption.isEmpty {
                    HStack(spacing: 3) {
                        if let date { Text(Bubble.timeString(date)).monospacedDigit() }
                        if let state { Bubble.tickView(state) }
                    }
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .environment(\.layoutDirection, .leftToRight) // length bottom-left, time bottom-right, in every language
            .padding(.horizontal, 8).padding(.bottom, 5)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
        .frame(width: box.width, height: box.height)
        .background(Theme.surface)
        .clipShape(shape)
        .contentShape(shape)
        // a picture still being sent keeps its own cancel button reachable
        .accessibilityElement(children: fileID == nil ? AccessibilityChildBehavior.contain : AccessibilityChildBehavior.ignore)
        .accessibilityLabel(Text(LocalizedStringKey(video ? "chat.video" : "mv.photo")))
        .accessibilityValue(Text(spokenValue))
        .accessibilityAddTraits(.isButton)
    }

    private var spokenValue: String {
        var parts: [String] = []
        if video, let seconds { parts.append(RemoteMedia.clock(seconds)) }
        if let date { parts.append(Bubble.timeString(date)) }
        return parts.joined(separator: ", ")
    }

    /// WhatsApp's forward button: a 34 pt grey see-through circle with a white arrow, outside the bubble.
    private func forwardButton(_ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color(white: 0.5, opacity: 0.38), in: Circle())
                .environment(\.layoutDirection, .leftToRight) // the arrow always points forward
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("chat.forward"))
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
        let cut = faded || expanded || ReadMore.opened.contains(text.hashValue) ? nil : ReadMore.cut(text)
        let arabic = TextLook.isArabic(text)
        var shown = TextLook.linked(cut ?? text)
        if cut != nil {
            var more = AttributedString("… " + NSLocalizedString("chat.readmore", comment: ""))
            more.link = URL(string: "tfreadmore://open")
            more.foregroundColor = Theme.accent
            more.font = .system(size: 15, weight: .semibold)
            shown += more
        } else if !faded, ReadMore.cut(text) != nil {
            // opened: "Show less" folds it back (on its own line, so it sits at the reading start in either direction)
            var less = AttributedString("\n" + NSLocalizedString("chat.showless", comment: ""))
            less.link = URL(string: "tfreadmore://close")
            less.foregroundColor = Theme.accent
            less.font = .system(size: 15, weight: .semibold)
            shown += less
        }
        let longText = !faded && ReadMore.cut(text) != nil
        return VStack(alignment: .leading, spacing: 4) {
            if let head { head }
            if longText || arabic {
                // a cut message ("… Read more") or right-to-left text: the time sits on its own line under the text, so the
                // two never overlap (mixed directions move an inline spacer)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(shown)
                        .font(.system(size: 15))
                        .italic(faded)
                        .foregroundStyle(Theme.text)
                        .tint(Theme.accent)
                        .opacity(faded ? 0.7 : 1)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(arabic ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: arabic ? .trailing : .leading)
                        .environment(\.layoutDirection, arabic ? .rightToLeft : .leftToRight)
                        .environment(\.openURL, OpenURLAction { url in
                            if url.scheme == "tfreadmore" {
                                if url.host == "close" {
                                    ReadMore.opened.remove(text.hashValue)
                                    withAnimation(.easeOut(duration: 0.15)) { expanded = false }
                                } else {
                                    ReadMore.opened.insert(text.hashValue)
                                    withAnimation(.easeOut(duration: 0.15)) { expanded = true }
                                }
                                return .handled
                            }
                            parentOpen(url)
                            return .handled
                        })
                    Self.meta(date: date, state: state, edited: edited)
                }
            } else {
            ZStack(alignment: .bottomTrailing) {
                (Text(shown) + Text(Self.metaSpacer(date: date, ticks: state != nil, edited: edited)).font(.system(size: 11)).foregroundColor(.clear))
                    .font(.system(size: 15))
                    .italic(faded)
                    .foregroundStyle(Theme.text)
                    .tint(Theme.accent)
                    .opacity(faded ? 0.7 : 1)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(arabic ? .trailing : .leading)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "tfreadmore" {
                            if url.host == "close" {
                                ReadMore.opened.remove(text.hashValue)
                                withAnimation(.easeOut(duration: 0.15)) { expanded = false }
                            } else {
                                ReadMore.opened.insert(text.hashValue)
                                withAnimation(.easeOut(duration: 0.15)) { expanded = true }
                            }
                            return .handled
                        }
                        parentOpen(url)
                        return .handled
                    })
                Self.meta(date: date, state: state, edited: edited)
            }
            .environment(\.layoutDirection, .leftToRight)
            }
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
    private static var linkedCache: [String: AttributedString] = [:]

    static func linked(_ text: String) -> AttributedString {
        if let hit = linkedCache[text] { return hit }
        let out = findLinks(text)
        if linkedCache.count > 800 { linkedCache.removeAll(keepingCapacity: true) }
        linkedCache[text] = out
        return out
    }

    private static func findLinks(_ text: String) -> AttributedString {
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

    /// Right-to-left message? Counts the strong letters (Arabic, Persian, Urdu, Hebrew vs Latin and others): the side with
    /// more letters sets the bubble's direction and alignment. Digits, prices, symbols and emoji are neutral, so a
    /// trading post that starts with "XAUUSD" or "1.0845" but is written in Arabic still reads right to left, and an
    /// English message with one Arabic word stays left to right. Each line keeps its own natural direction inside.
    static func isArabic(_ text: String) -> Bool {
        var rtl = 0, ltr = 0
        for s in text.unicodeScalars {
            let v = s.value
            if (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v) {
                if s.properties.isAlphabetic { rtl += 1 }
            } else if s.properties.isAlphabetic {
                ltr += 1
            }
        }
        return rtl > 0 && rtl >= ltr
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


/// The text being typed (see ChatView.box): only DraftField watches it; the chat hears when it turns empty / not empty
/// and when an @mention query starts or changes.
final class DraftBox: ObservableObject {
    @Published var text = "" {
        didSet {
            let e = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if e != empty { empty = e; onEmptyChange?(e) }
            let q = Self.mention(in: text)
            if q != mention { mention = q; onMentionChange?(q) }
        }
    }
    private(set) var empty = true
    private(set) var mention: String?
    var onEmptyChange: ((Bool) -> Void)?
    var onMentionChange: ((String?) -> Void)?

    static func mention(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let after = draft[draft.index(after: at)...]
        if after.contains(" ") || after.contains("\n") { return nil }
        if at != draft.startIndex, !(draft[draft.index(before: at)].isWhitespace) { return nil }
        return String(after).lowercased()
    }
}

/// The message field on its own: typing redraws only this.
struct DraftField: View {
    @ObservedObject var box: DraftBox
    let placeholder: LocalizedStringKey
    var focus: FocusState<Bool>.Binding
    let onType: () -> Void

    var body: some View {
        TextField(placeholder, text: $box.text, axis: .vertical)
            .onChange(of: box.text) { v in
                if !v.trimmingCharacters(in: .whitespaces).isEmpty { onType() }
            }
            .font(.system(size: 16))
            .foregroundStyle(Theme.text)
            .lineLimit(1...6)
            .focused(focus)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("chat.composer")
    }
}


/// The last messages each chat showed, kept in memory for this app session only (never on disk): opening a chat again
/// shows them at once while the newest are fetched. A locked chat and a sign-out drop them.
@MainActor
enum ChatMemo {
    private static var store: [String: [Message]] = [:]
    private static var order: [String] = []

    static func get(_ id: String) -> [Message]? { store[id] }

    static func put(_ id: String, _ list: [Message]) {
        store[id] = list
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > 20 { store[order.removeFirst()] = nil }
    }

    static func drop(_ id: String) { store[id] = nil; order.removeAll { $0 == id } }
    static func clear() { store = [:]; order = [] }
}
