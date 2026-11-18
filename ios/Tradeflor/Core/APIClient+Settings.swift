import Foundation

// Settings, Admin Center, call history and status-creator endpoints (desktop/src/shared/api/api.ts).
extension APIClient {
    // MARK: account

    func stPrivateAccount(token: String) async throws -> PrivateAccount {
        try decode(PrivateAccount.self, try await getJSON("account/private", token: token))
    }

    func stUpdatePrivateAccount(token: String, password: String, fullName: String?, phone: String?) async throws {
        var body: [String: Any] = ["Password": password]
        if let fullName { body["FullName"] = fullName }
        if let phone { body["Phone"] = phone }
        _ = try await postJSON("account/private", token: token, body: body)
    }

    // MARK: identity

    /// nil when there was no answer (offline, 429): "available" was assumed before, and Change was offered for a name
    /// nobody had checked.
    func stUsernameAvailable(token: String, _ u: String) async -> (available: Bool, reason: String?)? {
        struct Out: Decodable { let available: Bool; let reason: String? }
        guard let d = try? await getJSON("identity/username-available?u=\(APIClient.q(u))", token: token),
              let o = try? JSONDecoder().decode(Out.self, from: d) else { return nil }
        return (o.available, o.reason)
    }

    func stChangeUsername(token: String, _ u: String) async throws -> IdentityCard {
        try decode(IdentityCard.self, try await postJSON("identity/username", token: token, body: ["Username": u]))
    }

