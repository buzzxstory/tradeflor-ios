import SwiftUI

// Invite friends (website InviteFriendsSheet.tsx, 9f7f25d): any member. The group's link with Copy link / Share / QR code, and
// your contacts, each with Send (a private message with the link, from you) and, when you may add people, Add (straight into
// the group). A public group shares its permanent link; a private one an invitation link made on demand (only for people
// allowed to invite; the server decides).

struct InviteFriendsSheet: View {
    let groupID: String
    let groupName: String
    let handle: String
    let isPublic: Bool
    let canInvite: Bool
    let memberIDs: Set<String>
    var onAdded: () -> Void = {}
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var contacts: [ContactEntry]?
    @State private var q = ""
    @State private var link: String?
    @State private var linkBusy = false
    @State private var note: String?
    @State private var done: [String: String] = [:] // user id: "sent" | "added"
    @State private var busy: String?
    @State private var showQR = false
    @State private var sharing: ShareItems?

    private struct ShareItems: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    private var token: String { store.session?.token ?? "" }
    private var publicLink: String? { !handle.isEmpty && isPublic ? "https://app.tradeflor.com/g/\(handle)" : nil }
    private var canShareLink: Bool { publicLink != nil || canInvite }

    private static let cyan = Theme.dyn(0x2FF0F3, 0x0097A5)
    private static let primary = LinearGradient(colors: [Theme.hex(0x2FF0F3), Theme.hex(0x08A8B8)], startPoint: .topLeading, endPoint: .bottomTrailing)
    private static let onPrimary = Theme.hex(0x032229)
    private static let muted = Theme.dyn(0x7F9AA7, 0x5F7686)

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if canShareLink {
                        linkCard
                        Text(NSLocalizedString("gx.inv.contacts", comment: "").uppercased())
                            .font(.system(size: 11, weight: .bold)).tracking(0.9).foregroundStyle(Self.muted).padding(.top, 2)
                        searchField
                        contactList
                    } else {
                        Text("gx.inv.private").font(.system(size: 13.5)).foregroundStyle(Self.muted)
                            .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                            .padding(.vertical, 18).padding(.horizontal, 14)
                            .background(Theme.dyn(0x01141B, 0xF3FAFC, 0.45, 1), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
            if let note {
                Text(note).font(.system(size: 13)).foregroundStyle(Theme.dyn(0x5FE6EE, 0x0097A5))
                    .multilineTextAlignment(.center).padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .background(Theme.soulCard.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .tfColorScheme()
        .task {
            if link == nil { link = publicLink }
            contacts = (try? await APIClient.shared.ctContacts(token: token)) ?? []
        }
        .sheet(isPresented: $showQR) { GroupQRSheet(name: groupName, link: link ?? "") }
        .sheet(item: $sharing) { s in ActivityShare(items: s.items).presentationDetents([.medium, .large]) }
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "paperplane").font(.system(size: 18, weight: .semibold)).foregroundStyle(Self.cyan)
                .frame(width: 40, height: 40)
                .background(Theme.dyn(0x2FF0F3, 0x0097A5, 0.1, 0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text("gx.inv.title").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                Text(String(format: NSLocalizedString("ams.to", comment: ""), groupName)).font(.system(size: 12.5))
                    .foregroundStyle(Self.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
                    .background(Theme.dyn(0x78BED2, 0xD3E1EA, 0.1, 1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("chat.close"))
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)
    }

    private var linkCard: some View {
        let shown = link ?? publicLink
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "link").font(.system(size: 16, weight: .semibold)).foregroundStyle(Self.cyan)
                    .frame(width: 34, height: 34)
                    .background(Theme.dyn(0x2FF0F3, 0x0097A5, 0.1, 0.1), in: RoundedRectangle(cornerRadius: 10))
                if let shown {
                    Text(shown.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.dyn(0x5FE6EE, 0x0097A5))
                        .lineLimit(1).truncationMode(.middle)
                        .environment(\.layoutDirection, .leftToRight)
                } else {
                    Text("gx.inv.placeholder").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Self.muted).lineLimit(2)
                }
                Spacer(minLength: 0)
                if linkBusy { ProgressView().tint(Self.cyan) }
            }
            GeometryReader { geo in
                let unit = max(0, geo.size.width - 16) / 3.3
                HStack(spacing: 8) {
                    pillButton("grp.copy.link", primary: true) { Task { await copy() } }.frame(width: unit * 1.3)
                    pillButton("gi.share", primary: false) { Task { await share() } }.frame(width: unit)
                    pillButton("gx.inv.qr", primary: false) {
                        Task { if await getLink() != nil { showQR = true } }
                    }
                    .frame(width: unit)
                }
            }
            .frame(height: 36)
            .disabled(linkBusy)
            .opacity(linkBusy ? 0.55 : 1)
        }
        .padding(12)
        .background(Theme.dyn(0x00CAD1, 0x0097A5, 0.06, 0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.dyn(0x00CAD1, 0x00A8B5, 0.28, 0.35), lineWidth: 1))
    }

    private func pillButton(_ key: LocalizedStringKey, primary: Bool, height: CGFloat = 36, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(key).font(.system(size: 13.5, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(primary ? Self.onPrimary : Theme.text)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background {
                    if primary { Capsule().fill(Self.primary) } else { Capsule().fill(Theme.dyn(0x01141B, 0xFFFFFF, 0.6, 1)) }
                }
                .overlay { if !primary { Capsule().stroke(Theme.dyn(0x50AAC8, 0xA6E3E7, 0.4, 1), lineWidth: 1) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            TextField("", text: $q, prompt: Text("gx.inv.search").foregroundColor(Theme.faint))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .foregroundStyle(Theme.text).submitLabel(.search)
        }
        .padding(.horizontal, 14).frame(height: 42)
        .background(Theme.soulInput, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.dyn(0x00C8D7, 0x00A8B5, 0.35, 0.45), lineWidth: 1))
    }

    private var filtered: [ContactEntry] {
        var t = q.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("@") { t.removeFirst() }
        return (contacts ?? [])
            .filter { c in t.isEmpty || c.username.lowercased().contains(t) || (c.alias ?? "").lowercased().contains(t) }
            .sorted { a, b in
                let ma = memberIDs.contains(a.user_id), mb = memberIDs.contains(b.user_id)
                if ma != mb { return !ma }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
    }

    @ViewBuilder private var contactList: some View {
        let list = filtered
        VStack(spacing: 0) {
            if contacts == nil {
                empty("gx.inv.loading")
            } else if list.isEmpty {
                empty(LocalizedStringKey(q.trimmingCharacters(in: .whitespaces).isEmpty ? "gx.inv.empty" : "gx.inv.nomatch"))
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Rectangle().fill(Theme.dyn(0x78BED2, 0xD3E1EA, 0.06, 1)).frame(height: 1) }
                row(c)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .top)
        .background(Theme.dyn(0x01141B, 0xF3FAFC, 0.45, 1), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.soulCardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func empty(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.system(size: 13.5)).foregroundStyle(Self.muted).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, 18).padding(.horizontal, 14)
    }

    private func row(_ c: ContactEntry) -> some View {
        let inGroup = memberIDs.contains(c.user_id) || done[c.user_id] == "added"
        let sent = done[c.user_id] == "sent"
        return HStack(spacing: 10) {
            Avatar(token: token, userID: c.user_id, avatarID: nil, title: c.title, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(.system(size: 14.5, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("@" + c.username).font(.system(size: 12)).foregroundStyle(Self.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if inGroup {
                Text("ams.in").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Self.muted)
            } else if sent {
                Text("gx.inv.sent").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.dyn(0x3EE6A0, 0x0C8564))
            } else {
                if canInvite {
                    smallButton("ams.add", primary: false) { Task { await add(c) } }
                }
                smallButton(LocalizedStringKey(busy == c.user_id ? "…" : "gx.inv.send"), primary: true) { Task { await send(c) } }
            }
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 8)
        .disabled(busy == c.user_id)
    }

    private func smallButton(_ key: LocalizedStringKey, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(key).font(.system(size: 13, weight: .bold)).lineLimit(1)
                .foregroundStyle(primary ? Self.onPrimary : Theme.text)
                .padding(.horizontal, 14).frame(height: 32)
                .background {
                    if primary { Capsule().fill(Self.primary) } else { Capsule().fill(Theme.dyn(0x01141B, 0xFFFFFF, 0.6, 1)) }
                }
                .overlay { if !primary { Capsule().stroke(Theme.dyn(0x50AAC8, 0xA6E3E7, 0.4, 1), lineWidth: 1) } }
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: actions

    private func say(_ s: String) {
        note = s
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if note == s { note = nil }
        }
    }

    /// The link to share: the public one, or a fresh invitation link for a private group (made once, then reused).
    private func getLink() async -> String? {
        if let link { return link }
        if let publicLink { link = publicLink; return publicLink }
        guard canInvite else { return nil }
        linkBusy = true
        defer { linkBusy = false }
        do {
            let url = try await APIClient.shared.grpCreateInvite(token: token, id: groupID, hours: 0, maxUses: 0)
            link = url
            return url
        } catch APIError.refused(let why) {
            say(why.isEmpty ? NSLocalizedString("gx.inv.linkfail", comment: "") : why)
        } catch {
            say(NSLocalizedString("gx.inv.linkfail", comment: ""))
        }
        return nil
    }

    private func copy() async {
        guard let url = await getLink() else { return }
        UIPasteboard.general.string = url
        say(NSLocalizedString("grp.copied", comment: ""))
    }

    private func share() async {
        guard let url = await getLink() else { return }
        let text = String(format: NSLocalizedString("gi.share.text", comment: ""), groupName, url)
        sharing = ShareItems(items: [text])
    }

    private func send(_ c: ContactEntry) async {
        guard busy == nil, let url = await getLink() else { return }
        busy = c.user_id
        defer { busy = nil }
        do {
            let conv = try await APIClient.shared.directConversation(token: token, with: c.user_id)
            let body = String(format: NSLocalizedString("gx.inv.msg", comment: ""), groupName, url)
            let ms = Int64(Date().timeIntervalSince1970 * 1000)
            _ = try await APIClient.shared.sendText(token: token, conversationID: conv, body: body, key: "ginv-\(groupID)-\(c.user_id)-\(ms)")
            done[c.user_id] = "sent"
        } catch APIError.refused(let why) {
            say(why.isEmpty ? NSLocalizedString("gx.inv.sendfail", comment: "") : why)
        } catch {
            say(NSLocalizedString("gx.inv.sendfail", comment: ""))
        }
    }

    private func add(_ c: ContactEntry) async {
        guard busy == nil else { return }
        busy = c.user_id
        defer { busy = nil }
        do {
            try await APIClient.shared.grpAddMember(token: token, id: groupID, username: c.username)
            done[c.user_id] = "added"
            onAdded()
        } catch APIError.refused(let why) {
            say(why.isEmpty ? NSLocalizedString("ams.failed", comment: "") : why)
        } catch {
            say(NSLocalizedString("ams.failed", comment: ""))
        }
    }
}
