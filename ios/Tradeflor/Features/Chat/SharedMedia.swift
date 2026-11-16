import SwiftUI

/// What was shared in a conversation (website SharedMedia in GroupInfoPanel / ContactInfo): Media, Files, Voice, Links,
/// newest first, with "load more". Photos and videos open full screen, files in Quick Look, voice plays, links open.
struct SharedMediaCard: View {
    let token: String
    let conversationID: String

    @State private var tab = "media"
    @State private var items: [Message] = []
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var photo: ViewedPhoto?
    @State private var video: ViewedPhoto?
    @State private var doc: LocalDoc?
    @ObservedObject private var voice = VoicePlayer.shared
    @Environment(\.openURL) private var openURL

    private let pageSize = 60

    var body: some View {
        TFCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("ci.media").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(["media", "files", "voice", "links"], id: \.self) { c in
                            FilterChip(title: NSLocalizedString("ci.tab." + c, comment: ""), selected: tab == c) {
                                guard tab != c else { return }
                                tab = c
                                Task { await load(reset: true) }
                            }
                        }
                    }
                }
                if items.isEmpty {
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("ci.media.none").font(.system(size: 12)).foregroundStyle(Theme.faint) }
                } else if tab == "media" {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                        ForEach(items.filter { $0.file_id != nil }) { m in
                            let isVideo = (m.file_mime ?? "").hasPrefix("video/") || VideoNotePrep.isNote(m)
                            ZStack {
                                RemoteImage(token: token, fileID: m.file_id ?? "")
                                if isVideo {
                                    Image(systemName: "play.circle.fill").font(.system(size: 26)).foregroundStyle(.white.opacity(0.9))
                                }
                            }
                            .frame(height: 104).clipped().contentShape(Rectangle())
                            .onTapGesture {
                                if isVideo { video = ViewedPhoto(id: m.file_id ?? "") } else { photo = ViewedPhoto(id: m.file_id ?? "") }
                            }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(Text(LocalizedStringKey(isVideo ? "ci.open.video" : "ci.open.photo")))
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items) { m in row(m) }
                    }
                }
                if !items.isEmpty && !reachedEnd {
                    Button { Task { await load(reset: false) } } label: {
                        HStack { Spacer(); if loading { ProgressView() } else { Text("chat.older").font(.footnote) }; Spacer() }
                    }
                    .disabled(loading)
                }
            }
            .padding(14)
        }
        .task { await load(reset: true) }
        .fullScreenCover(item: $photo) { p in PhotoViewer(token: token, fileID: p.id) }
        .fullScreenCover(item: $video) { v in VideoScreen(token: token, fileID: v.id) }
        .fullScreenCover(item: $doc) { d in DocumentPreview(url: d.url).ignoresSafeArea() }
    }

    private func row(_ m: Message) -> some View {
        Button {
            Task { await open(m) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(m))
                    .foregroundStyle(Theme.accent).frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(m)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if let d = m.date { Text(d, style: .date).font(.system(size: 11)).foregroundStyle(Theme.faint) }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(_ m: Message) -> String {
        switch tab {
        case "voice": return voice.current == m.audio_id && m.audio_id != nil && voice.playing ? "pause.fill" : "play.fill"
        case "links": return "link"
        default: return "doc"
        }
    }

    private func title(_ m: Message) -> String {
        switch tab {
        case "files": return m.file_name ?? m.body
        case "voice": return String(format: NSLocalizedString("ci.voice.item", comment: ""), VoiceBubble.length(m.duration_ms ?? 0))
        case "links": return Self.firstLink(m.body)?.absoluteString ?? m.body
        default: return m.body
        }
    }

    static func firstLink(_ text: String) -> URL? {
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return det.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }

    private func open(_ m: Message) async {
        switch tab {
        case "voice":
            if let a = m.audio_id { voice.toggle(token: token, audioID: a, mime: m.mime_type) }
        case "links":
            if let u = Self.firstLink(m.body) { openURL(u) }
        default:
            if let fid = m.file_id, let url = await MediaSaver.localFile(token: token, fileID: fid, name: m.file_name) { doc = LocalDoc(url: url) }
        }
    }

    private func load(reset: Bool) async {
        loading = true
        defer { loading = false }
        let before = reset ? nil : items.last?.seq
        let b = before.map { "&before=\($0)" } ?? ""
        let page = (try? await APIClient.shared.list(Message.self, "conversations/\(conversationID)/media?category=\(tab)&limit=\(pageSize)\(b)", token: token)) ?? []
        if reset { items = page } else { items += page.filter { p in !items.contains { $0.id == p.id } } }
        reachedEnd = page.count < pageSize
    }
}
