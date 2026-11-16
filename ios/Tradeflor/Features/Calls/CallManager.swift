import Foundation
import Combine
import AVFoundation
import CallKit
import WebRTC

/// 1-to-1 voice calls, interoperable with the website's call engine (desktop/src/features/calls/callEngine.ts) and the
/// server's call service. The rules that matter for interop:
/// - signaling is `call.*` frames on the same /ws socket; the server binds a call to this device session
/// - the caller makes the first offer after `call.accepted`; the callee never offers first and attaches its mic to the
///   offered audio transceiver (one audio m-line); caller impolite, callee polite ("perfect negotiation")
/// - trickle ICE: candidates as {candidate, sdpMid, sdpMLineIndex}; no end-of-candidates frame
/// - `call.connected` once DTLS is up; `call.media {muted}` for mute; `call.ended` is the authoritative end
/// - audio only (the server and web support voice calls only)
/// CallKit shows the system call UI (lock screen, Bluetooth, the green bar). Without a paid Apple account there is no
/// VoIP push, so an incoming call rings only while the app is running and connected.
@MainActor
final class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    enum Phase: Equatable { case idle, outgoing, incoming, connecting, active, ended }
    enum Role { case caller, callee }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peerName = ""
    @Published private(set) var muted = false
    @Published private(set) var speaker = false
    @Published private(set) var peerMuted = false
    @Published private(set) var connectedAt: Date?
    @Published private(set) var endReason: String?
    @Published private(set) var enabled = false
    @Published var showScreen = false

    private var live: LiveConnection?
    private var token = ""
    private var me = ""
    private var subs = Set<AnyCancellable>()

    private var callID: String?
    private var conversationID: String?
    private var role: Role = .caller
    private var acknowledged = false
    private var uuid = UUID()

    private static let factory: RTCPeerConnectionFactory = {
        _ = RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
    private var pc: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var micAttached = false
    private var makingOffer = false
    private var pendingSignals: [[String: Any]] = []
    private var pendingCandidates: [RTCIceCandidate] = []
    private var sentConnected = false
    private var restarts = 0
    private var disconnectTimer: Task<Void, Never>?
    private var safetyTimer: Task<Void, Never>?

    private let provider: CXProvider
    private let callController = CXCallController()

    override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        cfg.includesCallsInRecents = false
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    // MARK: wiring

    func attach(live: LiveConnection, token: String, userID: String) {
        guard self.token != token else { return }
        self.live = live
        self.token = token
        self.me = userID
        subs.removeAll()
        live.calls.receive(on: RunLoop.main).sink { [weak self] ev in self?.handle(ev.type, ev.data) }.store(in: &subs)
        live.opened.receive(on: RunLoop.main).sink { [weak self] in self?.send("call.sync", [:]) }.store(in: &subs)
        Task { enabled = (try? await APIClient.shared.callsEnabled(token: token)) ?? false }
    }

    func detach() {
        if phase != .idle { hangUp() }
        subs.removeAll()
        token = ""
        enabled = false
    }

    @discardableResult
    private func send(_ type: String, _ data: [String: Any]) -> Bool {
        live?.send(type: type, data: data) ?? false
    }

    // MARK: user actions

    func start(conversationID: String, peerName: String) {
        guard phase == .idle, enabled else { return }
        Task {
            guard await micAllowed() else { endReason = "mic_denied"; finish(); return }
            let id = UUID()
            uuid = id
            callID = id.uuidString.lowercased()
            self.conversationID = conversationID
            self.peerName = peerName
            role = .caller
            acknowledged = false
            phase = .outgoing
            showScreen = true
            let handle = CXHandle(type: .generic, value: peerName)
            let action = CXStartCallAction(call: id, handle: handle)
            action.isVideo = false
            callController.request(CXTransaction(action: action)) { _ in }
            send("call.invite", ["call_id": callID ?? "", "conversation_id": conversationID])
            arm(seconds: 70) { [weak self] in self?.hangUp() }
        }
    }

    func accept() {
        guard phase == .incoming else { return }
        callController.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { [weak self] err in
            if err != nil { Task { @MainActor in self?.doAccept() } }
        }
    }

    private func doAccept() {
        guard phase == .incoming, let id = callID else { return }
        phase = .connecting
        showScreen = true
        Task {
            guard await micAllowed() else {
                send("call.decline", ["call_id": id])
                endReason = "mic_denied"
                finish()
                return
            }
            send("call.accept", ["call_id": id])
            arm(seconds: 45) { [weak self] in self?.hangUp() }
        }
    }

    func decline() {
        guard phase == .incoming, let id = callID else { return }
        send("call.decline", ["call_id": id])
        endReason = "declined"
        finish()
    }

    func hangUp() {
        guard let id = callID else { finish(); return }
        switch phase {
        case .outgoing: send("call.cancel", ["call_id": id])
        case .incoming: send("call.decline", ["call_id": id])
        case .connecting, .active: send("call.hangup", ["call_id": id])
        default: break
        }
        // the server answers with call.ended; if the socket is down, end here
        if !(live?.connected ?? false) { finish() } else { arm(seconds: 5) { [weak self] in self?.finish() } }
    }

    func toggleMute() {
        muted.toggle()
        audioTrack?.isEnabled = !muted
        if let id = callID, phase == .connecting || phase == .active { send("call.media", ["call_id": id, "muted": muted]) }
        provider.reportCall(with: uuid, updated: CXCallUpdate())
    }

    func toggleSpeaker() {
        speaker.toggle()
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.overrideOutputAudioPort(speaker ? .speaker : .none)
        s.unlockForConfiguration()
    }

    private func micAllowed() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    // MARK: server events

    private func handle(_ type: String, _ d: [String: Any]) {
        let cid = d["call_id"] as? String
        switch type {
        case "call.incoming":
            guard phase == .idle, (d["callee_id"] as? String) == me, let id = cid else { return }
            ringIncoming(d, id: id)
        case "call.outgoing":
            let summary = (d["call"] as? [String: Any]) ?? d
            guard summary["call_id"] as? String == callID else { return }
            acknowledged = true
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
        case "call.merged":
            guard cid == callID, let into = d["into"] as? String else { return }
            callID = into
            role = .callee
            phase = .connecting
        case "call.accepted":
            guard cid == callID else { return }
            phase = .connecting
            arm(seconds: 45) { [weak self] in self?.hangUp() }
            Task { await setUpPeerConnection() }
        case "call.active":
            guard cid == callID else { return }
            markActive()
        case "call.signal":
            guard cid == callID else { return }
            if pc == nil { pendingSignals.append(d) } else { Task { await applySignal(d) } }
        case "call.peer_media":
            guard cid == callID else { return }
            peerMuted = (d["muted"] as? Bool) ?? false
        case "call.ended":
            guard cid == callID else { return }
            endReason = d["reason"] as? String
            finish()
        case "call.sync":
            let call = d["call"] as? [String: Any]
            if call == nil {
                // the server knows no call for this device: end ours, unless our invite was not acknowledged yet
                if phase != .idle && !(phase == .outgoing && !acknowledged) { endReason = "connection_lost"; finish() }
            } else if let c = call, phase == .idle, (c["state"] as? String) == "ringing", (c["role"] as? String) == "callee",
                      let id = c["call_id"] as? String {
                ringIncoming(c, id: id)
            }
        case "call.error":
            guard cid == nil || cid == "" || cid == callID else { return }
            if (d["op"] as? String) == "call.invite" || phase == .outgoing {
                endReason = d["code"] as? String
                finish()
            }
        default:
            break
        }
    }

    private func ringIncoming(_ d: [String: Any], id: String) {
        callID = id
        conversationID = d["conversation_id"] as? String
        role = .callee
        uuid = UUID(uuidString: id) ?? UUID()
        phase = .incoming
        peerName = NSLocalizedString("call.someone", comment: "")
        if let caller = d["caller_id"] as? String { Task { await lookUpName(caller) } }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: peerName)
        update.localizedCallerName = peerName
        update.hasVideo = false
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in }
        showScreen = true
        arm(seconds: 50) { [weak self] in
            guard let self, self.phase == .incoming else { return }
            self.endReason = "no_answer"
            self.finish()
        }
    }

    private func lookUpName(_ userID: String) async {
        if let list = try? await APIClient.shared.conversations(token: token),
           let c = list.first(where: { $0.peer_id == userID }) {
            peerName = c.title
            let update = CXCallUpdate()
            update.localizedCallerName = c.title
            update.remoteHandle = CXHandle(type: .generic, value: c.title)
            provider.reportCall(with: uuid, updated: update)
        }
    }

    // MARK: WebRTC

    private func setUpPeerConnection() async {
        guard pc == nil else { return }
        let ice = (try? await APIClient.shared.iceServers(token: token)) ?? []
        let cfg = RTCConfiguration()
        cfg.iceServers = ice
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
        cfg.sdpSemantics = .unifiedPlan
        cfg.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let conn = Self.factory.peerConnection(with: cfg, constraints: constraints, delegate: self) else {
            fail("negotiation_failed")
            return
        }
        pc = conn
        let source = Self.factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: ["googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true"],
            optionalConstraints: nil))
        let track = Self.factory.audioTrack(with: source, trackId: "mic")
        track.isEnabled = !muted
        audioTrack = track
        if role == .caller {
            conn.add(track, streamIds: ["tf"]) // triggers negotiation: we make the first offer
            micAttached = true
        }
        let queued = pendingSignals
        pendingSignals = []
        for s in queued { await applySignal(s) }
    }

    private func makeOffer() async {
        guard let pc else { return }
        makingOffer = true
        defer { makingOffer = false }
        do {
            let offer = try await pc.tfOffer()
            try await pc.tfSetLocal(offer)
            sendDescription(offer)
        } catch {
            fail("negotiation_failed")
        }
    }

    private func applySignal(_ d: [String: Any]) async {
        guard let pc, let kind = d["kind"] as? String, let payload = d["payload"] as? [String: Any] else { return }
        if kind == "candidate" {
            guard let c = payload["candidate"] as? String else { return }
            let cand = RTCIceCandidate(sdp: c, sdpMLineIndex: Int32((payload["sdpMLineIndex"] as? Int) ?? 0),
                                       sdpMid: payload["sdpMid"] as? String)
            if pc.remoteDescription == nil { pendingCandidates.append(cand) } else { try? await pc.tfAdd(cand) }
            return
        }
        guard kind == "description", let t = payload["type"] as? String else { return }
        let sdp = (payload["sdp"] as? String) ?? ""
        do {
            if t == "offer" {
                let collision = makingOffer || pc.signalingState != .stable
                if collision && role == .caller { return } // impolite: ignore theirs, ours wins
                if collision { try await pc.tfSetLocal(RTCSessionDescription(type: .rollback, sdp: "")) }
                try await pc.tfSetRemote(RTCSessionDescription(type: .offer, sdp: sdp))
                attachMicIfNeeded()
                let answer = try await pc.tfAnswer()
                try await pc.tfSetLocal(answer)
                sendDescription(answer)
            } else if t == "answer" {
                try await pc.tfSetRemote(RTCSessionDescription(type: .answer, sdp: sdp))
            } else {
                return
            }
            let queued = pendingCandidates
            pendingCandidates = []
            for c in queued { try? await pc.tfAdd(c) }
        } catch {
            fail("negotiation_failed")
        }
    }

    /// Callee: put the mic on the audio transceiver the caller's offer created, so there is one audio m-line.
    private func attachMicIfNeeded() {
        guard !micAttached, let pc, let track = audioTrack else { return }
        if let t = pc.transceivers.first(where: { $0.mediaType == .audio }) {
            t.sender.track = track
            t.sender.streamIds = ["tf"]
            var err: NSError?
            t.setDirection(.sendRecv, error: &err)
        } else {
            pc.add(track, streamIds: ["tf"])
        }
        micAttached = true
    }

    private func sendDescription(_ desc: RTCSessionDescription) {
        guard let id = callID else { return }
        send("call.signal", ["call_id": id, "kind": "description",
                             "payload": ["type": RTCSessionDescription.string(for: desc.type), "sdp": desc.sdp]])
    }

    private func sendCandidate(_ c: RTCIceCandidate) {
        guard let id = callID else { return }
        var payload: [String: Any] = ["candidate": c.sdp, "sdpMLineIndex": Int(c.sdpMLineIndex)]
        if let mid = c.sdpMid { payload["sdpMid"] = mid }
        send("call.signal", ["call_id": id, "kind": "candidate", "payload": payload])
    }

    private func connectionChanged(_ state: RTCPeerConnectionState) {
        if state == .connected, !sentConnected, let id = callID {
            sentConnected = true
            send("call.connected", ["call_id": id])
            if muted { send("call.media", ["call_id": id, "muted": true]) }
            markActive()
        }
    }

    private func iceChanged(_ state: RTCIceConnectionState) {
        switch state {
        case .connected, .completed:
            disconnectTimer?.cancel()
        case .disconnected:
            disconnectTimer?.cancel()
            disconnectTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if !Task.isCancelled { await self?.restartIce() }
            }
        case .failed:
            Task { await restartIce() }
        default:
            break
        }
    }

    private func restartIce() async {
        guard let pc, phase == .connecting || phase == .active else { return }
        restarts += 1
        if restarts > 3 { fail("ice_failed"); return }
        if let ice = try? await APIClient.shared.iceServers(token: token) {
            let cfg = pc.configuration
            cfg.iceServers = ice
            _ = pc.setConfiguration(cfg)
        }
        pc.restartIce() // fires "negotiation needed": a new offer from this side
    }

    private func fail(_ cls: String) {
        if let id = callID { send("call.failed", ["call_id": id, "class": cls]) }
        endReason = "failed"
        finish()
    }

    private func markActive() {
        guard phase != .active else { return }
        phase = .active
        safetyTimer?.cancel()
        if connectedAt == nil { connectedAt = Date() }
        if role == .caller { provider.reportOutgoingCall(with: uuid, connectedAt: connectedAt) }
    }

    private func arm(seconds: Double, _ action: @escaping @MainActor () -> Void) {
        safetyTimer?.cancel()
        safetyTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { action() }
        }
    }

    /// Ends locally: closes media, tells CallKit, and shows "Call ended" briefly.
    private func finish() {
        guard phase != .ended else { return }
        let hadCall = callID != nil
        safetyTimer?.cancel()
        disconnectTimer?.cancel()
        pc?.close()
        pc = nil
        audioTrack = nil
        micAttached = false
        makingOffer = false
        pendingSignals = []
        pendingCandidates = []
        sentConnected = false
        restarts = 0
        if hadCall {
            let reason: CXCallEndedReason = endReason == "no_answer" ? .unanswered
                : (endReason == "answered_elsewhere" ? .answeredElsewhere : .remoteEnded)
            provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
            callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
        }
        callID = nil
        phase = .ended
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if phase == .ended {
                phase = .idle
                showScreen = false
                connectedAt = nil
                muted = false
                speaker = false
                peerMuted = false
                endReason = nil
            }
        }
    }
}