    /// `username` only when the person changed it (server 501fe26: a different name goes through the identity rules --
    /// 3-24 chars, the wait between changes, names just left are held). Name and bio are saved first, so a refused
    /// rename can still leave them saved. 400/409/429 come back as `.refused` with the server's own sentence.
    func stUpdateProfile(token: String, displayName: String, username: String?, bio: String) async throws -> Profile {
        var body: [String: Any] = ["DisplayName": displayName, "Bio": bio]
        if let username { body["Username"] = username }
        let (data, http) = try await send(request("profile", method: "POST", token: token, body: body))
        if [400, 409, 429].contains(http.statusCode) {
            throw APIError.refused(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        try check(http, data)
        return APIClient.known(try decode(Profile.self, data))
    }

    // MARK: settings switches

    /// The account's switches (GET /prefs → settings), e.g. "notifications.sound": true.
    func stSettings(token: String) async throws -> [String: Bool] {
        struct Out: Decodable { let settings: [String: Bool]? }
        return (try decode(Out.self, try await getJSON("prefs", token: token))).settings ?? [:]
    }

    func stSetSetting(token: String, key: String, value: Bool) async throws {
        _ = try await postJSON("settings", token: token, body: [key: value])
    }

    func stSetLockPIN(token: String, password: String, pin: String) async throws {
        _ = try await postJSON("locks/pin", token: token, body: ["Password": password, "PIN": pin])
    }

    // MARK: live location

    func stMyLocations(token: String) async -> [LivePosition] {
        (try? await list(LivePosition.self, "location/mine", token: token)) ?? []
    }

    // MARK: events

    func stSavedEvents(token: String) async throws -> [SavedEventFull] {
        try await list(SavedEventFull.self, "calendar/saved", token: token)
    }

    func stResaveEvent(token: String, _ e: SavedEventFull, remind: Int) async throws {
        _ = try await postJSON("calendar/saved", token: token,
                               body: ["event_key": e.event_key, "title": e.title, "currency": e.currency ?? "",
                                      "country_code": e.country_code ?? "", "impact": e.impact ?? "",
                                      "event_at": e.event_at, "remind_minutes": remind])
    }

    // MARK: calls

    func stCallHistory(token: String) async throws -> [CallHistoryItem] {
        struct Out: Decodable { let calls: [CallHistoryItem]? }
        return (try decode(Out.self, try await getJSON("calls/history?limit=30", token: token))).calls ?? []
    }

    func stClearCallHistory(token: String) async throws {
        _ = try await postJSON("calls/history/clear", token: token, body: [:])
    }

    // MARK: admin (admin roles only)

    func stAdminMe(token: String) async -> AdminMe? {
        guard let d = try? await getJSON("admin/me", token: token) else { return nil }
        return try? JSONDecoder().decode(AdminMe.self, from: d)
    }

    /// The admin role check with its answer kind (web 5106e98): .role / .none (401 / 403 / 404: no access) / .unknown
    /// (too many requests, network…: keep what is shown and ask again soon).
    enum AdminCheck { case role(String), none, unknown }

    func stAdminCheck(token: String) async -> AdminCheck {
        do {
            let d = try await getJSON("admin/me", token: token)
            if let me = try? JSONDecoder().decode(AdminMe.self, from: d) { return me.role.isEmpty ? .none : .role(me.role) }
            return .none
        } catch APIError.badCredentials {
            return .none
        } catch APIError.refused {
            return .none
        } catch APIError.server(let status) where status == 403 || status == 404 {
            return .none
        } catch {
            return .unknown
        }
    }

    func stAdminOverview(token: String) async throws -> AdminOverview {
        // the website sends the offset from UTC in seconds
        return try decode(AdminOverview.self, try await getJSON("admin/overview?tz=\(TimeZone.current.secondsFromGMT())", token: token))
    }

    func stAdminUsers(token: String, query: String, page: Int, filter: String = "all", sort: String = "newest") async throws -> AdminUsersPage {
        let day = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        // trimmed and at most 80 characters, as the website's search box
        let q = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let path = "admin/users?q=\(APIClient.q(q))&filter=\(APIClient.q(filter))&sort=\(APIClient.q(sort))&page=\(page)&limit=25&day_start=\(day)"
        return try decode(AdminUsersPage.self, try await getJSON(path, token: token))
    }

    func stAdminSuspend(token: String, userID: String, reason: String, hours: Int) async throws {
        let until = hours > 0 ? Int64(Date().timeIntervalSince1970) + Int64(hours) * 3600 : 0
        _ = try await postJSON("admin/users/\(userID)/suspend", token: token, body: ["Reason": reason, "Until": until])
    }

    func stAdminRestore(token: String, userID: String) async throws {
        _ = try await postJSON("admin/users/\(userID)/restore", token: token, body: [:])
    }

    func stAdminOfficial(token: String) async throws -> [AdminOfficialPost] {
        try await list(AdminOfficialPost.self, "admin/official", token: token)
    }

    func stAdminOfficialAction(token: String, id: String, action: String) async throws {
        let body: [String: Any] = action == "publish" ? ["PublishAt": 0, "Hours": 0] : [:]
        _ = try await postJSON("admin/official/\(id)/\(action)", token: token, body: body)
    }

    // MARK: status uploads (voice, music)

    /// Multipart POST /status for a photo / video / voice note, with optional caption and music.
    func stPostStatus(token: String, groupID: String? = nil, file: Data, fileName: String, mime: String, caption: String = "",
                      music: String? = nil, voiceMs: Int? = nil) async throws {
        let boundary = "tf-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("caption", caption)
        if let music, !music.isEmpty { field("music", music) }
        if let groupID, !groupID.isEmpty { field("group_id", groupID) } // a status for a group (owner and admins)
        if let voiceMs {
            field("kind", "voice")
            field("duration_ms", String(voiceMs))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = request("status", method: "POST", token: token, body: nil)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        req.httpBody = body
        let (data, http) = try await send(req)
        if [400, 413, 415].contains(http.statusCode) {
            throw APIError.refused(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        try check(http, data)
    }

    /// A text status with an optional track.
    func stPostTextStatus(token: String, groupID: String? = nil, text: String, bg: String, font: String, music: String?) async throws {
        let boundary = "tf-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("kind", "text")
        field("text", text)
        field("bg", bg)
        field("font", font)
        if let music, !music.isEmpty { field("music", music) }
        if let groupID, !groupID.isEmpty { field("group_id", groupID) }
        body.append(Data("--\(boundary)--\r\n".utf8))
        var req = request("status", method: "POST", token: token, body: nil)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, http) = try await send(req)
        if http.statusCode == 400 {
            throw APIError.refused(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        try check(http, data)
    }

    /// The app's music library track (served by the website).
    func stMusicURL(_ id: String) -> URL? {
        guard var c = URLComponents(url: AppConfig.apiBase, resolvingAgainstBaseURL: false) else { return nil }
        c.path = "/music/\(id).m4a"
        c.query = nil
        return c.url
    }
}
