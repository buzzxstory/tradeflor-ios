import Foundation

// Contact info, contacts, Chat Lock and Flash Connect endpoints (desktop/src/shared/api/api.ts).

extension APIClient {
    private static func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? s
    }

    // MARK: identity / contact info

    func ctIdentity(token: String, userID: String) async throws -> IdentityDetail {
        try decode(IdentityDetail.self, try await getJSON("identity/users/\(Self.esc(userID))", token: token))
    }

    func ctLookup(token: String, pin: String? = nil, username: String? = nil) async throws -> IdentityDetail {
        let q = pin != nil ? "pin=\(Self.esc(pin ?? ""))" : "username=\(Self.esc(username ?? ""))"
        return try decode(IdentityDetail.self, try await getJSON("identity/lookup?\(q)", token: token))
    }

    func ctSetRestricted(token: String, conversationID: String, on: Bool) async throws {
        _ = try await postJSON("conversations/settings", token: token, body: ["conversation_id": conversationID, "restricted": on])
    }

    func ctMedia(token: String, conversationID: String, category: String) async throws -> [Message] {
        try await list(Message.self, "conversations/\(conversationID)/media?category=\(category)&limit=60", token: token)
    }

    func ctSetTheme(token: String, conversationID: String, theme: String) async throws {
        _ = try await postJSON("conversations/prefs", token: token,
                               body: ["ConversationID": conversationID, "ChatTheme": theme, "MuteSeconds": 0, "MuteForever": false, "Unmute": false])
    }

    // MARK: contacts

    func ctContacts(token: String) async throws -> [ContactEntry] {
        try await list(ContactEntry.self, "contacts", token: token)
    }

    func ctSentRequests(token: String) async throws -> [SentContactRequest] {
        try await list(SentContactRequest.self, "contacts/requests/sent", token: token)
    }

    func ctConnect(token: String, userID: String) async throws {
        _ = try await postJSON("identity/connect", token: token, body: ["UserID": userID])
    }

    // MARK: Chat Lock

    func ctLockState(token: String) async throws -> LockState {
        try decode(LockState.self, try await getJSON("locks", token: token))
    }

    func ctSetLocked(token: String, conversationID: String, locked: Bool, hidePreviews: Bool) async throws {
        _ = try await postJSON("locks/conversations", token: token,
                               body: ["ConversationID": conversationID, "Locked": locked, "HidePreviews": hidePreviews])
    }

    func ctSetLockPIN(token: String, password: String, pin: String) async throws {
        _ = try await postJSON("locks/pin", token: token, body: ["Password": password, "PIN": pin])
    }

    // MARK: Flash Connect

    func ctMyCode(token: String) async throws -> String {
        struct C: Decodable { let code: String }
        return try decode(C.self, try await getJSON("connect/me", token: token)).code
    }

    func ctRotateCode(token: String) async throws -> String {
        struct C: Decodable { let code: String }
        return try decode(C.self, try await postJSON("connect/me/rotate", token: token, body: [:])).code
    }

    func ctResolveCode(token: String, code: String) async throws -> IdentityDetail {
        try decode(IdentityDetail.self, try await getJSON("connect/u/\(Self.esc(code))", token: token))
    }

    func ctStartMutual(token: String) async throws -> MutualSession {
        try decode(MutualSession.self, try await postJSON("connect/mutual", token: token, body: [:]))
    }

    func ctPeekMutual(token: String, tok: String) async throws -> MutualPeek {
        try decode(MutualPeek.self, try await getJSON("connect/mutual/\(Self.esc(tok))", token: token))
    }

    func ctClaimMutual(token: String, tok: String) async throws -> MutualStatus {
        try decode(MutualStatus.self, try await postJSON("connect/mutual/\(Self.esc(tok))/claim", token: token, body: [:]))
    }

    func ctMutualStatus(token: String, sessionID: String) async throws -> MutualStatus {
        try decode(MutualStatus.self, try await getJSON("connect/sessions/\(Self.esc(sessionID))", token: token))
    }

    func ctDecideMutual(token: String, sessionID: String, accept: Bool) async throws -> MutualStatus {
        try decode(MutualStatus.self, try await postJSON("connect/sessions/\(Self.esc(sessionID))/decide", token: token, body: ["Accept": accept]))
    }

    func ctPendingMutual(token: String) async throws -> [PendingMutual] {
        try await list(PendingMutual.self, "connect/pending", token: token)
    }

    func ctMeetups(token: String) async throws -> [Meetup] {
        try await list(Meetup.self, "connect/meetups", token: token)
    }

    func ctCreateMeetup(token: String, title: String, startsAt: Date) async throws -> Meetup {
        try decode(Meetup.self, try await postJSON("connect/meetups", token: token,
                                                   body: ["Title": title, "StartsAt": Int64(startsAt.timeIntervalSince1970)]))
    }

    func ctMeetupToken(token: String, id: String) async throws -> String {
        struct T: Decodable { let token: String }
        return try decode(T.self, try await postJSON("connect/meetups/\(Self.esc(id))/token", token: token, body: [:])).token
    }

    func ctRevokeMeetup(token: String, id: String) async throws {
        _ = try await postJSON("connect/meetups/\(Self.esc(id))/revoke", token: token, body: [:])
    }

    func ctMeetupPeople(token: String, id: String) async throws -> [IdentityDetail] {
        try await list(IdentityDetail.self, "connect/meetups/\(Self.esc(id))/people", token: token)
    }

    func ctPeekMeetup(token: String, tok: String) async throws -> MeetupPeek {
        try decode(MeetupPeek.self, try await getJSON("connect/meetup-codes/\(Self.esc(tok))", token: token))
    }

    func ctJoinMeetup(token: String, tok: String) async throws -> Meetup {
        try decode(Meetup.self, try await postJSON("connect/meetup-codes/\(Self.esc(tok))/join", token: token, body: [:]))
    }

    func ctLeaveMeetup(token: String, id: String) async throws {
        _ = try await postJSON("connect/meetups/\(Self.esc(id))/leave", token: token, body: [:])
    }

    /// A group invitation link (Group QR). hours 0 = never, maxUses 0 = no limit.
    func ctGroupInvite(token: String, groupID: String, hours: Int, maxUses: Int, approval: Bool) async throws -> String {
        let data = try await postJSON("groups/\(groupID)/invites", token: token,
                                      body: ["ExpiresInHours": hours, "MaxUses": maxUses, "RequireApproval": approval])
        struct I: Decodable { let token: String }
        return "https://app.tradeflor.com/join/" + (try decode(I.self, data).token)
    }

    /// Opens (or creates) the private chat with a contact and returns its summary for navigation.
    func ctOpenChat(token: String, userID: String) async -> ConversationSummary? {
        guard let id = try? await directConversation(token: token, with: userID) else { return nil }
        return ((try? await conversations(token: token)) ?? []).first { $0.conversation_id == id }
    }
}
