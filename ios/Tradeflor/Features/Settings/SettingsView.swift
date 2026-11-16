import SwiftUI
import PhotosUI

/// Settings tab: my profile (picture, name, about), linked devices, Face ID for locked chats, language, sign out.
struct SettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var profile: Profile?
    @State private var devices: [LinkedDevice] = []
    @State private var picked: PhotosPickerItem?
    @State private var busy = false
    @State private var problem: String?
    @State private var editing = false
    @State private var confirmSignOut = false
    @State private var pinSaved = BiometricPIN.isSaved

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        NavigationStack {
            List {
                Section { header }.listRowBackground(Theme.surface)
                Section(header: Text("settings.profile")) {
                    Button { editing = true } label: {
                        row("settings.edit", icon: "pencil", detail: nil)
                    }
                    PhotosPicker(selection: $picked, matching: .images) {
                        row("settings.photo.change", icon: "photo", detail: nil)
                    }
                    if let p = profile, !p.avatar_id.isEmpty {
                        Button(role: .destructive) { Task { await removePhoto() } } label: {
                            Label("settings.photo.remove", systemImage: "trash")
                        }
                    }
                }
                .listRowBackground(Theme.surface)
                Section(header: Text("settings.devices"), footer: Text("settings.devices.footer")) {
                    ForEach(devices) { d in
                        HStack {
                            Image(systemName: d.device.localizedCaseInsensitiveContains("iphone") ? "iphone"
                                  : (d.device.localizedCaseInsensitiveContains("windows") ? "desktopcomputer" : "globe"))
                                .foregroundStyle(Theme.accent).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.device).foregroundStyle(.white)
                                if d.current == true {
                                    Text("settings.devices.this").font(.caption).foregroundStyle(Theme.accent)
                                } else if let seen = d.last_seen_at.flatMap(serverDate) {
                                    Text(seen, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            if d.current != true {
                                Button(role: .destructive) { Task { await revoke(d) } } label: {
                                    Label("settings.devices.signout", systemImage: "rectangle.portrait.and.arrow.right")
                                }
                            }
                        }
                    }
                }
                .listRowBackground(Theme.surface)
                Section(header: Text("settings.privacy")) {
                    if pinSaved {
                        Button(role: .destructive) {
                            BiometricPIN.delete()
                            pinSaved = false
                        } label: {
                            Label(String(format: NSLocalizedString("settings.lock.forget", comment: ""), BiometricPIN.biometryName),
                                  systemImage: "faceid")
                        }
                    } else {
                        row("settings.lock.info", icon: "lock", detail: nil)
                    }
                    Button {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    } label: {
                        row("settings.language", icon: "globe", detail: nil)
                    }
                }
                .listRowBackground(Theme.surface)
                Section {
                    Button(role: .destructive) { confirmSignOut = true } label: {
                        Label("chats.signout", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } footer: {
                    Text("Tradeflor \(AppConfig.version)").frame(maxWidth: .infinity).padding(.top, 8)
                }
                .listRowBackground(Theme.surface)
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 48)
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .toolbarBackground(Theme.ground, for: .navigationBar)
            .navigationTitle(Text("settings.title"))
            .refreshable { await load() }
            .overlay { if busy { ProgressView().padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
        .task { await load() }
        .onAppear { pinSaved = BiometricPIN.isSaved }
        .onChange(of: picked) { item in
            guard let item else { return }
            picked = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { await setPhoto(img) }
            }
        }
        .sheet(isPresented: $editing) {
            if let profile {
                EditProfileSheet(profile: profile) { name, bio in await save(name: name, bio: bio) }
            }
        }
        .confirmationDialog(Text("settings.signout.confirm"), isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("chats.signout", role: .destructive) { Task { await store.signOut() } }
        }
        .alert(Text(problem ?? ""), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("chat.close", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let p = profile {
                Avatar(token: token, userID: p.user_id, avatarID: p.avatar_id.isEmpty ? nil : p.avatar_id,
                       title: p.display_name.isEmpty ? p.username : p.display_name)
                    .scaleEffect(1.3)
                    .frame(width: 64, height: 64)
            } else {
                Circle().fill(Theme.surface).frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.map { $0.display_name.isEmpty ? $0.username : $0.display_name } ?? (store.session?.username ?? ""))
                    .font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text("@" + (profile?.username ?? store.session?.username ?? "")).font(.subheadline).foregroundStyle(Theme.accent)
                if let bio = profile?.bio, !bio.isEmpty {
                    Text(bio).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func row(_ key: LocalizedStringKey, icon: String, detail: String?) -> some View {
        HStack {
            Label(key, systemImage: icon).foregroundStyle(.white)
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
    }

    private func load() async {
        do {
            async let p = APIClient.shared.profile(token: token)
            async let d = APIClient.shared.devices(token: token)
            profile = try await p
            devices = (try? await d) ?? devices
        } catch APIError.badCredentials {
            store.sessionExpired()
        } catch {}
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await work() } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
        } catch {
            problem = NSLocalizedString("settings.failed", comment: "")
        }
    }

    private func setPhoto(_ img: UIImage) async {
        // a square crop from the centre, 1024 px: the server keeps avatars small
        let side = min(img.size.width, img.size.height)
        let crop = CGRect(x: (img.size.width - side) / 2, y: (img.size.height - side) / 2, width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let target = CGSize(width: min(1024, side), height: min(1024, side))
        let square = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            img.draw(in: CGRect(x: -crop.minX * target.width / side, y: -crop.minY * target.height / side,
                                width: img.size.width * target.width / side, height: img.size.height * target.height / side))
        }
        guard let jpeg = square.jpegData(compressionQuality: 0.85) else { return }
        await run { profile = try await APIClient.shared.uploadAvatar(token: token, jpeg: jpeg) }
    }

    private func removePhoto() async {
        await run { profile = try await APIClient.shared.deleteAvatar(token: token) }
    }

    private func save(name: String, bio: String) async -> Bool {
        var ok = false
        await run {
            profile = try await APIClient.shared.updateProfile(token: token, displayName: name, bio: bio)
            ok = true
        }
        return ok
    }

    private func revoke(_ d: LinkedDevice) async {
        await run {
            try await APIClient.shared.revokeDevice(token: token, id: d.id)
            devices.removeAll { $0.id == d.id }
        }
    }
}

struct EditProfileSheet: View {
    let profile: Profile
    let onSave: (String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bio = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("settings.name")) {
                    TextField("settings.name", text: $name).textContentType(.name)
                }
                Section(header: Text("settings.bio")) {
                    TextField("settings.bio", text: $bio, axis: .vertical).lineLimit(3...6)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("settings.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("settings.save") {
                            Task {
                                saving = true
                                let ok = await onSave(name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      bio.trimmingCharacters(in: .whitespacesAndNewlines))
                                saving = false
                                if ok { dismiss() }
                            }
                        }
                        .bold()
                    }
                }
            }
        }
        .onAppear {
            name = profile.display_name
            bio = profile.bio
        }
    }
}
