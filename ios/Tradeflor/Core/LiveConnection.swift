import Foundation
import Combine

/// The app-wide live connection to /ws (same socket the website uses). New messages arrive here the moment the
/// server sends them; screens subscribe to `messages` and `changes`.
/// - a fresh one-minute ticket for every connection attempt
/// - a ping every 25 s; no answer in 10 s = dead connection, replaced at once
/// - reconnects with backoff (1, 2, 4 ... 30 s), and immediately when the app comes back to the foreground
@MainActor
final class LiveConnection: ObservableObject {
    @Published private(set) var connected = false

    /// A new message in any conversation.
    let messages = PassthroughSubject<Message, Never>()
    /// Something changed in a conversation (receipt, reaction, deletion, edit...): the id, so a screen can reload it.
    let changes = PassthroughSubject<String, Never>()
    /// Call events (type starts with "call."): the type and the raw `data` object.
    let calls = PassthroughSubject<(type: String, data: [String: Any]), Never>()
    /// Someone is typing: (conversation id, user id).
    let typing = PassthroughSubject<(conversation: String, user: String), Never>()
    /// Who of the people I share a chat with is online now.
    @Published private(set) var online: Set<String> = []
    /// When people were last seen (unix seconds), and who hides it from me (server d4d2e77): "last seen …" or nothing.
    @Published private(set) var lastSeen: [String: Int64] = [:]
    @Published private(set) var hiddenPresence: Set<String> = []
    /// The app is in front: only then am I "online" to others (sent on every change and after every connect).
    private(set) var appActive = true
    /// Fires every time the socket (re)opens, so calls can send call.sync.
    let opened = PassthroughSubject<Void, Never>()
    /// Someone asked to join a group I own or run: conversation_id, group, name, user_id.
    let joinRequests = PassthroughSubject<[String: String], Never>()
    /// Something changed in my signed-in sessions (sign-in, sign-out, rename on any device): Linked Devices reloads.
    let sessionsChanged = PassthroughSubject<Void, Never>()
    /// My contacts changed ("contact" event: saved / unsaved on one of my devices, accepted …): the Contacts list reloads.
    let contactsChanged = PassthroughSubject<[String: Any], Never>()
    /// Messages gone from my view (hidden for me, or a cleared chat, in batches): conversation id and message ids.
    let hidden = PassthroughSubject<(conversation: String, ids: [String]), Never>()
    /// Scan & Connect (event type "flash"): the raw `data` (action claimed / accepted / declined / decided, session_id, guest, peer).
    /// A notification only: whoever listens re-reads GET /connect/sessions/{id} or /connect/pending.
    let flash = PassthroughSubject<[String: Any], Never>()

    private var token: String?
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var lastPong = Date()
    private var attempt = 0

    func start(token: String) {
        guard self.token != token || loop == nil else { return }
        stop()
        self.token = token
        loop = Task { [weak self] in await self?.run() }
    }

    /// The app came to the front (true) or left it (false).
    func setActive(_ active: Bool) {
        guard active != appActive else { return }
        appActive = active
        if connected { sendRaw(["type": "active", "data": ["active": active]]) }
    }

    /// One person's presence read over HTTP (opening a private chat): the same fields as the live event.
    func applyPresence(_ p: PresenceInfo, userID: String) {
        if p.online == true { online.insert(userID) } else { online.remove(userID) }
        if let t = p.last_seen, t > 0 { lastSeen[userID] = t }
        if p.hidden == true { hiddenPresence.insert(userID); lastSeen[userID] = nil } else { hiddenPresence.remove(userID) }
    }

    /// The line under a person's name: "online", "last seen …", or nil.
    func presenceLine(_ userID: String, now: Date = Date()) -> String? {
        LastSeen.line(online: online.contains(userID), lastSeen: lastSeen[userID], hidden: hiddenPresence.contains(userID), now: now)
    }

