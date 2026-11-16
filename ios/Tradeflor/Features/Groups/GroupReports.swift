import SwiftUI

// Group Info › More like Telegram (website GroupInfoPanel / ReportGroup.tsx): Add to folder, Report (Telegram's reasons and
// an optional note), and the Admin Center's Reports tab that reviews them.

struct GroupReport: Decodable, Identifiable {
    let id: String
    let group_id: String
    let group_name: String
    let group_handle: String?
    let group_members: Int
    let open_for_group: Int
    let reporter_id: String
    let reporter_name: String
    let reason: String
    let comment: String?
    let created_at: Int64
    let status: String
    let reviewed_by: String?
    let reviewed_at: Int64?
}

extension APIClient {
    func grpReport(token: String, id: String, reason: String, comment: String) async throws {
        _ = try await postJSON("groups/\(id)/report", token: token, body: ["Reason": reason, "Comment": comment])
    }
    func admReports(token: String, status: String) async -> [GroupReport] {
        (try? await list(GroupReport.self, "admin/reports?status=\(status)", token: token)) ?? []
    }
    func admReviewReport(token: String, id: String) async throws {
        _ = try await postJSON("admin/reports/\(id)/review", token: token, body: [:])
    }
}

enum ReportReasons {
    static let all = ["spam", "violence", "child_abuse", "pornography", "copyright", "personal_details", "illegal_drugs", "other"]
    static func icon(_ r: String) -> String {
        switch r {
        case "spam": return "xmark.octagon"
        case "violence": return "exclamationmark.triangle"
        case "child_abuse": return "figure.and.child.holdinghands"
        case "pornography": return "eye.slash"
        case "copyright": return "c.circle"
        case "personal_details": return "person.text.rectangle"
        case "illegal_drugs": return "pills"
        default: return "ellipsis.circle"
        }
    }
}

struct ReportGroupSheet: View {
    let groupID: String
    let groupName: String
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var reason: String?
    @State private var note = ""
    @State private var busy = false
    @State private var done = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if done {
                    Section {
                        Label("report.thanks", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.online)
                        Text("report.thanks.sub").font(.footnote).foregroundStyle(Theme.faint)
                    }
                    .listRowBackground(Theme.card)
                } else if let r = reason {
                    Section(header: Text(LocalizedStringKey("report.r." + r))) {
                        TextField("report.note", text: $note, axis: .vertical).lineLimit(3...6).foregroundStyle(Theme.text)
                    }
                    .listRowBackground(Theme.card)
                    if let error { Text(error).foregroundStyle(Theme.danger).font(.footnote).listRowBackground(Color.clear) }
                } else {
                    Section(header: Text(String(format: NSLocalizedString("report.why", comment: ""), groupName))) {
                        ForEach(ReportReasons.all, id: \.self) { r in
                            Button { reason = r } label: {
                                Label(LocalizedStringKey("report.r." + r), systemImage: ReportReasons.icon(r)).foregroundStyle(Theme.text)
                            }
                        }
                    }
                    .listRowBackground(Theme.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.panelGradient.ignoresSafeArea())
            .navigationTitle(Text("report.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey(done ? "id.done" : (reason == nil ? "grp.cancel" : "fc.back"))) {
                        if done || reason == nil { dismiss() } else { reason = nil }
                    }
                }
                if reason != nil && !done {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { Task { await send() } } label: { if busy { ProgressView() } else { Text("report.send").bold() } }
                            .disabled(busy)
                    }
                }
            }
        }
        .tfColorScheme()
    }

    private func send() async {
        guard let r = reason else { return }
        busy = true
        defer { busy = false }
        do {
            try await APIClient.shared.grpReport(token: store.session?.token ?? "", id: groupID, reason: r,
                                                 comment: note.trimmingCharacters(in: .whitespacesAndNewlines))
            done = true
        } catch APIError.refused(let why) {
            error = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
        } catch {
            self.error = NSLocalizedString("settings.failed", comment: "")
        }
    }
}

