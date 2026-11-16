import SwiftUI

/// Contact info for a private chat: profile, disappearing messages (24 h / 7 d / 90 d), mute, shared photos, block.
struct ContactInfoView: View {
    let chat: ConversationSummary
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile: Profile?
    @State private var disappear = 0
    @State private var muted = false
    @State private var media: [Message] = []
    @State private var viewing: ViewedPhoto?
    @State private var problem: String?
    @State private var confirmBlock = false

    private var token: String { store.session?.token ?? "" }
    static let timers = [0, 86400, 604800, 7776000]
    static func timerKey(_ v: Int) -> String {
        switch v {
        case 86400: return "info.disappear.24h"
        case 604800: return "info.disappear.7d"
        case 7776000: return "info.disappear.90d"
        default: return "info.disappear.off"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Avatar(token: token, userID: chat.peer_id, avatarID: profile?.avatar_id ?? chat.peer_avatar_id, title: chat.title)
                            .scaleEffect(1.8).frame(width: 96, height: 96)
                        Text(profile.map { $0.display_name.isEmpty ? $0.username : $0.display_name } ?? chat.title)
                            .font(.title2.weight(.semibold)).foregroundStyle(.white)
                        Text("@" + (profile?.username ?? chat.peer_username)).foregroundStyle(Theme.accent)
                        if let bio = profile?.bio, !bio.isEmpty {
                            Text(bio).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Theme.surface)

                Section(footer: Text("info.disappear.footer")) {
                    Picker(selection: $disappear) {
                        ForEach(Self.timers, id: \.self) { v in Text(LocalizedStringKey(Self.timerKey(v))).tag(v) }
                    } label: {
                        Label("info.disappear", systemImage: "timer")
                    }
                    .onChange(of: disappear) { v in Task { await setTimer(v) } }
                    Toggle(isOn: $muted) { Label("info.mute", systemImage: "bell.slash") }
                        .tint(Theme.accent)
                        .onChange(of: muted) { v in Task { try? await APIClient.shared.setMuted(token: token, conversationID: chat.conversation_id, muted: v) } }
                }
                .listRowBackground(Theme.surface)

                if !media.isEmpty {
                    Section(header: Text("info.media")) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                            ForEach(media.filter { $0.kind == "image" && $0.file_id != nil }) { m in
                                RemoteImage(token: token, fileID: m.file_id ?? "")
                                    .frame(height: 100)
                                    .clipped()
                                    .contentShape(Rectangle())
                                    .onTapGesture { viewing = ViewedPhoto(id: m.file_id ?? "") }
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                }

                Section {
                    Button(role: .destructive) { confirmBlock = true } label: { Label("chat.block", systemImage: "hand.raised.fill") }
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("info.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
            .fullScreenCover(item: $viewing) { v in PhotoViewer(token: token, fileID: v.id) }
            .confirmationDialog(Text(String(format: NSLocalizedString("chat.block.confirm", comment: ""), chat.title)),
                                isPresented: $confirmBlock, titleVisibility: .visible) {
                Button("chat.block", role: .destructive) {
                    Task {
                        do { try await APIClient.shared.block(token: token, userID: chat.peer_id); dismiss() } catch {
                            problem = NSLocalizedString("chat.action.failed", comment: "")
                        }
                    }
                }
            }
            .alert(Text(problem ?? ""), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("chat.close", role: .cancel) {}
            }
        }
        .task {
            profile = try? await APIClient.shared.userProfile(token: token, userID: chat.peer_id)
            if let s = try? await APIClient.shared.chatSettings(token: token, conversationID: chat.conversation_id) { disappear = s.disappear_secs }
            media = (try? await APIClient.shared.sharedMedia(token: token, conversationID: chat.conversation_id)) ?? []
        }
    }

    private func setTimer(_ v: Int) async {
        do { try await APIClient.shared.setDisappearing(token: token, conversationID: chat.conversation_id, seconds: v) } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why
        } catch {
            problem = NSLocalizedString("chat.action.failed", comment: "")
        }
    }
}

/// Schedule a text message for later (once, daily or weekly), and see / cancel / send now the ones already planned.
struct ScheduleSheet: View {
    let chat: ConversationSummary
    let initialText: String
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var when = Date().addingTimeInterval(3600)
    @State private var repeatRule = "none"
    @State private var items: [ScheduledMessage] = []
    @State private var busy = false
    @State private var error: String?

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("chat.placeholder", text: $text, axis: .vertical).lineLimit(2...6)
                    DatePicker("schedule.when", selection: $when, in: Date().addingTimeInterval(90)...Date().addingTimeInterval(365 * 86400))
                    Picker("schedule.repeat", selection: $repeatRule) {
                        Text("schedule.once").tag("none")
                        Text("schedule.daily").tag("daily")
                        Text("schedule.weekly").tag("weekly")
                    }
                    Button { Task { await add() } } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("schedule.add").bold() }; Spacer() }
                    }
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .listRowBackground(Theme.surface)
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) }.listRowBackground(Theme.surface) }
                if !items.isEmpty {
                    Section(header: Text("schedule.list")) {
                        ForEach(items) { s in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.body).foregroundStyle(.white).lineLimit(2)
                                HStack {
                                    Text(s.date, style: .date)
                                    Text(s.date, style: .time)
                                    if let r = s.repeat_rule, r != "none" { Text(LocalizedStringKey("schedule." + r)) }
                                    Spacer()
                                    Text(LocalizedStringKey("schedule.status." + s.status)).foregroundStyle(Theme.accent)
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                if s.status == "pending" || s.status == "failed" {
                                    Button(role: .destructive) { Task { await act { try await APIClient.shared.cancelScheduled(token: token, id: s.id) } } } label: {
                                        Label("schedule.cancel", systemImage: "xmark")
                                    }
                                    Button { Task { await act { try await APIClient.shared.sendScheduledNow(token: token, id: s.id) } } } label: {
                                        Label("schedule.now", systemImage: "paperplane")
                                    }
                                    .tint(Theme.accent)
                                }
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("schedule.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .task {
            text = initialText
            await reload()
        }
    }

    private func reload() async {
        items = (try? await APIClient.shared.scheduled(token: token, conversationID: chat.conversation_id)) ?? items
    }

    private func act(_ work: () async throws -> Void) async {
        do { try await work() } catch APIError.refused(let why) { error = why } catch {
            self.error = NSLocalizedString("chat.action.failed", comment: "")
        }
        await reload()
    }

    private func add() async {
        busy = true
        error = nil
        defer { busy = false }
        await act {
            try await APIClient.shared.schedule(token: token, conversationID: chat.conversation_id,
                                                body: text.trimmingCharacters(in: .whitespacesAndNewlines), at: when, repeatRule: repeatRule)
            text = ""
        }
    }
}
