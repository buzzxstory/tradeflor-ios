import SwiftUI
import AVKit
import AVFoundation

// The full-screen photo / video viewer, laid out like WhatsApp iOS:
//  - black, swipe the media down (or up) to close while the background fades; a tap shows / hides everything;
//    swipe sideways for the chat's previous / next photo or video
//  - top: round back button, the sender ("You" for mine) and the date, a round "⋯" menu (Save to Photos, Share,
//    Forward, Show in Chat, Delete)
//  - videos: under the top bar a rounded bar with the time played, a scrubber, the time left, the speed (1× 1.5× 2×)
//    and Picture in Picture
//  - photos: pinch to zoom, double-tap to zoom in / out, drag when zoomed
//  - bottom: add a reaction (left), Reply (right), a strip of the chat's photos and videos, then Share and a capsule
//    with Forward, Play / Pause (videos) and Delete
// Only actions the chat already has are shown (nothing is offered that the server cannot do).

/// One photo or video the viewer can show.
struct MediaViewerItem: Identifiable, Equatable {
    let fileID: String
    let video: Bool
    /// Its message (nil when opened from somewhere without one, e.g. contact info).
    var message: Message? = nil
    var mine = false
    /// Who sent it ("You" for mine).
    var sender = ""

    var id: String { message?.id ?? fileID }
    var date: Date? { message?.date }
}

/// What the viewer may do with the message on screen; nil / false = the button is not shown.
struct MediaViewerActions {
    /// Forward (the viewer opens the chat's own ForwardSheet over itself).
    var forward = false
    /// These close the viewer first, then run in the chat.
    var reply: ((Message) -> Void)?
    var showInChat: ((Message) -> Void)?
    var delete: ((Message) -> Void)?
    /// A quick reaction (the viewer stays open).
    var react: ((Message, String) -> Void)?
}

@MainActor
struct MediaViewer: View {
    let token: String
    let items: [MediaViewerItem]
    var me = ""
    var actions = MediaViewerActions()

    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var direction
    @StateObject private var playback = VideoPlayback()
    @State private var currentID: String
    @State private var chrome = true
    @State private var hideTask: Task<Void, Never>?
    @State private var drag: CGSize = .zero
    @State private var axis: Axis?
    @State private var zoomed = false
    @State private var note: String?
    @State private var noteTask: Task<Void, Never>?
    @State private var saving = false
    @State private var preparingShare = false
    @State private var shareFile: ExportFile?
    @State private var forwardMessage: Message?
    @State private var reactionsOpen = false
    @State private var pipPossible = false
    /// The item on screen as last seen, so it stays when the chat's list is reloaded without it.
    @State private var remembered: MediaViewerItem?

