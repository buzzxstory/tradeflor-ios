import PhotosUI
import SwiftUI

// The rest of the website's Admin Center (features/admin/AdminCenter.tsx, OfficialAdmin.tsx): registration chart and recent
// registrations, Security & Audit, Admin Settings (your access, administrators), roles on an account, an account's admin
// history, the Content Library filter and the New official status composer.

struct AdminBucket: Decodable, Hashable { let label: String; let start: Int64; let count: Int }

struct AdminAuditEntry: Decodable, Identifiable {
    let id: Int64
    let at: Int64
    let actor_id: String
    let actor_name: String
    let action: String
    let target_user_id: String?
    let target_name: String?
    let detail: String?
    let ip: String?
}

struct AdminAccount: Decodable, Identifiable {
    let user_id: String
    let username: String
    let display_name: String
    let role: String
    let granted_by: String
    let granted_at: Int64
    var id: String { user_id }
}

extension APIClient {
    func admAudit(token: String, user: String = "", before: Int64 = 0) async -> [AdminAuditEntry] {
        (try? await list(AdminAuditEntry.self, "admin/audit?user=\(APIClient.q(user))&before=\(before)", token: token)) ?? []
    }
    func admAdmins(token: String) async -> [AdminAccount] {
        (try? await list(AdminAccount.self, "admin/admins", token: token)) ?? []
    }
    func admSetRole(token: String, userID: String, role: String) async throws {
        _ = try await postJSON("admin/admins", token: token, body: ["UserID": userID, "Role": role])
    }
    func admUser(token: String, id: String) async -> AdminUser? {
        guard let d = try? await getJSON("admin/users/\(id)", token: token) else { return nil }
        return try? JSONDecoder().decode(AdminUser.self, from: d)
    }

    /// Multipart POST /admin/official: the fields first, then the file (the server decides before it keeps the file).
    func admCreateOfficial(token: String, file: Data, fileName: String, mime: String, title: String, caption: String,
                           ctaLabel: String, ctaURL: String, hours: Int, publish: Bool) async throws {
        let boundary = "tf-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("title", title)
        field("caption", caption)
        field("cta_label", ctaLabel)
        field("cta_url", ctaURL)
        field("hours", String(hours))
        field("publish", publish ? "1" : "0")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = request("admin/official", method: "POST", token: token, body: nil)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = body
        let (data, http) = try await send(req)
        if [400, 403, 413, 415].contains(http.statusCode) {
            throw APIError.refused(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        try check(http, data)
    }
}

enum AdminFmt {
    static func date(_ s: Int64) -> String {
        Date(timeIntervalSince1970: Double(s > 100_000_000_000 ? s / 1000 : s)).formatted(date: .abbreviated, time: .shortened)
    }
    static func roleLabel(_ r: String) -> String { NSLocalizedString("adm.role." + (r.isEmpty ? "none" : r), comment: "") }
}

/// Registrations per day / week / month as bars.
struct AdminBars: View {
    let daily: [AdminBucket]
    let weekly: [AdminBucket]
    let monthly: [AdminBucket]
    @State private var range = "daily"

    private var data: [AdminBucket] { range == "weekly" ? weekly : (range == "monthly" ? monthly : daily) }

    var body: some View {
        TFCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("adm.registrations").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                    Spacer()
                    Picker("", selection: $range) {
                        Text("adm.range.daily").tag("daily")
                        Text("adm.range.weekly").tag("weekly")
                        Text("adm.range.monthly").tag("monthly")
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 210)
                }
                let top = max(1, data.map(\.count).max() ?? 1)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(data, id: \.self) { b in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.accent.opacity(b.count == 0 ? 0.18 : 0.85))
                            .frame(height: max(3, CGFloat(b.count) / CGFloat(top) * 110))
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(Text("\(b.label): \(b.count)"))
                    }
                }
                .frame(height: 112, alignment: .bottom)
                HStack {
                    Text(data.first?.label ?? "").font(.system(size: 10)).foregroundStyle(Theme.faint)
                    Spacer()
                    Text(String(format: NSLocalizedString("adm.range.total", comment: ""), data.reduce(0) { $0 + $1.count }))
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text(data.last?.label ?? "").font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
            }
            .padding(14)
        }
    }
}

/// Security & Audit: every administrative action, newest first.
struct AdminAuditView: View {
    var user: String = ""
    var onOpenUser: ((String) -> Void)?
    @EnvironmentObject private var store: SessionStore
    @State private var log: [AdminAuditEntry]?
    @State private var more = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if user.isEmpty { Text("adm.audit.note").font(.system(size: 12)).foregroundStyle(Theme.faint) }
            if let log {
                if log.isEmpty { Text("adm.audit.none").font(.system(size: 13)).foregroundStyle(Theme.faint) }
                TFCard {
                    ForEach(Array(log.enumerated()), id: \.element.id) { i, e in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(e.action.replacingOccurrences(of: "_", with: " ").capitalized).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                Spacer()
                                Text(AdminFmt.date(e.at)).font(.system(size: 10)).foregroundStyle(Theme.faint)
                            }
                            Text(String(format: NSLocalizedString("adm.audit.by", comment: ""), e.actor_name, e.target_name ?? "—"))
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            if let d = e.detail, !d.isEmpty { Text(d).font(.system(size: 12)).foregroundStyle(Theme.faint) }
                            if let ip = e.ip, !ip.isEmpty { Text("IP " + ip).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.faint) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .onTapGesture { if let t = e.target_user_id, !t.isEmpty { onOpenUser?(t) } }
                        if i < log.count - 1 { TFDivider() }
                    }
                }
                if more && !log.isEmpty {
                    Button("chat.older") { Task { await load(before: log.last?.id ?? 0) } }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent).frame(maxWidth: .infinity)
                }
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
        }
        .task { await load(before: 0) }
    }

    private func load(before: Int64) async {
        let page = await APIClient.shared.admAudit(token: store.session?.token ?? "", user: user, before: before)
        log = before == 0 ? page : (log ?? []) + page
        more = page.count == 50
    }
}

