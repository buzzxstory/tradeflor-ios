import SwiftUI
import UIKit

// Contact info V3 (website features/profile/ContactInfo.tsx and 77-contact-info-v3.css "ci3", db83951): the row, card, tile and
// switch look, and the sub-pages Media, links and docs · Free up storage · Groups in common · Add to list, plus the helpers
// behind Favorites / lists, this device's copy of a chat and Export chat.

// MARK: look

enum CIV3 {
    static let cyan = Theme.dyn(0x35E6F2, 0x0097A5)
    static let rowText = Theme.dyn(0xEEF6F9, 0x10303A)
    static let rowIcon = Theme.dyn(0xCFE0E6, 0x3C5668)
    static let value = Theme.dyn(0x93AAB4, 0x5F7686)
    static let about = Theme.dyn(0xC9D8DE, 0x3C5668)
    static let handle = Theme.dyn(0x8FA6B2, 0x5F7686)
    static let danger = Theme.dyn(0xFF6B78, 0xD8404A)
    static let tile = Theme.dyn(0x03161E, 0xFFFFFF, 0.72, 1)
    static let divider = Theme.dyn(0x3C8CA5, 0x1E5A78, 0.22, 0.12)
    static let explain = Theme.dyn(0x9FB4BF, 0x3C5668)

    /// "Zero KB", "1.2 MB" (the system's file-size wording, localized).
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func tr(_ key: String) -> String { NSLocalizedString(key, comment: "") }
}

/// A rounded navy card of rows (website .pf-card.ci-group).
struct CIV3Card<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .background(Theme.soulCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.soulCardBorder, lineWidth: 1))
    }
}

/// The thin line between two rows.
struct CIV3Divider: View {
    var inset: CGFloat = 56
    var body: some View {
        Rectangle().fill(CIV3.divider).frame(height: 0.5).padding(.leading, inset)
    }
}

/// One row: icon, medium 16.5 pt label (optional small line), muted value, chevron or switch; 50 pt high.
struct CIV3Row: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var danger = false
    var chevron = true
    /// a switch instead of the chevron (Lock chat)
    var toggle: Bool? = nil

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .foregroundStyle(danger ? CIV3.danger : CIV3.rowIcon)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 16.5, weight: .medium))
                    .foregroundStyle(danger ? CIV3.danger : CIV3.rowText)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(verbatim: subtitle).font(.system(size: 13)).foregroundStyle(CIV3.value).multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(verbatim: value).font(.system(size: 15.5)).foregroundStyle(CIV3.value).lineLimit(1)
            }
            if let toggle {
                CIV3Switch(on: toggle)
            } else if chevron {
                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(CIV3.value)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

/// The switch look of "Lock chat" (the row opens the lock flow; the switch only shows the state).
struct CIV3Switch: View {
    let on: Bool
    var body: some View {
        Capsule()
            .fill(on ? Theme.hex(0x12B8C4) : Theme.dyn(0x1D3D4A, 0xC9D8DE))
            .frame(width: 46, height: 28)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(Theme.hex(0xEEF6F9)).frame(width: 22, height: 22).padding(3)
            }
            .animation(.easeOut(duration: 0.18), value: on)
            .accessibilityHidden(true)
    }
}

