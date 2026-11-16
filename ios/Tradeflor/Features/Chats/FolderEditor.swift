import SwiftUI

/// Smart Folders editing (folders/FolderEditor.tsx, ManageFolders.tsx): name, icon, colour, smart rules, chats in /
/// kept out, templates, reorder and remove. Saved with the server's version (409 = another device saved first:
/// reload and try again).
struct EditableFolder: Identifiable, Equatable {
    var id: String
    var name: String
    var items: [String]
    var exclude: [String]
    var icon: String
    var color: String
    var rulesOn: Bool
    var matchAll: Bool
    var conditions: [EditableCondition]

    func json() -> [String: Any] {
        var o: [String: Any] = ["id": id, "name": name, "items": items, "exclude": exclude, "icon": icon, "color": color]
        if !conditions.isEmpty || rulesOn {
            o["rules"] = ["on": rulesOn, "match": matchAll ? "all" : "any",
                          "conditions": conditions.map { $0.json() }]
        } else {
            o["rules"] = NSNull()
        }
        return o
    }
}

struct EditableCondition: Identifiable, Equatable {
    var id = UUID()
    var type: String // kind | name_contains | in_list | unread | muted | pinned
    var value: String
    var values: [String]
    var enabled: Bool

    func json() -> [String: Any] {
        var o: [String: Any] = ["type": type, "enabled": enabled]
        if ["kind", "unread", "muted", "pinned"].contains(type) { o["value"] = value }
        if ["name_contains", "in_list"].contains(type) { o["values"] = values }
        return o
    }
}

enum FolderStore {
    struct RawCondition: Decodable { let type: String; let value: String?; let values: [String]?; let enabled: Bool? }
    struct RawRules: Decodable { let on: Bool?; let match: String?; let conditions: [RawCondition]? }
    struct RawFolder: Decodable {
        let id: String; let name: String; let items: [String]?; let exclude: [String]?
        let icon: String?; let color: String?; let rules: RawRules?
    }
    struct Doc: Decodable { let version: Int?; let folders: [RawFolder]? }

    static func load(token: String) async throws -> (Int, [EditableFolder]) {
        let d = try JSONDecoder().decode(Doc.self, from: try await APIClient.shared.getJSON("folders?v=2", token: token))
        var list: [EditableFolder] = []
        for f in d.folders ?? [] {
            var conds: [EditableCondition] = []
            for c in f.rules?.conditions ?? [] {
                conds.append(EditableCondition(type: c.type, value: c.value ?? "", values: c.values ?? [], enabled: c.enabled ?? true))
            }
            let match: String = f.rules?.match ?? "all"
            let rulesOn: Bool = f.rules?.on ?? false
            list.append(EditableFolder(id: f.id, name: f.name, items: f.items ?? [], exclude: f.exclude ?? [], icon: f.icon ?? "",
                                       color: f.color ?? "", rulesOn: rulesOn, matchAll: match == "all", conditions: conds))
        }
        return (d.version ?? 0, list)
    }