// MARK: RTCPeerConnectionDelegate (called on WebRTC's thread: hop to the main actor)

extension CallManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        Task { @MainActor in
            // the callee only negotiates for an ICE restart; its first answer comes from the caller's offer
            guard self.pc === peerConnection, self.role == .caller || self.restarts > 0 else { return }
            await self.makeOffer()
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in if self.pc === peerConnection { self.iceChanged(newState) } }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in if self.pc === peerConnection { self.sendCandidate(candidate) } }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in if self.pc === peerConnection { self.connectionChanged(newState) } }
    }
}

// MARK: CXProviderDelegate (system call UI)

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.finish() }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in self.doAccept() }
        action.fulfill()
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            if self.phase == .incoming { self.decline() } else if self.phase != .ended && self.phase != .idle { self.hangUp() }
        }
        action.fulfill()
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let wantMuted = action.isMuted
        Task { @MainActor in if self.muted != wantMuted { self.toggleMute() } }
        action.fulfill()
    }
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        let s = RTCAudioSession.sharedInstance()
        s.audioSessionDidActivate(audioSession)
        s.isAudioEnabled = true
    }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        let s = RTCAudioSession.sharedInstance()
        s.audioSessionDidDeactivate(audioSession)
        s.isAudioEnabled = false
    }
}