/// Add to folder: my folders with a tick where this chat is in the folder's list; a tap adds or removes it.
struct AddToFolderSheet: View {
    let conversationID: String
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [EditableFolder] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
                else if folders.isEmpty { Text("folder.none").foregroundStyle(Theme.faint).listRowBackground(Color.clear) }
                ForEach(folders) { f in
                    Button { Task { await toggle(f) } } label: {
                        HStack {
                            Label(f.name, systemImage: "folder").foregroundStyle(Theme.text)
                            Spacer()
                            if f.items.contains(conversationID) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
                .listRowBackground(Theme.card)
                if let error { Text(error).foregroundStyle(Theme.danger).font(.footnote).listRowBackground(Color.clear) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.panelGradient.ignoresSafeArea())
            .navigationTitle(Text("folder.addto"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("id.done") { dismiss() } } }
        }
        .tfColorScheme()
        .task { await load() }
    }

    private func load() async {
        loading = true
        folders = (try? await FolderStore.load(token: store.session?.token ?? ""))?.1 ?? []
        loading = false
    }

    private func toggle(_ f: EditableFolder) async {
        let id = f.id
        do {
            try await FolderStore.save(token: store.session?.token ?? "") { list in
                list.map { x in
                    guard x.id == id else { return x }
                    var y = x
                    if y.items.contains(conversationID) { y.items.removeAll { $0 == conversationID } }
                    else { y.items.append(conversationID); y.exclude.removeAll { $0 == conversationID } }
                    return y
                }
            }
            await load()
        } catch {
            self.error = NSLocalizedString("settings.failed", comment: "")
        }
    }
}

/// Admin Center › Reports: open reports first; Mark reviewed.
struct AdminReportsView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var status = "open"
    @State private var list: [GroupReport]?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $status) {
                Text("adm.rep.open").tag("open")
                Text("adm.rep.reviewed").tag("reviewed")
                Text("adm.state.all").tag("all")
            }
            .pickerStyle(.segmented)
            if let list {
                if list.isEmpty { Text("adm.rep.none").font(.system(size: 13)).foregroundStyle(Theme.faint) }
                ForEach(list) { r in
                    TFCard {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(r.group_name).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                                Spacer()
                                Text(LocalizedStringKey("report.r." + r.reason)).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.danger)
                                    .padding(.horizontal, 8).padding(.vertical, 3).overlay(Capsule().stroke(Theme.danger.opacity(0.5), lineWidth: 1))
                            }
                            Text(String(format: NSLocalizedString("adm.rep.meta", comment: ""), r.reporter_name, r.group_members, r.open_for_group))
                                .font(.system(size: 12)).foregroundStyle(Theme.faint)
                            if let c = r.comment, !c.isEmpty { Text(c).font(.system(size: 13)).foregroundStyle(Theme.muted) }
                            HStack {
                                Text(AdminFmt.date(r.created_at)).font(.system(size: 11)).foregroundStyle(Theme.faint)
                                if let h = r.group_handle, !h.isEmpty { Text("· /g/" + h).font(.system(size: 11)).foregroundStyle(Theme.accent) }
                                Spacer()
                                if r.status == "open" {
                                    Button("adm.rep.review") { Task { await review(r) } }
                                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                                } else {
                                    Text("adm.rep.reviewed").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.buy)
                                }
                            }
                        }
                        .padding(14)
                    }
                }
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
        .task(id: status) { list = await APIClient.shared.admReports(token: store.session?.token ?? "", status: status) }
    }

    private func review(_ r: GroupReport) async {
        do {
            try await APIClient.shared.admReviewReport(token: store.session?.token ?? "", id: r.id)
            list = await APIClient.shared.admReports(token: store.session?.token ?? "", status: status)
        } catch {
            note = NSLocalizedString("settings.failed", comment: "")
        }
    }
}
