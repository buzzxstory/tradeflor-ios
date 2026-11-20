import Foundation

/// The call engine's decisions that need no CallKit, WebRTC or network: what to do with a `call.sync` answer, which call
/// to name in `call.sync`, glare adoption (`merged_from`), a repeated offer, TURN refresh timing and ICE URL checks.
/// CallManager acts on what these return; TradeflorTests/CallDecisionsTests checks them (server contract 2026-11-20,
/// docs/audit-2026-11-20/SHARED_PROTOCOL_CONTRACT.md section 6).
enum CallDecisions {

    // MARK: call.sync

    /// What this phone holds when a `call.sync` answer arrives.
    struct Local: Equatable {
        /// The call this phone holds (nil when idle, or once a call ended here).
        var callID: String?
        var phase: CallManager.Phase
        var role: CallManager.Role
        /// The server confirmed our invite (call.outgoing).
        var acknowledged: Bool
        var hasPeerConnection: Bool
        /// Local ICE is connected or completed (audio can flow).
        var mediaUp: Bool
        /// Calls this phone ended whose end may not have reached the server.
        var endedHere: Set<String>

        var lineInUse: Bool { phase != .idle && phase != .ended }
    }

    /// The server's call in a `call.sync` answer (`call`), or any call summary: the fields decided on.
    struct Server: Equatable {
        var id: String
        /// ringing | connecting | active
        var state: String?
        /// caller | callee, for this device
        var role: String?
        /// Glare: the id of the callee's own invite that became the answer to this call (server b35bc5d7, additive).
        var mergedFrom: String?

        init(id: String, state: String? = nil, role: String? = nil, mergedFrom: String? = nil) {
            self.id = id; self.state = state; self.role = role; self.mergedFrom = mergedFrom
        }