    /// Saves the whole list; on a conflict reloads the server copy, re-applies `change`, and saves once more.
    static func save(token: String, change: ([EditableFolder]) -> [EditableFolder]) async throws {
        for _ in 0..<2 {
            let (v, current) = try await load(token: token)
            let next = change(current)
            var req = APIClient.shared.request("folders", method: "POST", token: token,
                                               body: ["base_version": v, "folders": next.map { $0.json() }])
            req.timeoutInterval = 20
            let (data, http) = try await APIClient.shared.send(req)
            if http.statusCode == 409 { continue }
            if http.statusCode == 400 {
                throw APIError.refused(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            }
            try APIClient.shared.check(http, data)
            return
        }
        throw APIError.refused(NSLocalizedString("folder.conflict", comment: ""))
    }

    static let icons = ["folder", "chart", "briefcase", "people", "star", "bell", "bolt", "heart", "globe"]
    static let colors = ["turquoise", "blue", "purple", "orange", "pink", "gold"]

    static func symbol(_ icon: String) -> String {
        switch icon {
        case "chart": return "chart.line.uptrend.xyaxis"
        case "briefcase": return "briefcase"
        case "people": return "person.2"
        case "star": return "star"
        case "bell": return "bell"
        case "bolt": return "bolt"
        case "heart": return "heart"
        case "globe": return "globe"
        default: return "folder"
        }
    }

    static func color(_ c: String) -> Color {
        switch c {
        case "blue": return Theme.hex(0x3B82F6)
        case "purple": return Theme.hex(0x8F6BFF)
        case "orange": return Theme.hex(0xFF9F43)
        case "pink": return Theme.hex(0xFF7A93)
        case "gold": return Theme.gold
        case "turquoise": return Theme.accent
        default: return Theme.gold
        }
    }
}

struct FolderEditorView: View {
    let token: String
    let chats: [ConversationSummary]
    var editing: EditableFolder? = nil
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var f = EditableFolder(id: "", name: "", items: [], exclude: [], icon: "folder", color: "turquoise",
                                          rulesOn: false, matchAll: false, conditions: [])
    @State private var word = ""
    @State private var find = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if editing == nil {
                    Section(header: Text("folder.start")) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                template("folder.tpl.trading", "chart", "turquoise",
                                         [EditableCondition(type: "name_contains", value: "", values: ["Gold", "XAU", "Forex", "Trading", "Signals", "Crypto"], enabled: true)])
                                template("folder.tpl.work", "briefcase", "orange", [])
                                template("folder.tpl.friends", "people", "blue",
                                         [EditableCondition(type: "kind", value: "direct", values: [], enabled: true)])
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
                Section(header: Text("folder.name")) {
                    TextField("folder.name.ph", text: $f.name).onChange(of: f.name) { v in f.name = String(v.prefix(24)) }
                    HStack {
                        ForEach(FolderStore.icons, id: \.self) { i in
                            Image(systemName: FolderStore.symbol(i)).foregroundStyle(f.icon == i ? Theme.onAccent : Theme.muted)
                                .frame(width: 30, height: 30).background(f.icon == i ? Theme.accent : Theme.chip, in: Circle())
                                .onTapGesture { f.icon = i }
                        }
                    }
                    HStack {
                        ForEach(FolderStore.colors, id: \.self) { c in
                            Circle().fill(FolderStore.color(c)).frame(width: 26, height: 26)
                                .overlay(Circle().stroke(.white, lineWidth: f.color == c ? 2 : 0))
                                .onTapGesture { f.color = c }
                        }
                    }
                }
                .listRowBackground(Theme.surface)
                Section(header: Text("folder.smart"), footer: Text("folder.smart.note")) {
                    Toggle("folder.smart", isOn: $f.rulesOn).tint(Theme.accent)
                    if f.rulesOn {
                        Picker("folder.match", selection: $f.matchAll) {
                            Text("folder.any").tag(false)
                            Text("folder.all").tag(true)
                        }
                        .pickerStyle(.segmented)
                        ForEach($f.conditions) { $c in conditionRow($c) }
                        Menu {
                            ForEach(["kind", "name_contains", "unread", "muted", "pinned"], id: \.self) { t in
                                Button(LocalizedStringKey("folder.cond." + t)) {
                                    f.conditions.append(EditableCondition(type: t, value: t == "kind" ? "direct" : "yes", values: [], enabled: true))
                                }
                            }
                        } label: { Label("folder.choose", systemImage: "plus") }
                    }
                }
                .listRowBackground(Theme.surface)
                Section(header: Text("folder.in")) {
                    TextField("folder.find", text: $find)
                    ForEach(chats.filter { find.isEmpty || $0.title.localizedCaseInsensitiveContains(find) }) { c in
                        HStack {
                            Text(c.title).foregroundStyle(Theme.text)
                            Spacer()
                            if f.exclude.contains(c.conversation_id) {
                                Button("folder.allow") { f.exclude.removeAll { $0 == c.conversation_id } }.foregroundStyle(Theme.accent)
                            } else if f.items.contains(c.conversation_id) {
                                Button("folder.remove.chat") { f.items.removeAll { $0 == c.conversation_id } }.foregroundStyle(Theme.danger)
                            } else {
                                Button("folder.add") { f.items.append(c.conversation_id) }.foregroundStyle(Theme.accent)
                                Button("folder.keepout") { f.exclude.append(c.conversation_id) }.foregroundStyle(Theme.faint)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .listRowBackground(Theme.surface)
                if let error { Section { Text(error).foregroundStyle(Theme.danger) }.listRowBackground(Theme.surface) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text(LocalizedStringKey(editing == nil ? "folder.new" : "folder.edit")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button(LocalizedStringKey(editing == nil ? "folder.create" : "settings.save")) { Task { await save() } }
                            .bold().disabled(f.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .tfColorScheme()
        .onAppear { if let editing { f = editing } }
    }

    private func template(_ key: String, _ icon: String, _ color: String, _ conds: [EditableCondition]) -> some View {
        Button {
            f.name = NSLocalizedString(key, comment: "")
            f.icon = icon
            f.color = color
            f.conditions = conds
            f.rulesOn = !conds.isEmpty
        } label: {
            Label(LocalizedStringKey(key), systemImage: FolderStore.symbol(icon)).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FolderStore.color(color)).padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func conditionRow(_ c: Binding<EditableCondition>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(LocalizedStringKey("folder.cond." + c.wrappedValue.type), isOn: c.enabled).tint(Theme.accent)
                Button { f.conditions.removeAll { $0.id == c.wrappedValue.id } } label: { Image(systemName: "trash").foregroundStyle(Theme.danger) }
                    .buttonStyle(.borderless)
            }
            switch c.wrappedValue.type {
            case "kind":
                Picker("", selection: c.value) {
                    Text("folder.kind.direct").tag("direct")
                    Text("folder.kind.group").tag("group")
                }
                .pickerStyle(.segmented)
            case "name_contains":
                Text(c.wrappedValue.values.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.muted)
                HStack {
                    TextField("folder.word", text: $word)
                    Button("folder.add") {
                        let w = word.trimmingCharacters(in: .whitespaces)
                        if !w.isEmpty && c.wrappedValue.values.count < 12 { c.wrappedValue.values.append(String(w.prefix(32))) }
                        word = ""
                    }
                    .buttonStyle(.borderless)
                }
            default:
                Picker("", selection: c.value) {
                    Text(LocalizedStringKey("folder.yes." + c.wrappedValue.type)).tag("yes")
                    Text(LocalizedStringKey("folder.no." + c.wrappedValue.type)).tag("no")
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func save() async {
        busy = true
        error = nil
        defer { busy = false }
        var out = f
        if out.id.isEmpty { out.id = "f" + String(UUID().uuidString.prefix(8)).lowercased() }
        do {
            try await FolderStore.save(token: token) { current in
                var list = current
                if let i = list.firstIndex(where: { $0.id == out.id }) { list[i] = out } else { list.append(out) }
                return Array(list.prefix(10))
            }
            onSaved()
            dismiss()
        } catch APIError.refused(let why) {
            error = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
        } catch {
            self.error = NSLocalizedString("settings.failed", comment: "")
        }
    }
}

struct ManageFoldersView: View {
    let token: String
    let chats: [ConversationSummary]
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [EditableFolder] = []
    @State private var editing: EditableFolder?
    @State private var creating = false
    @State private var removing: EditableFolder?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(NSLocalizedString("folders.all", comment: ""), NSLocalizedString("folder.always.first", comment: ""))
                    row(NSLocalizedString("folders.unread", comment: ""), NSLocalizedString("folder.always.there", comment: ""))
                }
                .listRowBackground(Theme.surface)
                Section {
                    ForEach(folders) { f in
                        HStack {
                            Image(systemName: FolderStore.symbol(f.icon)).foregroundStyle(FolderStore.color(f.color))
                            Text(f.name + (f.rulesOn ? " · smart" : "")).foregroundStyle(Theme.text)
                            Spacer()
                            Button("folder.edit.short") { editing = f }.foregroundStyle(Theme.accent).buttonStyle(.borderless)
                            Button("folder.remove") { removing = f }.foregroundStyle(Theme.danger).buttonStyle(.borderless)
                        }
                    }
                    .onMove { from, to in
                        folders.move(fromOffsets: from, toOffset: to)
                        let order = folders.map(\.id)
                        Task {
                            try? await FolderStore.save(token: token) { cur in order.compactMap { id in cur.first { $0.id == id } } }
                            onChanged()
                        }
                    }
                    Button { creating = true } label: { Label("folder.new", systemImage: "plus") }.disabled(folders.count >= 10)
                }
                .listRowBackground(Theme.surface)
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("folder.manage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("chat.done") { dismiss() } } }
            .sheet(item: $editing) { f in FolderEditorView(token: token, chats: chats, editing: f) { Task { await reload() } } }
            .sheet(isPresented: $creating) { FolderEditorView(token: token, chats: chats) { Task { await reload() } } }
            .confirmationDialog(Text("folder.remove.title"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("folder.remove", role: .destructive) {
                    if let r = removing {
                        Task {
                            try? await FolderStore.save(token: token) { $0.filter { $0.id != r.id } }
                            await reload()
                        }
                    }
                }
            } message: { Text("folder.remove.note") }
        }
        .tfColorScheme()
        .task { await reload() }
    }

    private func row(_ title: String, _ sub: String) -> some View {
        HStack { Text(title).foregroundStyle(Theme.text); Spacer(); Text(sub).font(.caption).foregroundStyle(Theme.faint) }
    }

    private func reload() async {
        if let r = try? await FolderStore.load(token: token) { folders = r.1 }
        onChanged()
    }
}
