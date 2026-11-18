import SwiftUI
import PhotosUI

/// A square, centred JPEG for group logos (the server keeps pictures small).
enum GrpImage {
    static func squareJPEG(_ img: UIImage, side maxSide: CGFloat = 1024) -> Data? {
        let side = min(img.size.width, img.size.height)
        guard side > 0 else { return nil }
        let target = min(maxSide, side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let scale = target / side
        let out = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            img.draw(in: CGRect(x: -(img.size.width - side) / 2 * scale, y: -(img.size.height - side) / 2 * scale,
                                width: img.size.width * scale, height: img.size.height * scale))
        }
        return out.jpegData(compressionQuality: 0.85)
    }
}

/// New Group / Edit Group (website CreateGroupModal.tsx): logo, name, permanent link, description, privacy, and
/// (new group only) members picked from my chats.
struct CreateGroupView: View {
    let onCreated: (String) -> Void
    var editing: GrpInfo? = nil
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var about = ""
    @State private var handle = ""
    @State private var isPublic = false
    @State private var people: [ConversationSummary] = []
    @State private var picked: Set<String> = []
    @State private var logoItem: PhotosPickerItem?
    @State private var logo: UIImage?
    @State private var busy = false
    @State private var error: String?
    @State private var createKey = ""
    @State private var createSig = ""

    private var token: String { store.session?.token ?? "" }
    private var isEdit: Bool { editing != nil }
    /// The permanent link and the privacy are the owner's (server: handle and privacy refuse admins, web 6f61080):
    /// an admin editing the group sees them but cannot change them.
    private var ownerEdit: Bool { editing.map { $0.isOwner } ?? true }
    private var handleLocked: Bool { !(editing?.handle ?? "").isEmpty || !ownerEdit }

    /// The fields that light up when focused (website .g-control:focus / .g-link-input:focus-within).
    private enum Field: Hashable { case name, handle, about }
    @FocusState private var focus: Field?

    // the owner's design (website 14-modals.css, fb9b6fc + bea99e7)
    private static let fieldFill = Theme.dyn(0x01141B, 0xFFFFFF, 0.6, 1)
    private static let fieldLine = Theme.dyn(0x287896, 0xC5D6E0, 0.55, 1)
    private static let fieldFocus = Theme.dyn(0x12E0F0, 0x0097A5, 0.8, 0.8)
    private static let labelTint = Theme.dyn(0x5FE6EE, 0x0097A5)