/// Chat · Voice · Search: a square tile.
struct CIV3Tile: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 23)).foregroundStyle(CIV3.cyan).frame(height: 28)
                Text(verbatim: title).font(.system(size: 14.5, weight: .medium)).foregroundStyle(CIV3.rowText)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: 110)
            .frame(height: 78)
            .background(CIV3.tile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hex(0x35E6F2, 0.3), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Something to hand to the system share sheet (Share contact's card image, the exported chat file).
struct CIV3Share: Identifiable {
    let id = UUID()
    let items: [Any]
}

// MARK: Media, links and docs

/// Three tabs as a segmented control (Media · Links · Docs), 24 at a time, newest first. Photos and videos in a 3-column grid
/// (videos carry a play mark and open in the video player), links open, documents open in Quick Look.
@MainActor
struct CIV3MediaPage: View {
    let token: String
    let conversationID: String

    @State private var tab = "media"
    @State private var items: [Message] = []
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var photo: ViewedPhoto?
    @State private var video: ViewedPhoto?
    @State private var doc: LocalDoc?
    @State private var opening = false
    @Environment(\.openURL) private var openURL

    private let pageSize = 24
    private struct Tab: Identifiable {
        let id: String
        let key: String
    }
    private static let tabs = [Tab(id: "media", key: "ci.tab.media"), Tab(id: "links", key: "ci.tab.links"), Tab(id: "files", key: "civ3.tab.docs")]

    var body: some View {
        SettingsPage(title: CIV3.tr("ci.media")) {
            segmented
            content
            if !items.isEmpty && !reachedEnd {
                Button { Task { await load(reset: false) } } label: {
                    HStack {
                        Spacer()
                        if loading { ProgressView().tint(Theme.accent) } else {
                            Text("chat.older").font(.system(size: 14, weight: .medium)).foregroundStyle(CIV3.cyan)
                        }
                        Spacer()
                    }
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(loading)
            }
        }
        .task { if items.isEmpty { await load(reset: true) } }
        .fullScreenCover(item: $photo) { p in PhotoViewer(token: token, fileID: p.id) }
        .fullScreenCover(item: $video) { v in VideoScreen(token: token, fileID: v.id) }
        .fullScreenCover(item: $doc) { d in DocumentPreview(url: d.url).ignoresSafeArea() }
    }

    private var segmented: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs) { t in
                Button {
                    guard tab != t.id else { return }
                    tab = t.id
                    Task { await load(reset: true) }
                } label: {
                    Text(LocalizedStringKey(t.key))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(tab == t.id ? Theme.hex(0x032029) : CIV3.rowText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if tab == t.id {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(LinearGradient(colors: [Theme.hex(0x1FD2DC), Theme.hex(0x0EA9B5)], startPoint: .top, endPoint: .bottom))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == t.id ? .isSelected : [])
            }
        }
        .padding(3)
        .background(CIV3.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hex(0x35E6F2, 0.25), lineWidth: 1))
    }

    @ViewBuilder private var content: some View {
        if items.isEmpty {
            Group {
                if loading { ProgressView().tint(Theme.accent) } else {
                    Text("ci.media.none").font(.system(size: 14)).foregroundStyle(CIV3.explain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
        } else if tab == "media" {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(items.filter { $0.file_id != nil }) { m in thumb(m) }
            }
        } else {
            CIV3Card {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, m in
                    if i > 0 { CIV3Divider(inset: 66) }
                    row(m)
                }
            }
        }
    }

    private func thumb(_ m: Message) -> some View {
        let isVideo = (m.file_mime ?? "").hasPrefix("video/") || VideoNotePrep.isNote(m)
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { RemoteImage(token: token, fileID: m.file_id ?? "") }
            .overlay(alignment: .bottomLeading) {
                if isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .padding(6)
                }
            }
            .background(Theme.hex(0x08202A))
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                guard let f = m.file_id else { return }
                if isVideo { video = ViewedPhoto(id: f) } else { photo = ViewedPhoto(id: f) }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(LocalizedStringKey(isVideo ? "ci.open.video" : "ci.open.photo")))
    }

    private func row(_ m: Message) -> some View {
        Button { Task { await open(m) } } label: {
            HStack(spacing: 14) {
                Image(systemName: tab == "links" ? "link" : "doc.text")
                    .font(.system(size: 17))
                    .foregroundStyle(CIV3.cyan)
                    .frame(width: 38, height: 38)
                    .background(CIV3.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title(m)).font(.system(size: 15.5, weight: .medium)).foregroundStyle(CIV3.rowText)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if let d = m.date { Text(d, style: .date).font(.system(size: 13)).foregroundStyle(CIV3.value) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(opening)
    }

    private func title(_ m: Message) -> String {
        if tab == "links" { return SharedMediaCard.firstLink(m.body)?.absoluteString ?? m.body }
        if let n = m.file_name, !n.isEmpty { return n }
        return m.body
    }

    private func open(_ m: Message) async {
        if tab == "links" {
            if let u = SharedMediaCard.firstLink(m.body) { openURL(u) }
            return
        }
        guard let fid = m.file_id else { return }
        opening = true
        defer { opening = false }
        if let url = await MediaSaver.localFile(token: token, fileID: fid, name: m.file_name) { doc = LocalDoc(url: url) }
    }

    private func load(reset: Bool) async {
        if loading && !reset { return }
        let category = tab
        if reset {
            items = []
            reachedEnd = false
        }
        loading = true
        defer { loading = false }
        let before = reset ? nil : items.last?.seq
        let page = (try? await APIClient.shared.civ3MediaPage(token: token, conversationID: conversationID, category: category,
                                                              before: before, limit: pageSize)) ?? []
        guard category == tab else { return } // another tab was chosen meanwhile
        if reset { items = page } else { items += page.filter { p in !items.contains { $0.id == p.id } } }
        reachedEnd = page.count < pageSize
    }
}

// MARK: Free up storage

/// What this device keeps of one chat. The app keeps no message history on disk (the server marks conversation content as
/// not-for-disk), so the copy is: documents opened from this chat (written to tmp/tf-files/<file id> for Quick Look) and the
/// photos, video covers and voice messages of this chat still held in the in-memory cache. Unsent messages (the Outbox) are
/// never counted or removed: they are not on the account yet.
enum LocalChatCopy {
    struct Copy {
        var bytes: Int64 = 0
        var folders: [URL] = []
        var cacheKeys: [String] = []
        /// Copies kept on disk in Caches (FileDiskCache): "<file id>/t" and "<file id>/f".
        var diskKeys: [String] = []
    }

    static var filesDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("tf-files", isDirectory: true) }

    /// This chat's attachment ids, read page by page from the server's index of shared items (at most 8 pages per kind).
    static func attachmentIDs(token: String, conversationID: String) async -> (files: Set<String>, audio: Set<String>) {
        var files = Set<String>(), audio = Set<String>()
        let limit = 60
        for category in ["media", "files", "voice"] {
            var before: Int64?
            for _ in 0..<8 {
                guard let page = try? await APIClient.shared.civ3MediaPage(token: token, conversationID: conversationID, category: category,
                                                                           before: before, limit: limit),
                      !page.isEmpty else { break }
                for m in page {
                    if let f = m.file_id, !f.isEmpty { files.insert(f) }
                    if let a = m.audio_id, !a.isEmpty { audio.insert(a) }
                }
                let oldest = page.map(\.seq).min()
                if page.count < limit || oldest == nil || oldest == before { break }
                before = oldest
            }
        }
        return (files, audio)
    }

    static func measure(token: String, conversationID: String) async -> Copy {
        let ids = await attachmentIDs(token: token, conversationID: conversationID)
        var copy = Copy()
        let fm = FileManager.default
        let cache = APIClient.shared.avatarCache
        for id in ids.files {
            let dir = filesDir.appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: dir.path) {
                copy.folders.append(dir)
                copy.bytes += folderSize(dir)
            }
            for key in ["\(id)/t", "\(id)/f"] {
                var counted = false
                if let d = cache.object(forKey: key as NSString) {
                    copy.cacheKeys.append(key)
                    copy.bytes += Int64(d.length)
                    counted = true
                }
                // the same picture kept on disk (Caches/tf-files): it is removed too, and counted once
                let onDisk = FileDiskCache.size(key)
                if onDisk > 0 {
                    copy.diskKeys.append(key)
                    if !counted { copy.bytes += onDisk }
                }
            }
        }
        for a in ids.audio {
            let key = "voice/\(a)"
            if let d = cache.object(forKey: key as NSString) {
                copy.cacheKeys.append(key)
                copy.bytes += Int64(d.length)
            }
        }
        return copy
    }

    static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        while let f = e.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Removes only this device's copy. Never calls the server.
    static func clear(_ copy: Copy) {
        for d in copy.folders { try? FileManager.default.removeItem(at: d) }
        for k in copy.cacheKeys { APIClient.shared.avatarCache.removeObject(forKey: k as NSString) }
        for k in copy.diskKeys { FileDiskCache.remove(k) }
        // pictures that were only on disk are gone from memory as well
        for k in copy.diskKeys { APIClient.shared.avatarCache.removeObject(forKey: k as NSString) }
    }
}

struct CIV3StoragePage: View {
    @Binding var bytes: Int64
    @Binding var measuring: Bool
    let onClear: () -> Void
    @State private var ask = false

    var body: some View {
        SettingsPage(title: CIV3.tr("civ3.storage")) {
            CIV3Card {
                HStack(spacing: 16) {
                    Image(systemName: "internaldrive").font(.system(size: 19)).foregroundStyle(CIV3.rowIcon).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("civ3.storage.saved").font(.system(size: 16.5, weight: .medium)).foregroundStyle(CIV3.rowText)
                        Text("civ3.storage.saved.sub").font(.system(size: 13)).foregroundStyle(CIV3.value)
                    }
                    Spacer(minLength: 8)
                    if measuring {
                        ProgressView().tint(Theme.accent)
                    } else {
                        Text(verbatim: CIV3.bytes(bytes)).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                }
                .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 10)
                .frame(minHeight: 50)
            }
            Text("civ3.storage.explain")
                .font(.system(size: 14)).foregroundStyle(CIV3.explain).lineSpacing(3)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
            Button { ask = true } label: {
                Text("civ3.storage.clear")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CIV3.danger)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hex(0xFF6B78, 0.45), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(bytes == 0 || measuring)
            .opacity(bytes == 0 || measuring ? 0.45 : 1)
        }
        .alert(Text("civ3.storage.confirm"), isPresented: $ask) {
            Button("grp.cancel", role: .cancel) {}
            Button("civ3.storage.confirm.ok") { onClear() }
        } message: {
            Text("civ3.storage.confirm.msg")
        }
    }
}

