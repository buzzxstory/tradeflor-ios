import SwiftUI

/// A group member's Contact info (website ContactInfo.tsx opened from a group, like Telegram): picture, name, @username,
/// presence; Message, Voice, Add contact, Share; About; the TRADEFLOR PIN with its badges; Share contact.
struct MemberProfileRef: Identifiable {
    let userID: String
    let username: String
    var id: String { userID }
}

struct MemberProfileSheet: View {
    let member: MemberProfileRef
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var calls = CallManager.shared
    @State private var card: IdentityDetail?
    @State private var profile: Profile?
    @State private var contact = "unknown" // unknown | yes | no | busy | sent
    @State private var note: String?
    @State private var viewing = false

    private var token: String { store.session?.token ?? "" }
    private var name: String { profile.map { $0.display_name.isEmpty ? $0.username : $0.display_name } ?? card?.title ?? member.username }
    private var avatarID: String? {
        if let a = profile?.avatar_id, !a.isEmpty { return a }
        if let a = card?.avatar_id, !a.isEmpty { return a }
        return nil
    }
    private var shareLink: String { "https://app.tradeflor.com/?id=\(card?.pin ?? "")" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        Avatar(token: token, userID: member.userID, avatarID: avatarID, title: name, size: 112)
                            .padding(4)
                            .overlay(Circle().stroke(Theme.accent, lineWidth: 2.5))
                            .onTapGesture { if avatarID != nil { viewing = true } }
                        Text(name).font(.system(size: 24, weight: .heavy)).foregroundStyle(Theme.text).padding(.top, 6)
                        Text("@" + member.username).font(.system(size: 15)).foregroundStyle(Theme.muted)
                        HStack(spacing: 5) {
                            Circle().fill(live.online.contains(member.userID) ? Theme.online : Theme.faint).frame(width: 7, height: 7)
                            Text(LocalizedStringKey(live.online.contains(member.userID) ? "chat.online" : "ci.lastseen.recently"))
                                .font(.system(size: 13)).foregroundStyle(Theme.faint)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)

                    HStack(spacing: 10) {
                        quick("text.bubble", "ci.message") { Task { await message() } }
                        if calls.enabled {
                            quick("phone", "ci.voice") { Task { await voice() } }
                        }
                        if contact != "unknown" {
                            quick(contact == "yes" || contact == "sent" ? "checkmark" : "person.badge.plus",
                                  contact == "yes" ? "ci.contact" : (contact == "sent" ? "ci.requested" : (contact == "busy" ? "ci.sending" : "ci.addcontact"))) {
                                Task { await addContact() }
                            }
                            .disabled(contact != "no")
                        }
                        ShareLink(item: shareLink) { quickLabel("square.and.arrow.up", "ci.share") }
                            .buttonStyle(.plain)
                    }

                    if let bio = profile?.bio, !bio.isEmpty {
                        TFCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("ci.about").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint)
                                Text(bio).font(.system(size: 15)).foregroundStyle(Theme.text)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        }
                    }

                    if let c = card {
                        TFCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 10) {
                                    Image(systemName: "person").foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("TRADEFLOR PIN").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                        if let since = c.member_since, since > 0 {
                                            Text(String(format: NSLocalizedString("ci.member.since", comment: ""), String(since)))
                                                .font(.system(size: 12)).foregroundStyle(Theme.faint)
                                        }
                                    }
                                    Spacer()
                                    Text(c.pin).font(.system(size: 24, weight: .heavy, design: .rounded).monospacedDigit()).foregroundStyle(Theme.text)
                                        .environment(\.layoutDirection, .leftToRight)
                                    Button {
                                        UIPasteboard.general.string = c.pin
                                        flash("set.copied.pin")
                                    } label: { Image(systemName: "doc.on.doc").foregroundStyle(Theme.muted) }
                                    .accessibilityLabel(Text("set.copy.pin"))
                                }
                                let cls = c.pin_class ?? ""
                                if !cls.isEmpty || c.early_member == true {
                                    HStack(spacing: 6) {
                                        if !cls.isEmpty { badge(LocalizedStringKey("id.class." + cls), IdentityCardFace.classIcon(cls)) }
                                        if c.early_member == true { badge("set.early", "star") }
                                    }
                                }
                            }
                            .padding(14)
                        }
                    }

                    ShareLink(item: shareLink, message: Text(String(format: NSLocalizedString("ci.share.msg", comment: ""), name))) {
                        HStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.up")
                            Text("ci.share.contact").font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(14)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.accent) }
                }
                .padding(16)
            }
            .background(Theme.panelGradient.ignoresSafeArea())
            .navigationTitle(Text("ci.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .tfColorScheme()
        .task { await load() }
        .fullScreenCover(isPresented: $viewing) {
            AvatarViewer(token: token, userID: member.userID, avatarID: avatarID ?? "")
        }
    }

    private func quickLabel(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 54, height: 54).background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderActive, lineWidth: 1))
            Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func quick(_ icon: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { quickLabel(icon, title) }.buttonStyle(.plain)
    }

    private func badge(_ title: LocalizedStringKey, _ icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 4).overlay(Capsule().stroke(Theme.borderActive, lineWidth: 1))
    }

    private func load() async {
        async let c = try? APIClient.shared.ctIdentity(token: token, userID: member.userID)
        async let p: Profile? = {
            guard let d = try? await APIClient.shared.getJSON("users/\(member.userID)/profile", token: token) else { return nil }
            return try? JSONDecoder().decode(Profile.self, from: d)
        }()
        async let list = try? APIClient.shared.ctContacts(token: token)
        card = await c
        profile = await p
        if let l = await list {
            contact = l.contains { $0.user_id == member.userID } ? "yes" : (card?.relation == "outgoing" ? "sent" : "no")
        }
    }

    private func message() async {
        guard let chat = await APIClient.shared.ctOpenChat(token: token, userID: member.userID) else { flash("ci.failed"); return }
        dismiss()
        LocalNotifier.shared.tappedConversation = chat.conversation_id
    }

    private func voice() async {
        guard let chat = await APIClient.shared.ctOpenChat(token: token, userID: member.userID) else { flash("ci.call.failed"); return }
        calls.start(conversationID: chat.conversation_id, peerName: name, peerID: member.userID)
    }

    private func addContact() async {
        contact = "busy"
        do {
            try await APIClient.shared.ctConnect(token: token, userID: member.userID)
            contact = "sent"
            flash("ci.request.sent")
        } catch APIError.refused(let why) {
            contact = "no"
            note = why.isEmpty ? NSLocalizedString("ci.request.failed", comment: "") : why
        } catch {
            contact = "no"
            flash("ci.request.failed")
        }
    }

    private func flash(_ key: String) {
        note = NSLocalizedString(key, comment: "")
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); note = nil }
    }
}