    /// `startID`: the message id (or the file id) to open on; the newest item when nil.
    init(token: String, items: [MediaViewerItem], startID: String? = nil, me: String = "",
         actions: MediaViewerActions = MediaViewerActions()) {
        self.token = token
        self.items = items
        self.me = me
        self.actions = actions
        let start = startID.flatMap { s in items.first(where: { $0.id == s })?.id ?? items.last(where: { $0.fileID == s })?.id }
        _currentID = State(initialValue: start ?? items.last?.id ?? "")
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var index: Int? { items.firstIndex { $0.id == currentID } }
    private var current: MediaViewerItem? {
        if let i = index { return items[i] }
        return remembered?.id == currentID ? remembered : nil
    }
    private var chromeShown: Bool { (chrome || UIAccessibility.isVoiceOverRunning) && abs(drag.height) < 1 }

    /// The chat shows through while the media is dragged away only where the cover can be clear (iOS 16.4+).
    private var backdrop: Double {
        if #available(iOS 16.4, *) { return 1 - min(0.9, Double(abs(drag.height)) / 420) }
        return 1
    }

    var body: some View {
        ZStack {
            Color.black.opacity(backdrop).ignoresSafeArea()
            page
            chromeLayer
                .opacity(chromeShown ? 1 : 0)
                .allowsHitTesting(chromeShown)
                .animation(.easeOut(duration: 0.2), value: chromeShown)
            if let note {
                Text(note)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .modifier(ClearCover())
        .statusBarHidden(!chromeShown)
        .onAppear {
            PiPKeeper.shared.onStart = { dismiss() } // WhatsApp: the video goes on in the small window, the chat comes back
            PiPKeeper.shared.onPossible = { ok in pipPossible = ok }
            PiPKeeper.shared.endAdopted()
            remembered = current
            loadCurrent()
        }
        .onDisappear {
            hideTask?.cancel()
            noteTask?.cancel()
            if !PiPKeeper.shared.adopt(playback) {
                playback.stop()
                // the viewer is gone: the music or podcast another app was playing carries on (never during a call, nor over a voice note)
                if !VoicePlayer.shared.playing { StatusAudio.release() }
            }
        }
        .onChange(of: currentID) { _ in
            remembered = current
            reactionsOpen = false
            zoomed = false
            loadCurrent()
        }
        .onChange(of: playback.playing) { playing in
            if playing { keepShown() } else { hideTask?.cancel(); chrome = true }
        }
        .sheet(item: $forwardMessage) { m in
            ForwardSheet(token: token, message: m) { forwardMessage = nil }
        }
        .sheet(item: $shareFile) { f in
            ActivityShare(items: [f.url]).ignoresSafeArea()
        }
    }

    // MARK: - the media

    @ViewBuilder private var page: some View {
        if let item = current {
            Group {
                if item.video {
                    videoPage(item)
                } else {
                    ZoomablePhoto(token: token, fileID: item.fileID, zoomed: $zoomed) { toggleChrome() }
                }
            }
            .id(item.id)
            .transition(.opacity)
            .offset(x: drag.width, y: drag.height)
            .scaleEffect(1 - min(0.2, abs(drag.height) / 1800))
            .gesture(swipe, including: zoomed ? .subviews : .all)
            // offsets and finger movement in plain left-to-right terms; the paging order follows `direction`
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    private func videoPage(_ item: MediaViewerItem) -> some View {
        ZStack {
            if !playback.ready, let cover = RemoteMedia.cachedCover(item.fileID) {
                Image(uiImage: cover).resizable().scaledToFit()
            }
            PlayerLayerView(player: playback.player) { v in PiPKeeper.shared.attach(v) }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleChrome() }
                .accessibilityHidden(true)
            centre
        }
        .ignoresSafeArea()
    }

    /// The big round button in the middle: play when paused, replay at the end; a spinner while it waits.
    @ViewBuilder private var centre: some View {
        if playback.failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Color.black.opacity(0.42), in: Circle())
                .accessibilityLabel(Text("media.failed"))
        } else if playback.buffering && !playback.ended {
            ProgressView().tint(.white).scaleEffect(1.3)
                .frame(width: 72, height: 72)
                .background(Color.black.opacity(0.42), in: Circle())
        } else if !playback.playing {
            Button {
                playback.toggle()
                keepShown()
            } label: {
                Image(systemName: playback.ended ? "arrow.counterclockwise" : "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.leading, playback.ended ? 0 : 4)
                    .frame(width: 72, height: 72)
                    .background(Color.black.opacity(0.42), in: Circle())
            }
            .accessibilityLabel(Text(LocalizedStringKey(playback.ended ? "vp.replay" : "vp.play")))
        }
    }

    /// Down (or up) closes; sideways goes to the previous / next item (not while a photo is zoomed in).
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .global)
            .onChanged { v in
                let t = v.translation
                if axis == nil { axis = abs(t.height) > abs(t.width) ? .vertical : .horizontal }
                if axis == .vertical {
                    drag = CGSize(width: 0, height: t.height)
                } else {
                    let free = neighbour(t.width) != nil
                    drag = CGSize(width: free ? t.width : t.width * 0.25, height: 0)
                }
            }
            .onEnded { v in
                let was = axis
                axis = nil
                if was == .vertical {
                    if abs(drag.height) > 120 || abs(v.predictedEndTranslation.height) > 380 {
                        dismiss()
                        return
                    }
                } else if was == .horizontal {
                    let t = v.translation.width
                    if abs(t) > 70 || abs(v.predictedEndTranslation.width) > 260, let next = neighbour(t) {
                        drag = .zero
                        withAnimation(.easeOut(duration: 0.18)) { currentID = next.id }
                        return
                    }
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = .zero }
            }
    }

    /// The item a sideways move of `dx` leads to (in Arabic the next one is to the left, as the strip runs).
    private func neighbour(_ dx: CGFloat) -> MediaViewerItem? {
        guard let i = index, dx != 0 else { return nil }
        let towardsNext = direction == .rightToLeft ? dx > 0 : dx < 0
        let j = towardsNext ? i + 1 : i - 1
        return items.indices.contains(j) ? items[j] : nil
    }

    // MARK: - chrome

    private var chromeLayer: some View {
        VStack(spacing: 10) {
            topBar
            if current?.video == true { playbackBar }
            Spacer(minLength: 0)
            if reactionsOpen, let m = current?.message { reactionBar(m) }
            actionRow
            if items.count > 1 { thumbnails }
            bottomBar
        }
        .padding(.bottom, 6)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 170)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .frame(height: 240)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    private var topBar: some View {
        ZStack {
            VStack(spacing: 1) {
                if let name = current?.sender, !name.isEmpty {
                    Text(name).font(.system(size: 16, weight: .semibold))
                }
                if let d = current?.date {
                    Text(Self.stamp.string(from: d)).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.72))
                }
            }
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 60)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            HStack {
                glassCircle("chevron.backward", "chat.back", size: 40) { dismiss() }
                Spacer()
                moreMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var moreMenu: some View {
        Menu {
            Button { save() } label: { Label("media.save", systemImage: "square.and.arrow.down") }
            Button { share() } label: { Label("mv.share", systemImage: "square.and.arrow.up") }
            if let m = current?.message {
                if actions.forward {
                    Button { forwardMessage = m } label: { Label("chat.forward", systemImage: "arrowshape.turn.up.right") }
                }
                if let jump = actions.showInChat {
                    Button { leave { jump(m) } } label: { Label("mv.showinchat", systemImage: "text.bubble") }
                }
                if let del = actions.delete {
                    Divider()
                    Button(role: .destructive) { leave { del(m) } } label: { Label("chat.delete", systemImage: "trash") }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(Text("chat.more"))
    }

    /// 0:04 ━━━●──── -0:16  1×  PiP — always left to right.
    private var playbackBar: some View {
        HStack(spacing: 10) {
            Text(RemoteMedia.clock(playback.current)).modifier(ViewerClock())
            ViewerScrubber(
                value: playback.current,
                total: playback.total,
                onChange: { v in
                    playback.current = v
                    playback.seek(to: v, exact: false)
                    keepShown()
                },
                onEditing: { editing in
                    playback.scrubbing = editing
                    if !editing { playback.seek(to: playback.current, exact: true) }
                    keepShown()
                }
            )
            .disabled(playback.total <= 0)
            Text("-" + RemoteMedia.clock(max(0, playback.total - playback.current))).modifier(ViewerClock())
            Button {
                playback.cycleRate()
                keepShown()
            } label: {
                Text(rateLabel)
                    .font(.system(size: 13.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 36, minHeight: 32)
            }
            .accessibilityLabel(Text("mv.speed"))
            .accessibilityValue(Text(rateLabel))
            if pipShown {
                Button { PiPKeeper.shared.start() } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(Text("mv.pip"))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.layoutDirection, .leftToRight)
        .padding(.horizontal, 12)
    }

    private var rateLabel: String {
        playback.rate >= 1.75 ? "2×" : (playback.rate >= 1.25 ? "1.5×" : "1×")
    }

    private var pipShown: Bool { PiPKeeper.supported && pipPossible && !CallManager.shared.lineInUse }

    /// Add a reaction (left) and Reply (right).
    @ViewBuilder private var actionRow: some View {
        if let m = current?.message, actions.react != nil || actions.reply != nil {
            HStack {
                if actions.react != nil { reactButton(m) }
                Spacer(minLength: 8)
                if let reply = actions.reply {
                    Button { leave { reply(m) } } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                            Text("chat.reply")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func reactButton(_ m: Message) -> some View {
        let mineNow = m.reactionList(me: me).first(where: { $0.mine })?.emoji
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { reactionsOpen.toggle() }
            keepShown()
        } label: {
            Group {
                if let mineNow {
                    Text(mineNow).font(.system(size: 21))
                } else {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "face.smiling").font(.system(size: 20))
                        Image(systemName: "plus").font(.system(size: 8, weight: .heavy)).offset(x: 5, y: -3)
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(Text("mv.react"))
    }

    /// The chat's quick reactions (the same as the message menu); mine are lit.
    private func reactionBar(_ m: Message) -> some View {
        let active = Set(m.reactionList(me: me).filter(\.mine).map(\.emoji))
        return HStack(spacing: 2) {
            ForEach(MessageMenuStyle.quickEmoji, id: \.self) { e in
                Button {
                    actions.react?(m, e)
                    withAnimation(.easeOut(duration: 0.15)) { reactionsOpen = false }
                    keepShown()
                } label: {
                    Text(e)
                        .font(.system(size: 25))
                        .frame(width: 40, height: 40)
                        .background(active.contains(e) ? Color.white.opacity(0.22) : Color.clear, in: Circle())
                }
                .accessibilityLabel(Text(e))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .transition(.opacity)
    }

    /// The chat's photos and videos, the one on screen a little wider with a white edge.
    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 2) {
                    ForEach(items) { it in
                        let on = it.id == currentID
                        ViewerThumb(token: token, item: it)
                            .frame(width: on ? 44 : 30, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.white, lineWidth: on ? 2 : 0))
                            .padding(.horizontal, on ? 4 : 0)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                currentID = it.id
                                keepShown()
                            }
                            .id(it.id)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(LocalizedStringKey(it.video ? "chat.video" : "mv.photo")))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .animation(.easeOut(duration: 0.18), value: currentID)
            }
            .frame(height: 46)
            .onAppear { proxy.scrollTo(currentID, anchor: .center) }
            .onChange(of: currentID) { id in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// Share (left); Forward, Play / Pause and Delete in one capsule (middle).
    private var bottomBar: some View {
        HStack(spacing: 0) {
            glassCircle("square.and.arrow.up", "mv.share", busy: preparingShare) { share() }
            Spacer(minLength: 8)
            centreCapsule
            Spacer(minLength: 8)
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var centreCapsule: some View {
        let m = current?.message
        let video = current?.video == true
        let canForward = m != nil && actions.forward
        let canDelete = m != nil && actions.delete != nil
        if canForward || video || canDelete {
            HStack(spacing: 26) {
                if canForward, let m {
                    toolButton("arrowshape.turn.up.right", "chat.forward") { forwardMessage = m }
                }
                if video {
                    toolButton(playback.ended ? "arrow.counterclockwise" : (playback.playing ? "pause.fill" : "play.fill"),
                               playback.ended ? "vp.replay" : (playback.playing ? "vp.pause" : "vp.play")) {
                        playback.toggle()
                        keepShown()
                    }
                }
                if canDelete, let m, let del = actions.delete {
                    toolButton("trash", "chat.delete") { leave { del(m) } }
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func toolButton(_ symbol: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(.white)
                .frame(width: 32, height: 40)
        }
        .accessibilityLabel(Text(LocalizedStringKey(key)))
    }

    private func glassCircle(_ symbol: String, _ key: String, size: CGFloat = 44, busy: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(.white) } else { Image(systemName: symbol).font(.system(size: 17, weight: .semibold)) }
            }
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
        }
        .disabled(busy)
        .accessibilityLabel(Text(LocalizedStringKey(key)))
    }

    // MARK: - actions

    private func loadCurrent() {
        playback.stop()
        pipPossible = false
        guard let item = current else { return }
        if item.video {
            VoicePlayer.shared.stop()
            if !CallManager.shared.lineInUse { // never cut a running call's microphone
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try? AVAudioSession.sharedInstance().setActive(true)
            }
            playback.load(token: token, fileID: item.fileID)
            keepShown()
        } else {
            hideTask?.cancel()
        }
    }

    private func toggleChrome() {
        reactionsOpen = false
        if chrome {
            hideTask?.cancel()
            chrome = false
        } else {
            keepShown()
        }
    }

    /// Shows the bars; while a video plays they hide by themselves after ~3 s.
    private func keepShown() {
        chrome = true
        hideTask?.cancel()
        guard current?.video == true else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, playback.playing, !playback.scrubbing, !reactionsOpen else { return }
            chrome = false
        }
    }

    /// Closes the viewer, then runs `then` in the chat (it may open its own sheets and dialogs).
    private func leave(_ then: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { then() }
    }

    private func save() {
        guard let item = current, !saving else { return }
        saving = true
        show(NSLocalizedString("mv.saving", comment: ""), hold: true)
        Task { @MainActor in
            let r = await MediaSaver.saveToPhotos(token: token, fileID: item.fileID, video: item.video)
            saving = false
            show(NSLocalizedString(r == .saved ? "media.saved" : (r == .denied ? "media.denied" : "media.failed"), comment: ""))
        }
    }

    private func share() {
        guard let item = current, !preparingShare else { return }
        preparingShare = true
        Task { @MainActor in
            let given = item.message?.file_name ?? ""
            let name = given.isEmpty ? (item.video ? "video.mp4" : "photo.jpg") : given
            let url = await MediaSaver.localFile(token: token, fileID: item.fileID, name: name)
            preparingShare = false
            if let url { shareFile = ExportFile(url: url) } else { show(NSLocalizedString("mv.share.failed", comment: "")) }
        }
    }

    private func show(_ text: String, hold: Bool = false) {
        noteTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { note = text }
        UIAccessibility.post(notification: .announcement, argument: text)
        guard !hold else { return }
        noteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { note = nil }
        }
    }
}

// MARK: - pieces

/// A photo that zooms: pinch (1× to 5×), double-tap to zoom in / back out, drag around while zoomed. The server's small
/// picture shows at once underneath while the full one arrives.
struct ZoomablePhoto: View {
    let token: String
    let fileID: String
    @Binding var zoomed: Bool
    let onTap: () -> Void
    /// The small picture, kept (it was made again from its bytes on every frame of a swipe: this view is rebuilt for each).
    @State private var preview: UIImage?
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    init(token: String, fileID: String, zoomed: Binding<Bool>, onTap: @escaping () -> Void) {
        self.token = token
        self.fileID = fileID
        _zoomed = zoomed
        self.onTap = onTap
        // the bubble's own decoded picture when it is still in memory (a look-up, no bytes read); else read below, once
        _preview = State(initialValue: RemoteImage.cachedDecoded(fileID: fileID, thumb: true))
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                if let preview { Image(uiImage: preview).resizable().scaledToFit() }
                RemoteImage(token: token, fileID: fileID, thumb: false, contentMode: .fit)
            }
            .frame(width: g.size.width, height: g.size.height)
            .scaleEffect(scale)
            .offset(offset)
            .contentShape(Rectangle())
            .gesture(pinch(g.size))
            .simultaneousGesture(pan(g.size), including: scale > 1.01 ? .all : .none)
            .onTapGesture(count: 2) { doubleTap() }
            .onTapGesture { onTap() }
        }
        .ignoresSafeArea()
        .task(id: fileID) {
            // only what is already on this phone (no request), read and decoded off the main thread
            guard preview == nil else { return }
            let id = fileID
            let kept = await Task.detached(priority: .userInitiated) { APIClient.shared.cachedFile(fileID: id, thumb: true) }.value
            guard let kept, let img = await AvatarImages.decode(kept, maxPixels: 1600) else { return }
            if !Task.isCancelled && preview == nil { preview = img }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("mv.photo"))
        .accessibilityAddTraits(.isImage)
    }

    private func pinch(_ size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { v in
                scale = min(5, max(1, base * v))
                zoomed = scale > 1.01
            }
            .onEnded { _ in
                if scale <= 1.01 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { reset() }
                } else {
                    base = scale
                    offset = clamp(offset, size)
                    baseOffset = offset
                }
            }
    }

    private func pan(_ size: CGSize) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { v in
                offset = clamp(CGSize(width: baseOffset.width + v.translation.width,
                                      height: baseOffset.height + v.translation.height), size)
            }
            .onEnded { _ in baseOffset = offset }
    }

    private func doubleTap() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if scale > 1.01 {
                reset()
            } else {
                scale = 2.5
                base = 2.5
                zoomed = true
            }
        }
    }

    private func reset() {
        scale = 1
        base = 1
        offset = .zero
        baseOffset = .zero
        zoomed = false
    }

    private func clamp(_ o: CGSize, _ size: CGSize) -> CGSize {
        let mx = max(0, (size.width * scale - size.width) / 2)
        let my = max(0, (size.height * scale - size.height) / 2)
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }
}

/// One square of the viewer's strip: a photo's small picture or a video's cover.
private struct ViewerThumb: View {
    let token: String
    let item: MediaViewerItem
    @State private var cover: UIImage?

    init(token: String, item: MediaViewerItem) {
        self.token = token
        self.item = item
        _cover = State(initialValue: item.video ? RemoteMedia.cachedCover(item.fileID) : nil)
    }

    var body: some View {
        Group {
            if item.video {
                ZStack {
                    if let cover { Image(uiImage: cover).resizable().scaledToFill() } else { Color.white.opacity(0.12) }
                }
                .task(id: item.fileID) {
                    if cover == nil { cover = await RemoteMedia.cover(token: token, fileID: item.fileID) }
                }
            } else {
                RemoteImage(token: token, fileID: item.fileID)
            }
        }
        .background(Color.white.opacity(0.08))
        .clipped()
    }
}

/// A thin WhatsApp-style scrubber: a 3 pt line, the played part white, a small knob that grows under the finger.
private struct ViewerScrubber: View {
    let value: Double
    let total: Double
    let onChange: (Double) -> Void
    let onEditing: (Bool) -> Void
    @State private var active = false

    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width)
            let p = total > 0 ? min(1, max(0, value / total)) : 0
            let knob: CGFloat = active ? 15 : 11
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3)).frame(height: 3)
                Capsule().fill(Color.white).frame(width: w * CGFloat(p), height: 3)
                Circle().fill(Color.white).frame(width: knob, height: knob)
                    .offset(x: min(w - knob, max(0, w * CGFloat(p) - knob / 2)))
            }
            .frame(width: w, height: g.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !active { active = true; onEditing(true) }
                        onChange(total * Double(min(1, max(0, v.location.x / w))))
                    }
                    .onEnded { _ in
                        active = false
                        onEditing(false)
                    }
            )
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel(Text("vp.seek"))
        .accessibilityValue(Text(RemoteMedia.clock(value)))
        .accessibilityAdjustableAction { dir in
            guard total > 0 else { return }
            let step = max(1, total / 20)
            switch dir {
            case .increment: onChange(min(total, value + step))
            case .decrement: onChange(max(0, value - step))
            @unknown default: break
            }
        }
    }
}

