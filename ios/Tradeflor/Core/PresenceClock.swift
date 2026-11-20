import Foundation

/// Orders presence answers (audit IOS-PRES-3, web presenceClock.ts): a live `presence` event bumps that person's counter, a
/// `presence_snapshot` (or a sign-out) bumps the global one. An HTTP answer is applied only when nothing newer arrived while
/// it was on its way, so an older "offline" never overwrites a live "online".
struct PresenceClock {
    struct Stamp: Equatable {
        let user: Int
        let global: Int
    }

    private var perUser: [String: Int] = [:]
    private var global = 0

    func stamp(_ userID: String) -> Stamp { Stamp(user: perUser[userID] ?? 0, global: global) }

    mutating func bump(_ userID: String) { perUser[userID, default: 0] += 1 }

    mutating func bumpAll() { global += 1 }

    /// Nothing about this person arrived since `stamp` was taken.
    func isCurrent(_ stamp: Stamp, for userID: String) -> Bool { self.stamp(userID) == stamp }

    /// Sign-out: the counters start over, and every stamp taken before is stale (the global counter moves on).
    mutating func reset() {
        perUser = [:]
        global += 1
    }
}

/// When a network change needs a new live socket (audit IOS-NET-3). A new socket is made when the interface the socket
/// used is gone, or when the set of interfaces changed and another one leads. The same interfaces in another order (Wi-Fi
/// Assist, a hotspot) keep the socket: replacing it left a gap that showed the person offline, and churned sockets.
enum NetworkChange {
    static func needsNewSocket<T: Equatable>(before: [T], after: [T]) -> Bool {
        guard let old = before.first else { return false }
        if !after.contains(old) { return true }
        let sameSet = before.count == after.count && before.allSatisfy { after.contains($0) } && after.allSatisfy { before.contains($0) }
        if sameSet { return false }
        return after.first != old
    }
}
