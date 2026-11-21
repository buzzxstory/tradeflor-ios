import Combine
import UIKit

/// A background task that is ended once, whichever comes first: the work finishing or iOS's time running out.
@MainActor
private final class BackgroundTimeBox {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Runs `work` with background time: a message on its way when the person leaves the app is still sent instead of
/// waiting, half sent, for the next time the app opens (iOS gives about 30 s; a send cut off there is retried with the
/// same key).
@MainActor
enum BackgroundTime {
    static func run<T>(_ name: String, _ work: () async -> T) async -> T {
        let box = BackgroundTimeBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: name) { box.end() }
        let out = await work()
        box.end()
        return out
    }
}

/// Sends the texts and voice notes a chat screen left in the saved outbox (OutboxStore), when no chat screen is there to do
/// it: after a restart that stays on the lists, after leaving a chat while it was still retrying. Runs on sign-in, when the
/// live connection opens and when the app comes to the front. Same idempotency key as the chat screen, so a message the
/// server already has is never stored twice. Photos, videos and documents resume from their files when their chat opens.
@MainActor
final class OutboxFlusher {
    static let shared = OutboxFlusher()

    private var subs = Set<AnyCancellable>()
    private var token = ""
    private var account = ""
    private var running = false
    /// A flush was asked for while one was running: it runs once more when that one ends.
    private var wanted = false
    private var again: Task<Void, Never>?
    /// Server errors (5xx) seen per message in this session: after five it is marked "Not sent" and the next one goes on.
    private var serverFails: [String: Int] = [:]

