import Foundation

// Group management endpoints (desktop/src/shared/api/api.ts, section "Groups"). Request bodies are PascalCase as the
// website sends them; GroupPermissions is nested snake_case (backend messaging.GroupPermissions).
extension APIClient {
    func grpInfo(token: String, id: String) async throws -> GrpInfo {
        try decode(GrpInfo.self, try await getJSON("groups/\(id)", token: token))
    }

    func grpListExtras(token: String) async -> [String: GrpListExtra] {
        let rows = (try? await self.list(GrpListExtra.self, "groups", token: token)) ?? []
        return Dictionary(rows.map { ($0.conversation_id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// POST /groups/{id}/update; only the given fields change.
    func grpUpdate(token: String, id: String, name: String? = nil, description: String? = nil, permissions: GrpPermissions? = nil,
                   historyVisible: Bool? = nil, privacy: String? = nil, slowMode: Int? = nil, joinApproval: Bool? = nil,
                   comments: Bool? = nil) async throws {
        var body: [String: Any] = [:]
        if let name { body["Name"] = name }
        if let description { body["Description"] = description }
        if let permissions { body["Permissions"] = permissions.dict }
        if let historyVisible { body["HistoryVisible"] = historyVisible }
        if let privacy { body["Privacy"] = privacy }
        if let slowMode { body["SlowMode"] = slowMode }
        if let joinApproval { body["JoinApproval"] = joinApproval }
        if let comments { body["Comments"] = comments }
        _ = try await postJSON("groups/\(id)/update", token: token, body: body)
    }

    func grpSetHandle(token: String, id: String, handle: String) async throws {
        _ = try await postJSON("groups/\(id)/handle", token: token, body: ["Handle": handle])
    }

    func grpDelete(token: String, id: String) async throws {
        _ = try await postJSON("groups/\(id)/delete", token: token, body: [:])
    }

    func grpMembers(token: String, id: String) async throws -> [GrpMember] {
        try await list(GrpMember.self, "groups/\(id)/members", token: token)
    }

    func grpAddMember(token: String, id: String, username: String) async throws {
        _ = try await postJSON("groups/\(id)/members", token: token,
                               body: ["Username": username.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))])
    }

    /// Empty userID = leave the group myself.
    func grpRemove(token: String, id: String, userID: String) async throws {
        _ = try await postJSON("groups/\(id)/members/remove", token: token, body: ["UserID": userID])
    }

    func grpRole(token: String, id: String, userID: String, admin: Bool) async throws {
        _ = try await postJSON("groups/\(id)/members/role", token: token, body: ["UserID": userID, "Role": admin ? "admin" : "member"])
    }

    func grpTransfer(token: String, id: String, userID: String) async throws {
        _ = try await postJSON("groups/\(id)/transfer", token: token, body: ["UserID": userID])
    }

    /// seconds > 0 = for that long; permanent; neither = unmute.
    func grpMuteMember(token: String, id: String, userID: String, seconds: Int, permanent: Bool) async throws {
        _ = try await postJSON("groups/\(id)/members/mute", token: token, body: ["UserID": userID, "Seconds": seconds, "Permanent": permanent])
    }

    func grpBan(token: String, id: String, userID: String) async throws {
        _ = try await postJSON("groups/\(id)/members/ban", token: token, body: ["UserID": userID])
    }

    func grpUnban(token: String, id: String, userID: String) async throws {
        _ = try await postJSON("groups/\(id)/members/unban", token: token, body: ["UserID": userID])
    }

    func grpBans(token: String, id: String) async -> [GrpBan] {
        (try? await list(GrpBan.self, "groups/\(id)/bans", token: token)) ?? []
    }

    func grpInvites(token: String, id: String) async -> [GrpInvite] {
        (try? await list(GrpInvite.self, "groups/\(id)/invites", token: token)) ?? []
    }

    /// Returns the share link (the token is returned only here).
    func grpCreateInvite(token: String, id: String, hours: Int, maxUses: Int) async throws -> String {
        let data = try await postJSON("groups/\(id)/invites", token: token,
                                      body: ["ExpiresInHours": hours, "MaxUses": maxUses, "RequireApproval": false])
        struct I: Decodable { let token: String }
        return "https://app.tradeflor.com/join/" + (try decode(I.self, data).token)
    }

    func grpRevokeInvite(token: String, id: String, inviteID: String) async throws {
        _ = try await postJSON("groups/\(id)/invites/revoke", token: token, body: ["ID": inviteID])
    }

    func grpJoinRequests(token: String, id: String) async -> [GrpJoinRequest] {
        (try? await list(GrpJoinRequest.self, "groups/\(id)/join-requests", token: token)) ?? []
    }

    // The same lists, but nil when the request failed: a network blip must not empty what the admin already sees
    // (the versions above return [] for a failure).
    func grpBansIfOK(token: String, id: String) async -> [GrpBan]? {
        try? await list(GrpBan.self, "groups/\(id)/bans", token: token)
    }

    func grpInvitesIfOK(token: String, id: String) async -> [GrpInvite]? {
        try? await list(GrpInvite.self, "groups/\(id)/invites", token: token)
    }

    func grpJoinRequestsIfOK(token: String, id: String) async -> [GrpJoinRequest]? {
        try? await list(GrpJoinRequest.self, "groups/\(id)/join-requests", token: token)
    }

    func grpAuditIfOK(token: String, id: String) async -> [GrpAudit]? {
        try? await list(GrpAudit.self, "groups/\(id)/audit", token: token)
    }

    func grpDecide(token: String, id: String, userID: String, approve: Bool) async throws {
        _ = try await postJSON("groups/\(id)/join-requests/decide", token: token, body: ["UserID": userID, "Approve": approve])
    }

    func grpAudit(token: String, id: String) async -> [GrpAudit] {
        (try? await list(GrpAudit.self, "groups/\(id)/audit", token: token)) ?? []
    }

    func grpMediaStats(token: String, conversationID: String) async -> GrpMediaStats? {
        guard let data = try? await getJSON("conversations/\(conversationID)/media-stats", token: token) else { return nil }
        return try? JSONDecoder().decode(GrpMediaStats.self, from: data)
    }

    /// Marks everything read (the website sends Number.MAX_SAFE_INTEGER).
    func grpMarkRead(token: String, id: String) async throws {
        _ = try await postJSON("groups/\(id)/read", token: token, body: ["Seq": Int64(9_007_199_254_740_991)])
    }

    /// Multipart POST /groups/{id}/avatar, field "avatar".
    func grpUploadAvatar(token: String, id: String, jpeg: Data) async throws {
        let boundary = "tf-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"avatar.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = request("groups/\(id)/avatar", method: "POST", token: token, body: nil)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, http) = try await send(req)
        if [400, 403, 413, 415].contains(http.statusCode) {
            throw APIError.refused(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        try check(http, data)
    }

    func grpRemoveAvatar(token: String, id: String) async throws {
        _ = try await postJSON("groups/\(id)/avatar/delete", token: token, body: [:])
    }

    func grpDiscover(token: String, query: String) async -> [GrpDiscover] {
        (try? await list(GrpDiscover.self, "discover/groups?q=\(APIClient.q(query))", token: token)) ?? []
    }

    func grpLinkPreview(token: String, handle: String) async throws -> GrpInvitePreview {
        try decode(GrpInvitePreview.self, try await getJSON("group-links/\(handle)", token: token))
    }

    func grpJoinLink(token: String, handle: String) async throws -> GrpJoinResult {
        try decode(GrpJoinResult.self, try await postJSON("group-links/\(handle)/join", token: token, body: [:]))
    }

    /// The picture of a public group, by its permanent link.
    func grpLinkAvatar(token: String, handle: String) async -> Data? {
        let key = "gl/\(handle)" as NSString
        if let hit = avatarCache.object(forKey: key) { return hit as Data }
        var req = URLRequest(url: AppConfig.apiBase.appendingPathComponent("group-links").appendingPathComponent(handle).appendingPathComponent("avatar"))
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let out = try? await send(req), out.1.statusCode == 200, !out.0.isEmpty else { return nil }
        avatarCache.setObject(out.0 as NSData, forKey: key, cost: out.0.count)
        return out.0
    }
}