private struct ViewerClock: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12.5).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 36)
    }
}

/// Picture in Picture for the viewer's video (AVPictureInPictureController on its AVPlayerLayer). When it starts the
/// viewer closes (as in WhatsApp) and its playback is kept here until the small window is closed.
final class PiPKeeper: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PiPKeeper()

    @MainActor static var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    var onStart: (@MainActor () -> Void)?
    var onPossible: (@MainActor (Bool) -> Void)?
    private var controller: AVPictureInPictureController?
    private var host: PlayerLayerUIView?
    private var possible: NSKeyValueObservation?
    private var adopted: VideoPlayback?
    private var running = false

    @MainActor func attach(_ view: PlayerLayerUIView) {
        guard Self.supported else { return }
        endAdopted()
        let c = AVPictureInPictureController(contentSource: AVPictureInPictureController.ContentSource(playerLayer: view.playerLayer))
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = false
        controller = c
        host = view
        possible = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, let c = self.controller else { return }
                self.onPossible?(c.isPictureInPicturePossible)
            }
        }
    }

    @MainActor func start() {
        guard let controller, controller.isPictureInPicturePossible else { return }
        controller.startPictureInPicture()
    }

    /// The viewer is closing: while the small window runs, keep its playback alive here. False = not running.
    @MainActor func adopt(_ p: VideoPlayback) -> Bool {
        guard running else {
            detach()
            return false
        }
        adopted = p
        return true
    }

    /// Ends a small window left from an earlier viewer (a new one is opening).
    @MainActor func endAdopted() {
        if let p = adopted {
            adopted = nil
            p.stop()
        }
        if running { controller?.stopPictureInPicture() }
        detach()
    }

    @MainActor private func detach() {
        possible?.invalidate()
        possible = nil
        controller?.delegate = nil
        controller = nil
        host = nil
        running = false
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.running = true
            self.onStart?()
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.running = false
            if let p = self.adopted {
                self.adopted = nil
                p.stop()
                self.detach()
            }
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in self.running = false }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
