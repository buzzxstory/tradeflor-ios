import Foundation

enum AppConfig {
    /// Read from Info.plist (`TFAPIBase`, set from the TF_API_BASE build setting in project.yml).
    static let apiBase: URL = {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "TFAPIBase") as? String) ?? ""
        return URL(string: raw.isEmpty ? "https://app.tradeflor.com/api" : raw)!
    }()

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }
}

enum APIError: Error, Equatable {
    case badCredentials
    case emailNotVerified(userID: String)
    case rateLimited
    case suspended
    case locked
    case refused(String)
    case network
    case server(status: Int)
    case decoding
}

/// Talks to the same Go API the website uses. No Origin header is sent (native clients are judged by their token),
/// and the User-Agent contains "iPhone" so the server's session list labels this device as an iPhone.
final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let base: URL
    private let userAgent: String

    init(base: URL = AppConfig.apiBase, session: URLSession? = nil) {
        self.base = base
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.urlCache = nil
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 6
        self.session = session ?? URLSession(configuration: cfg)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        self.userAgent = "Tradeflor-iOS/\(AppConfig.version) (iPhone; iOS \(v.majorVersion).\(v.minorVersion))"
    }

    private func request(_ path: String, method: String, token: String?, body: [String: Any]?,
                         rawQuery: Bool = false) -> URLRequest {
        // appendingPathComponent would escape the "?" of a query, so a path with a query is joined as text.
        let url = rawQuery ? URL(string: base.absoluteString + "/" + path)! : base.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if token != nil, let unlock = unlockToken { req.setValue(unlock, forHTTPHeaderField: "X-Tradeflor-Unlock") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw APIError.network }
            return (data, http)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.network
        }
    }

    func login(username: String, password: String) async throws -> Session {
        let req = request("auth/login", method: "POST", token: nil,
                          body: ["Username": username, "Password": password])
        let (data, http) = try await send(req)
        switch http.statusCode {
        case 200:
            guard let out = try? JSONDecoder().decode(LoginResponse.self, from: data) else { throw APIError.decoding }
            return Session(token: out.token, userID: out.user_id, username: username)
        case 403:
            let uid = (try? JSONDecoder().decode(UnverifiedResponse.self, from: data))?.user_id ?? ""
            throw APIError.emailNotVerified(userID: uid)
        case 400, 401: throw APIError.badCredentials
        case 423: throw APIError.suspended
        case 429: throw APIError.rateLimited
        default: throw APIError.server(status: http.statusCode)
        }
    }

    func logout(token: String) async {
        _ = try? await send(request("auth/logout", method: "POST", token: token, body: nil))
    }

    func conversations(token: String) async throws -> [ConversationSummary] {
        let (data, http) = try await send(request("conversations", method: "GET", token: token, body: nil))
        switch http.statusCode {
        case 200:
            if data.isEmpty || data == Data("null".utf8) { return [] }
            do { return try JSONDecoder().decode([ConversationSummary]?.self, from: data) ?? [] }
            catch { throw APIError.decoding }
        case 401: throw APIError.badCredentials
        case 429: throw APIError.rateLimited
        default: throw APIError.server(status: http.statusCode)
        }
    }

    /// A user's profile picture (only someone you share a chat with). Kept in memory only: the server marks
    /// conversation content as not-for-disk, and avatars follow the same rule here.
    func avatar(token: String, userID: String, avatarID: String) async -> Data? {
        let key = "\(userID)/\(avatarID)" as NSString
        if let hit = avatarCache.object(forKey: key) { return hit as Data }
        guard var comps = URLComponents(url: base.appendingPathComponent("users").appendingPathComponent(userID)
                                            .appendingPathComponent("avatar"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = [URLQueryItem(name: "v", value: avatarID)]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let unlock = unlockToken { req.setValue(unlock, forHTTPHeaderField: "X-Tradeflor-Unlock") }
        guard let out = try? await send(req), out.1.statusCode == 200, !out.0.isEmpty else { return nil }
        let data = out.0
        avatarCache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    /// A plain authenticated GET, for small endpoints defined next to their feature.
    func getJSON(_ path: String, token: String) async throws -> Data {
        let (data, http) = try await send(request(path, method: "GET", token: token, body: nil))
        try check(http, data)
        return data
    }

    // MARK: profile and devices

    func profile(token: String) async throws -> Profile {
        let data = try await getJSON("profile", token: token)
        do { return try JSONDecoder().decode(Profile.self, from: data) } catch { throw APIError.decoding }
    }

    /// Fields left nil are not changed.
    func updateProfile(token: String, displayName: String?, bio: String?) async throws -> Profile {
        var body: [String: Any] = [:]
        if let displayName { body["DisplayName"] = displayName }
        if let bio { body["Bio"] = bio }
        let (data, http) = try await send(request("profile", method: "POST", token: token, body: body))
        if http.statusCode == 400 || http.statusCode == 409 {
            throw APIError.refused(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        try check(http, data)
        do { return try JSONDecoder().decode(Profile.self, from: data) } catch { throw APIError.decoding }
    }

    func uploadAvatar(token: String, jpeg: Data) async throws -> Profile {
        let boundary = "tf-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"avatar.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = request("profile/avatar", method: "POST", token: token, body: nil)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, http) = try await send(req)
        if http.statusCode == 400 || http.statusCode == 413 || http.statusCode == 415 {
            throw APIError.refused(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        try check(http, data)
        do { return try JSONDecoder().decode(Profile.self, from: data) } catch { throw APIError.decoding }
    }

    func deleteAvatar(token: String) async throws -> Profile {
        let (data, http) = try await send(request("profile/avatar/delete", method: "POST", token: token, body: nil))
        try check(http, data)
        do { return try JSONDecoder().decode(Profile.self, from: data) } catch { throw APIError.decoding }
    }

    func devices(token: String) async throws -> [LinkedDevice] {
        try decodeList(LinkedDevice.self, try await getJSON("auth/sessions", token: token))
    }

    func revokeDevice(token: String, id: String) async throws {
        let (data, http) = try await send(request("auth/sessions/revoke", method: "POST", token: token, body: ["id": id]))
        try check(http, data)
    }

    // MARK: chat lock

    /// The Chat Lock grant for this device session (memory only: a restart, sign-out or going to the background
    /// locks the chats again).
    private(set) var unlockToken: String?

    func unlockChats(token: String, pin: String) async throws {
        let (data, http) = try await send(request("locks/unlock", method: "POST", token: token, body: ["PIN": pin]))
        if http.statusCode == 409 { throw APIError.server(status: 409) }
        try check(http, data)
        struct Grant: Decodable { let token: String }
        guard let g = try? JSONDecoder().decode(Grant.self, from: data) else { throw APIError.decoding }
        unlockToken = g.token
    }

    func relockChats(token: String) async {
        guard unlockToken != nil else { return }
        unlockToken = nil
        _ = try? await send(request("locks/relock", method: "POST", token: token, body: nil))
    }

    // MARK: chat

    /// Maps the common failure statuses of an authenticated call.
    private func check(_ http: HTTPURLResponse, _ data: Data) throws {
        switch http.statusCode {
        case 200..<300: return
        case 401: throw APIError.badCredentials
        case 423: throw APIError.locked
        case 429: throw APIError.rateLimited
        case 403, 413:
            throw APIError.refused(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        default: throw APIError.server(status: http.statusCode)
        }
    }

    private func decodeList<T: Decodable>(_ type: T.Type, _ data: Data) throws -> [T] {
        if data.isEmpty || data == Data("null".utf8) { return [] }
        do { return try JSONDecoder().decode([T]?.self, from: data) ?? [] } catch { throw APIError.decoding }
    }

    /// Oldest first. No `before`: the newest page (opening a chat). With `before` (a seq): the page above it.
    func messages(token: String, conversationID: String, before: Int64? = nil, limit: Int = 50) async throws -> [Message] {
        var q = "conversation_id=\(Self.q(conversationID))&limit=\(limit)"
        if let before { q += "&before=\(before)" }
        let (data, http) = try await send(request("messages?\(q)", method: "GET", token: token, body: nil, rawQuery: true))
        try check(http, data)
        return try decodeList(Message.self, data)
    }

    /// `key` makes a retry safe: the server stores a message once per key.
    func sendText(token: String, conversationID: String, body: String, key: String) async throws -> Message {
        var req = request("messages", method: "POST", token: token,
                          body: ["ConversationID": conversationID, "Body": body, "ReplyToID": ""])
        req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        let (data, http) = try await send(req)
        try check(http, data)
        do { return try JSONDecoder().decode(Message.self, from: data) } catch { throw APIError.decoding }
    }

    /// Sends a photo (already JPEG) as an image message: multipart, fields first, the file last (the server checks
    /// permission before it stores a byte). `key` makes a retry safe, like text.
    func sendImage(token: String, conversationID: String, jpeg: Data, caption: String, key: String,
                   fileName: String = "photo.jpg", mime: String = "image/jpeg") async throws -> Message {
        let boundary = "tf-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("conversation_id", conversationID)
        if !caption.isEmpty { field("caption", caption) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = request("messages/file", method: "POST", token: token, body: nil)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        req.timeoutInterval = 120
        req.httpBody = body
        let (data, http) = try await send(req)
        try check(http, data)
        do { return try JSONDecoder().decode(Message.self, from: data) } catch { throw APIError.decoding }
    }

    /// An attachment's bytes (`thumb`: the server's small JPEG of an image). Memory-only cache.
    func file(token: String, fileID: String, thumb: Bool) async -> Data? {
        let key = "\(fileID)/\(thumb ? "t" : "f")" as NSString
        if let hit = avatarCache.object(forKey: key) { return hit as Data }
        guard var comps = URLComponents(url: base.appendingPathComponent("files").appendingPathComponent(fileID),
                                        resolvingAgainstBaseURL: false) else { return nil }
        if thumb { comps.queryItems = [URLQueryItem(name: "thumb", value: "1")] }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let unlock = unlockToken { req.setValue(unlock, forHTTPHeaderField: "X-Tradeflor-Unlock") }
        guard let out = try? await send(req), out.1.statusCode == 200, !out.0.isEmpty else { return nil }
        avatarCache.setObject(out.0 as NSData, forKey: key, cost: out.0.count)
        return out.0
    }

    /// A voice message: M4A (AAC) from the recorder, its length and a level waveform (0...1, at most 512 samples).
    func sendVoice(token: String, conversationID: String, audio: Data, durationMs: Int, waveform: [Double],
                   key: String) async throws -> Message {
        let boundary = "tf-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("conversation_id", conversationID)
        field("duration_ms", String(durationMs))
        if let w = try? JSONEncoder().encode(waveform), let s = String(data: w, encoding: .utf8) { field("waveform", s) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = request("messages/voice", method: "POST", token: token, body: nil)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        req.timeoutInterval = 120
        req.httpBody = body
        let (data, http) = try await send(req)
        try check(http, data)
        do { return try JSONDecoder().decode(Message.self, from: data) } catch { throw APIError.decoding }
    }

    /// A voice recording's bytes (memory-only cache).
    func voice(token: String, audioID: String) async -> Data? {
        let key = "voice/\(audioID)" as NSString
        if let hit = avatarCache.object(forKey: key) { return hit as Data }
        var req = URLRequest(url: base.appendingPathComponent("media").appendingPathComponent("voice").appendingPathComponent(audioID))
        req.timeoutInterval = 60
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let unlock = unlockToken { req.setValue(unlock, forHTTPHeaderField: "X-Tradeflor-Unlock") }
        guard let out = try? await send(req), out.1.statusCode == 200, !out.0.isEmpty else { return nil }
        avatarCache.setObject(out.0 as NSData, forKey: key, cost: out.0.count)
        return out.0
    }

    /// A one-minute media ticket, for players that cannot send an Authorization header.
    func mediaTicket(token: String) async throws -> String {
        let (data, http) = try await send(request("auth/ticket", method: "POST", token: token, body: ["Purpose": "media"]))
        try check(http, data)
        guard let t = try? JSONDecoder().decode(TicketResponse.self, from: data) else { throw APIError.decoding }
        return t.ticket
    }

    func voiceURL(audioID: String, ticket: String) -> URL {
        let u = base.appendingPathComponent("media").appendingPathComponent("voice").appendingPathComponent(audioID)
        var comps = URLComponents(url: u, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "token", value: ticket)]
        return comps.url ?? u
    }

    // MARK: status

    func statusFeed(token: String) async throws -> [StatusGroup] {
        let (data, http) = try await send(request("status/feed", method: "GET", token: token, body: nil))
        try check(http, data)
        return try decodeList(StatusGroup.self, data)
    }

    /// Posts a photo or video status (`file` as JPEG/MP4), or a text status when `file` is nil.
    func postStatus(token: String, file: Data?, fileName: String = "", mime: String = "", caption: String = "",
                    text: String = "", bg: String = "", font: String = "") async throws -> StatusPost {
        let boundary = "tf-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        if let file {
            field("caption", caption)
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
            body.append(file)
            body.append(Data("\r\n".utf8))
        } else {
            field("kind", "text")
            field("text", text)
            field("bg", bg)
            field("font", font)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        var req = request("status", method: "POST", token: token, body: nil)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        req.httpBody = body
        let (data, http) = try await send(req)
        if http.statusCode == 400 || http.statusCode == 415 {
            throw APIError.refused(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        try check(http, data)
        do { return try JSONDecoder().decode(StatusPost.self, from: data) } catch { throw APIError.decoding }
    }

    func statusSeen(token: String, id: String) async {
        _ = try? await send(request("status/\(id)/seen", method: "POST", token: token, body: nil))
    }

    func statusDelete(token: String, id: String) async throws {
        let (data, http) = try await send(request("status/\(id)/delete", method: "POST", token: token, body: nil))
        try check(http, data)
    }

    func statusViewers(token: String, id: String) async throws -> [StatusViewerEntry] {
        let (data, http) = try await send(request("status/\(id)/viewers", method: "GET", token: token, body: nil))
        try check(http, data)
        return try decodeList(StatusViewerEntry.self, data)
    }

    /// A status photo's bytes, or (poster: true) a video status's poster. Memory-only.
    func statusMedia(token: String, id: String, poster: Bool = false) async -> Data? {
        let key = "status/\(id)/\(poster)" as NSString
        if let hit = avatarCache.object(forKey: key) { return hit as Data }
        guard var comps = URLComponents(url: base.appendingPathComponent("status-media").appendingPathComponent(id),
                                        resolvingAgainstBaseURL: false) else { return nil }
        if poster { comps.queryItems = [URLQueryItem(name: "poster", value: "1")] }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let unlock = unlockToken { req.setValue(unlock, forHTTPHeaderField: "X-Tradeflor-Unlock") }
        guard let out = try? await send(req), out.1.statusCode == 200, !out.0.isEmpty else { return nil }
        avatarCache.setObject(out.0 as NSData, forKey: key, cost: out.0.count)
        return out.0
    }

    func statusMediaURL(id: String) -> URL {
        base.appendingPathComponent("status-media").appendingPathComponent(id)
    }

    func markRead(token: String, conversationID: String) async {
        _ = try? await send(request("conversations/\(Self.q(conversationID))/read-all", method: "POST", token: token,
                                    body: ["Silent": false]))
    }

    /// A one-minute ticket for the live socket, and the socket address.
    func liveURL(token: String) async throws -> URL {
        let (data, http) = try await send(request("auth/ticket", method: "POST", token: token, body: ["Purpose": "ws"]))
        try check(http, data)
        guard let t = try? JSONDecoder().decode(TicketResponse.self, from: data),
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw APIError.decoding }
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        comps.path = "/ws"
        comps.queryItems = [URLQueryItem(name: "ticket", value: t.ticket)]
        guard let url = comps.url else { throw APIError.decoding }
        return url
    }

    func webSocket(_ url: URL) -> URLSessionWebSocketTask {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return session.webSocketTask(with: req)
    }

    private static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?/"))) ?? s
    }

    private let avatarCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.totalCostLimit = 80 << 20
        return c
    }()
}