// MARK: Groups in common

struct CIV3GroupsPage: View {
    let token: String
    let groups: [CommonGroup]
    let name: String
    let onOpen: (CommonGroup) -> Void

    var body: some View {
        SettingsPage(title: CIV3.tr("civ3.groups.title")) {
            if groups.isEmpty {
                Text("civ3.groups.none").font(.system(size: 14)).foregroundStyle(CIV3.explain).padding(.horizontal, 4)
            } else {
                CIV3Card {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                        if i > 0 { CIV3Divider(inset: 70) }
                        Button { onOpen(g) } label: {
                            HStack(spacing: 14) {
                                Avatar(token: token, userID: "", avatarID: g.avatar_id, title: g.name, groupID: g.id, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: g.name).font(.system(size: 16.5, weight: .medium)).foregroundStyle(CIV3.rowText).lineLimit(1)
                                    Text(verbatim: Self.members(g.member_count)).font(.system(size: 13)).foregroundStyle(CIV3.value)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(CIV3.value)
                            }
                            .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 8)
                            .frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(verbatim: String(format: CIV3.tr("civ3.groups.note"), name))
                .font(.system(size: 14)).foregroundStyle(CIV3.explain).padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func members(_ n: Int) -> String {
        n == 1 ? CIV3.tr("civ3.member.one") : String(format: CIV3.tr("civ3.members"), n)
    }
}

// MARK: Favorites and lists (the chat folders)

enum CIV3Folders {
    static func isFavorites(_ f: EditableFolder) -> Bool {
        f.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "favorites"
    }

    static func apply(_ list: [EditableFolder], conversationID: String, on: Bool, match: (EditableFolder) -> Bool) -> [EditableFolder] {
        list.map { f in
            guard match(f) else { return f }
            var g = f
            if on {
                if !g.items.contains(conversationID) { g.items.append(conversationID) }
                g.exclude.removeAll { $0 == conversationID }
            } else {
                g.items.removeAll { $0 == conversationID }
            }
            return g
        }
    }

    /// Adds the chat to (or removes it from) the folders that match, saves (re-applied on the server's copy after a 409,
    /// FolderStore.save) and returns the saved list.
    static func set(token: String, conversationID: String, on: Bool, match: @escaping (EditableFolder) -> Bool) async throws -> [EditableFolder] {
        try await FolderStore.save(token: token) { list in apply(list, conversationID: conversationID, on: on, match: match) }
        return try await FolderStore.load(token: token).1
    }

    /// Favorites is the folder of that name, created on first use.
    static func setFavorite(token: String, conversationID: String, on: Bool) async throws -> [EditableFolder] {
        try await FolderStore.save(token: token) { list in
            if list.contains(where: { isFavorites($0) }) {
                return apply(list, conversationID: conversationID, on: on, match: { isFavorites($0) })
            }
            guard on else { return list }
            let id = "fav_" + String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36)
            return list + [EditableFolder(id: id, name: "Favorites", items: [conversationID], exclude: [], icon: "", color: "",
                                          rulesOn: false, matchAll: true, conditions: [])]
        }
        return try await FolderStore.load(token: token).1
    }
}

/// "Add to list": every folder with a check where this chat is in it; a tap adds or removes it.
@MainActor
struct CIV3ListsPage: View {
    let token: String
    let conversationID: String
    @Binding var folders: [EditableFolder]?
    let flash: (String) -> Void
    @State private var busy = false

    var body: some View {
        SettingsPage(title: CIV3.tr("civ3.list")) {
            if let folders {
                if folders.isEmpty {
                    Text("civ3.list.none").font(.system(size: 14)).foregroundStyle(CIV3.explain).padding(.horizontal, 4)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    CIV3Card {
                        ForEach(Array(folders.enumerated()), id: \.element.id) { i, f in
                            if i > 0 { CIV3Divider() }
                            let inside = f.items.contains(conversationID)
                            Button { Task { await toggle(f) } } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: FolderStore.symbol(f.icon)).font(.system(size: 19)).foregroundStyle(CIV3.rowIcon).frame(width: 24)
                                    Text(verbatim: f.name).font(.system(size: 16.5, weight: .medium)).foregroundStyle(CIV3.rowText).lineLimit(1)
                                    Spacer(minLength: 8)
                                    ZStack {
                                        Circle().stroke(inside ? CIV3.cyan : Theme.hex(0x5F8B99), lineWidth: 2)
                                        if inside {
                                            Circle().fill(CIV3.cyan)
                                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.hex(0x032029))
                                        }
                                    }
                                    .frame(width: 24, height: 24)
                                }
                                .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 8)
                                .frame(minHeight: 50)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                            .accessibilityAddTraits(inside ? .isSelected : [])
                        }
                    }
                }
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 30)
            }
        }
    }

    private func toggle(_ f: EditableFolder) async {
        let on = !f.items.contains(conversationID)
        let id = f.id
        busy = true
        defer { busy = false }
        do {
            folders = try await CIV3Folders.set(token: token, conversationID: conversationID, on: on) { $0.id == id }
            flash(String(format: CIV3.tr(on ? "civ3.list.added" : "civ3.list.removed"), f.name))
        } catch {
            flash(CIV3.tr("settings.failed"))
        }
    }
}

