import Combine
import UIKit

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
    }

    func flushSoon() { Task { await flush() } }

    private func flush() async {
        guard !running, !token.isEmpty, !account.isEmpty else { return }
        running = true
        defer { running = false }
        let tok = token, acct = account
        var waiting = false
        var delay = 20.0
        let byChat = Dictionary(grouping: OutboxStore.lines(account: acct), by: { $0.conversation })
        for (conv, items) in byChat {
            // the chat on screen sends its own (it also builds @mentions, which are not kept with the entry)
            if LocalNotifier.shared.openConversation == conv { continue }
            for line in items.sorted(by: { $0.date < $1.date }) {
                guard tok == token else { return } // signed out, or another account, meanwhile
                if conv.hasPrefix("grp_"), line.audio == nil, line.body.contains("@") { break }
                do {
                    if let audio = line.audio, let ms = line.durationMs {
                        _ = try await APIClient.shared.sendVoice(token: tok, conversationID: conv, audio: audio, durationMs: ms,
                                                                 waveform: line.waveform, key: line.id)
                    } else {
                        _ = try await APIClient.shared.sendText(token: tok, conversationID: conv, body: line.body, key: line.id,
                                                                replyTo: line.replyTo)
                    }
                    OutboxStore.remove(account: acct, conversation: conv, id: line.id)
                    serverFails[line.id] = nil
                } catch APIError.badCredentials {
                    return // the session is over: the app signs out by itself
                } catch APIError.decoding {
                    // the server took it (only its answer could not be read)
                    OutboxStore.remove(account: acct, conversation: conv, id: line.id)
                } catch APIError.locked {
                    break // a locked chat: left for when it is opened
                } catch {
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
                                OutboxStore.markFailed(account: acct, conversation: conv, id: line.id)
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
                    OutboxStore.markFailed(account: acct, conversation: conv, id: line.id)
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
}