    private var sheetGround: some View {
        ZStack {
            LinearGradient(colors: [Theme.dyn(0x03202B, 0xF6F9FC), Theme.dyn(0x021821, 0xF1F6F9), Theme.dyn(0x01141B, 0xEEF4F8)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.dyn(0x06465A, 0xDFF2F5, 0.35, 0.6), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            GroupDialogArt().allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(LocalizedStringKey(isEdit ? "gx.edit.sub" : "grp.create.sub")).font(.system(size: 13.5)).foregroundStyle(Theme.faint)
                    HStack(spacing: 18) {
                        ZStack {
                            Circle().fill(Theme.avatarGradient)
                            if let logo {
                                Image(uiImage: logo).resizable().scaledToFill()
                            } else if let g = editing {
                                Avatar(token: token, userID: "", avatarID: g.avatar_id, title: g.name, groupID: g.conversation_id, size: 68)
                            } else {
                                Image(systemName: "person.3").font(.system(size: 24)).foregroundStyle(Theme.accent)
                            }
                        }
                        .frame(width: 68, height: 68).clipShape(Circle())
                        .overlay(Circle().stroke(Theme.hex(0x12E0F0, 0.55), lineWidth: 2))
                        PhotosPicker(selection: $logoItem, matching: .images) {
                            HStack(spacing: 8) {
                                Image(systemName: "camera").font(.system(size: 15))
                                Text(LocalizedStringKey((logo != nil || editing?.avatar_id != nil) ? "grp.logo.change" : "grp.logo.upload"))
                            }
                            .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.accent).lineLimit(1)
                            .padding(.horizontal, 14).frame(height: 36)
                            .background(Theme.hex(0x00CAD1, 0.06), in: Capsule())
                            .overlay(Capsule().stroke(Theme.borderActive, lineWidth: 1))
                        }
                    }
                    .padding(.top, 2)
                    Rectangle().fill(Theme.dyn(0x78BED2, 0xD3E1EA, 0.12, 1)).frame(height: 1)

                    field("grp.name", icon: "person.3", focused: focus == .name) {
                        TextField("", text: $name, prompt: Text("grp.name.ph").foregroundColor(Theme.faint))
                            .focused($focus, equals: .name)
                            .padding(.horizontal, 14).frame(height: 42)
                    }
                    field("grp.link", icon: "link", focused: focus == .handle) {
                        HStack(spacing: 0) {
                            Text("app.tradeflor.com/g/").font(.system(size: 14)).foregroundStyle(Theme.dyn(0x7F9AA7, 0x5F7686))
                                .lineLimit(1).fixedSize().padding(.leading, 14).padding(.trailing, 2)
                            TextField("", text: $handle, prompt: Text("yourgroup").foregroundColor(Theme.faint))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focus, equals: .handle)
                                .disabled(handleLocked)
                                .padding(.trailing, 12)
                                .onChange(of: handle) { v in
                                    let clean = String(v.lowercased().filter { ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "_" }.prefix(32))
                                    if clean != v { handle = clean }
                                }
                        }
                        .frame(height: 42)
                        .environment(\.layoutDirection, .leftToRight)
                    }
                    Text(LocalizedStringKey(handleLocked ? "grp.link.locked" : "grp.link.hint")).font(.system(size: 12)).foregroundStyle(Theme.faint)
                        .padding(.top, -6).padding(.leading, 4)
                    field("grp.desc", icon: "doc.text", focused: focus == .about) {
                        TextField("", text: $about, prompt: Text("grp.desc.ph").foregroundColor(Theme.faint), axis: .vertical)
                            .lineLimit(2...5)
                            .focused($focus, equals: .about)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(minHeight: 72, alignment: .topLeading)
                    }
                    label("grp.privacy", icon: "lock.shield")
                    VStack(spacing: 8) {
                        radio("grp.privacy.public", icon: "globe", selected: isPublic) { isPublic = true }
                        radio("grp.privacy.private", icon: "lock", selected: !isPublic) { isPublic = false }
                    }
                    .disabled(!ownerEdit)
                    .opacity(ownerEdit ? 1 : 0.55)

                    if !isEdit && !people.isEmpty {
                        TFSectionLabel(text: NSLocalizedString("group.members.pick", comment: ""))
                        TFCard {
                            ForEach(people) { c in
                                Button {
                                    if picked.contains(c.peer_id) { picked.remove(c.peer_id) } else { picked.insert(c.peer_id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        Avatar(token: token, userID: c.peer_id, avatarID: c.peer_avatar_id, title: c.title, size: 40)
                                        Text(c.title).foregroundStyle(Theme.text)
                                        Spacer()
                                        Image(systemName: picked.contains(c.peer_id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.accent)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.danger) }

                    // Cancel / Create (website .g-foot)
                    HStack(spacing: 10) {
                        Spacer()
                        Button { dismiss() } label: {
                            Text("grp.cancel").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.text)
                                .frame(width: 92, height: 40)
                                .background(Self.fieldFill, in: Capsule())
                                .overlay(Capsule().stroke(Self.fieldLine, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        Button { Task { await submit() } } label: {
                            HStack(spacing: 8) {
                                if busy { ProgressView().tint(Theme.hex(0x032229)) }
                                else {
                                    Image(systemName: isEdit ? "checkmark" : "plus").font(.system(size: 15, weight: .bold))
                                    Text(LocalizedStringKey(isEdit ? "grp.save" : "grp.create.go")).font(.system(size: 14.5, weight: .bold))
                                }
                            }
                            .foregroundStyle(Theme.hex(0x032229))
                            .padding(.horizontal, 20).frame(height: 42)
                            .background(LinearGradient(colors: [Theme.hex(0x2FF0F3), Theme.hex(0x08A8B8)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: Capsule())
                            .shadow(color: Theme.hex(0x2FF0F3, 0.3), radius: 8)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.6 : 1)
                    }
                    .padding(.top, 10)
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(sheetGround)
            .navigationTitle(Text(LocalizedStringKey(isEdit ? "grp.edit.title" : "grp.new.title")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.dyn(0x03202B, 0xF6F9FC), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                            .frame(width: 32, height: 32)
                            .background(Theme.dyn(0x78BED2, 0xD3E1EA, 0.1, 1), in: Circle())
                    }
                    .accessibilityLabel(Text("chat.close"))
                }
            }
        }
        .task {
            if let g = editing {
                name = g.name
                about = g.description
                handle = g.handle ?? ""
                isPublic = g.privacy == "public"
            } else {
                people = ((try? await APIClient.shared.conversations(token: token)) ?? []).filter { $0.conversation_id.hasPrefix("dm_") }
            }
        }
        .onChange(of: logoItem) { item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { logo = img }
            }
        }
    }

    /// A label with its 17 pt icon (website .g-label).
    private func label(_ key: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 17, height: 17).foregroundStyle(Self.labelTint)
            Text(key).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.muted)
        }
    }

    /// A field: label, then the control in a 42 pt box (radius 11, 1.5 pt line, cyan while focused).
    private func field<C: View>(_ key: LocalizedStringKey, icon: String, focused: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            label(key, icon: icon)
            content()
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Self.fieldFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(focused ? Self.fieldFocus : Self.fieldLine, lineWidth: 1.5))
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }

    private func radio(_ key: LocalizedStringKey, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 20).foregroundStyle(selected ? Theme.accent : Theme.faint)
                Text(key).font(.system(size: 14)).foregroundStyle(Theme.text)
                Spacer()
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Theme.accent : Theme.faint)
            }
            .padding(.horizontal, 14).frame(minHeight: 42)
            .background(selected ? Theme.hex(0x00CAD1, 0.08) : Self.fieldFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(selected ? Self.fieldFocus : Self.fieldLine, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private func submit() async {
        guard !busy else { return } // a second tap before the button greys out
        busy = true
        error = nil
        defer { busy = false }
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        let h = handle.trimmingCharacters(in: .whitespaces)
        if !h.isEmpty && !handleLocked && (h.count < 5 || !(h.first?.isLetter ?? false)) {
            error = NSLocalizedString("grp.link.invalid", comment: "")
            return
        }
        do {
            let id: String
            if let g = editing {
                id = g.conversation_id
                // privacy only from the owner, and only when it changed (website saveGroupEdit): the server refuses it from an admin
                let wanted = isPublic ? "public" : "private"
                try await APIClient.shared.grpUpdate(token: token, id: id, name: cleanName, description: about,
                                                     privacy: g.isOwner && wanted != g.privacy ? wanted : nil)
                if !handleLocked && !h.isEmpty { try await APIClient.shared.grpSetHandle(token: token, id: id, handle: h) }
            } else {
                // one key per form content (website createGroup): a retry after a lost answer returns the group already made,
                // a changed form is a new group
                let sig = [cleanName, about, isPublic ? "1" : "0", h].joined(separator: "\u{1}")
                if createSig != sig { createSig = sig; createKey = UUID().uuidString.lowercased() }
                id = try await APIClient.shared.createGroup(token: token, name: cleanName, description: about, isPublic: isPublic,
                                                            memberIDs: Array(picked), handle: h, key: createKey)
            }
            if let logo, let jpeg = GrpImage.squareJPEG(logo) {
                try? await APIClient.shared.grpUploadAvatar(token: token, id: id, jpeg: jpeg)
            }
            dismiss()
            onCreated(id)
        } catch APIError.refused(let why) {
            self.error = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
        } catch {
            self.error = NSLocalizedString("login.error.network", comment: "")
        }
    }
}

/// Join a group from an invite link or a public group link.
struct JoinGroupView: View {
    let onJoined: (String) -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var busy = false
    @State private var info: String?
    @State private var requested = false

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("group.join.hint")) {
                    TextField("group.join.link", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                .listRowBackground(Theme.surface)
                if let info { Section { Text(info).foregroundStyle(Theme.accent) }.listRowBackground(Theme.surface) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("group.join"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !requested { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    if requested {
                        Button("id.done") { dismiss() }.bold()
                    } else if busy { ProgressView() } else {
                        Button("group.join.go") { Task { await join() } }.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func join() async {
        guard let token = store.session?.token, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let id = try await APIClient.shared.joinGroup(token: token, link: link)
            if id.isEmpty {
                // asked to join: the owner or an admin decides
                info = NSLocalizedString("group.request.sent", comment: "")
                requested = true
            } else {
                dismiss()
                onJoined(id)
            }
        } catch APIError.refused(let why) {
            // a bad, expired or used-up link is the server's bare "not found" (404): the app's own words for it
            let w = why.lowercased()
            info = why.isEmpty || w == "not found" || w.contains("does not exist") || w.contains("not valid")
                ? NSLocalizedString("group.join.bad", comment: "") : why
        } catch APIError.rateLimited {
            info = NSLocalizedString("login.error.rate", comment: "")
        } catch {
            info = NSLocalizedString("login.error.network", comment: "")
        }
    }
}

/// Group Info (website GroupInfoPanel.tsx): tabs "Group Info" | "Members (N)", identity and picture, Mute / Manage / More,
/// the permanent link, description, invite links, Group Management, join requests, recent actions, stats, leave/delete.
struct GroupInfoView: View {
    let groupID: String
    /// I left or deleted the group from here: the chat behind closes too.
    var onGone: (() -> Void)? = nil
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var group: GrpInfo?
    @State private var members: [GrpMember] = []
    /// Current and former members (names for Recent actions).
    @State private var everyone: [GrpMember] = []
    /// A change on its way to the server: shown at once, and the base for the next one (two quick switches used to send
    /// the same old permissions, the second one undoing the first). Cleared once the group is read again.
    @State private var pendingPerms: GrpPermissions?
    @State private var pendingFlags: [String: Bool] = [:]
    @State private var pendingSlow: Int?
    @State private var creatingInvite = false
    @State private var loadFailed = false
    @State private var revoking: Set<String> = []
    @State private var bans: [GrpBan] = []
    @State private var invites: [GrpInvite] = []
    @State private var requests: [GrpJoinRequest] = []
    @State private var audit: [GrpAudit] = []
    @State private var stats: GrpMediaStats?
    @State private var cropping: PickedImage?
    @State private var viewingPicture: String?
    @State private var profileFor: MemberProfileRef?
    @State private var reporting = false
    @State private var addingToFolder = false
    @State private var showAudit = false
    @State private var newLink: String?
    @State private var inviteHours = 0
    @State private var inviteUses = 0
    @State private var handleDraft = ""
    @State private var editingDesc = false
    @State private var descDraft = ""
    @State private var addName = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var manage = false
    @State private var confirmLeave = false
    @State private var confirmDelete = false
    @State private var transferTo: GrpMember?
    /// Remove / Ban asked from a member's menu: confirmed first (they can't be undone from here).
    @State private var memberDanger: MemberDanger?
    /// Join requests being answered: a second tap on ✓ / ✕ is ignored.
    @State private var deciding: Set<String> = []
    @State private var problem: String?
    @State private var toast: String?
    @State private var addingMembers = false
    @State private var showQR = false
    @State private var manageInvites = false
    @State private var mediaCat: String?
    @State private var inviting = false
    /// Join requests that arrived live while Group Info is open (website freshIds): they keep the cyan edge.
    @State private var freshIDs: Set<String> = []
    @EnvironmentObject private var live: LiveConnection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var token: String { store.session?.token ?? "" }
    private var me: String { store.session?.userID ?? "" }
    private var admin: Bool { group?.isAdmin ?? false }
    private var owner: Bool { group?.isOwner ?? false }
    private var canInvite: Bool { admin || group?.can_invite == true }
    /// Invite friends is offered when there is a link to share: a public group's permanent link, or the right to make invites.
    private func showInvite(_ g: GrpInfo) -> Bool { (!(g.handle ?? "").isEmpty && g.privacy == "public") || canInvite }
    /// Telegram's member view (website .gip-tg, aa1cb91): ordinary members only; the owner and the admins keep the management
    /// panel (website GroupsView isOwner = owner || admin). `admin` is true for the owner too (GrpInfo.isAdmin).
    private var tg: Bool { !admin }
    private var groupLink: String? { group?.handle.flatMap { $0.isEmpty ? nil : "https://app.tradeflor.com/g/\($0)" } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: tg ? 0 : 12) {
                    if admin {
                        Picker("", selection: $tab) {
                            Text("grp.tab.info").tag(0)
                            Text(String(format: NSLocalizedString("grp.tab.members", comment: ""), group?.member_count ?? members.count)).tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 12)
                    }
                    if let g = group {
                        if tab == 0 { infoTab(g) } else { membersTab(g) }
                    } else if loadFailed {
                        VStack(spacing: 12) {
                            Text("chat.action.failed").font(.system(size: 14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                            Button("chats.retry") { loadFailed = false; Task { await load() } }
                                .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 20)
                    } else {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(.horizontal, tg ? 0 : 14)
            }
            .background(Theme.soul.ignoresSafeArea())
            .navigationTitle(tg ? Text("") : Text("grp.info.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.soul, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)) }
                        .accessibilityLabel(Text("chat.close"))
                }
            }
            .sheet(isPresented: $manage, onDismiss: { Task { await load() } }) {
                if let g = group { CreateGroupView(onCreated: { _ in }, editing: g) }
            }
            // the owner is told to hand the group over first (server 409), as in the chat's own menu
            .confirmationDialog(Text(LocalizedStringKey(owner ? "grp.leave.owner" : "grp.leave.confirm")), isPresented: $confirmLeave,
                                titleVisibility: .visible) {
                if !owner { Button("grp.leave", role: .destructive) { Task { await leave() } } }
            }
            .confirmationDialog(Text("grp.delete.confirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("grp.delete", role: .destructive) {
                    Task {
                        // closes only once the group is gone; a refusal stays on screen with its reason
                        do {
                            try await APIClient.shared.grpDelete(token: token, id: groupID)
                            onGone?()
                            dismiss()
                        } catch APIError.refused(let why) {
                            problem = why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why
                        } catch {
                            problem = NSLocalizedString("chat.action.failed", comment: "")
                        }
                    }
                }
            }
            .confirmationDialog(Text(String(format: NSLocalizedString("grp.transfer.confirm", comment: ""), transferTo?.title ?? "")),
                                isPresented: Binding(get: { transferTo != nil }, set: { if !$0 { transferTo = nil } }), titleVisibility: .visible) {
                Button("grp.m.transfer", role: .destructive) {
                    if let m = transferTo { Task { await run { try await APIClient.shared.grpTransfer(token: token, id: groupID, userID: m.user_id) } } }
                }
            }
            .confirmationDialog(Text(String(format: NSLocalizedString(memberDanger?.ban == true ? "grp.m.ban.confirm" : "grp.m.remove.confirm",
                                                                      comment: ""), memberDanger?.member.title ?? "")),
                                isPresented: Binding(get: { memberDanger != nil }, set: { if !$0 { memberDanger = nil } }),
                                titleVisibility: .visible) {
                if let d = memberDanger {
                    Button(LocalizedStringKey(d.ban ? "grp.m.ban" : "grp.m.remove"), role: .destructive) {
                        let uid = d.member.user_id
                        Task {
                            await run {
                                if d.ban { try await APIClient.shared.grpBan(token: token, id: groupID, userID: uid) }
                                else { try await APIClient.shared.grpRemove(token: token, id: groupID, userID: uid) }
                            }
                        }
                    }
                }
            }
            .alert(Text(problem ?? ""), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("chat.close", role: .cancel) {}
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 16).padding(.vertical, 10).background(Theme.card, in: Capsule())
                        .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1)).padding(.bottom, 24)
                }
            }
        }
        .task {
            await load()
            #if DEBUG
            // CI only: TF_CI_ADD_MEMBERS=<name> opens Add members with that name typed, for a screenshot
            if let q = ProcessInfo.processInfo.environment["TF_CI_ADD_MEMBERS"], !q.isEmpty { addingMembers = true }
            #endif
        }
        .onChange(of: avatarItem) { item in
            guard let item else { return }
            avatarItem = nil
            Task {
                guard let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) else { return }
                cropping = PickedImage(image: img)
            }
        }
        .fullScreenCover(isPresented: Binding(get: { viewingPicture != nil }, set: { if !$0 { viewingPicture = nil } })) {
            GroupPictureViewer(token: token, groupID: groupID, avatarID: viewingPicture ?? "")
        }
        .sheet(item: $profileFor) { p in MemberProfileSheet(member: p).environmentObject(store) }
        .sheet(isPresented: $reporting) { ReportGroupSheet(groupID: groupID, groupName: group?.name ?? "").environmentObject(store) }
        .sheet(isPresented: $addingToFolder) { AddToFolderSheet(conversationID: groupID).environmentObject(store) }
        .sheet(isPresented: $addingMembers, onDismiss: { Task { await load() } }) {
            AddMembersSheet(groupID: groupID, groupName: group?.name ?? "", memberIDs: Set(members.map(\.user_id))).environmentObject(store)
        }
        .sheet(isPresented: $showQR) { GroupQRSheet(name: group?.name ?? "", link: groupLink ?? newLink ?? "") }
        .sheet(isPresented: $inviting, onDismiss: { Task { await load() } }) {
            if let g = group {
                InviteFriendsSheet(groupID: groupID, groupName: g.name, handle: g.handle ?? "", isPublic: g.privacy == "public",
                                   canInvite: canInvite, memberIDs: Set(members.map(\.user_id))).environmentObject(store)
            }
        }
        // someone just asked to join this group: show it now, with the cyan edge (website tf-join-request, 3c68bec)
        .onReceive(live.joinRequests) { d in
            guard d["conversation_id"] == groupID, group?.isAdmin == true else { return }
            if let u = d["user_id"], !u.isEmpty { freshIDs.insert(u) }
            Task { requests = await APIClient.shared.grpJoinRequests(token: token, id: groupID) }
        }
        // and every 30 s while Group Info is open, in case a live event was missed (website 3c68bec)
        .task(id: admin) {
            guard admin else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                let fresh = await APIClient.shared.grpJoinRequests(token: token, id: groupID)
                for r in fresh where !requests.contains(where: { $0.user_id == r.user_id }) { freshIDs.insert(r.user_id) }
                requests = fresh
            }
        }
        .fullScreenCover(item: $cropping) { p in
            AvatarEditor(image: p.image) { jpeg in
                Task { await run { try await APIClient.shared.grpUploadAvatar(token: token, id: groupID, jpeg: jpeg) } }
            }
        }
    }

    // MARK: Group Info tab

    /// A block of Group Info: the owner's view draws rounded cards (#041D26, radius 16); the member view draws flat full-width
    /// blocks separated by the panel's own colour, like Telegram (website 65-group-info-cards.css).
    @ViewBuilder private func block<C: View>(danger: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        if tg {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 18).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.soulCard)
        } else {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(danger ? Theme.danger.opacity(0.04) : Theme.soulCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(danger ? Theme.hex(0xFF6E6E, 0.22) : Theme.soulCardBorder, lineWidth: 1))
        }
    }

