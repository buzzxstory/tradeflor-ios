import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// One conversation: history (newest page first, older pages on demand), live incoming messages, and sending text.
struct ChatView: View {
    let chat: ConversationSummary

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
    @State private var showCamera = false
    @State private var viewing: ViewedPhoto?
    @State private var watching: ViewedPhoto?
    @StateObject private var recorder = VoiceRecorder()
    @State private var locked = false
    @State private var replyingTo: Message?
    @State private var forwarding: Message?
    @State private var peerTypingUntil: Date?
    @State private var lastTypingSent = Date.distantPast
    @ObservedObject private var calls = CallManager.shared
    @State private var showUnlock = false

    private let pageSize = 50
    private var me: String { store.session?.userID ?? "" }
    private var token: String { store.session?.token ?? "" }

    var body: some View {
        VStack(spacing: 0) {
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
                        ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                            if i == 0 || !sameDay(messages[i - 1], m) {
                                DayDivider(date: m.date)
                            }
                            MessageRow(message: m, mine: m.sender_id == me, myID: me, peerName: chat.title,
                                       onReply: { replyingTo = m; composerFocused = true },
                                       onReact: { e in Task { await react(m, e) } },
                                       onCopy: { UIPasteboard.general.string = displayText(m) },
                                       onForward: { forwarding = m },
                                       onDelete: { everyone in Task { await delete(m, everyone: everyone) } }) {
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
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
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
                    }
                }
                .onChange(of: messages.last?.id) { _ in scrollToBottom(proxy) }
                .onChange(of: pending.count) { _ in scrollToBottom(proxy) }
                .onChange(of: composerFocused) { f in if f { scrollToBottom(proxy) } }
            }
            composer
        }
        .background(Theme.ground.ignoresSafeArea())
        .toolbarBackground(Theme.ground, for: .navigationBar)
        .navigationTitle(chat.title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(chat.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(Theme.accent) }
                }
            }
        }
        .onReceive(live.typing) { t in
            guard t.conversation == chat.conversation_id, t.user != me else { return }
            peerTypingUntil = Date().addingTimeInterval(5)
            Task {
                try? await Task.sleep(nanoseconds: 5_200_000_000)
                if let u = peerTypingUntil, u <= Date() { peerTypingUntil = nil }
            }
        }
        .sheet(item: $forwarding) { m in
            ForwardSheet(token: token, message: m) { forwarding = nil }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar) // full height for the conversation, like other messengers
        .toolbar {
            if calls.enabled && chat.conversation_id.hasPrefix("dm_") {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        calls.start(conversationID: chat.conversation_id, peerName: chat.title)
                    } label: { Image(systemName: "phone.fill") }
                    .disabled(calls.phase != .idle)
                    .accessibilityLabel(Text("call.voice"))
                }
            }
        }
        .task { await loadNewest() }
        .onReceive(live.messages) { m in
            guard m.conversation_id == chat.conversation_id else { return }
            merge([m])
            pending.removeAll { $0.id == m.client_key }
            if m.sender_id != me { Task { await APIClient.shared.markRead(token: token, conversationID: chat.conversation_id) } }
        }
        .onReceive(live.changes) { id in
            guard id == chat.conversation_id else { return }
            Task { await loadNewest(quiet: true) }
        }
        .onChange(of: picked) { items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                for item in items {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        if let movie = try? await item.loadTransferable(type: PickedMovie.self) { await sendVideo(movie.url) }
                    } else if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        await sendPhoto(img)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in Task { await sendPhoto(img) } }
                .ignoresSafeArea()
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
        .onDisappear {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var composerBar: some View {
        Group {
            if recorder.recording {
                RecordingBar(recorder: recorder, onCancel: { recorder.cancel() }, onSend: { Task { await sendVoice() } })
            } else {
                typingBar
            }
        }
    }

    private var draftIsEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var typingBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .any(of: [.images, .videos])) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 20))
                    .frame(width: 36, height: 40)
            }
            .accessibilityLabel(Text("chat.photos"))
            .accessibilityIdentifier("chat.photos")
            if CameraPicker.isAvailable {
                Button { showCamera = true } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 20))
                        .frame(width: 36, height: 40)
                }
                .accessibilityLabel(Text("chat.camera"))
            }
            TextField("chat.placeholder", text: $draft, axis: .vertical)
                .onChange(of: draft) { v in
                    guard !v.isEmpty, Date().timeIntervalSince(lastTypingSent) > 3 else { return }
                    lastTypingSent = Date()
                    live.sendTyping(conversationID: chat.conversation_id)
                }
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityIdentifier("chat.composer")
            Button {
                if draftIsEmpty {
                    VoicePlayer.shared.stop()
                    Task { await recorder.start() }
                } else {
                    Task { await sendDraft() }
                }
            } label: {
                Image(systemName: draftIsEmpty ? "mic.fill" : "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: Circle())
            }
            .accessibilityLabel(Text(draftIsEmpty ? "chat.voice.record" : "chat.send"))
            .accessibilityIdentifier(draftIsEmpty ? "chat.mic" : "chat.send")
        }
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
            await APIClient.shared.markRead(token: token, conversationID: chat.conversation_id)
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
        let next = byID.values.sorted { $0.seq < $1.seq }
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
        if m.kind == "voice", m.audio_id != nil, !m.isDeleted {
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
        } else {
            Bubble(text: displayText(m), mine: m.sender_id == me, date: m.date,
                   state: m.sender_id == me ? receipt(m) : nil, faded: m.isDeleted)
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

    private func sendVideo(_ url: URL) async {
        let key = UUID().uuidString.lowercased()
        let placeholder = PendingMessage(id: key, body: "", date: Date(), video: Data())
        pending.append(placeholder) // shows "sending video" while it is re-encoded
        guard let out = await VideoPrep.mp4(from: url) else {
            if let i = pending.firstIndex(where: { $0.id == key }) { pending[i].failed = true }
            problem = NSLocalizedString("chat.video.toolarge", comment: "")
            return
        }
        if let i = pending.firstIndex(where: { $0.id == key }) { pending[i].video = out.data }
        if let p = pending.first(where: { $0.id == key }) { await deliver(p) }
    }

    private func sendPhoto(_ img: UIImage) async {
        // Encoding a 12 MP photo takes a moment: off the main thread.
        let encoded = await Task.detached(priority: .userInitiated) { ImagePrep.jpeg(from: img) }.value
        guard let jpeg = encoded else { return }
        let preview = UIImage(data: jpeg) ?? img
        let p = PendingMessage(id: UUID().uuidString.lowercased(), body: "", date: Date(), image: preview, jpeg: jpeg)
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
                        .foregroundStyle(mine ? Theme.onAccent : Color.white)
                        .frame(maxWidth: 240, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    if let date { Text(Self.time.string(from: date)) }
                    if let state { Bubble.tickView(state) }
                }
                .font(.caption2)
                .foregroundStyle(mine ? Theme.onAccent.opacity(0.7) : Color.white.opacity(0.55))
                .padding(.trailing, 4)
            }
            .padding(4)
            .background(mine ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            Text(Self.f.string(from: date))
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
                    .foregroundStyle(mine ? Theme.onAccent : Color.white)
                    .opacity(faded ? 0.7 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 4) {
                    if let date { Text(Self.time.string(from: date)) }
                    if let state { tick(state) }
                }
                .font(.caption2)
                .foregroundStyle(mine ? Theme.onAccent.opacity(0.7) : Color.white.opacity(0.55))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(mine ? Theme.accent : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