    func attach(live: LiveConnection, token: String, userID: String) {
        guard self.token != token else { return }
        self.token = token
        account = userID
        subs.removeAll()
        live.opened.receive(on: DispatchQueue.main).sink { [weak self] _ in Task { await self?.flush() } }.store(in: &subs)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { await self?.flush() } }.store(in: &subs)
        flushSoon()
    }

    func detach() {
        subs.removeAll()
        again?.cancel()
        again = nil
        token = ""
        account = ""
        serverFails = [:]
        wanted = false
    }

    func flushSoon() { Task { await flush() } }

    private func flush() async {
        guard !token.isEmpty, !account.isEmpty else { return }
        // asked for while one is running (a chat was just left while another chat's message is on its way): run again
        // afterwards, so what was saved meanwhile does not wait for the next connection or return to the app
        guard !running else { wanted = true; return }
        running = true
        // time to finish if the person leaves the app while a message is on its way
        await BackgroundTime.run("tf.outbox") { await self.flushNow() }
        running = false
        if wanted {
            wanted = false
            flushSoon()
        }
    }

    private func flushNow() async {
        let tok = token, acct = account
        var waiting = false
        var delay = 20.0
        // reading and decoding the saved files (voice notes in base64) stays off the main thread
        let all = await Task.detached(priority: .utility) { OutboxStore.lines(account: acct) }.value
        let byChat = Dictionary(grouping: all, by: { $0.conversation })
        // a group's people, read once per flush (for the @mentions of texts saved without them)
        var people: [String: [GroupMember]] = [:]
        for (conv, items) in byChat {
            // the chat on screen sends its own
            if LocalNotifier.shared.openConversation == conv { continue }
            for line in items.sorted(by: { $0.date < $1.date }) {
                guard tok == token else { return } // signed out, or another account, meanwhile
                do {
                    if let audio = line.audio, let ms = line.durationMs {
                        _ = try await APIClient.shared.sendVoice(token: tok, conversationID: conv, audio: audio, durationMs: ms,
                                                                 waveform: line.waveform, key: line.id)
                    } else if let sticker = line.stickerID {
                        _ = try await APIClient.shared.sendSticker(token: tok, conversationID: conv, stickerID: sticker,
                                                                   packID: line.stickerPack, key: line.id, replyTo: line.replyTo)
                    } else {
                        var mentions: [[String: Any]] = []
                        if conv.hasPrefix("grp_"), line.body.contains("@") {
                            if let kept = line.mentions {
                                mentions = kept.map { m -> [String: Any] in ["user_id": m.user_id, "username": m.username] }
                            } else {
                                // built as the chat screen builds them, from the same lists of the group's people
                                if people[conv] == nil { people[conv] = await groupPeople(tok, conv) }
                                // the people could not be read: left, with the ones after it, for when the chat is opened
                                guard let known = people[conv] else { break }
                                mentions = MentionsBuilder.build(line.body, members: known)
                            }
                        }
                        if mentions.isEmpty {
                            _ = try await APIClient.shared.sendText(token: tok, conversationID: conv, body: line.body, key: line.id,
                                                                    replyTo: line.replyTo)
                        } else {
                            _ = try await APIClient.shared.chSendText(token: tok, conversationID: conv, body: line.body,
                                                                      replyTo: line.replyTo, mentions: mentions, key: line.id)
                        }
                    }
                    guard tok == token else { return } // signed out while it was on its way: nothing written for that account
                    await remove(acct, conv, line.id)
                    serverFails[line.id] = nil
                } catch APIError.badCredentials {
                    return // the session is over: the app signs out by itself
                } catch APIError.decoding {
                    // the server took it (only its answer could not be read)
                    guard tok == token else { return }
                    await remove(acct, conv, line.id)
                } catch APIError.locked {
                    break // a locked chat: left for when it is opened
                } catch is SendDeadlineExceeded {
                    // a long voice note on a slow uplink: it steps aside, the texts after it go now; tried again on the next
                    // flush with the same key (audit IOS-MSG-3)
                    waiting = true
                    continue
                } catch {
                    guard tok == token else { return }
                    if SendPolicy.decide(error) == .conflict {
                        // the server says this key was used for another conversation: a client bug, never retried by itself
                        NSLog("TF outbox: Idempotency-Key %@ already used for another conversation (409); marked Not sent", line.id)
                    }
                    var passing = error is URLError
                    var serverError = false
                    if let a = error as? APIError {
                        switch a {
                        case .rateLimited, .network: passing = true
                        case .server(let status) where status >= 500: passing = true; serverError = true
                        default: break
                        }
                    }
                    if passing {
                        if serverError {
                            serverFails[line.id, default: 0] += 1
                            if (serverFails[line.id] ?? 0) >= 5 {
                                await markFailed(acct, conv, line.id)
                                serverFails[line.id] = nil
                                continue // this one is "Not sent"; the ones after it go on
                            }
                        }
                        let after = APIClient.shared.lastRetryAfter
                        APIClient.shared.lastRetryAfter = 0
                        delay = max(delay, after)
                        waiting = true
                        break // keeps its place: the next ones wait behind it
                    }
                    // refused for good (blocked, too long, no longer a member): shown as "Not sent" when the chat opens
                    await markFailed(acct, conv, line.id)
                }
            }
        }
        again?.cancel()
        again = nil
        if waiting {
            let wait = delay
            again = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.flush()
            }
        }
    }

    /// A group's people as the chat screen reads them (ChatView.loadPeople): the posters, the admins and, for an admin, the
    /// whole directory. nil when the posters could not be read (everyone may read them); the other two are added when this
    /// account may read them.
    private func groupPeople(_ tok: String, _ conv: String) async -> [GroupMember]? {
        guard let senders = try? await APIClient.shared.list(GroupMemberFull.self, "groups/\(conv)/senders", token: tok) else { return nil }
        var all: [String: GroupMemberFull] = [:]
        for p in senders { all[p.user_id] = p }
        for p in (try? await APIClient.shared.list(GroupMemberFull.self, "groups/\(conv)/admins", token: tok)) ?? [] { all[p.user_id] = p }
        for p in (try? await APIClient.shared.list(GroupMemberFull.self, "groups/\(conv)/members", token: tok)) ?? [] { all[p.user_id] = p }
        return all.values.map { GroupMember(user_id: $0.user_id, username: $0.username, display_name: $0.display_name) }
    }

    /// The saved outbox is changed off the main thread (each change reads, decodes and rewrites the chat's file).
    private func remove(_ account: String, _ conversation: String, _ id: String) async {
        await Task.detached(priority: .utility) { OutboxStore.remove(account: account, conversation: conversation, id: id) }.value
    }

    private func markFailed(_ account: String, _ conversation: String, _ id: String) async {
        await Task.detached(priority: .utility) { OutboxStore.markFailed(account: account, conversation: conversation, id: id) }.value
    }
}
