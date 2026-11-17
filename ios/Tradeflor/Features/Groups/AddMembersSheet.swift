import SwiftUI

// Add members (website AddMembersSheet.tsx, 19b9c5f): Group Info > More > Add members and the Members tab button. Type
// someone's @username or TRADEFLOR PIN; their card shows as you type (picture, name, @username, PIN, badges); one tap adds them.
// Several in a row, listed under "Added just now". The server decides who may add and who can be added; its answer is shown.

struct AddMembersSheet: View {
    let groupID: String
    let groupName: String
    let memberIDs: Set<String>
    var onAdded: () -> Void = {}
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    @State private var looking = false
    @State private var card: IdentityDetail?
    @State private var none: String?
    @State private var busy = false
    @State private var error: String?
    @State private var added: [IdentityDetail] = []
    @FocusState private var focused: Bool

    private var token: String { store.session?.token ?? "" }
    private var me: String { store.session?.userID ?? "" }
    private var trimmed: String { q.trimmingCharacters(in: .whitespaces) }
    private static func isPin(_ s: String) -> Bool { (3...10).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber } }
    private var username: String { trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "@")).trimmingCharacters(in: .whitespaces) }
    private var already: Bool { card.map { c in memberIDs.contains(c.user_id) || added.contains { $0.user_id == c.user_id } } ?? false }
    private var isSelf: Bool { card?.user_id == me }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text(Self.isPin(trimmed) ? "#" : "@").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.accent).frame(width: 18)
                        TextField("", text: $q, prompt: Text("ams.ph").foregroundColor(Theme.faint))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                            .foregroundStyle(Theme.text).focused($focused).submitLabel(.done)
                            .onSubmit { Task { await add() } }
                            .accessibilityIdentifier("ams.field")
                        if looking { ProgressView().tint(Theme.accent) }
                    }
                    .padding(.horizontal, 14).frame(height: 48)
                    .background(Theme.soulInput, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hex(0x00C8D7, 0.35), lineWidth: 1))
                    .environment(\.layoutDirection, .leftToRight)
                    Text("ams.hint").font(.system(size: 12.5)).foregroundStyle(Theme.faint)

                    if let c = card { result(c) }
                    if let none { Text(none).font(.system(size: 13.5)).foregroundStyle(Theme.faint).padding(.top, 2) }
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.danger) }

                    if !added.isEmpty {
                        Text("ams.added").font(.system(size: 11.5, weight: .bold)).tracking(0.8).textCase(.uppercase)
                            .foregroundStyle(Theme.faint).padding(.top, 8)
                        ForEach(added, id: \.user_id) { a in
                            HStack(spacing: 10) {
                                Avatar(token: token, userID: a.user_id, avatarID: a.avatar_id, title: a.title, size: 34)
                                Text(a.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                Text("@" + a.username).font(.system(size: 12.5)).foregroundStyle(Theme.faint).lineLimit(1)
                                Spacer()
                                Image(systemName: "checkmark").foregroundStyle(Theme.online)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.soul.ignoresSafeArea())
            .navigationTitle(Text("ams.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("ams.title").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                        Text(String(format: NSLocalizedString("ams.to", comment: ""), groupName)).font(.system(size: 11.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("id.done") { dismiss() }.disabled(busy) }
            }
        }
        .tfColorScheme()
        .onAppear { focused = true }
        .task(id: trimmed) { await search() }
    }

    private func result(_ c: IdentityDetail) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Avatar(token: token, userID: c.user_id, avatarID: c.avatar_id, title: c.title, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("@" + c.username).font(.system(size: 13)).foregroundStyle(Theme.faint).lineLimit(1)
                HStack(spacing: 6) {
                    (Text("PIN ").foregroundColor(Theme.gold.opacity(0.8)) + Text(c.pin).foregroundColor(Theme.gold).bold())
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Theme.gold.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(Theme.gold.opacity(0.4), lineWidth: 1))
                        .environment(\.layoutDirection, .leftToRight)
                    let cls = c.pin_class ?? ""
                    if !cls.isEmpty { badge(LocalizedStringKey("id.class." + cls), IdentityCardFace.classIcon(cls)) }
                    if c.early_member == true { badge("set.early", "star") }
                }
            }
            Spacer(minLength: 4)
            Button { Task { await add() } } label: {
                Group {
                    if busy { ProgressView().tint(Theme.onAccent) }
                    else { Text(LocalizedStringKey(isSelf ? "ams.you" : already ? "ams.in" : "ams.add")) }
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isSelf || already ? Theme.faint : Theme.onAccent)
                .padding(.horizontal, 16).frame(height: 36)
                .background(isSelf || already ? AnyShapeStyle(Theme.chip) : AnyShapeStyle(Theme.accent), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy || already || isSelf)
            .accessibilityIdentifier("ams.add")
        }
        .padding(14)
        .background(Theme.soulCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.soulCardBorder, lineWidth: 1))
    }

    private func badge(_ key: LocalizedStringKey, _ icon: String) -> some View {
        Label(key, systemImage: icon).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accent)
            .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.accent.opacity(0.10), in: Capsule())
            .lineLimit(1)
    }

    private func search() async {
        let t = trimmed
        error = nil
        guard !t.isEmpty, Self.isPin(t) || username.count >= 3 else { card = nil; none = nil; looking = false; return }
        looking = true
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        let pin = Self.isPin(t)
        let found = try? await APIClient.shared.ctLookup(token: token, pin: pin ? t : nil, username: pin ? nil : username)
        if Task.isCancelled { return }
        looking = false
        card = found
        none = found == nil ? (pin ? String(format: NSLocalizedString("ams.none.pin", comment: ""), t)
                                   : String(format: NSLocalizedString("ams.none.user", comment: ""), username)) : nil
    }

    private func add() async {
        guard let c = card, !busy, !already, !isSelf else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await APIClient.shared.grpAddMember(token: token, id: groupID, username: c.username)
            added.insert(c, at: 0)
            q = ""
            card = nil
            none = nil
            focused = true
            onAdded()
        } catch APIError.refused(let why) {
            error = why.isEmpty ? NSLocalizedString("ams.failed", comment: "") : why
        } catch {
            self.error = NSLocalizedString("ams.failed", comment: "")
        }
    }
}