    private func hair() -> some View { Rectangle().fill(Theme.dyn(0x78BED2, 0xD3E1EA, 0.08, 1)).frame(height: 1) }

    private func upperLabel(_ key: String) -> some View {
        Text(NSLocalizedString(key, comment: "").uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.9)
            .foregroundStyle(Theme.dyn(0x6F93A3, 0x5F7686))
    }

    /// The owner's banner (website .gip-banner): a quiet market chart behind the picture.
    private var banner: some View {
        Canvas { ctx, size in
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x / 350 * size.width, y: y / 150 * size.height) }
            var line = Path()
            let ys: [CGFloat] = [110, 100, 114, 92, 100, 74, 84, 54, 60, 26, 18]
            for (i, y) in ys.enumerated() { let p = pt(10 + CGFloat(i) * 30, y); if i == 0 { line.move(to: p) } else { line.addLine(to: p) } }
            ctx.stroke(line, with: .color(Theme.hex(0x22C7DA, 0.35)), lineWidth: 1.2)
            let bars: [(CGFloat, CGFloat, CGFloat, UInt32)] = [(40, 96, 22, 0x14C27A), (100, 84, 26, 0xF0525B), (160, 70, 30, 0x14C27A),
                                                                (220, 52, 28, 0x14C27A), (280, 36, 24, 0xF0525B), (320, 18, 30, 0xF0525B)]
            for b in bars {
                ctx.fill(Path(CGRect(origin: pt(b.0, b.1), size: CGSize(width: 5 / 350 * size.width, height: b.2 / 150 * size.height))),
                         with: .color(Theme.hex(b.3, 0.55)))
            }
        }
        .frame(height: 130)
        .background(LinearGradient(colors: [Theme.hex(0x062A33), Theme.hex(0x01141B)], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }

    @ViewBuilder private func identity(_ g: GrpInfo) -> some View {
        VStack(spacing: 0) {
            if !tg { banner.padding(.horizontal, -14) }
            Avatar(token: token, userID: "", avatarID: g.avatar_id, title: g.name, groupID: g.conversation_id, size: tg ? 96 : 108)
                .overlay(Circle().stroke(tg ? Color.clear : Theme.hex(0xE8B931), lineWidth: 3))
                .background(Circle().fill(Theme.soul).padding(tg ? 0 : -6))
                .padding(.top, tg ? 26 : -52)
                .onTapGesture { if let a = g.avatar_id, !a.isEmpty { viewingPicture = a } }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("grp.picture.view"))
            HStack(spacing: 5) {
                Text(g.name).font(.system(size: tg ? 19 : 21, weight: .bold)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                if g.verified == true { Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.verified) }
            }
            .padding(.top, 14)
            Text(String(format: NSLocalizedString("groups.members", comment: ""), g.member_count)).font(.system(size: 13))
                .foregroundStyle(Theme.dyn(0x8FB0BC, 0x5F7686)).padding(.top, 4)
            // picture actions: owner and admins (server SetAvatar: isModerator)
            if admin {
                HStack(spacing: 8) {
                    if let a = g.avatar_id, !a.isEmpty {
                        pill("grp.picture.view", Theme.hex(0x5FE6EE), Theme.hex(0x00CAD1)) { viewingPicture = a }
                    }
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        pillLabel("grp.picture.change", Theme.hex(0x5FE6EE), Theme.hex(0x00CAD1))
                    }
                    if !(g.avatar_id ?? "").isEmpty {
                        pill("grp.picture.remove", Theme.hex(0xFF9A9A), Theme.hex(0xFF7878)) {
                            Task { await run { try await APIClient.shared.grpRemoveAvatar(token: token, id: groupID) } }
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, tg ? 4 : 14)
    }

    private func pillLabel(_ key: LocalizedStringKey, _ fg: Color, _ line: Color) -> some View {
        Text(key).font(.system(size: 12, weight: .semibold)).foregroundStyle(fg)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(line.opacity(0.06), in: Capsule()).overlay(Capsule().stroke(line.opacity(0.35), lineWidth: 1))
    }

    private func pill(_ key: LocalizedStringKey, _ fg: Color, _ line: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { pillLabel(key, fg, line) }.buttonStyle(.plain)
    }

    @ViewBuilder private func tiles(_ g: GrpInfo) -> some View {
        HStack(spacing: 10) {
            actionButton(g.isMuted ? "bell" : "bell.slash", g.isMuted ? "grp.unmute.short" : "grp.mute.short") {
                Task {
                    await run {
                        if g.isMuted { try await APIClient.shared.setPrefs(token: token, conversationID: groupID, unmute: true) }
                        else { try await APIClient.shared.setPrefs(token: token, conversationID: groupID, muteForever: true) }
                    }
                }
            }
            if tg { actionButton("rectangle.portrait.and.arrow.right", "gi.leave") { confirmLeave = true } }
            if admin { actionButton("slider.horizontal.3", "grp.manage") { manage = true } }
            Menu {
                if showInvite(g) { Button { inviting = true } label: { Label("gx.inv.title", systemImage: "paperplane") } }
                if admin || g.can_invite == true { Button { addingMembers = true } label: { Label("grp.add.members", systemImage: "person.badge.plus") } }
                Button { addingToFolder = true } label: { Label("folder.addto", systemImage: "folder.badge.plus") }
                if let h = g.handle, !h.isEmpty {
                    Button { copy("https://app.tradeflor.com/g/\(h)") } label: { Label("grp.copy.link", systemImage: "link") }
                }
                if !owner { Button { reporting = true } label: { Label("report.title", systemImage: "exclamationmark.bubble") } }
                Button(role: .destructive) { confirmLeave = true } label: { Label("grp.leave", systemImage: "rectangle.portrait.and.arrow.right") }
            } label: {
                actionLabel("ellipsis", "grp.more")
            }
            .accessibilityIdentifier("gi.more")
        }
        .padding(.horizontal, tg ? 14 : 0)
        .padding(.top, tg ? 10 : 0)
    }

    @ViewBuilder private func infoTab(_ g: GrpInfo) -> some View {
        identity(g)
        tiles(g)
        if g.isAdmin && (!requests.isEmpty || g.join_approval == true) {
            joinRequestsCard
                .padding(.horizontal, tg ? 14 : 0)
                .padding(.top, tg ? 12 : 0)
        }
        if tg { memberBlocks(g) } else { ownerBlocks(g) }
    }

    // MARK: join requests (website .jr, 3c68bec): right under the tiles, owners and admins

    private var joinRequestsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.hex(0xE8B931))
                    .frame(width: 30, height: 30)
                    .background(Theme.hex(0xE8B931, 0.1), in: RoundedRectangle(cornerRadius: 10))
                Text(NSLocalizedString("gx.jr.title", comment: "").uppercased()).font(.system(size: 13, weight: .bold)).tracking(0.78)
                    .foregroundStyle(Theme.dyn(0xE8B931, 0x9A7410)).lineLimit(1)
                Spacer(minLength: 4)
                if requests.isEmpty {
                    Text("gx.jr.none").font(.system(size: 12.5)).foregroundStyle(Theme.dyn(0x7F9AA7, 0x5F7686))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Theme.hex(0x78BED2, 0.07), in: Capsule())
                } else {
                    JoinRequestCountBadge(count: requests.count, animate: !reduceMotion)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                VStack(spacing: 0) {
                    ForEach(requests) { r in
                        JoinRequestRow(token: token, request: r, now: ctx.date, live: freshIDs.contains(r.user_id), animate: !reduceMotion,
                                       decide: { approve in
                                           // once per request: the row leaves at once (a refusal brings it back on reload)
                                           let uid = r.user_id
                                           guard !deciding.contains(uid) else { return }
                                           deciding.insert(uid)
                                           freshIDs.remove(uid)
                                           requests.removeAll { $0.user_id == uid }
                                           Task {
                                               await run { try await APIClient.shared.grpDecide(token: token, id: groupID, userID: uid, approve: approve) }
                                               deciding.remove(uid)
                                           }
                                       })
                    }
                }
            }
        }
        .background(Theme.soulCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.soulCardBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    // MARK: the member view (Telegram)

    @ViewBuilder private func memberBlocks(_ g: GrpInfo) -> some View {
        let handle = g.handle ?? ""
        let desc = g.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let invite = showInvite(g)
        if !handle.isEmpty || !desc.isEmpty || invite {
            block {
                if !handle.isEmpty {
                    HStack(spacing: 10) {
                        Button { copy("https://app.tradeflor.com/g/\(handle)") } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("app.tradeflor.com/g/\(handle)").font(.system(size: 15)).foregroundStyle(Theme.dyn(0x5FE6EE, 0x0097A5)).lineLimit(1)
                                Text("gi.link.label").font(.system(size: 13)).foregroundStyle(Theme.dyn(0x7F9AA7, 0x5F7686))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { showQR = true } label: {
                            Image(systemName: "qrcode").font(.system(size: 19)).foregroundStyle(Theme.dyn(0x5FE6EE, 0x0097A5)).frame(width: 38, height: 38)
                        }
                        .accessibilityLabel(Text("gi.qr"))
                    }
                    .padding(.vertical, 12)
                }
                if invite {
                    // Invite friends (website .gip-tg-invite, 9f7f25d): link, contacts, QR
                    if !handle.isEmpty { hair() }
                    Button { inviting = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "paperplane").font(.system(size: 17))
                            Text("gx.inv.title").font(.system(size: 15, weight: .bold))
                            Spacer(minLength: 4)
                            Text("gx.inv.row.sub").font(.system(size: 12)).foregroundStyle(Theme.dyn(0x7F9AA7, 0x5F7686)).lineLimit(1)
                        }
                        .foregroundStyle(Theme.dyn(0x2FF0F3, 0x0097A5))
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if (!handle.isEmpty || invite) && !desc.isEmpty { hair() }
                if !desc.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(desc).font(.system(size: 15)).foregroundStyle(Theme.text).lineSpacing(3).textSelection(.enabled)
                        Text("gi.desc.label").font(.system(size: 13)).foregroundStyle(Theme.dyn(0x7F9AA7, 0x5F7686))
                    }
                    .padding(.vertical, 12)
                }
            }
            .padding(.top, 10)
        }

        if let s = stats {
            VStack(spacing: 0) {
                let rows: [(String, String, Int, String?)] = [
                    ("photo", "gi.n.photos", s.photos ?? 0, "media"), ("video", "gi.n.videos", s.videos ?? 0, "media"), ("doc", "gi.n.files", s.files ?? 0, "files"),
                    ("link", "gi.n.links", s.links ?? 0, "links"), ("mic", "gi.n.voice", s.voice ?? 0, "voice"), ("chart.bar", "gi.n.polls", s.polls ?? 0, nil),
                ]
                ForEach(rows.filter { $0.2 > 0 }, id: \.1) { r in
                    Button { if let c = r.3 { mediaCat = mediaCat == c ? nil : c } } label: {
                        HStack(spacing: 18) {
                            Image(systemName: r.0).font(.system(size: 17)).foregroundStyle(Theme.dyn(0x7F9AA7, 0x5F7686)).frame(width: 22)
                            Text(String(format: NSLocalizedString(r.1, comment: ""), r.2)).font(.system(size: 15)).foregroundStyle(Theme.text)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 11)
                        .background(r.3 != nil && mediaCat == r.3 ? Theme.card : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(r.3 == nil)
                }
                if [s.photos, s.videos, s.files, s.links, s.voice, s.polls].allSatisfy({ ($0 ?? 0) == 0 }) {
                    Text("gi.nothing").font(.system(size: 13.5)).foregroundStyle(Theme.faint).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.soulCard)
            .padding(.top, 10)
        }
        if let c = mediaCat {
            SharedMediaCard(token: token, conversationID: groupID, initialTab: c).id(c).padding(.horizontal, 14).padding(.top, 10)
        }

        let admins = members.filter { $0.role == "owner" || $0.role == "admin" }
            .sorted { ($0.role == "owner" ? 0 : 1, $0.title) < ($1.role == "owner" ? 0 : 1, $1.title) }
        if !admins.isEmpty {
            block {
                HStack(spacing: 18) {
                    Image(systemName: "person.2").font(.system(size: 17)).foregroundStyle(Theme.dyn(0x7F9AA7, 0x5F7686))
                    Text(NSLocalizedString("gi.administrators", comment: "").uppercased()).font(.system(size: 13, weight: .bold)).tracking(0.8)
                        .foregroundStyle(Theme.text)
                }
                .padding(.top, 14).padding(.bottom, 8)
                ForEach(admins) { a in
                    Button { if a.user_id != me { profileFor = MemberProfileRef(userID: a.user_id, username: a.username) } } label: {
                        HStack(spacing: 12) {
                            Avatar(token: token, userID: a.user_id, avatarID: a.avatar_id, title: a.title, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(a.user_id == me ? NSLocalizedString("gi.you", comment: "") : "@" + a.username)
                                    .font(.system(size: 13)).foregroundStyle(Theme.dyn(0x7F9AA7, 0x5F7686)).lineLimit(1)
                            }
                            Spacer()
                            Text(LocalizedStringKey(a.role == "owner" ? "gi.role.owner" : "gi.role.admin"))
                                .font(.system(size: 12)).foregroundStyle(a.role == "owner" ? Theme.hex(0xC7A8FF) : Theme.hex(0x8FD9E0))
                                .padding(.horizontal, 9).padding(.vertical, 2)
                                .background(a.role == "owner" ? Theme.hex(0x966EFF, 0.16) : Theme.hex(0x00CAD1, 0.12), in: Capsule())
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(a.user_id == me)
                }
                Spacer().frame(height: 6)
            }
            .padding(.top, 10)
        }
        Spacer().frame(height: 24)
    }

    // MARK: the owner's view (cards)

    @ViewBuilder private func ownerBlocks(_ g: GrpInfo) -> some View {
        // link: shown when there is one, or to the owner who may set it (website: handle || isGroupOwner; server: handle is the owner's)
        if !(g.handle ?? "").isEmpty || owner {
        block {
            VStack(alignment: .leading, spacing: 8) {
                upperLabel("gi.link.label")
                if let h = g.handle, !h.isEmpty {
                    HStack {
                        Text("app.tradeflor.com/g/\(h)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent).lineLimit(1)
                        Spacer()
                        Button("grp.copy") { copy("https://app.tradeflor.com/g/\(h)") }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    if g.privacy != "public" {
                        Text("grp.link.private").font(.system(size: 12)).foregroundStyle(Theme.faint)
                        // privacy is the owner's (server UpdateGroup refuses Privacy from an admin)
                        if owner {
                        Button("grp.make.public") { Task { await run { try await APIClient.shared.grpUpdate(token: token, id: groupID, privacy: "public") } } }
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                } else {
                    Text("grp.link.permanent").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    HStack(spacing: 0) {
                        Text("app.tradeflor.com/g/").foregroundStyle(Theme.faint)
                        TextField("", text: $handleDraft, prompt: Text("yourgroup").foregroundColor(Theme.faint))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().foregroundStyle(Theme.text)
                    }
                    .font(.system(size: 14))
                    .environment(\.layoutDirection, .leftToRight)
                    Text("grp.link.once").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    Button("grp.link.set") {
                        let h = handleDraft.lowercased()
                        guard h.count >= 5, h.count <= 32, h.first?.isLetter == true,
                              h.allSatisfy({ ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "_" }) else {
                            problem = NSLocalizedString("grp.link.invalid", comment: "")
                            return
                        }
                        Task { await run { try await APIClient.shared.grpSetHandle(token: token, id: groupID, handle: h) } }
                    }
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.vertical, 12)
        }
        }

        // description
        block {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    upperLabel("gi.desc.label")
                    Spacer()
                    if !editingDesc {
                        Button(LocalizedStringKey(g.description.isEmpty ? "grp.add" : "grp.edit")) {
                            descDraft = g.description
                            editingDesc = true
                        }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                }
                if editingDesc {
                    TextField("", text: $descDraft, prompt: Text("grp.desc.ph").foregroundColor(Theme.faint), axis: .vertical)
                        .lineLimit(3...8).foregroundStyle(Theme.text)
                        .onChange(of: descDraft) { v in if v.count > 500 { descDraft = String(v.prefix(500)) } }
                    HStack {
                        Spacer()
                        Button("grp.cancel") { editingDesc = false }.foregroundStyle(Theme.faint)
                        Button("grp.save.short") {
                            editingDesc = false
                            Task { await run { try await APIClient.shared.grpUpdate(token: token, id: groupID, description: descDraft) } }
                        }
                        .bold().foregroundStyle(Theme.accent)
                    }
                    .font(.system(size: 14))
                } else {
                    Text(g.description.isEmpty ? NSLocalizedString("grp.desc.none", comment: "") : g.description)
                        .font(.system(size: 14.5)).lineSpacing(4).foregroundStyle(g.description.isEmpty ? Theme.faint : Theme.dyn(0xDFEEF4, 0x0F2533))
                }
            }
            .padding(.vertical, 12)
        }

        // counts + shared media, right under the description
        if let s = stats {
            block {
                let rows: [(String, String, Int?)] = [("photo", "grp.stat.photos", s.photos), ("video", "grp.stat.videos", s.videos),
                                                      ("doc", "grp.stat.files", s.files), ("link", "grp.stat.links", s.links),
                                                      ("chart.bar", "grp.stat.polls", s.polls), ("mic", "grp.stat.voice", s.voice),
                                                      ("person.2", "grp.stat.members", g.member_count),
                                                      ("star", "grp.stat.admins", members.isEmpty ? nil : members.filter { $0.role != "member" }.count)]
                let shown = rows.compactMap { r in r.2.map { (r.0, r.1, $0) } }
                ForEach(Array(shown.enumerated()), id: \.offset) { i, r in
                    if i > 0 { hair() }
                    gipRow(r.0, NSLocalizedString(r.1, comment: ""), trailing: "\(r.2)")
                }
            }
        }
        SharedMediaCard(token: token, conversationID: groupID)

        inviteBlock(g)
        management(g)

        // join requests: the card right under the tiles (infoTab)

        block {
            Button { showAudit.toggle() } label: { gipRow("clock.arrow.circlepath", NSLocalizedString("grp.audit", comment: ""), chevron: true) }
                .buttonStyle(.plain)
            if showAudit {
                if audit.isEmpty {
                    hair()
                    Text("grp.audit.none").font(.system(size: 13)).foregroundStyle(Theme.faint).padding(.vertical, 12)
                }
                ForEach(audit.prefix(50)) { a in
                    hair()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(auditLine(a)).font(.system(size: 13)).foregroundStyle(Theme.text)
                        Text(serverDate(a.created_at).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                            .font(.system(size: 11)).foregroundStyle(Theme.faint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
            }
        }

        block(danger: true) {
            Button { confirmLeave = true } label: {
                gipRow("rectangle.portrait.and.arrow.right", NSLocalizedString("grp.leave", comment: ""), tint: Theme.hex(0xFF8F8F), textTint: Theme.hex(0xFF8F8F))
            }
            .buttonStyle(.plain)
            // deleting the group is the owner's alone (server DeleteGroup: RoleOwner; website: myRole === "owner")
            if owner {
                hair()
                Button { confirmDelete = true } label: {
                    gipRow("trash", NSLocalizedString("grp.delete", comment: ""), tint: Theme.hex(0xFF8F8F), textTint: Theme.hex(0xFF8F8F))
                }
                .buttonStyle(.plain)
            }
        }
        Spacer().frame(height: 12)
    }

    /// A row inside a card: cyan icon, label, an optional value or chevron (website .gip-row).
    private func gipRow(_ icon: String, _ title: String, trailing: String? = nil, chevron: Bool = false,
                        tint: Color = Theme.dyn(0x5FE6EE, 0x0097A5), textTint: Color = Theme.text) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(tint).frame(width: 24)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(textTint)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 14)).foregroundStyle(Theme.faint) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint) }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// Invite link, Telegram-simple (website GroupInviteSection.tsx): the fresh link with Copy / Share, then Create invite link,
    /// Invite via QR and Manage invite links; expiry, limit, WhatsApp / Telegram, the active links and Reset fold under Manage.
    @ViewBuilder private func inviteBlock(_ g: GrpInfo) -> some View {
        block {
            upperLabel("gi.inv.title").padding(.top, 12).padding(.bottom, 6)
            if let newLink {
                HStack(spacing: 8) {
                    Text(newLink.replacingOccurrences(of: "https://", with: "")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("grp.copy") { copy(newLink) }
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 12).frame(height: 32).background(Theme.accent, in: Capsule())
                    ShareLink(item: URL(string: newLink) ?? URL(string: "https://app.tradeflor.com")!,
                              message: Text(shareText(g.name, newLink))) {
                        Text("gi.share").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12).frame(height: 32).overlay(Capsule().stroke(Theme.hex(0x78BED2, 0.22), lineWidth: 1))
                    }
                }
                .padding(.bottom, 10)
            }
            hair()
            Button { Task { await createInvite(resetAll: false) } } label: {
                gipRow("link.badge.plus", NSLocalizedString(newLink == nil ? "grp.invite.create" : "grp.invite.new", comment: ""),
                       textTint: Theme.dyn(0x5FE6EE, 0x0097A5))
            }
            .buttonStyle(.plain)
            hair()
            Button { Task { if groupLink == nil && newLink == nil { await createInvite(resetAll: false) }; if groupLink != nil || newLink != nil { showQR = true } } } label: {
                gipRow("qrcode", NSLocalizedString("gi.inv.qr", comment: ""), chevron: true)
            }
                .buttonStyle(.plain)
            hair()
            Button { withAnimation { manageInvites.toggle() } } label: {
                gipRow("gearshape", invites.isEmpty ? NSLocalizedString("gi.inv.manage", comment: "")
                                                    : String(format: NSLocalizedString("gi.inv.manage.n", comment: ""), invites.count),
                       chevron: true)
            }
            .buttonStyle(.plain)
            if manageInvites {
                VStack(alignment: .leading, spacing: 10) {
                    Text("gi.inv.note").font(.system(size: 12.5)).foregroundStyle(Theme.dyn(0x8FB0BC, 0x5F7686))
                    HStack(spacing: 10) {
                        optionColumn("grp.invite.expires") {
                            Picker("", selection: $inviteHours) {
                                Text("grp.never").tag(0); Text("grp.1day").tag(24); Text("grp.7days").tag(168); Text("grp.30days").tag(720)
                            }
                        }
                        optionColumn("grp.invite.uses") {
                            Picker("", selection: $inviteUses) {
                                Text("grp.unlimited").tag(0); Text("grp.1person").tag(1); Text("grp.10people").tag(10); Text("grp.100people").tag(100)
                            }
                        }
                    }
                    if let link = newLink ?? g.handle.flatMap({ $0.isEmpty ? nil : "https://app.tradeflor.com/g/\($0)" }) {
                        HStack(spacing: 8) {
                            shareButton("WhatsApp", "https://wa.me/?text=" + esc(shareText(g.name, link)))
                            shareButton("Telegram", "https://t.me/share/url?url=" + esc(link) + "&text=" + esc(shareText(g.name, link)))
                        }
                    }
                    if !invites.isEmpty {
                        Text("grp.invite.active").font(.system(size: 12.5)).foregroundStyle(Theme.dyn(0x8FB0BC, 0x5F7686))
                        ForEach(invites) { inv in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(inviteLine(inv)).font(.system(size: 13)).foregroundStyle(Theme.text)
                                    if let e = inv.expires_at, e > 0 {
                                        Text(String(format: NSLocalizedString("grp.expires.at", comment: ""),
                                                    Date(timeIntervalSince1970: Double(e)).formatted(date: .abbreviated, time: .shortened)))
                                            .font(.system(size: 11)).foregroundStyle(Theme.faint)
                                    }
                                }
                                Spacer()
                                Button("grp.revoke") {
                                    guard !revoking.contains(inv.id) else { return } // a second tap: "not found"
                                    revoking.insert(inv.id)
                                    Task {
                                        newLink = nil
                                        await run { try await APIClient.shared.grpRevokeInvite(token: token, id: groupID, inviteID: inv.id) }
                                        revoking.remove(inv.id)
                                    }
                                }
                                .disabled(revoking.contains(inv.id))
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.danger)
                            }
                        }
                        Button("gi.inv.reset") { Task { await createInvite(resetAll: true) } }
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.danger)
                            .padding(.horizontal, 12).frame(height: 32).overlay(Capsule().stroke(Theme.danger.opacity(0.4), lineWidth: 1))
                    }
                }
                .padding(.top, 4).padding(.bottom, 12)
            }
        }
    }

    private func optionColumn<C: View>(_ key: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            upperLabel(key)
            content()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(Theme.soul, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hex(0x78BED2, 0.22), lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }

    private func shareButton(_ title: String, _ url: String) -> some View {
        Button(title) { if let u = URL(string: url) { UIApplication.shared.open(u) } }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: 36)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hex(0x78BED2, 0.22), lineWidth: 1))
    }

    private func shareText(_ name: String, _ url: String) -> String {
        String(format: NSLocalizedString("gi.share.text", comment: ""), name, url)
    }

    private func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? s
    }

    private func createInvite(resetAll: Bool) async {
        guard !creatingInvite else { return } // a second tap made a second link
        creatingInvite = true
        defer { creatingInvite = false }
        do {
            if resetAll { for i in invites { try? await APIClient.shared.grpRevokeInvite(token: token, id: groupID, inviteID: i.id) } }
            newLink = try await APIClient.shared.grpCreateInvite(token: token, id: groupID, hours: inviteHours, maxUses: inviteUses)
            invites = await APIClient.shared.grpInvites(token: token, id: groupID)
        } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why
        } catch {
            problem = NSLocalizedString("chat.action.failed", comment: "")
        }
    }

    /// Group Management: the same switches and choices as the website; every drop-down one width (142), on the right.
    @ViewBuilder private func management(_ g: GrpInfo) -> some View {
        let perms = pendingPerms ?? g.permissions ?? GrpPermissions(allow_chat: true, allow_media: true, allow_reactions: true, members_can_invite: false,
                                                                    signal_permission: "owner_admins", chat_permission: "everyone")
        block {
            upperLabel("grp.management").padding(.top, 12).padding(.bottom, 2)
            // each change starts from the newest choice (pendingPerms), not from the group as last read
            toggleRow("grp.allow.chat", perms.allow_chat) { v in var p = pendingPerms ?? perms; p.allow_chat = v; await setPerms(p) }
            toggleRow("grp.allow.media", perms.allow_media) { v in var p = pendingPerms ?? perms; p.allow_media = v; await setPerms(p) }
            toggleRow("grp.allow.reactions", perms.allow_reactions) { v in var p = pendingPerms ?? perms; p.allow_reactions = v; await setPerms(p) }
            toggleRow("grp.history", pendingFlags["history"] ?? g.history_visible_to_new_members ?? false) { v in
                await setFlag("history", v) { try await APIClient.shared.grpUpdate(token: token, id: groupID, historyVisible: v) }
            }
            toggleRow("grp.approve.new", pendingFlags["approval"] ?? g.join_approval ?? false) { v in
                await setFlag("approval", v) { try await APIClient.shared.grpUpdate(token: token, id: groupID, joinApproval: v) }
            }
            toggleRow("grp.comments", pendingFlags["comments"] ?? g.comments ?? false, sub: "grp.comments.sub") { v in
                await setFlag("comments", v) { try await APIClient.shared.grpUpdate(token: token, id: groupID, comments: v) }
            }
            pickerRow("grp.slow", selection: pendingSlow ?? g.slow_mode ?? 0, options: [(0, "grp.off"), (10, "grp.10s"), (30, "grp.30s"), (60, "grp.1m"),
                                                                          (300, "grp.5m"), (900, "grp.15m"), (3600, "grp.1h")]) { v in
                pendingSlow = v
                await run { try await APIClient.shared.grpUpdate(token: token, id: groupID, slowMode: v) }
                if pendingSlow == v { pendingSlow = nil }
            }
            stringPickerRow("grp.signals.who", selection: perms.signal_permission,
                            options: [("owner_only", "grp.owner.only"), ("owner_admins", "grp.owner.admins"), ("all_members", "grp.all.members")]) { v in
                var p = pendingPerms ?? perms; p.signal_permission = v; await setPerms(p)
            }
            stringPickerRow("grp.chat.permission", selection: perms.chat_permission,
                            options: [("everyone", "grp.everyone"), ("admins_only", "grp.admins.only"), ("restricted", "grp.restricted")]) { v in
                var p = pendingPerms ?? perms; p.chat_permission = v; await setPerms(p)
            }
            hair()
            Button { tab = 1 } label: { gipRow("person.2", NSLocalizedString("grp.manage.members", comment: ""), chevron: true) }
                .buttonStyle(.plain)
            hair()
            Button { manage = true } label: { gipRow("gearshape", NSLocalizedString("grp.settings", comment: ""), chevron: true) }
                .buttonStyle(.plain)
        }
    }

    // MARK: Members tab

    @ViewBuilder private func membersTab(_ g: GrpInfo) -> some View {
        Button { addingMembers = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.plus").font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("grp.add.members").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent)
                    Text("ams.by").font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
                Spacer()
            }
            .padding(14)
            .background(Theme.soulCard, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.soulCardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        // two cards (website .mgroup, 75bbc6f): Admins (the owner first), then Members · N; each A-Z
        let sorted: [GrpMember] = members.sorted { (a: GrpMember, b: GrpMember) -> Bool in
            let ra = Self.roleRank(a.role), rb = Self.roleRank(b.role)
            if ra != rb { return ra < rb }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        let staff = sorted.filter { $0.role == "owner" || $0.role == "admin" }
        let plain = sorted.filter { $0.role != "owner" && $0.role != "admin" }
        if !staff.isEmpty { memberGroup(NSLocalizedString("gx.m.admins", comment: ""), staff) }
        if !plain.isEmpty { memberGroup(String(format: NSLocalizedString("gx.m.members", comment: ""), plain.count), plain) }
        if !members.isEmpty {
            Text("grp.members.hint").font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
        if !bans.isEmpty {
            TFSectionLabel(text: NSLocalizedString("grp.banned", comment: ""))
            TFCard {
                ForEach(bans) { b in
                    HStack {
                        Text("@" + b.username).foregroundStyle(Theme.text)
                        Spacer()
                        Button("grp.unban") { Task { await run { try await APIClient.shared.grpUnban(token: token, id: groupID, userID: b.user_id) } } }
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
    }

    private static func roleRank(_ role: String) -> Int { role == "owner" ? 0 : role == "admin" ? 1 : 2 }

    /// One card of the Members tab (website .mgroup): a small uppercase title, then compact rows.
    private func memberGroup(_ title: String, _ list: [GrpMember]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.88)
                .foregroundStyle(Theme.dyn(0x6F93A3, 0x5F7686))
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Rectangle().fill(Theme.dyn(0x78BED2, 0xD3E1EA, 0.06, 1)).frame(height: 1) }
                memberRow(m)
                    .onTapGesture { if m.user_id != me { profileFor = MemberProfileRef(userID: m.user_id, username: m.username) } }
                    .contextMenu { if memberHasActions(m) { memberMenu(m) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soulCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.soulCardBorder, lineWidth: 1))
    }

    /// What this account may do to that member (website actionsFor): the owner acts on everyone but themself; an admin only on
    /// ordinary members (server: an admin cannot mute, remove or ban another admin).
    private func memberHasActions(_ m: GrpMember) -> Bool {
        guard admin, m.user_id != me, m.role != "owner" else { return false }
        return owner || (m.role != "admin" && m.role != "owner")
    }

    /// A member row (website .mrow): avatar in a gold (owner) or cyan (admin) ring, name with " (you)" and the owner's crown,
    /// @username under it, the role chip, and ⋯ for the member's actions.
    private func memberRow(_ m: GrpMember) -> some View {
        let isOwner = m.role == "owner", isAdmin = m.role == "admin"
        let ring: Color = isOwner ? Theme.hex(0xE8B931) : isAdmin ? Theme.hex(0x2FF0F3) : .clear
        let glow: Color = isOwner ? Theme.hex(0xE8B931, 0.45) : isAdmin ? Theme.hex(0x2FF0F3, 0.35) : .clear
        let mutedText = Theme.dyn(0x7F9AA7, 0x5F7686)
        return HStack(spacing: 11) {
            Avatar(token: token, userID: m.user_id, avatarID: m.avatar_id, title: m.title, size: 36)
                .frame(width: 38, height: 38)
                .overlay(Circle().stroke(ring, lineWidth: 2).shadow(color: glow, radius: isOwner ? 6 : 5))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    (Text(m.title).font(.system(size: 14.5, weight: .semibold)).foregroundColor(Theme.text)
                     + (m.user_id == me ? Text(" " + NSLocalizedString("grp.you", comment: "")).font(.system(size: 14.5, weight: .medium)).foregroundColor(mutedText) : Text("")))
                        .lineLimit(1)
                    if isOwner {
                        Image(systemName: "crown.fill").font(.system(size: 11)).foregroundStyle(Theme.hex(0xE8B931))
                            .shadow(color: Theme.hex(0xE8B931, 0.6), radius: 3)
                    }
                }
                Text("@" + m.username).font(.system(size: 12)).foregroundStyle(mutedText).lineLimit(1)
            }
            Spacer(minLength: 4)
            if m.isMuted {
                Text("grp.muted").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.hex(0x9FB2BB))
                    .padding(.horizontal, 9).padding(.vertical, 3).background(Theme.hex(0x78BED2, 0.1), in: Capsule())
            }
            if isOwner {
                Text("grp.role.owner").font(.system(size: 11, weight: .heavy)).tracking(0.33).foregroundStyle(Theme.hex(0x2B1D00))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(LinearGradient(colors: [Theme.hex(0xFFD76A), Theme.hex(0xE8B931)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                    .shadow(color: Theme.hex(0xE8B931, 0.35), radius: 5)
            } else if isAdmin {
                HStack(spacing: 4) {
                    Image(systemName: "shield.fill").font(.system(size: 9.5, weight: .bold))
                    Text("grp.role.admin").font(.system(size: 11, weight: .heavy)).tracking(0.33)
                }
                .foregroundStyle(Theme.hex(0x032229))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(LinearGradient(colors: [Theme.hex(0x2FF0F3), Theme.hex(0x08A8B8)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
            }
            if memberHasActions(m) {
                Menu { memberMenu(m) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).foregroundStyle(mutedText)
                        .frame(width: 30, height: 30)
                        .background(Theme.hex(0x78BED2, 0.06), in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel(Text("grp.more"))
            }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 7)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func memberMenu(_ m: GrpMember) -> some View {
        if owner {
            Button { Task { await run { try await APIClient.shared.grpRole(token: token, id: groupID, userID: m.user_id, admin: m.role != "admin") } } } label: {
                Label(LocalizedStringKey(m.role == "admin" ? "grp.m.unadmin" : "grp.m.admin"), systemImage: "star")
            }
            Button { transferTo = m } label: { Label("grp.m.transfer", systemImage: "crown") }
        }
        // restrictions apply to ordinary members only (website actionsFor)
        if m.role != "admin" && m.role != "owner" {
        if m.isMuted {
            Button { Task { await run { try await APIClient.shared.grpMuteMember(token: token, id: groupID, userID: m.user_id, seconds: 0, permanent: false) } } } label: {
                Label("grp.m.unmute", systemImage: "speaker.wave.2")
            }
        } else {
            Button { Task { await run { try await APIClient.shared.grpMuteMember(token: token, id: groupID, userID: m.user_id, seconds: 3600, permanent: false) } } } label: {
                Label("grp.m.mute1h", systemImage: "speaker.slash")
            }
            Button { Task { await run { try await APIClient.shared.grpMuteMember(token: token, id: groupID, userID: m.user_id, seconds: 0, permanent: true) } } } label: {
                Label("grp.m.mutep", systemImage: "speaker.slash.fill")
            }
        }
        }
        Button(role: .destructive) { memberDanger = MemberDanger(member: m, ban: false) } label: {
            Label("grp.m.remove", systemImage: "person.fill.xmark")
        }
        Button(role: .destructive) { memberDanger = MemberDanger(member: m, ban: true) } label: {
            Label("grp.m.ban", systemImage: "nosign")
        }
    }

    // MARK: pieces

    private func actionLabel(_ icon: String, _ key: LocalizedStringKey) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.accent)
            Text(key).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderStrong, lineWidth: 1))
    }

    private func actionButton(_ icon: String, _ key: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(icon, key) }.buttonStyle(.plain)
    }

    private func toggleRow(_ key: LocalizedStringKey, _ value: Bool, sub: LocalizedStringKey? = nil, set: @escaping (Bool) async -> Void) -> some View {
        Toggle(isOn: Binding(get: { value }, set: { v in Task { await set(v) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                if let sub { Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.faint) }
            }
        }
        .tint(Theme.accent)
        .padding(.vertical, 9)
    }

    private func pickerRow(_ key: LocalizedStringKey, selection: Int, options: [(Int, String)], set: @escaping (Int) async -> Void) -> some View {
        HStack {
            Text(key).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(0..<options.count, id: \.self) { i in
                    Button(LocalizedStringKey(options[i].1)) { Task { await set(options[i].0) } }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(options.first(where: { $0.0 == selection })?.1 ?? options[0].1)).lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                }
                .font(.system(size: 13)).foregroundStyle(Theme.text)
                .padding(.horizontal, 8).frame(width: 142, height: 34)
                .background(Theme.soul, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hex(0x78BED2, 0.22), lineWidth: 1))
            }
        }
        .padding(.vertical, 8)
    }

    private func stringPickerRow(_ key: LocalizedStringKey, selection: String, options: [(String, String)], set: @escaping (String) async -> Void) -> some View {
        HStack {
            Text(key).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(0..<options.count, id: \.self) { i in
                    Button(LocalizedStringKey(options[i].1)) { Task { await set(options[i].0) } }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(options.first(where: { $0.0 == selection })?.1 ?? options[0].1)).lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                }
                .font(.system(size: 13)).foregroundStyle(Theme.text)
                .padding(.horizontal, 8).frame(width: 142, height: 34)
                .background(Theme.soul, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hex(0x78BED2, 0.22), lineWidth: 1))
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func statRow(_ icon: String, _ key: String, _ value: Int?) -> some View {
        if let value {
            TFRow(icon: icon, title: NSLocalizedString(key, comment: ""), trailing: "\(value)", showChevron: false)
        }
    }

    private func inviteLine(_ inv: GrpInvite) -> String {
        if let max = inv.max_uses, max > 0 {
            return String(format: NSLocalizedString("grp.invite.used.of", comment: ""), inv.uses, max)
        }
        return String(format: NSLocalizedString("grp.invite.used", comment: ""), inv.uses)
    }

    private func auditLine(_ a: GrpAudit) -> String {
        let who = everyone.first { $0.user_id == a.actor_id }?.title ?? NSLocalizedString("grp.someone", comment: "")
        let target = a.target_user_id.flatMap { t in everyone.first { $0.user_id == t }?.title }
        var line = "\(who) · \(a.action.replacingOccurrences(of: "_", with: " "))"
        if let target { line += " · \(target)" }
        if let d = a.detail, !d.isEmpty { line += " · \(d)" }
        return line
    }

    private func copy(_ s: String) {
        UIPasteboard.general.string = s
        showToast(NSLocalizedString("grp.copied", comment: ""))
    }

    private func showToast(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            toast = nil
        }
    }

    private func addMember() {
        let n = addName.trimmingCharacters(in: .whitespaces)
        guard n.count >= 2 else { return }
        addName = ""
        Task { await run { try await APIClient.shared.grpAddMember(token: token, id: groupID, username: n) } }
    }

    /// Shown at once; `run` reads the group again afterwards, so a refusal puts the switch back (with the reason).
    private func setPerms(_ p: GrpPermissions) async {
        pendingPerms = p
        await run { try await APIClient.shared.grpUpdate(token: token, id: groupID, permissions: p) }
        if pendingPerms == p { pendingPerms = nil } // a newer change keeps its own until it is answered
    }

    private func setFlag(_ key: String, _ v: Bool, _ work: () async throws -> Void) async {
        pendingFlags[key] = v
        await run(work)
        if pendingFlags[key] == v { pendingFlags[key] = nil }
    }

    private func run(_ work: () async throws -> Void) async {
        do { try await work() } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why
        } catch {
            problem = NSLocalizedString("chat.action.failed", comment: "")
        }
        await load()
    }

    private func leave() async {
        do {
            try await APIClient.shared.grpRemove(token: token, id: groupID, userID: "")
            onGone?()
            dismiss()
        } catch APIError.refused(let why) {
            problem = owner ? NSLocalizedString("grp.leave.owner", comment: "") : (why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why)
        } catch {
            problem = NSLocalizedString("chat.action.failed", comment: "")
        }
    }

    private func load() async {
        let g: GrpInfo
        do {
            g = try await APIClient.shared.grpInfo(token: token, id: groupID)
        } catch {
            // no endless spinner: no longer a member (403), the group gone, or no connection -- said, with Try again
            if group == nil { loadFailed = true }
            return
        }
        loadFailed = false
        group = g
        if g.isAdmin, let all = try? await APIClient.shared.grpMembers(token: token, id: groupID) {
            // /members also returns people who left or were removed (active: false, kept to name old messages): they are not
            // members any more (website GroupInfoPanel: members.filter(m => m.active)); Remove/Ban on them failed with
            // "not found" and Add members could not re-add them. Their names still serve Recent actions.
            members = all.filter { $0.active != false }
            everyone = all
        } else {
            // an ordinary member: the people who posted, plus the owner and admins (GET /groups/{id}/admins, server d772cba)
            var out = (try? await APIClient.shared.list(GrpMember.self, "groups/\(groupID)/senders", token: token)) ?? []
            for a in (try? await APIClient.shared.list(GrpMember.self, "groups/\(groupID)/admins", token: token)) ?? [] {
                if let i = out.firstIndex(where: { $0.user_id == a.user_id }) { out[i] = a } else { out.append(a) }
            }
            members = out
            everyone = out
        }
        stats = await APIClient.shared.grpMediaStats(token: token, conversationID: groupID)
        if g.isAdmin || g.can_invite == true { invites = await APIClient.shared.grpInvites(token: token, id: groupID) }
        if g.isAdmin { bans = await APIClient.shared.grpBans(token: token, id: groupID) }
        if g.isOwner || g.isAdmin {
            requests = await APIClient.shared.grpJoinRequests(token: token, id: groupID)
            audit = await APIClient.shared.grpAudit(token: token, id: groupID)
        }
    }
}