        /// From the raw summary; nil without a call id (no call).
        init?(_ d: [String: Any]?) {
            guard let d, let id = d["call_id"] as? String, !id.isEmpty else { return nil }
            self.init(id: id, state: d["state"] as? String, role: d["role"] as? String,
                      mergedFrom: (d["merged_from"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    enum SyncAction: Equatable {
        /// The server has no call for this device but this phone holds one: it ends as "connection_lost".
        case endLost
        /// Our invite never reached the server (sent while the socket was down): sent again, same id.
        case resendInvite
        /// Close a call the server still has for this device: one this phone ended while offline, or one left from before
        /// the app was killed (op: call.decline, call.cancel or call.hangup), and end its CallKit call.
        case close(op: String, callID: String)
        /// A call ringing for this phone: ring it.
        case ring
        /// Glare whose `call.merged` was lost: our invite became the answer to `into`; continue as its callee.
        case adoptMerge(into: String)
        /// Our invite rings on the server: the ringback starts.
        case acknowledge
        /// The server still rings us after we answered: our accept was lost.
        case resendAccept
        /// The call connected on the server but `call.accepted` was lost: set up the peer connection now.
        case acceptedLost
        /// The socket was down: resend what may have been lost, restart ICE if the media is down.
        case resume
        /// The server says active while this phone still waits in "connecting" (`call.active` was lost).
        case markActive
        /// The server still says connecting while our media is up (`call.connected` was lost): send it again.
        case resendConnected
    }

    /// What to do with a `call.sync` answer (the `ended` part and VoIP push rings are handled before this).
    static func syncActions(server: Server?, local: Local) -> [SyncAction] {
        guard let s = server else {
            let unacknowledged = local.phase == .outgoing && !local.acknowledged
            var out: [SyncAction] = []
            if local.lineInUse && !unacknowledged { out.append(.endLost) }
            if unacknowledged { out.append(.resendInvite) }
            return out
        }
        // glare whose call.merged was lost (web stayed on "Calling..."): the server's call names our invite
        if let into = mergeTarget(server: s, placed: local.callID, phase: local.phase) {
            var merged = local
            merged.callID = into
            merged.role = .callee
            merged.phase = .connecting
            merged.acknowledged = true
            return [.adoptMerge(into: into)] + syncActions(server: s, local: merged)
        }
        // this phone ended it while offline: the server still has it
        if local.endedHere.contains(s.id) && s.id != local.callID {
            return [.close(op: closeOp(state: s.state, role: s.role), callID: s.id)]
        }
        if !local.lineInUse {
            if s.state == "ringing" && s.role == "callee" { return [.ring] }
            // a call bound to this device that this phone does not hold: left from before the app was killed or crashed
            // (no peer connection survives a relaunch). Closed now instead of the server's 20 / 90 s grace, so both people
            // can call again at once.
            return [.close(op: closeOp(state: s.state, role: s.role), callID: s.id)]
        }
        guard s.id == local.callID else { return [] }
        let st = s.state
        if local.phase == .outgoing && st == "ringing" {
            return local.acknowledged ? [] : [.acknowledge]
        }
        if local.phase == .connecting && st == "ringing" && local.role == .callee {
            return [.resendAccept]
        }
        guard local.phase == .outgoing || local.phase == .connecting || local.phase == .active,
              st == "connecting" || st == "active" else { return [] }
        if !local.hasPeerConnection { return [.acceptedLost] }
        var out: [SyncAction] = [.resume]
        if st == "active" && local.phase == .connecting { out.append(.markActive) }
        if st == "connecting" && local.mediaUp { out.append(.resendConnected) }
        return out
    }

    /// How a call this phone no longer holds is closed on the server: a ring for us is declined, our own ring cancelled,
    /// anything answered hung up.
    static func closeOp(state: String?, role: String?) -> String {
        if state == "ringing" { return role == "caller" ? "call.cancel" : "call.decline" }
        return "call.hangup"
    }

    /// Glare adoption: the call this phone placed (`placed`, still "calling") was merged into the server's call `server.id`.
    static func mergeTarget(server: Server, placed: String?, phase: CallManager.Phase) -> String? {
        guard phase == .outgoing, let placed, server.mergedFrom == placed, server.id != placed else { return nil }
        return server.id
    }

    /// The call `call.sync` names (server: a socket that comes back keeps a call only if it names it): the call this phone
    /// holds wins, then the newest ring a VoIP push started, then any other push ring, then a ring that arrived while this
    /// phone was placing a call. nil = name nothing (an older server ignores the field anyway).
    static func syncCallID(held: String?, pushRings: [String: String], lastPushKey: String?, rememberedIncoming: String?) -> String? {
        if let held, !held.isEmpty { return held }
        if let key = lastPushKey, let id = pushRings[key], !id.isEmpty { return id }
        if let key = pushRings.keys.sorted().first(where: { !(pushRings[$0] ?? "").isEmpty }), let id = pushRings[key] { return id }
        if let rememberedIncoming, !rememberedIncoming.isEmpty { return rememberedIncoming }
        return nil
    }

    // MARK: offers

    /// The same offer again (a web caller re-sends its unanswered first offer every 4 s, 3 times): answered again with the
    /// answer already made, without renegotiating. Compared with the raw text last applied (WebRTC's own copy of the remote
    /// description gains trickled candidates, so it never matches).
    static func isRepeatedOffer(_ sdp: String, lastApplied: String?, stable: Bool) -> Bool {
        stable && !sdp.isEmpty && lastApplied == sdp
    }

    /// The first offer is sent again while unanswered: every 4 s, at most 3 times (web callEngine, same rule).
    static let offerResendDelays: [UInt64] = [4, 4, 4]

    // MARK: a ring that arrived while placing a call

    /// The ring that came in while this phone was placing a call is asked about again (call.sync) when our call ends
    /// without having connected, within 50 s of that ring.
    static func shouldRecheckIncoming(rememberedAt: Date, now: Date, ourCallConnected: Bool) -> Bool {
        !ourCallConnected && now.timeIntervalSince(rememberedAt) <= 50
    }

    // MARK: TURN

    /// When to fetch fresh TURN credentials during a call: at 80 % of `ttl_seconds`, never sooner than 30 s. nil when the
    /// server gives no lifetime (an older server): no refresh, as before.
    static func iceRefreshDelay(ttl: Int?) -> TimeInterval? {
        guard let ttl, ttl > 0 else { return nil }
        return max(30, Double(ttl) * 4 / 5) // 80 %, exact for whole seconds
    }

    /// The server's own rule (contract section 6): `stun|turn|turns:host[:port]`, `?transport=udp|tcp` for turn/turns only.
    /// A URL that does not pass is dropped here instead of making WebRTC refuse the whole configuration.
    static func validICEURL(_ url: String) -> Bool {
        guard let colon = url.firstIndex(of: ":") else { return false }
        let scheme = url[..<colon]
        guard scheme == "stun" || scheme == "turn" || scheme == "turns" else { return false }
        let rest = url[url.index(after: colon)...]
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let hostPort = parts.first, !hostPort.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:[]"))
        guard hostPort.unicodeScalars.allSatisfy({ allowed.contains($0) }), !hostPort.hasPrefix(":") else { return false }
        if parts.count == 2 {
            guard scheme != "stun", parts[1] == "transport=udp" || parts[1] == "transport=tcp" else { return false }
        }
        return true
    }
}