/// Admin Settings: what my role allows, and (owners) the administrators.
struct AdminSettingsView: View {
    let me: AdminMe
    var onOpenUser: (String) -> Void
    @EnvironmentObject private var store: SessionStore
    @State private var admins: [AdminAccount]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TFCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("adm.access").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(AdminFmt.roleLabel(me.role)).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 9).padding(.vertical, 3).overlay(Capsule().stroke(Theme.borderActive, lineWidth: 1))
                    }
                    can("adm.can.figures", me.users == true)
                    can("adm.can.suspend", me.users == true)
                    can("adm.can.official", me.content == true)
                    can("adm.can.erase", me.users == true)
                    can("adm.can.audit", me.audit == true)
                    can("adm.can.roles", me.roles == true)
                    Text("adm.access.note").font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
                .padding(14)
            }
            if me.roles == true {
                TFSectionLabel(text: NSLocalizedString("adm.admins", comment: ""))
                TFCard {
                    ForEach(Array((admins ?? []).enumerated()), id: \.element.id) { i, a in
                        Button { onOpenUser(a.user_id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.display_name.isEmpty ? "@" + a.username : a.display_name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                    Text("@\(a.username) · \(AdminFmt.date(a.granted_at))").font(.system(size: 11)).foregroundStyle(Theme.faint)
                                }
                                Spacer()
                                Text(AdminFmt.roleLabel(a.role)).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        if i < (admins ?? []).count - 1 { TFDivider() }
                    }
                }
                Text("adm.admins.note").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
        .task { if me.roles == true { admins = await APIClient.shared.admAdmins(token: store.session?.token ?? "") } }
    }

    private func can(_ key: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark" : "minus").font(.system(size: 11, weight: .bold)).foregroundStyle(ok ? Theme.buy : Theme.faint).frame(width: 14)
            Text(LocalizedStringKey(key)).font(.system(size: 13)).foregroundStyle(ok ? Theme.text : Theme.faint)
        }
        .accessibilityElement(children: .combine)
    }
}

/// New official status: a photo or video with title, caption, a button (label + link), lifetime, publish now or keep as draft.
struct AdminOfficialComposer: View {
    var onDone: () -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotosPickerItem?
    @State private var file: (data: Data, name: String, mime: String, preview: UIImage?)?
    @State private var title = ""
    @State private var caption = ""
    @State private var ctaLabel = ""
    @State private var ctaURL = ""
    @State private var hours = 24
    @State private var publish = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $item, matching: .any(of: [.images, .videos])) {
                        HStack {
                            if let p = file?.preview { Image(uiImage: p).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8)) }
                            else if file != nil { Image(systemName: "video").frame(width: 56, height: 56) }
                            Text(LocalizedStringKey(file == nil ? "adm.off.pick" : "adm.off.change")).foregroundStyle(Theme.accent)
                        }
                    }
                }
                .listRowBackground(Theme.surface)
                Section {
                    TextField("adm.off.title", text: $title)
                    TextField("adm.off.caption", text: $caption, axis: .vertical).lineLimit(2...5)
                    TextField("adm.off.cta.label", text: $ctaLabel)
                    TextField("adm.off.cta.url", text: $ctaURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("adm.off.hours", selection: $hours) {
                        ForEach([12, 24, 48, 72, 168], id: \.self) { h in
                            Text(h < 48 ? String(format: NSLocalizedString("adm.off.h", comment: ""), h) : String(format: NSLocalizedString("adm.off.d", comment: ""), h / 24)).tag(h)
                        }
                    }
                    Toggle("adm.off.publish", isOn: $publish).tint(Theme.accent)
                }
                .listRowBackground(Theme.surface)
                if let error { Section { Text(error).foregroundStyle(Theme.danger).font(.footnote) }.listRowBackground(Theme.surface) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("adm.off.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("grp.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await submit() } } label: { if busy { ProgressView() } else { Text(LocalizedStringKey(publish ? "adm.publish" : "adm.off.draft")).bold() } }
                        .disabled(file == nil || busy)
                }
            }
            .onChange(of: item) { it in
                guard let it else { return }
                Task {
                    if let m = try? await it.loadTransferable(type: PickedMovie.self), let d = try? Data(contentsOf: m.url) {
                        file = (d, m.url.lastPathComponent, "video/" + (m.url.pathExtension.lowercased() == "mov" ? "quicktime" : "mp4"), nil)
                    } else if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d), let jpeg = img.jpegData(compressionQuality: 0.9) {
                        file = (jpeg, "official.jpg", "image/jpeg", img)
                    }
                }
            }
        }
        .tfColorScheme()
    }

    private func submit() async {
        guard let f = file else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await APIClient.shared.admCreateOfficial(token: store.session?.token ?? "", file: f.data, fileName: f.name, mime: f.mime,
                                                         title: title.trimmingCharacters(in: .whitespaces).isEmpty ? String(f.name.prefix(60)) : title.trimmingCharacters(in: .whitespaces),
                                                         caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                                                         ctaLabel: ctaLabel.trimmingCharacters(in: .whitespaces), ctaURL: ctaURL.trimmingCharacters(in: .whitespaces),
                                                         hours: hours, publish: publish)
            onDone()
            dismiss()
        } catch APIError.refused(let why) {
            error = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
        } catch {
            self.error = NSLocalizedString("settings.failed", comment: "")
        }
    }
}