/// "View group picture" (website GroupInfoPanel / PictureViewer): the group's logo full screen.
/// A member's Remove or Ban waiting for its confirmation (Group Info › Members).
struct MemberDanger {
    let member: GrpMember
    let ban: Bool
}

struct GroupPictureViewer: View {
    let token: String
    let groupID: String
    let avatarID: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("chat.close"))
        }
        .task { if let d = await APIClient.shared.groupAvatar(token: token, groupID: groupID, avatarID: avatarID) { image = UIImage(data: d) } }
    }
}


/// The group's link as a QR code (website .gip-qr-card): name, code, the link, Copy link.
struct GroupQRSheet: View {
    let name: String
    let link: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Text(name).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text).padding(.top, 28)
            FlashConnectView.qrCard(link)
            Text(link.replacingOccurrences(of: "https://", with: "")).font(.system(size: 13)).foregroundStyle(Theme.faint)
                .environment(\.layoutDirection, .leftToRight)
            Button {
                UIPasteboard.general.string = link
                copied = true
            } label: {
                Text(LocalizedStringKey(copied ? "grp.copied" : "grp.copy.link")).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 46).background(Theme.accent, in: Capsule())
            }
            .padding(.horizontal, 24)
            Button("chat.close") { dismiss() }.foregroundStyle(Theme.accent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.soul.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .tfColorScheme()
    }
}


