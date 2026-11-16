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

    private var token: String { store.session?.token ?? "" }
    private var isEdit: Bool { editing != nil }
    private var handleLocked: Bool { !(editing?.handle ?? "").isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !isEdit {
                        Text("grp.create.sub").font(.system(size: 14)).foregroundStyle(Theme.faint)
                    }
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(Theme.avatarGradient)
                            if let logo {
                                Image(uiImage: logo).resizable().scaledToFill()
                            } else if let g = editing {
                                Avatar(token: token, userID: "", avatarID: g.avatar_id, title: g.name, groupID: g.conversation_id, size: 72)
                            } else {
                                Image(systemName: "camera").font(.system(size: 22)).foregroundStyle(Theme.accent)
                            }
                        }
                        .frame(width: 72, height: 72).clipShape(Circle())
                        PhotosPicker(selection: $logoItem, matching: .images) {
                            Text(LocalizedStringKey((logo != nil || editing?.avatar_id != nil) ? "grp.logo.change" : "grp.logo.upload"))
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 14).frame(height: 36)
                                .overlay(Capsule().stroke(Theme.borderActive, lineWidth: 1))
                        }
                    }
                    field("grp.name") {
                        TextField("", text: $name, prompt: Text("grp.name.ph").foregroundColor(Theme.faint))
                    }
                    field("grp.link") {
                        HStack(spacing: 0) {
                            Text("app.tradeflor.com/g/").foregroundStyle(Theme.faint)
                            TextField("", text: $handle, prompt: Text("yourgroup").foregroundColor(Theme.faint))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .disabled(handleLocked)
                                .onChange(of: handle) { v in
                                    let clean = String(v.lowercased().filter { ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "_" }.prefix(32))
                                    if clean != v { handle = clean }
                                }
                        }
                        .environment(\.layoutDirection, .leftToRight)
                    }
                    Text(LocalizedStringKey(handleLocked ? "grp.link.locked" : "grp.link.hint")).font(.system(size: 12)).foregroundStyle(Theme.faint)
                    field("grp.desc") {
                        TextField("", text: $about, prompt: Text("grp.desc.ph").foregroundColor(Theme.faint), axis: .vertical).lineLimit(2...5)
                    }
                    Text("grp.privacy").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    radio("grp.privacy.public", selected: isPublic) { isPublic = true }
                    radio("grp.privacy.private", selected: !isPublic) { isPublic = false }

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
                    Button { Task { await submit() } } label: {
                        HStack { if busy { ProgressView().tint(Theme.onAccent) } else { Text(LocalizedStringKey(isEdit ? "grp.save" : "grp.create.go")).bold() } }
                            .foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 50)
                            .background(Theme.accent, in: Capsule())
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.6 : 1)
                    .padding(.top, 6)
                }
                .padding(16)
            }
            .background(Theme.panelGradient.ignoresSafeArea())
            .navigationTitle(Text(LocalizedStringKey(isEdit ? "grp.edit.title" : "grp.new.title")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.header, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
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

    private func field<C: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            content()
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.inputGradient, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderStrong, lineWidth: 1))
        }
    }

    private func radio(_ key: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Theme.accent : Theme.faint)
                Text(key).font(.system(size: 14)).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(12)
            .background(selected ? Theme.active : Theme.chip, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.borderActive : Theme.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func submit() async {
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
                try await APIClient.shared.grpUpdate(token: token, id: id, name: cleanName, description: about,
                                                     privacy: isPublic ? "public" : "private")
                if !handleLocked && !h.isEmpty { try await APIClient.shared.grpSetHandle(token: token, id: id, handle: h) }
            } else {
                id = try await APIClient.shared.createGroup(token: token, name: cleanName, description: about, isPublic: isPublic,
                                                            memberIDs: Array(picked))
                if !h.isEmpty { try? await APIClient.shared.grpSetHandle(token: token, id: id, handle: h) }
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
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("group.join.go") { Task { await join() } }.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func join() async {
        guard let token = store.session?.token else { return }
        busy = true
        defer { busy = false }
        do {
            let id = try await APIClient.shared.joinGroup(token: token, link: link)
            if id.isEmpty {
                info = NSLocalizedString("group.join.pending", comment: "")
            } else {
                dismiss()
                onJoined(id)
            }
        } catch APIError.refused(let why) {
            info = why.isEmpty ? NSLocalizedString("group.join.bad", comment: "") : why
        } catch {
            info = NSLocalizedString("login.error.network", comment: "")
        }
    }
}

/// Group Info (website GroupInfoPanel.tsx): tabs "Group Info" | "Members (N)", identity and picture, Mute / Manage / More,
/// the permanent link, description, invite links, Group Management, join requests, recent actions, stats, leave/delete.
struct GroupInfoView: View {
    let groupID: String
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var group: GrpInfo?
    @State private var members: [GrpMember] = []
    @State private var bans: [GrpBan] = []
    @State private var invites: [GrpInvite] = []
    @State private var requests: [GrpJoinRequest] = []
    @State private var audit: [GrpAudit] = []
    @State private var stats: GrpMediaStats?
    @State private var cropping: PickedImage?
    @State private var viewingPicture: String?
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
    @State private var problem: String?
    @State private var toast: String?

    private var token: String { store.session?.token ?? "" }
    private var me: String { store.session?.userID ?? "" }
    private var admin: Bool { group?.isAdmin ?? false }
    private var owner: Bool { group?.isOwner ?? false }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if admin {
                        Picker("", selection: $tab) {
                            Text("grp.tab.info").tag(0)
                            Text(String(format: NSLocalizedString("grp.tab.members", comment: ""), group?.member_count ?? members.count)).tag(1)
                        }
                        .pickerStyle(.segmented)
                    }
                    if let g = group {
                        if tab == 0 { infoTab(g) } else { membersTab(g) }
                    } else {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(16)
            }
            .background(Theme.panelGradient.ignoresSafeArea())
            .navigationTitle(Text("grp.info.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.header, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
            .sheet(isPresented: $manage, onDismiss: { Task { await load() } }) {
                if let g = group { CreateGroupView(onCreated: { _ in }, editing: g) }
            }
            .confirmationDialog(Text("grp.leave.confirm"), isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("grp.leave", role: .destructive) { Task { await leave() } }
            }
            .confirmationDialog(Text("grp.delete.confirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("grp.delete", role: .destructive) {
                    Task {
                        await run { try await APIClient.shared.grpDelete(token: token, id: groupID) }
                        dismiss()
                    }
                }
            }
            .confirmationDialog(Text(String(format: NSLocalizedString("grp.transfer.confirm", comment: ""), transferTo?.title ?? "")),
                                isPresented: Binding(get: { transferTo != nil }, set: { if !$0 { transferTo = nil } }), titleVisibility: .visible) {
                Button("grp.m.transfer", role: .destructive) {
                    if let m = transferTo { Task { await run { try await APIClient.shared.grpTransfer(token: token, id: groupID, userID: m.user_id) } } }
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
        .task { await load() }
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
        .fullScreenCover(item: $cropping) { p in
            AvatarEditor(image: p.image) { jpeg in
                Task { await run { try await APIClient.shared.grpUploadAvatar(token: token, id: groupID, jpeg: jpeg) } }
            }
        }
    }

    // MARK: Group Info tab

    @ViewBuilder private func infoTab(_ g: GrpInfo) -> some View {
        VStack(spacing: 8) {
            Avatar(token: token, userID: "", avatarID: g.avatar_id, title: g.name, groupID: g.conversation_id, size: 96)
                .onTapGesture { if let a = g.avatar_id, !a.isEmpty { viewingPicture = a } }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("grp.picture.view"))
            if owner {
                HStack(spacing: 14) {
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        Text("grp.picture.change").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    if !(g.avatar_id ?? "").isEmpty {
                        Button("grp.picture.remove") { Task { await run { try await APIClient.shared.grpRemoveAvatar(token: token, id: groupID) } } }
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.danger)
                    }
                }
            }
            HStack(spacing: 5) {
                Text(g.name).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                if g.verified == true { Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.verified) }
            }
            Text(String(format: NSLocalizedString("groups.members", comment: ""), g.member_count)).font(.system(size: 13)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity)

        HStack(spacing: 10) {
            actionButton(g.isMuted ? "bell" : "bell.slash", g.isMuted ? "grp.unmute.short" : "grp.mute.short") {
                Task {
                    await run {
                        if g.isMuted { try await APIClient.shared.setPrefs(token: token, conversationID: groupID, unmute: true) }
                        else { try await APIClient.shared.setPrefs(token: token, conversationID: groupID, muteForever: true) }
                    }
                }
            }
            if owner { actionButton("slider.horizontal.3", "grp.manage") { manage = true } }
            Menu {
                if let h = g.handle, !h.isEmpty {
                    Button { copy("https://app.tradeflor.com/g/\(h)") } label: { Label("grp.copy.link", systemImage: "link") }
                }
                Button(role: .destructive) { confirmLeave = true } label: { Label("grp.leave", systemImage: "rectangle.portrait.and.arrow.right") }
            } label: {
                actionLabel("ellipsis", "grp.more")
            }
        }

        // permanent link
        TFSectionLabel(text: NSLocalizedString("grp.link", comment: ""))
        TFCard {
            VStack(alignment: .leading, spacing: 10) {
                if let h = g.handle, !h.isEmpty {
                    HStack {
                        Text("app.tradeflor.com/g/\(h)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent).lineLimit(1)
                        Spacer()
                        Button("grp.copy") { copy("https://app.tradeflor.com/g/\(h)") }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    if g.privacy != "public" {
                        Text("grp.link.private").font(.system(size: 12)).foregroundStyle(Theme.faint)
                        if owner {
                            Button("grp.make.public") { Task { await run { try await APIClient.shared.grpUpdate(token: token, id: groupID, privacy: "public") } } }
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                } else if owner {
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
                } else {
                    Text("grp.link.none").font(.system(size: 13)).foregroundStyle(Theme.faint)
                }
            }
            .padding(14)
        }

        // description
        TFSectionLabel(text: NSLocalizedString("grp.desc", comment: ""))
        TFCard {
            VStack(alignment: .leading, spacing: 10) {
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
                    HStack(alignment: .top) {
                        Text(g.description.isEmpty ? NSLocalizedString("grp.desc.none", comment: "") : g.description)
                            .font(.system(size: 14)).foregroundStyle(g.description.isEmpty ? Theme.faint : Theme.muted)
                        Spacer()
                        if owner {
                            Button(LocalizedStringKey(g.description.isEmpty ? "grp.add" : "grp.edit")) {
                                descDraft = g.description
                                editingDesc = true
                            }
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .padding(14)
        }

        // invite links
        TFSectionLabel(text: NSLocalizedString("grp.invite.title", comment: ""))
        TFCard {
            VStack(alignment: .leading, spacing: 10) {
                if admin || g.can_invite == true {
                    HStack {
                        Text("grp.invite.expires").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        Spacer()
                        Picker("", selection: $inviteHours) {
                            Text("grp.never").tag(0)
                            Text("grp.1day").tag(24)
                            Text("grp.7days").tag(168)
                            Text("grp.30days").tag(720)
                        }
                        .tint(Theme.accent)
                    }
                    HStack {
                        Text("grp.invite.uses").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        Spacer()
                        Picker("", selection: $inviteUses) {
                            Text("grp.unlimited").tag(0)
                            Text("grp.1person").tag(1)
                            Text("grp.10people").tag(10)
                            Text("grp.100people").tag(100)
                        }
                        .tint(Theme.accent)
                    }
                    Button {
                        Task {
                            do {
                                newLink = try await APIClient.shared.grpCreateInvite(token: token, id: groupID, hours: inviteHours, maxUses: inviteUses)
                                invites = await APIClient.shared.grpInvites(token: token, id: groupID)
                            } catch APIError.refused(let why) {
                                problem = why
                            } catch {
                                problem = NSLocalizedString("chat.action.failed", comment: "")
                            }
                        }
                    } label: {
                        Label(LocalizedStringKey(invites.isEmpty ? "grp.invite.create" : "grp.invite.new"), systemImage: "link.badge.plus")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                    }
                    if let newLink {
                        HStack {
                            Text(newLink).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("grp.copy") { copy(newLink) }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                            ShareLink(item: newLink) { Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.accent) }
                        }
                    }
                    if !invites.isEmpty {
                        Text("grp.invite.active").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint).padding(.top, 4)
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
                                    Task {
                                        await run { try await APIClient.shared.grpRevokeInvite(token: token, id: groupID, inviteID: inv.id) }
                                    }
                                }
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.danger)
                            }
                        }
                    }
                } else {
                    Text("grp.invite.only.admins").font(.system(size: 13)).foregroundStyle(Theme.faint)
                }
            }
            .padding(14)
        }

        // admins
        let adminNames = members.filter { $0.role != "member" }.map(\.title)
        if !adminNames.isEmpty {
            Button { if admin { tab = 1 } } label: {
                TFCard { TFRow(icon: "star", title: NSLocalizedString("grp.admins", comment: ""), subtitle: adminNames.joined(separator: ", "), showChevron: admin) }
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }

        if admin { management(g) }

        if owner && (g.join_approval ?? false) {
            TFSectionLabel(text: String(format: NSLocalizedString("grp.requests.n", comment: ""), requests.count))
            TFCard {
                if requests.isEmpty {
                    Text("grp.requests.none").font(.system(size: 13)).foregroundStyle(Theme.faint).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(requests) { r in
                    HStack {
                        Avatar(token: token, userID: r.user_id, avatarID: nil, title: r.display_name ?? r.username, size: 36)
                        Text((r.display_name?.isEmpty == false ? r.display_name! : r.username)).foregroundStyle(Theme.text)
                        Spacer()
                        Button("grp.decline") { Task { await run { try await APIClient.shared.grpDecide(token: token, id: groupID, userID: r.user_id, approve: false) } } }
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.danger)
                        Button("grp.approve") { Task { await run { try await APIClient.shared.grpDecide(token: token, id: groupID, userID: r.user_id, approve: true) } } }
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
        }

        if owner {
            Button { showAudit.toggle() } label: {
                TFCard { TFRow(icon: "clock.arrow.circlepath", title: NSLocalizedString("grp.audit", comment: ""), showChevron: true) }
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            if showAudit {
                TFCard {
                    if audit.isEmpty {
                        Text("grp.audit.none").font(.system(size: 13)).foregroundStyle(Theme.faint).padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(audit.prefix(50)) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(auditLine(a)).font(.system(size: 13)).foregroundStyle(Theme.text)
                            Text(serverDate(a.created_at).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                                .font(.system(size: 11)).foregroundStyle(Theme.faint)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
            }
        }

        SharedMediaCard(token: token, conversationID: groupID)
        if let s = stats {
            TFSectionLabel(text: NSLocalizedString("grp.stats", comment: ""))
            TFCard {
                statRow("photo", "grp.stat.photos", s.photos)
                statRow("video", "grp.stat.videos", s.videos)
                statRow("doc", "grp.stat.files", s.files)
                statRow("link", "grp.stat.links", s.links)
                statRow("chart.bar", "grp.stat.polls", s.polls)
                statRow("mic", "grp.stat.voice", s.voice)
                statRow("person.2", "grp.stat.members", g.member_count)
                statRow("star", "grp.stat.admins", members.isEmpty ? nil : members.filter { $0.role != "member" }.count)
            }
        }

        TFCard {
            Button { confirmLeave = true } label: {
                TFRow(icon: "rectangle.portrait.and.arrow.right", title: NSLocalizedString("grp.leave", comment: ""), tint: Theme.danger, showChevron: false)
            }
            .buttonStyle(.plain)
            if owner {
                Rectangle().fill(Theme.rowRule).frame(height: 1).padding(.leading, 50)
                Button { confirmDelete = true } label: {
                    TFRow(icon: "trash", title: NSLocalizedString("grp.delete", comment: ""), tint: Theme.danger, showChevron: false)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 10)
    }

    /// Group Management: the same switches and choices as the website.
    @ViewBuilder private func management(_ g: GrpInfo) -> some View {
        let perms = g.permissions ?? GrpPermissions(allow_chat: true, allow_media: true, allow_reactions: true, members_can_invite: false,
                                                    signal_permission: "owner_admins", chat_permission: "everyone")
        TFSectionLabel(text: NSLocalizedString("grp.management", comment: ""))
        TFCard {
            toggleRow("grp.allow.chat", perms.allow_chat) { v in var p = perms; p.allow_chat = v; await setPerms(p) }
            toggleRow("grp.allow.media", perms.allow_media) { v in var p = perms; p.allow_media = v; await setPerms(p) }
            toggleRow("grp.allow.reactions", perms.allow_reactions) { v in var p = perms; p.allow_reactions = v; await setPerms(p) }
            toggleRow("grp.history", g.history_visible_to_new_members ?? false) { v in
                await run { try await APIClient.shared.grpUpdate(token: token, id: groupID, historyVisible: v) }
            }
            toggleRow("grp.approve.new", g.join_approval ?? false) { v in
                await run { try await APIClient.shared.grpUpdate(token: token, id: groupID, joinApproval: v) }
            }
            toggleRow("grp.comments", g.comments ?? false, sub: "grp.comments.sub") { v in
                await run { try await APIClient.shared.grpUpdate(token: token, id: groupID, comments: v) }
            }
            pickerRow("grp.slow", selection: g.slow_mode ?? 0, options: [(0, "grp.off"), (10, "grp.10s"), (30, "grp.30s"), (60, "grp.1m"),
                                                                          (300, "grp.5m"), (900, "grp.15m"), (3600, "grp.1h")]) { v in
                await run { try await APIClient.shared.grpUpdate(token: token, id: groupID, slowMode: v) }
            }
            stringPickerRow("grp.signals.who", selection: perms.signal_permission,
                            options: [("owner_only", "grp.owner.only"), ("owner_admins", "grp.owner.admins"), ("all_members", "grp.all.members")]) { v in
                var p = perms; p.signal_permission = v; await setPerms(p)
            }
            stringPickerRow("grp.chat.permission", selection: perms.chat_permission,
                            options: [("everyone", "grp.everyone"), ("admins_only", "grp.admins.only"), ("restricted", "grp.restricted")]) { v in
                var p = perms; p.chat_permission = v; await setPerms(p)
            }
            Button { tab = 1 } label: { TFRow(icon: "person.2", title: NSLocalizedString("grp.manage.members", comment: "")) }
                .buttonStyle(.plain)
            if owner {
                Button { manage = true } label: { TFRow(icon: "gearshape", title: NSLocalizedString("grp.settings", comment: "")) }
                    .buttonStyle(.plain)
            }
        }
    }

    // MARK: Members tab

    @ViewBuilder private func membersTab(_ g: GrpInfo) -> some View {
        TFCard {
            HStack {
                Image(systemName: "person.badge.plus").foregroundStyle(Theme.accent)
                TextField("", text: $addName, prompt: Text("grp.add.member").foregroundColor(Theme.faint))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().foregroundStyle(Theme.text)
                    .submitLabel(.done)
                    .onSubmit { addMember() }
                if !addName.isEmpty { Button("grp.add") { addMember() }.font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent) }
            }
            .padding(14)
        }
        TFCard {
            ForEach(Array(members.enumerated()), id: \.element.id) { i, m in
                memberRow(m)
                    .contextMenu { if admin && m.user_id != me && m.role != "owner" { memberMenu(m) } }
                if i < members.count - 1 { Rectangle().fill(Theme.rowRule).frame(height: 1).padding(.leading, 62) }
            }
        }
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

    private func memberRow(_ m: GrpMember) -> some View {
        HStack(spacing: 12) {
            Avatar(token: token, userID: m.user_id, avatarID: m.avatar_id, title: m.title, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.user_id == me ? m.title + " " + NSLocalizedString("grp.you", comment: "") : m.title)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("@" + m.username).font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            Spacer()
            if m.isMuted { Text("grp.muted").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.gold) }
            if m.role != "member" {
                Text(LocalizedStringKey(m.role == "owner" ? "grp.role.owner" : "grp.role.admin"))
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3).overlay(Capsule().stroke(Theme.borderActive, lineWidth: 1))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func memberMenu(_ m: GrpMember) -> some View {
        if owner {
            Button { Task { await run { try await APIClient.shared.grpRole(token: token, id: groupID, userID: m.user_id, admin: m.role != "admin") } } } label: {
                Label(LocalizedStringKey(m.role == "admin" ? "grp.m.unadmin" : "grp.m.admin"), systemImage: "star")
            }
            Button { transferTo = m } label: { Label("grp.m.transfer", systemImage: "crown") }
        }
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
        Button(role: .destructive) { Task { await run { try await APIClient.shared.grpRemove(token: token, id: groupID, userID: m.user_id) } } } label: {
            Label("grp.m.remove", systemImage: "person.fill.xmark")
        }
        Button(role: .destructive) { Task { await run { try await APIClient.shared.grpBan(token: token, id: groupID, userID: m.user_id) } } } label: {
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
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func pickerRow(_ key: LocalizedStringKey, selection: Int, options: [(Int, String)], set: @escaping (Int) async -> Void) -> some View {
        HStack {
            Text(key).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            Menu {
                ForEach(0..<options.count, id: \.self) { i in
                    Button(LocalizedStringKey(options[i].1)) { Task { await set(options[i].0) } }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(options.first(where: { $0.0 == selection })?.1 ?? options[0].1))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                }
                .font(.system(size: 13)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func stringPickerRow(_ key: LocalizedStringKey, selection: String, options: [(String, String)], set: @escaping (String) async -> Void) -> some View {
        HStack {
            Text(key).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            Menu {
                ForEach(0..<options.count, id: \.self) { i in
                    Button(LocalizedStringKey(options[i].1)) { Task { await set(options[i].0) } }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(options.first(where: { $0.0 == selection })?.1 ?? options[0].1))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                }
                .font(.system(size: 13)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
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
        let who = members.first { $0.user_id == a.actor_id }?.title ?? NSLocalizedString("grp.someone", comment: "")
        let target = a.target_user_id.flatMap { t in members.first { $0.user_id == t }?.title }
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

    private func setPerms(_ p: GrpPermissions) async {
        await run { try await APIClient.shared.grpUpdate(token: token, id: groupID, permissions: p) }
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
            dismiss()
        } catch APIError.refused(let why) {
            problem = owner ? NSLocalizedString("grp.leave.owner", comment: "") : (why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why)
        } catch {
            problem = NSLocalizedString("chat.action.failed", comment: "")
        }
    }

    private func load() async {
        guard let g = try? await APIClient.shared.grpInfo(token: token, id: groupID) else { return }
        group = g
        members = (try? await APIClient.shared.grpMembers(token: token, id: groupID)) ?? members
        stats = await APIClient.shared.grpMediaStats(token: token, conversationID: groupID)
        if g.isAdmin || g.can_invite == true { invites = await APIClient.shared.grpInvites(token: token, id: groupID) }
        if g.isAdmin { bans = await APIClient.shared.grpBans(token: token, id: groupID) }
        if g.isOwner {
            requests = await APIClient.shared.grpJoinRequests(token: token, id: groupID)
            audit = await APIClient.shared.grpAudit(token: token, id: groupID)
        }
    }
}


/// "View group picture" (website GroupInfoPanel / PictureViewer): the group's logo full screen.
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