// MARK: Export chat

/// The conversation's history as a plain text file, from the server's own history (my "Clear chat" and "Delete for me" are
/// respected there), like the website's exportChat.ts. The caller refuses a restricted chat.
enum ChatExporter {
    static func export(token: String, conversationID: String, title: String, nameOf: (String) -> String, me: String) async throws -> (URL, Int) {
        var all: [Message] = []
        var before: Int64?
        for _ in 0..<400 {
            let page = try await APIClient.shared.messages(token: token, conversationID: conversationID, before: before, limit: 200)
            if page.isEmpty { break }
            all.insert(contentsOf: page, at: 0)
            guard let oldest = page.map(\.seq).min() else { break }
            if let b = before, oldest >= b { break }
            before = oldest
            if page.count < 200 { break }
        }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        var lines: [String] = []
        for m in all where !m.isDeleted {
            let when = m.date.map { f.string(from: $0) } ?? ""
            let who = nameOf(m.sender_id)
            switch m.kind {
            case "image", "file":
                let line = "[\(when)] \(who): [\(m.kind): \(m.file_name ?? "file")] \(m.body)"
                lines.append(line.trimmingCharacters(in: .whitespaces))
            case "voice":
                lines.append("[\(when)] \(who): [voice message]")
            default:
                lines.append("[\(when)] \(who): \(m.body)")
            }
        }
        let text = "\(title) - exported \(f.string(from: Date())) by \(me)\n\(lines.count) messages\n\n\(lines.joined(separator: "\n"))\n"
        let safe = title.replacingOccurrences(of: "[^A-Za-z0-9_\\-]+", with: "-", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty || safe == "-" ? "chat" : safe)-chat-history.txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (url, lines.count)
    }
}