    func stop() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        token = nil
        connected = false
    }

    /// Back in the foreground: prove the connection now instead of trusting a socket that only looks open.
    func probe() {
        guard let token else { return }
        if !connected || Date().timeIntervalSince(lastPong) > 35 {
            start(tokenForcing: token)
        } else {
            sendPing()
        }
    }

    private func start(tokenForcing token: String) {
        stop()
        self.token = token
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            guard let token else { return }
            do {
                var url = try await APIClient.shared.liveURL(token: token)
                if !appActive, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    // not in front right now: connect without counting as online
                    c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "active", value: "0")]
                    if let u = c.url { url = u }
                }
                let ws = APIClient.shared.webSocket(url)
                task = ws
                ws.resume()
                lastPong = Date()
                let heartbeat = Task { [weak self] in await self?.heartbeat(ws) }
                defer { heartbeat.cancel() }
                try await receive(ws)
            } catch APIError.badCredentials {
                connected = false
                return // signed out elsewhere; the screens notice on their next request
            } catch {
                // fall through to the backoff below
            }
            connected = false
            if Task.isCancelled { return }
            let delay = min(30.0, pow(2.0, Double(attempt)))
            attempt += 1
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func receive(_ ws: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let msg = try await ws.receive()
            if !connected {
                connected = true
                opened.send(())
                sendRaw(["type": "active", "data": ["active": appActive]])
                sendRaw(["type": "presence"]) // ask for the online snapshot
                attempt = 0
            }
            let data: Data
            switch msg {
            case .string(let s): data = Data(s.utf8)
            case .data(let d): data = d
            @unknown default: continue
            }
            handle(data)
        }
    }

    /// I am typing in this conversation (the server forwards it to the other members). Throttle at the caller.
    func sendTyping(conversationID: String) {
        sendRaw(["type": "typing", "conversation_id": conversationID])
    }

    @discardableResult
    private func sendRaw(_ obj: [String: Any]) -> Bool {
        guard let task, let json = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: json, encoding: .utf8) else { return false }
        task.send(.string(text)) { _ in }
        return true
    }

    /// Sends one frame {"type": ..., "data": {...}}; false when the socket is not open.
    @discardableResult
    func send(type: String, data: [String: Any]) -> Bool {
        guard connected, let task,
              let json = try? JSONSerialization.data(withJSONObject: ["type": type, "data": data]),
              let text = String(data: json, encoding: .utf8) else { return false }
        task.send(.string(text)) { _ in }
        return true
    }

    private func handle(_ data: Data) {
        guard let env = try? JSONDecoder().decode(LiveEnvelope.self, from: data) else { return }
        if env.type == "typing" || env.type == "presence" || env.type == "presence_snapshot" {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = obj["data"] as? [String: Any] else { return }
            switch env.type {
            case "typing":
                if let c = d["conversation_id"] as? String, let u = d["user_id"] as? String { typing.send((c, u)) }
            case "presence":
                if let u = d["user_id"] as? String {
                    if (d["online"] as? Bool) == true { online.insert(u) } else { online.remove(u) }
                    if let t = (d["last_seen"] as? NSNumber)?.int64Value, t > 0 { lastSeen[u] = t }
                    if (d["hidden"] as? Bool) == true { hiddenPresence.insert(u); lastSeen[u] = nil } else { hiddenPresence.remove(u) }
                }
            default:
                // the snapshot replaces what I knew
                online = Set((d["online"] as? [String]) ?? [])
                var seen: [String: Int64] = [:]
                for (k, v) in (d["last_seen"] as? [String: Any]) ?? [:] { if let t = (v as? NSNumber)?.int64Value, t > 0 { seen[k] = t } }
                lastSeen = seen
                hiddenPresence = Set((d["hidden"] as? [String]) ?? [])
            }
            return
        }
        if env.type == "join_request" {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = obj["data"] as? [String: String] {
                joinRequests.send(d)
            }
            return
        }
        if env.type == "sessions" { sessionsChanged.send(()); return }
        if env.type == "contact" {
            let d = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any]) ?? [:]
            contactsChanged.send(d)
            return
        }
        if env.type == "hidden" {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = obj["data"] as? [String: Any] {
                let conv = (d["conversation_id"] as? String) ?? env.conversation_id ?? ""
                let ids = (d["message_ids"] as? [String]) ?? []
                if !conv.isEmpty { hidden.send((conv, ids)); changes.send(conv) }
            }
            return
        }
        if env.type == "flash" {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = obj["data"] as? [String: Any] {
                flash.send(d)
            }
            return
        }
        if env.type.hasPrefix("call.") {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                calls.send((env.type, (obj["data"] as? [String: Any]) ?? [:]))
            }
            return
        }
        switch env.type {
        case "pong":
            lastPong = Date()
        case "message":
            if let ev = try? JSONDecoder().decode(LiveMessageEvent.self, from: data) {
                messages.send(ev.data)
            } else if let id = env.conversation_id {
                changes.send(id)
            }
        case "reaction", "deleted", "receipt", "edited", "conversation", "vanished", "notice", "scheduled", "hidden":
            if let id = env.conversation_id { changes.send(id) }
        default:
            break
        }
    }

    private func heartbeat(_ ws: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            if Task.isCancelled { return }
            let sent = Date()
            sendPing()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if Task.isCancelled { return }
            if lastPong < sent {
                ws.cancel(with: .abnormalClosure, reason: nil) // receive() throws, run() reconnects
                return
            }
        }
    }

    private func sendPing() {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        task?.send(.string("{\"type\":\"ping\",\"data\":{\"t\":\(ms)}}")) { _ in }
    }
}
