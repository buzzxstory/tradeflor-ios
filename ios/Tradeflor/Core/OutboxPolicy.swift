import Foundation

/// A send ran past its whole deadline (a voice note on a slow uplink): passing, retried later with the same key, but out of
/// the conversation's send line meanwhile so the texts behind it go.
struct SendDeadlineExceeded: Error, Equatable {}

/// What the send line does with a failed send (chat screen and OutboxFlusher). Pure: unit tested in SendPolicyTests.
/// Contract 2026-11-20 section 3 and 8: never retry a 4xx by itself except 429; 409 on a send is a client bug (the key was
/// used for another conversation); 403 is final, with the server's text.
enum SendPolicy {
    enum Decision: Equatable {
        /// Passing (offline, 429, 5xx): the line waits and tries again with the same key.
        case wait
        /// Passing, but this one leaves the line for a while (a timed-out voice note): the ones behind it go first.
        case later
        /// Refused for good: "Not sent", with the server's text when it has one; never sent again by itself.
        case final(String)
        /// 409: this Idempotency-Key was already used for another conversation. Failed for good and logged (a new key would
        /// be needed; the app never makes one by itself).
        case conflict
        /// 401: the session is gone, the app signs out.
        case signOut
    }

    static func decide(_ error: Error) -> Decision {
        if error is SendDeadlineExceeded { return .later }
        if error is URLError { return .wait }
        guard let a = error as? APIError else { return .final("") }
        switch a {
        case .badCredentials: return .signOut
        case .rateLimited, .network: return .wait
        case .server(let status):
            if status == 409 { return .conflict }
            return status >= 500 ? .wait : .final("")
        case .refused(let why):
            // a group text goes through postJSON, which turns every 409 into `refused` with the server's text
            if why.localizedCaseInsensitiveContains("Idempotency-Key") { return .conflict }
            return .final(why)
        default:
            return .final("")
        }
    }

    /// The whole time a voice note may take (web: 120 s + bytes / 2 KB per second, at most 15 minutes).
    static func voiceDeadline(bytes: Int) -> TimeInterval {
        min(900, 120 + Double(max(0, bytes)) / 2048)
    }

    /// The next message of the line that may go now: the first one in writing order that is not held back (a timed-out voice
    /// note waits out its hold while the ones behind it go).
    static func nextInLine(_ queue: [String], held: [String: Date], now: Date) -> String? {
        queue.first { id in (held[id].map { $0 <= now }) ?? true }
    }

    /// How long a timed-out voice note stays out of the line before it is tried again (same key).
    static let laterHold: TimeInterval = 30
}

enum SendDeadline {
    /// Runs `work`, and gives up with `SendDeadlineExceeded` (cancelling it: the request is cancelled too) once `seconds` have
    /// passed. A cancellation of the caller cancels `work` as well.
    static func run<T: Sendable>(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw SendDeadlineExceeded()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw SendDeadlineExceeded() }
            return first
        }
    }
}
