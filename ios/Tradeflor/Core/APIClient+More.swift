import Foundation

// Endpoints for groups management, contact info, scheduled messages, live location, folders, the TRADEFLOR Official
// channel and the economic calendar. Shapes mirror desktop/src/shared/api/api.ts and types.ts.

extension APIClient {
    /// Authenticated JSON POST; 400/403/404/409/413/415 bodies are the server's readable text.
    func postJSON(_ path: String, token: String, body: [String: Any], key: String? = nil) async throws -> Data {
        var req = request(path, method: "POST", token: token, body: body)
        if let key { req.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        let (data, http) = try await send(req)
        if [400, 403, 404, 409, 413, 415].contains(http.statusCode) {
            throw APIError.refused(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        try check(http, data)
        return data
    }

    func decode<T: Decodable>(_ t: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw APIError.decoding }
    }

    func list<T: Decodable>(_ t: T.Type, _ path: String, token: String) async throws -> [T] {
        let data = try await getJSON(path, token: token)
        if data.isEmpty || data == Data("null".utf8) { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    // MARK: groups management

    func createGroup(token: String, name: String, description: String, isPublic: Bool, memberIDs: [String]) async throws -> String {
        let data = try await postJSON("groups", token: token,
                                      body: ["Name": name, "Description": description, "Privacy": isPublic ? "public" : "private",
                                             "MemberIDs": memberIDs], key: UUID().uuidString.lowercased())
        struct G: Decodable { let conversation_id: String }
        return try decode(G.self, data).conversation_id
    }

    func groupInfo(token: String, id: String) async throws -> GroupDetail {
        try decode(GroupDetail.self, try await getJSON("groups/\(id)", token: token))
    }

    func updateGroup(token: String, id: String, name: String, description: String) async throws {
        _ = try await postJSON("groups/\(id)/update", token: token, body: ["Name": name, "Description": description])
    }

    func addGroupMember(token: String, id: String, username: String) async throws {
        _ = try await postJSON("groups/\(id)/members", token: token,
                               body: ["Username": username.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))])
    }

    func removeGroupMember(token: String, id: String, userID: String) async throws {
        _ = try await postJSON("groups/\(id)/members/remove", token: token, body: ["UserID": userID])
    }

    func setGroupRole(token: String, id: String, userID: String, admin: Bool) async throws {
        _ = try await postJSON("groups/\(id)/members/role", token: token, body: ["UserID": userID, "Role": admin ? "admin" : "member"])
    }

    /// Returns the share link (the token is only ever returned here).
    func createInvite(token: String, id: String) async throws -> String {
        let data = try await postJSON("groups/\(id)/invites", token: token,
                                      body: ["ExpiresInHours": 0, "MaxUses": 0, "RequireApproval": false])
        struct I: Decodable { let token: String }
        return "https://app.tradeflor.com/join/" + (try decode(I.self, data).token)
    }

    /// Joins by an invite link (.../join/<token>) or a permanent link (.../g/<handle>). Empty id = waiting for approval.
    func joinGroup(token: String, link: String) async throws -> String {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if let r = s.range(of: "/g/") {
            path = "group-links/\(String(s[r.upperBound...]).split(separator: "/").first ?? "")/join"
        } else if let r = s.range(of: "/join/") {
            path = "group-invites/\(String(s[r.upperBound...]).split(separator: "/").first ?? "")/join"
        } else {
            path = "group-invites/\(s)/join"
        }
        struct J: Decodable { let conversation_id: String }
        return try decode(J.self, try await postJSON(path, token: token, body: [:])).conversation_id
    }

    // MARK: contact info and chat settings

    func userProfile(token: String, userID: String) async throws -> Profile {
        try decode(Profile.self, try await getJSON("users/\(userID)/profile", token: token))
    }

    func chatSettings(token: String, conversationID: String) async throws -> ChatSettings {
        try decode(ChatSettings.self, try await getJSON("conversations/settings?conversation_id=\(conversationID)", token: token))
    }

    func setDisappearing(token: String, conversationID: String, seconds: Int) async throws {
        _ = try await postJSON("conversations/settings", token: token,
                               body: ["conversation_id": conversationID, "disappear_secs": seconds])
    }

    func setMuted(token: String, conversationID: String, muted: Bool) async throws {
        let body: [String: Any] = muted
            ? ["ConversationID": conversationID, "MuteForever": true, "MuteSeconds": 0, "Unmute": false]
            : ["ConversationID": conversationID, "Unmute": true, "MuteSeconds": 0, "MuteForever": false]
        _ = try await postJSON("conversations/prefs", token: token, body: body)
    }

    func sharedMedia(token: String, conversationID: String) async throws -> [Message] {
        try await list(Message.self, "conversations/\(conversationID)/media?category=media&limit=60", token: token)
    }

    // MARK: scheduled messages

    func scheduled(token: String, conversationID: String) async throws -> [ScheduledMessage] {
        try await list(ScheduledMessage.self, "scheduled?conversation_id=\(conversationID)", token: token)
    }

    func schedule(token: String, conversationID: String, body: String, at date: Date, repeatRule: String) async throws {
        _ = try await postJSON("scheduled", token: token,
                               body: ["ConversationID": conversationID, "Body": body, "SendAt": Int64(date.timeIntervalSince1970),
                                      "TimeZone": TimeZone.current.identifier, "Repeat": repeatRule])
    }

    func cancelScheduled(token: String, id: String) async throws {
        _ = try await postJSON("scheduled/\(id)/cancel", token: token, body: [:])
    }

    func sendScheduledNow(token: String, id: String) async throws {
        _ = try await postJSON("scheduled/\(id)/send-now", token: token, body: [:])
    }

    // MARK: live location

    func startLocation(token: String, conversationID: String, minutes: Int, lat: Double, lon: Double, accuracy: Double) async throws {
        _ = try await postJSON("location/start", token: token,
                               body: ["conversation_id": conversationID, "minutes": minutes, "lat": lat, "lon": lon, "accuracy": accuracy])
    }

    /// false when the share is over (409 or gone): stop sending.
    func updateLocation(token: String, conversationID: String, lat: Double, lon: Double, accuracy: Double) async -> Bool {
        do {
            _ = try await postJSON("location/update", token: token,
                                   body: ["conversation_id": conversationID, "lat": lat, "lon": lon, "accuracy": accuracy])
            return true
        } catch APIError.refused(_) {
            return false
        } catch {
            return true
        }
    }

    func stopLocation(token: String, conversationID: String) async {
        _ = try? await postJSON("location/stop", token: token, body: ["conversation_id": conversationID])
    }

    func livePositions(token: String, conversationID: String) async -> [LivePosition] {
        (try? await list(LivePosition.self, "location/live?conversation_id=\(conversationID)", token: token)) ?? []
    }

    // MARK: folders

    func folders(token: String) async throws -> [ChatFolder] {
        struct Doc: Decodable { let folders: [ChatFolder]? }
        return (try decode(Doc.self, try await getJSON("folders?v=2", token: token))).folders ?? []
    }

    // MARK: TRADEFLOR Official

    func official(token: String) async throws -> OfficialChannel {
        try decode(OfficialChannel.self, try await getJSON("official/status", token: token))
    }

    func officialSeen(token: String, id: String) async {
        _ = try? await postJSON("official/\(id)/seen", token: token, body: [:])
    }

    // MARK: calendar

    func calendar(token: String, from: Date, to: Date) async throws -> [CalendarEvent] {
        let f = ISO8601DateFormatter()
        struct Out: Decodable { let events: [CalendarEvent]? }
        let data = try await getJSON("calendar/events?from=\(f.string(from: from))&to=\(f.string(from: to))", token: token)
        return (try decode(Out.self, data)).events ?? []
    }

    func savedEvents(token: String) async throws -> [SavedEvent] {
        try await list(SavedEvent.self, "calendar/saved", token: token)
    }

    func saveEvent(token: String, _ e: CalendarEvent) async throws {
        _ = try await postJSON("calendar/saved", token: token,
                               body: ["event_key": e.id, "title": String(e.event.prefix(140)), "currency": e.currency,
                                      "country_code": e.country_code, "impact": e.impact,
                                      "event_at": Int64((e.date ?? Date()).timeIntervalSince1970), "remind_minutes": 15])
    }

    func removeSavedEvent(token: String, key: String) async throws {
        _ = try await postJSON("calendar/saved/remove", token: token, body: ["event_key": key])
    }
}

extension APIClient {
    func prefs(token: String) async throws -> [ConversationPrefs] {
        struct Out: Decodable { let conversations: [ConversationPrefs]? }
        return (try decode(Out.self, try await getJSON("prefs", token: token))).conversations ?? []
    }

    /// One change to a chat's preferences. Mute: seconds > 0, forever, or unmute.
    func setPrefs(token: String, conversationID: String, pinned: Bool? = nil, archived: Bool? = nil, markedUnread: Bool? = nil,
                  muteSeconds: Int = 0, muteForever: Bool = false, unmute: Bool = false) async throws {
        var body: [String: Any] = ["ConversationID": conversationID, "MuteSeconds": muteSeconds, "MuteForever": muteForever, "Unmute": unmute]
        if let pinned { body["Pinned"] = pinned }
        if let archived { body["Archived"] = archived }
        if let markedUnread { body["MarkedUnread"] = markedUnread }
        _ = try await postJSON("conversations/prefs", token: token, body: body)
    }
}