// Explicit completion-handler wrappers (the ObjC API also has sync and auto-imported async overloads; these avoid
// ambiguity between them).
private struct RTCFailure: Error {}

extension RTCPeerConnection {
    private static var noConstraints: RTCMediaConstraints { RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil) }

    func tfOffer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<RTCSessionDescription, Error>) in
            self.offer(for: Self.noConstraints, completionHandler: { sdp, err in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: err ?? RTCFailure()) }
            })
        }
    }

    func tfAnswer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<RTCSessionDescription, Error>) in
            self.answer(for: Self.noConstraints, completionHandler: { sdp, err in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: err ?? RTCFailure()) }
            })
        }
    }

    func tfSetLocal(_ d: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.setLocalDescription(d, completionHandler: { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            })
        }
    }

    func tfSetRemote(_ d: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.setRemoteDescription(d, completionHandler: { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            })
        }
    }

    func tfAdd(_ candidate: RTCIceCandidate) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.add(candidate, completionHandler: { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            })
        }
    }
}

// MARK: call REST endpoints

private struct CallsConfig: Decodable { let enabled: Bool }
private struct IceServersResponse: Decodable {
    struct Server: Decodable { let urls: [String]; let username: String?; let credential: String? }
    let ice_servers: [Server]
}

extension APIClient {
    /// GET /calls/config: calls are on for this account (server switch and rollout list).
    func callsEnabled(token: String) async throws -> Bool {
        let data = try await getJSON("calls/config", token: token)
        return (try? JSONDecoder().decode(CallsConfig.self, from: data))?.enabled ?? false
    }

    /// GET /calls/ice-servers: STUN and short-lived TURN credentials, fetched fresh for every connection.
    func iceServers(token: String) async throws -> [RTCIceServer] {
        let data = try await getJSON("calls/ice-servers", token: token)
        let out = try JSONDecoder().decode(IceServersResponse.self, from: data)
        return out.ice_servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
    }
}