/// The owner's dialog art (website 14-modals.css, fb9b6fc): a thin glowing cyan curve at the top right and the
/// wallpaper's dotted wave at the bottom left, fading to the right.
struct GroupDialogArt: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            // the curve, top right
            var curve = Path()
            curve.move(to: CGPoint(x: w * 0.52, y: -4))
            curve.addQuadCurve(to: CGPoint(x: w + 6, y: h * 0.22), control: CGPoint(x: w * 0.86, y: h * 0.02))
            ctx.stroke(curve, with: .color(Theme.hex(0x2AF0FF, 0.22)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            ctx.stroke(curve, with: .color(Theme.hex(0x2AF0FF, 0.75)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            // the dotted wave, bottom left
            let base = h - 70
            for row in 0..<4 {
                var x: CGFloat = 8
                while x < w * 0.62 {
                    let t = x / (w * 0.62)
                    let y = base + CGFloat(row) * 11 + sin(t * .pi * 2.2 + CGFloat(row) * 0.5) * 16
                    let a = 0.5 * (1 - t) * (1 - Double(row) * 0.18)
                    let r: CGFloat = 1.6 - CGFloat(row) * 0.25
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(Theme.hex(0x3FE3F0, a)))
                    x += 9
                }
            }
            var wave = Path()
            wave.move(to: CGPoint(x: 0, y: base + 28))
            var x: CGFloat = 0
            while x <= w * 0.7 {
                let t = x / (w * 0.7)
                wave.addLine(to: CGPoint(x: x, y: base + 28 + sin(t * .pi * 2.2) * 18))
                x += 4
            }
            ctx.stroke(wave, with: .linearGradient(Gradient(colors: [Theme.hex(0x3FE3F0, 0.55), Theme.hex(0x3FE3F0, 0)]),
                                                    startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: w * 0.7, y: 0)),
                       lineWidth: 1.2)
        }
        .accessibilityHidden(true)
    }
}
