import SwiftUI
import AVKit
import AVFoundation

/// "View once" (WhatsApp): a photo, video or voice note the other person can open one time. The server enforces it (the
/// file answers 410 after the first open, it cannot be forwarded and it is not in shared media); the app only never
/// keeps a copy, offers no save / forward / copy, and shows "Opened".

/// The messages being sent as "view once", by their idempotency key, until they have left (kept across launches so a
/// retry from the outbox is still sent as view once).
enum ViewOnceSend {
    private static let key = "tf.viewonce.keys"
    private static let lock = NSLock()

    static func mark(_ id: String) {
        lock.withLock {
            var all = UserDefaults.standard.stringArray(forKey: key) ?? []
            if !all.contains(id) { all.append(id) }
            if all.count > 200 { all.removeFirst(all.count - 200) }
            UserDefaults.standard.set(all, forKey: key)
        }
    }

    static func has(_ id: String) -> Bool {
        lock.withLock { (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id) }
    }

    static func clearAll() { UserDefaults.standard.removeObject(forKey: key) }
}

/// The view-once messages this phone has opened (a group says "Opened" for me once I opened it).
enum ViewOnceSeen {
    private static let key = "tf.viewonce.opened"
    private static let lock = NSLock()
    /// The saved ids, read once (a view-once bubble asked for the whole saved list several times on every redraw); kept
    /// in step by `mark` and `clearAll`, the only places that write the list.
    private static var known: Set<String>?

    static func mark(_ id: String) {
        lock.withLock {
            var all = UserDefaults.standard.stringArray(forKey: key) ?? []
            if !all.contains(id) { all.append(id) }
            if all.count > 500 { all.removeFirst(all.count - 500) }
            UserDefaults.standard.set(all, forKey: key)
            known = Set(all)
        }
    }

    static func has(_ id: String) -> Bool {
        lock.withLock { () -> Bool in
            if let known { return known.contains(id) }
            let all = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            known = all
            return all.contains(id)
        }
    }

    static func clearAll() {
        lock.withLock {
            UserDefaults.standard.removeObject(forKey: key)
            known = []
        }
    }
}

extension Message {
    var isViewOnce: Bool { view_once == true }
    var viewOnceKind: String {
        if kind == "voice" { return "voice" }
        if (file_mime ?? "").hasPrefix("video/") { return "video" }
        return "photo"
    }
}

/// The bubble of a view-once message: the ring with a 1, "Photo" / "Video" / "Voice message", and its state.
struct ViewOnceBubble: View {
    let message: Message
    let mine: Bool
    var isGroup = false
    /// Changes when a viewer closes (the bubble is drawn again with its new state).
    var tick = 0
    let onOpen: () -> Void

    private var opened: Bool {
        _ = tick
        return message.view_gone == true || ViewOnceSeen.has(message.id) || (message.viewed_at != nil && (mine || !isGroup))
    }

    var body: some View {
        // read once per redraw (it was read again for each use below)
        let opened = self.opened
        HStack {
            if mine { Spacer(minLength: 48) }
            Button(action: { if !mine && !self.opened { onOpen() } }) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(style: StrokeStyle(lineWidth: 2, dash: opened ? [3, 3] : []))
                            .foregroundStyle(opened ? Theme.faint : Theme.accent)
                        Text(verbatim: "1").font(.system(size: 14, weight: .heavy)).foregroundStyle(opened ? Theme.faint : Theme.accent)
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey("vo." + message.viewOnceKind)).font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(LocalizedStringKey(stateKey(opened))).font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                    }
                    Spacer(minLength: 6)
                    if let d = message.date {
                        Text(Bubble.timeString(d)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(minWidth: 200, alignment: .leading)
                .tfBubble(mine: mine)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            if !mine { Spacer(minLength: 48) }
        }
    }

    private func stateKey(_ opened: Bool) -> String {
        if mine { return message.viewed_at != nil ? "vo.opened" : "vo.sent" }
        return opened ? "vo.opened" : "vo.tap"
    }
}

/// Opens a view-once message one time: nothing is saved, the screen cannot be shared from, and closing it ends it.
struct ViewOnceViewer: View {
    let message: Message
    let token: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var audio: AVAudioPlayer?
    @State private var gone = false
    @State private var failed = false
    @State private var loading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            } else if audio != nil {
                VStack(spacing: 14) {
                    Image(systemName: "waveform").font(.system(size: 56, weight: .light)).foregroundStyle(Theme.accent)
                    Text("vo.voice.playing").font(.system(size: 16)).foregroundStyle(.white.opacity(0.8))
                }
            } else if failed {
                // no connection: nothing was opened, it can be tried again
                Button { failed = false; loading = true; Task { await load() } } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise").font(.title2)
                        Text("photo.retry").font(.footnote)
                    }
                    .foregroundStyle(.white.opacity(0.85)).frame(width: 180, height: 120)
                }
            } else if gone {
                Text("vo.gone").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center).padding(24)
            } else if loading {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(Color.black.opacity(0.4), in: Circle())
                    }
                    .accessibilityLabel(Text("chat.close"))
                    Spacer()
                    Label("vo.once", systemImage: "1.circle").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 32).background(Color.black.opacity(0.4), in: Capsule())
                }
                .padding(.horizontal, 14)
                Spacer()
            }
        }
        .statusBarHidden()
        .task { await load() }
        .onDisappear {
            player?.pause()
            audio?.stop()
        }
    }

    private func load() async {
        defer { loading = false }
        switch message.viewOnceKind {
        case "voice":
            guard let id = message.audio_id else { gone = true; return }
            let (data, status) = await APIClient.shared.viewOnceData(token: token, path: ["media", "voice", id])
            if status == 200 || status == 404 || status == 410 { ViewOnceSeen.mark(message.id) } // a dropped connection is not an open
            if status == 0 { failed = true; return }
            guard let data, let a = try? AVAudioPlayer(data: data) else { gone = true; return }
            if !CallManager.shared.lineInUse {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try? AVAudioSession.sharedInstance().setActive(true)
            }
            a.play()
            audio = a
        case "video":
            guard let fid = message.file_id else { gone = true; return }
            let asset = AVURLAsset(url: APIClient.shared.viewOnceURL(path: ["files", fid]),
                                   options: ["AVURLAssetHTTPHeaderFieldsKey": APIClient.shared.viewOnceHeaders(token: token)])
            let item = AVPlayerItem(asset: asset)
            let p = AVPlayer(playerItem: item)
            p.play()
            player = p
            ViewOnceSeen.mark(message.id) // the stream is the one open
            // a video that cannot be read any more (opened before, or past its time)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if item.status == .failed { player = nil; gone = true }
        default:
            guard let fid = message.file_id else { gone = true; return }
            let (data, status) = await APIClient.shared.viewOnceData(token: token, path: ["files", fid])
            if status == 200 || status == 404 || status == 410 { ViewOnceSeen.mark(message.id) }
            if status == 0 { failed = true; return }
            guard let data, let img = UIImage(data: data) else { gone = true; return }
            image = img
        }
    }
}
