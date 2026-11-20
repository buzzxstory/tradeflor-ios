import Foundation
import Combine
import AVFoundation
import CallKit
import UserNotifications
import UIKit
import WebRTC
import os

/// Call timing (Console: subsystem com.tradeflor.ios, category call): how long after the tap the call screen closed, and
/// how long the peer connection and audio teardown took in the background.
private let callLog = Logger(subsystem: "com.tradeflor.ios", category: "call")

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

    @Published private(set) var phase: Phase = .idle {
        // while a call is on, the live socket reconnects without backoff (the server keeps a call for a device whose socket
        // is away: 20 s while it is still connecting, 90 s once it is active; an older server 20 s for both)
        didSet { live?.callInProgress = phase != .idle && phase != .ended }
    }
    @Published private(set) var peerName = ""
    @Published private(set) var muted = false
    @Published private(set) var speaker = false { didSet { applyRemoteVolume() } }
    @Published private(set) var peerMuted = false
    @Published private(set) var connectedAt: Date?
    @Published private(set) var endReason: String?
    @Published private(set) var enabled = false
    @Published var showScreen = false
    /// Outgoing: the other side's device is ringing (online), not just "calling".
    @Published private(set) var ringing = false
    /// Active call whose connection dropped: trying to get it back (ICE restart).
    @Published private(set) var reconnecting = false
    @Published private(set) var peerID: String?
    /// How long the call that just ended lasted (shown on the end-of-call card).
    @Published private(set) var lastDuration: TimeInterval?
    /// The call that just ended was ended on this phone by the person (End, Cancel, Decline, or the system call screen's
    /// End): no end-of-call notice then (website: nothing shows when you end it yourself). Cleared with the linger.
    @Published private(set) var endedByMe = false
    /// When End / Decline was pressed (CACurrentMediaTime), for the timing log in finish().
    private var endTappedAt: CFTimeInterval?
    /// A call holds the phone's audio: voice notes and videos must not change or switch off the audio session meanwhile
    /// (a .playback category or setActive(false) cuts the call's microphone and sound).
    var lineInUse: Bool { phase != .idle && phase != .ended }
    /// CallKit put this call on hold (a phone call answered with "Hold & Accept"): no microphone until it is resumed.
    private var held = false

    private var live: LiveConnection?
    private var token = ""
    private var me = ""
    private var subs = Set<AnyCancellable>()

    private var callID: String?
    /// The user pressed End on this phone (so a CallKit end that follows is theirs, not the system's).
    private var userEnding = false
    /// Why this phone ended the call itself, when the server would only say "canceled".
    private var localReason: String?
    private var conversationID: String?
    /// The chat this call belongs to (the call screen's "Message" button).
    var conversation: String? { conversationID }
    private var role: Role = .caller
    private var acknowledged = false
    private var uuid = UUID()
    /// This phone started the call through CallKit (CXStartCallAction): CallKit is told when it connects, also after a
    /// glare merge turned us into the callee.
    private var startedHere = false
    /// Accept was tapped in the app: a second tap (or CallKit's answer racing it) must not answer twice.
    private var answering = false
    /// The 1.8 s "Call ended" linger; a new call that starts meanwhile cancels it (or it would reset the new call).
    private var linger: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private static let factory: RTCPeerConnectionFactory = {
        _ = RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
    private var pc: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    /// The other person's voice. On the loudspeaker the call (voice-chat mode) is quiet: its gain is raised (WebRTC's own
    /// 0...10 volume of a remote track), back to normal on the earpiece and on headsets.
    private var remoteTrack: RTCAudioTrack?
    private func applyRemoteVolume() {
        remoteTrack?.source.volume = speaker ? 4 : 1
    }
    private var micAttached = false
    private var makingOffer = false
    private var pendingSignals: [[String: Any]] = []
    private var pendingCandidates: [RTCIceCandidate] = []
    private var sentConnected = false
    /// ICE restarts in a row without getting the connection back (web callEngine.ts MAX_ICE_RESTARTS = 3); back to 0 once
    /// media flows again, so a long call survives several separate blips.
    private var restarts = 0
    /// This side asked for an ICE restart: the callee may make an offer (otherwise only the caller offers).
    private var restartPending = false
    /// The wait before an ICE restart (3.5 s grace for "disconnected", web DISCONNECT_GRACE_MS) and between attempts (9 s,
    /// web RESTART_WAIT_MS).
    private var restartTimer: Task<Void, Never>?
    /// An ICE restart was due while the app's own live socket was down: its offer could not travel, so no attempt was
    /// spent. It is made as soon as the socket is back (resumeAfterSocketGap).
    private var restartWaitingForSocket = false
    /// How many times that happened since the media last flowed (see restartIce for the limit).
    private var socketWaits = 0
    /// The limit of one such wait (90 s, what the server gives an active call whose device is away): after it the call
    /// ends here as "connection_lost", so it never stays on "Reconnecting..." for good.
    private var socketWaitTimer: Task<Void, Never>?
    /// "Reconnecting..." only for a disconnection that lasts 2 s (web RECONNECTING_LABEL_MS).
    private var labelTimer: Task<Void, Never>?
    private var safetyTimer: Task<Void, Never>?
    /// Offers, answers and candidates are applied one at a time, in arrival order: WebRTC's asynchronous steps must not
    /// interleave (an offer applied while our own was half made is what broke renegotiation).
    private var negotiation: Task<Void, Never>?
    /// The raw text of the last offer applied: the same offer again is answered with the answer already made (a web
    /// caller re-sends its unanswered first offer; CallDecisions.isRepeatedOffer).
    private var lastRemoteOffer: String?
    /// Our first offer, sent again every 4 s (3 times) while unanswered (it may be lost in a socket gap).
    private var offerResend: Task<Void, Never>?
    /// The connecting timer already gave one more period because our media was up (CALL-1): the next one hangs up.
    private var connectGraceUsed = false
    /// TURN credentials refreshed during the call at 80 % of their lifetime (CallDecisions.iceRefreshDelay).
    private var iceRefresh: Task<Void, Never>?
    /// A ring that arrived while this phone was placing a call (our invite not yet on the server): asked about again with
    /// call.sync if our call ends without connecting (CallDecisions.shouldRecheckIncoming).
    private var pendingIncoming: (id: String, at: Date)?

    private let provider: CXProvider
    private let callController = CXCallController()

    // MARK: VoIP push (PushKit)
    /// Call ids a VoIP push already reported to CallKit, not yet seen on the live socket.
    private var pushCalls = Set<String>()
    /// The server's own call id of each of them (pushCalls holds CallKit UUID strings), and the newest one: call.sync asks
    /// the server about it.
    private var pushCallID: [String: String] = [:]
    private var lastPushKey: String?
    /// The call id the last call.sync asked about (the answer's `ended` may not repeat it).
    private var syncAsked: String?

    /// call.sync, sent every time the socket opens. With the id of the call this phone holds (else of the ring a VoIP push
    /// started), the server can say what became of exactly that call (`ended`), and a call it restored after a restart is
    /// claimed back. A server that does not know the field ignores it.
    /// The server keeps a call through a socket gap only if the device names it here (contract section 6, "claim").
    private func sendSync(remembered: String? = nil) {
        var rings: [String: String] = [:]
        for key in pushCalls { if let id = pushCallID[key] { rings[key] = id } }
        var data: [String: Any] = [:]
        // the call in hand wins over a push ring, a push ring over a ring remembered while placing a call
        if let id = CallDecisions.syncCallID(held: lineInUse ? callID : nil, pushRings: rings, lastPushKey: lastPushKey,
                                             rememberedIncoming: remembered) {
            data["call_id"] = id
        }
        syncAsked = data["call_id"] as? String
        send("call.sync", data)
    }

    /// The person answered / declined in the system UI before the socket told the app about the call: done when it does.
    private var pendingAnswer: UUID?
    private var pendingEnd: UUID?

    /// iOS demands a CallKit incoming call for every VoIP push, before anything else: it rings as "Tradeflor" and the real
    /// name arrives with the call on the socket (ringIncoming). A call the socket never knows (it ended before this phone
    /// woke up) is ended again, so no phantom ring stays.
    func reportPushCall(callID: String) {
        if !callID.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [callID])
            // the alert and the VoIP push leave the server together: the alert may land after this, so once more
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                // only while this call still rings or runs: once it ended, the same identifier holds its "Missed call" notice
                guard let self, !self.endedHere.contains(callID) else { return }
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [callID])
            }
        }
        let id = CallManager.callUUID(callID) ?? UUID()
        let update = callCapabilities()
        let name = (self.callID == callID && !peerName.isEmpty) ? peerName : "Tradeflor"
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        let key = id.uuidString
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] err in
            guard err == nil else { return } // already ringing from the socket, or the system refused (Do Not Disturb)
            Task { @MainActor in
                guard let self else { return }
                if self.endedHere.contains(callID) {
                    // a late push for a call the socket already saw end (cancelled, declined, answered elsewhere): it was
                    // reported as iOS demands and ends at once, instead of ringing 25 s for nobody (in front the socket
                    // is healthy, so no call.sync comes to end it)
                    self.provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
                    return
                }
                self.pushCalls.insert(key)
                if !callID.isEmpty { self.pushCallID[key] = callID; self.lastPushKey = key }
                self.guardPushCall(key: key, uuid: id)
            }
        }
    }

    /// A VoIP push that arrived with no account signed in (it was in flight across a sign-out): iOS demands a CallKit report
    /// for every VoIP push, so it is reported and ended at once (audit IOS-APL-5).
    func reportEndedPushCall(callID: String) {
        let id = CallManager.callUUID(callID) ?? UUID()
        let update = callCapabilities()
        update.remoteHandle = CXHandle(type: .generic, value: "Tradeflor")
        update.localizedCallerName = "Tradeflor"
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] err in
            guard err == nil else { return }
            Task { @MainActor in self?.provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded) }
        }
    }

    /// The CallKit UUID of a call id, the same for the VoIP push and the socket. Call ids are normally UUIDs; a browser
    /// without crypto.randomUUID (and the server's own tools) make 32 hex digits without dashes, which is the same value
    /// written differently. nil for anything else (the caller then makes a random one).
    nonisolated static func callUUID(_ id: String) -> UUID? {
        if let u = UUID(uuidString: id) { return u }
        guard id.count == 32, id.utf8.count == 32 else { return nil }
        var s = id
        for offset in [20, 16, 12, 8] { s.insert("-", at: s.index(s.startIndex, offsetBy: offset)) }
        return UUID(uuidString: s)
    }

    private func guardPushCall(key: String, uuid: UUID) {
        Task { @MainActor [weak self] in
            // a new socket is on its way (PushManager.ensureConnected): the call comes in with it. Up to 25 s are given before the
            // ring is taken back (the caller rings 45 s; a call the server does not know any more is not left ringing).
            var waited = 0
            while waited < 50 {
                guard let self, self.pushCalls.contains(key) else { return } // the socket knows it now
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 1
            }
            guard let self else { return }
            self.pushCallID[key] = nil // the 25 s are over
            guard self.pushCalls.contains(key) else { return }
            self.pushCalls.remove(key)
            if self.uuid != uuid || self.phase == .idle || self.phase == .ended {
                self.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
            }
        }
    }

    override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        // not in the Phone app's Recents: tapping one there would open the app without placing the call (no call intents)
        cfg.includesCallsInRecents = false
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
        CallDeviceGuard.shared.watch(self) // proximity sensor and no auto-lock during a call
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        let nc = NotificationCenter.default
        // AirPods connected, the speaker override dropped by iOS...: the Speaker button follows the real route
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.routeChanged() }
        })
        // only matters when CallKit is not managing the audio (it refused the call, or reset): an interruption (a phone
        // call, Siri) leaves the session off, and nothing would switch it back on
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap { AVAudioSession.InterruptionType(rawValue: $0) } == .began
            Task { @MainActor in self?.interrupted(began: began) }
        })
    }

    /// What the user chose with the Speaker button. iOS (or WebRTC starting its audio unit) can drop the loudspeaker
    /// override without telling the app: the choice is kept and applied again, instead of the button flipping back to off
    /// (which looked like "the speaker does nothing").
    private var wantSpeaker = false

    /// One line per audio milestone (route, category, mode, WebRTC's switch): a "no sound" report can then be traced.
    private func logAudio(_ what: String) {
        let a = AVAudioSession.sharedInstance()
        let outs = a.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let ins = a.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        NSLog("[call-audio] %@ category=%@ mode=%@ out=%@ in=%@ rtcEnabled=%d wantSpeaker=%d own=%d", what,
              a.category.rawValue, a.mode.rawValue, outs, ins, RTCAudioSession.sharedInstance().isAudioEnabled ? 1 : 0,
              wantSpeaker ? 1 : 0, ownAudio ? 1 : 0)
    }

    private func applySpeaker() {
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.overrideOutputAudioPort(wantSpeaker ? .speaker : .none)
        s.unlockForConfiguration()
    }

    /// The audio unit of WebRTC starts a moment after CallKit switches the session on and may reset the route then:
    /// apply the choice again shortly after.
    private func reapplySpeakerSoon() {
        applySpeaker()
        Task { @MainActor [weak self] in
            for ms in [350, 900, 2000] as [UInt64] {
                try? await Task.sleep(nanoseconds: ms * 1_000_000)
                guard let self, self.lineInUse else { return }
                let out = AVAudioSession.sharedInstance().currentRoute.outputs
                if out.contains(where: { Self.isExternal($0.portType) }) { return }
                if out.contains(where: { $0.portType == .builtInSpeaker }) != self.wantSpeaker { self.applySpeaker() }
            }
        }
    }

    /// Headphones, AirPods, a car, AirPlay...: the phone's own speaker choice does not apply while one of them plays.
    nonisolated private static func isExternal(_ t: AVAudioSession.Port) -> Bool {
        switch t {
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones, .headsetMic, .usbAudio, .carAudio, .airPlay, .HDMI, .lineOut:
            return true
        default: return false
        }
    }

    private func routeChanged() {
        guard lineInUse, AVAudioSession.sharedInstance().category == .playAndRecord else { return }
        let out = AVAudioSession.sharedInstance().currentRoute.outputs
        if out.contains(where: { Self.isExternal($0.portType) }) {
            // AirPods or headphones took the call: the Speaker button goes off, as in WhatsApp
            wantSpeaker = false
            if speaker { speaker = false }
            return
        }
        let onSpeaker = out.contains { $0.portType == .builtInSpeaker }
        if wantSpeaker && !onSpeaker { applySpeaker(); return } // iOS dropped the override: put it back
        if wantSpeaker != onSpeaker { wantSpeaker = onSpeaker }
        if speaker != onSpeaker { speaker = onSpeaker }
    }

    private func interrupted(began: Bool) {
        guard ownAudio, lineInUse else { return }
        let s = RTCAudioSession.sharedInstance()
        if began { s.isAudioEnabled = false; return }
        s.lockForConfiguration()
        try? s.setActive(true)
        s.unlockForConfiguration()
        s.isAudioEnabled = true
        reapplySpeakerSoon()
    }

    /// Clears what the previous call left (its "Call ended" linger may still be on) before a new call starts.
    private func beginCall() {
        linger?.cancel(); linger = nil
        // a previous call's teardown still queued in the background must not switch this call's audio off
        audioGeneration.bump()
        if phase == .ended { phase = .idle }
        endedByMe = false
        endTappedAt = nil
        connectedAt = nil
        muted = false
        speaker = false
        wantSpeaker = false
        peerMuted = false
        ringing = false
        reconnecting = false
        endReason = nil
        lastDuration = nil
        userEnding = false
        localReason = nil
        acknowledged = false
        startedHere = false
        answering = false
        held = false
        connectGraceUsed = false
        lastRemoteOffer = nil
        pendingIncoming = nil
    }

    // MARK: wiring

    func attach(live: LiveConnection, token: String, userID: String) {
        guard self.token != token else { return }
        self.live = live
        self.token = token
        self.me = userID
        live.callInProgress = phase != .idle && phase != .ended
        subs.removeAll()
        // DispatchQueue.main, not RunLoop.main: RunLoop.main only delivers in the default run-loop mode, so while a finger
        // scrolls a list an incoming call (and every ICE candidate of a running call) waited until the scroll stopped
        live.calls.receive(on: DispatchQueue.main).sink { [weak self] ev in self?.handle(ev.type, ev.data) }.store(in: &subs)
        live.opened.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.sendSync()
            self?.refreshEnabled() // the first request may have failed (offline launch): ask again when the socket opens
        }.store(in: &subs)
        refreshEnabled()
        applyRingSetting()
    }

    private func refreshEnabled() {
        let t = token
        guard !t.isEmpty, !enabled else { return }
        Task {
            // the answer belongs to the account that asked: a late one for the account that signed out set `enabled`, and
            // the next account's attach then skipped its own check (audit IOS-LC-2)
            if let on = try? await APIClient.shared.callsEnabled(token: t), t == token { enabled = on }
        }
    }

    /// Settings › Calls › Ring for incoming calls.
    func applyRingSetting() {
        let ring = UserDefaults.standard.object(forKey: "tf.calls.ring") as? Bool ?? true
        let cfg = provider.configuration
        cfg.ringtoneSound = ring ? nil : "silence.wav"
        provider.configuration = cfg
    }

    func detach() {
        confirming = nil
        // signing out: the socket closes right after this, so call.ended would never come (the call screen stayed 5 s)
        if lineInUse { hangUp(); finish() }
        // rings a VoIP push reported that the socket never confirmed: ended in CallKit, then forgotten, so the next account's
        // call.sync never asks about the last account's call (audit IOS-LC-2)
        for k in pushCalls {
            if let u = UUID(uuidString: k) { provider.reportCall(with: u, endedAt: Date(), reason: .remoteEnded) }
        }
        pushCalls = []
        pushCallID = [:]
        lastPushKey = nil
        syncAsked = nil
        subs.removeAll()
        token = ""
        enabled = false
    }

    @discardableResult
    private func send(_ type: String, _ data: [String: Any]) -> Bool {
        live?.send(type: type, data: data) ?? false
    }

    // MARK: user actions

    struct PendingCall: Identifiable { let id = UUID(); let conversationID: String; let peerName: String; let peerID: String? }
    /// Settings › Calls › Ask Before Starting a Call: the call waiting for "Call" in the confirmation.
    @Published var confirming: PendingCall?
    /// A call button was tapped and the call is being set up (the settings read, the microphone check): a second tap in
    /// that window started a second call.
    private var starting = false

    func start(conversationID: String, peerName: String, peerID: String? = nil, confirmed: Bool = false) {
        // .ended is the 1.8 s "Call ended" linger: calling back at once is allowed (web: busy() is false once ended)
        guard !lineInUse, enabled, !starting else { return }
        starting = true
        if !confirmed {
            Task {
                // unread (offline, slow): does not ask (calls.confirm is off unless turned on)
                let ask = ((try? await APIClient.shared.stSettings(token: token)) ?? [:])["calls.confirm"] ?? false
                starting = false
                guard !lineInUse else { return } // a call rang in while the setting was read
                if ask { confirming = PendingCall(conversationID: conversationID, peerName: peerName, peerID: peerID) }
                else { start(conversationID: conversationID, peerName: peerName, peerID: peerID, confirmed: true) }
            }
            return
        }
        Task {
            defer { starting = false }
            let allowed = await micAllowed()
            // a call rang in while the permission prompt was up: that one goes on (this one would have overwritten it and
            // left its CallKit call ringing forever)
            guard !lineInUse else { return }
            beginCall()
            self.conversationID = conversationID
            self.peerName = peerName
            self.peerID = peerID
            guard allowed else {
                // the end card says why, with the person's name (it showed nothing, or the previous call's name)
                callID = nil
                endReason = "mic_denied"
                finish()
                return
            }
            let id = UUID()
            uuid = id
            callID = id.uuidString.lowercased()
            role = .caller
            startedHere = true
            phase = .outgoing
            showScreen = true
            let handle = CXHandle(type: .generic, value: peerName)
            let action = CXStartCallAction(call: id, handle: handle)
            action.isVideo = false
            callController.request(CXTransaction(action: action)) { [weak self] err in
                let refused = err != nil
                Task { @MainActor in
                    guard let self = self, self.uuid == id else { return }
                    if refused { self.audioWithoutCallKit() } // CallKit refused: no one else switches the audio on
                    else { self.provider.reportCall(with: id, updated: self.callCapabilities()) }
                }
            }
            arm(seconds: 70) { [weak self] in self?.localReason = "no_answer"; self?.hangUp() }
            let cid = callID ?? ""
            if !sendInvite() {
                // socket down (backoff after a blip): the invite was silently lost and the phone said "Calling..." for
                // 70 s. Reconnect now; call.sync on the new socket sends it (see "call.sync"); no socket in 10 s: offline.
                live?.reconnectNow()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard let self, self.callID == cid, self.phase == .outgoing, !self.acknowledged,
                          !(self.live?.connected ?? false) else { return }
                    self.endReason = "offline"
                    self.finish()
                }
            }
        }
    }

    @discardableResult
    private func sendInvite() -> Bool {
        guard let id = callID, let conv = conversationID else { return false }
        return send("call.invite", ["call_id": id, "conversation_id": conv])
    }

    func accept() {
        guard phase == .incoming, !answering else { return }
        answering = true
        callController.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { [weak self] err in
            guard err != nil else { return }
            // CallKit no longer knows the call (reset, or refused it): answer without it. Only while it still rings here:
            // a failed second request after CallKit's own answer turned on a second, app-owned audio session
            Task { @MainActor in
                guard let self, self.phase == .incoming else { return }
                self.audioWithoutCallKit()
                self.doAccept()
            }
        }
    }

    private func doAccept() {
        guard phase == .incoming, let id = callID else { return }
        phase = .connecting
        showScreen = true
        Task {
            let allowed = await micAllowed()
            // the call may have ended (or another started) while the permission prompt was up
            guard phase == .connecting, callID == id else { return }
            guard allowed else {
                send("call.decline", ["call_id": id])
                endReason = "mic_denied"
                finish()
                return
            }
            // the call may have ended while the permission prompt was up
            guard phase == .connecting, callID == id else { return }
            send("call.accept", ["call_id": id])
            // the server sends this phone's devices a silent "Call ended" alert at this very moment (it replaces the
            // "Incoming call" elsewhere): not on the phone that answered
            LocalNotifier.shared.callAnsweredHere(callID: id)
            arm(seconds: 45) { [weak self] in self?.connectTimedOut() }
        }
    }

    func decline() {
        guard phase == .incoming, let id = callID else { return }
        if endTappedAt == nil { endTappedAt = CACurrentMediaTime() }
        userEnding = true
        send("call.decline", ["call_id": id])
        endReason = "declined"
        finish()
    }

    func hangUp() {
        // still ringing here: a decline (offline it ended with no reason and posted "Missed voice call" for a call the
        // person turned down)
        if endTappedAt == nil { endTappedAt = CACurrentMediaTime() }
        if phase == .incoming { decline(); return }
        userEnding = true
        guard let id = callID else { finish(); return }
        switch phase {
        case .outgoing: send("call.cancel", ["call_id": id])
        case .connecting, .active: send("call.hangup", ["call_id": id])
        default: break
        }
        // end here at once (the card closes and the microphone is released without waiting for the server's call.ended, which
        // is ignored when it arrives: the call id is gone). A frame that was lost is closed again by the next sync (endedHere).
        finish()
    }

    func toggleMute() {
        let want = !muted
        callController.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: want))) { [weak self] err in
            if err != nil { Task { @MainActor in self?.applyMute(want) } }
        }
    }

    /// CallKit normally activates the call's audio session (provider didActivate). When it refused the call, the app does
    /// it itself, or WebRTC never starts the microphone and speaker (and iOS suspends the app in the background).
    /// Calls this phone ended (declined, cancelled, hung up) whose message may not have reached the server (socket down):
    /// a later sync that still lists one is closed again, and never rings.
    private var endedHere: Set<String> = []
    /// The same ids, oldest first (only finish() adds to the two, together).
    private var endedOrder: [String] = []

    private var ownAudio = false { didSet { callAudioOwned.value = ownAudio } }
    private func audioWithoutCallKit() {
        guard !ownAudio else { return }
        ownAudio = true
        audioGeneration.bump() // after a queued teardown's audio reset, never before it
        CallManager.configureAudioSession()
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setActive(true)
        s.unlockForConfiguration()
        s.isAudioEnabled = true
        CallTones.shared.sessionActive = true
    }

    fileprivate func applyHeld(_ value: Bool) {
        held = value
        audioTrack?.isEnabled = !(muted || held)
    }

    /// What CallKit may do with this call: hold it (WhatsApp's "Hold & Accept" for a phone call), nothing else.
    private func callCapabilities() -> CXCallUpdate {
        let u = CXCallUpdate()
        u.supportsHolding = true
        u.supportsGrouping = false
        u.supportsUngrouping = false
        u.supportsDTMF = false
        u.hasVideo = false
        return u
    }

    fileprivate func applyMute(_ value: Bool) {
        guard muted != value else { return }
        muted = value
        audioTrack?.isEnabled = !(muted || held)
        if let id = callID, phase == .connecting || phase == .active { send("call.media", ["call_id": id, "muted": muted]) }
    }

    /// The WebRTC voice-chat audio session (play and record, echo cancellation); CallKit activates it.
    nonisolated fileprivate static func configureAudioSession() {
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        let cfg = RTCAudioSessionConfiguration.webRTC()
        cfg.category = AVAudioSession.Category.playAndRecord.rawValue
        cfg.mode = AVAudioSession.Mode.voiceChat.rawValue
        cfg.categoryOptions = [.allowBluetooth] // A2DP is output-only: not valid with a microphone in a call
        try? s.setConfiguration(cfg)
        s.unlockForConfiguration()
    }

    func toggleSpeaker() {
        // with AirPods / headphones connected the button chooses the phone's loudspeaker over them (and back)
        wantSpeaker.toggle()
        speaker = wantSpeaker
        reapplySpeakerSoon()
    }

    private func micAllowed() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    // MARK: server events

    private func handle(_ type: String, _ d: [String: Any]) {
        // glare whose call.merged was lost: any summary of the merged call names our invite in merged_from (server
        // b35bc5d7): our call continues as its callee (the summary is then handled under the adopted id)
        if type != "call.sync", type != "call.merged", let s = CallDecisions.Server(d),
           let into = CallDecisions.mergeTarget(server: s, placed: callID, phase: phase) {
            adoptMerge(into: into)
        }
        let cid = d["call_id"] as? String
        switch type {
        case "call.incoming":
            guard (d["callee_id"] as? String) == me, let id = cid else { return }
            guard !lineInUse else {
                // ringing while this phone places a call (our invite was not on the server yet): kept, and asked about
                // again if our call ends without connecting (finish)
                if role == .caller, connectedAt == nil, phase == .outgoing || phase == .connecting, id != callID {
                    pendingIncoming = (id, Date())
                }
                return
            }
            // .ended (the "Call ended" linger) is free: a call back within 1.8 s was never shown (web busy() is false then)
            ringIncoming(d, id: id)
        case "call.outgoing":
            let summary = (d["call"] as? [String: Any]) ?? d
            // only while it rings (web): a late or retried answer must not start the ringback over a connecting call
            guard summary["call_id"] as? String == callID, phase == .outgoing else { return }
            acknowledged = true
            ringing = (d["ringing"] as? Bool) ?? ringing
            CallTones.shared.ringback(true)
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
        case "call.merged":
            guard cid == callID, phase == .outgoing, let into = d["into"] as? String else { return }
            adoptMerge(into: into)
        case "call.accepted":
            // hung up meanwhile: the server ends it (call.ended), nothing more to set up
            guard cid == callID, pc == nil, !userEnding else { return }
            CallTones.shared.ringback(false)
            if let r = d["role"] as? String { role = r == "caller" ? .caller : .callee }
            peerID = (role == .caller ? d["callee_id"] : d["caller_id"]) as? String ?? peerID
            phase = .connecting
            arm(seconds: 45) { [weak self] in self?.connectTimedOut() }
            serially { [weak self] in await self?.setUpPeerConnection() }
        case "call.active":
            guard cid == callID else { return }
            markActive()
        case "call.signal":
            guard cid == callID else { return }
            // before call.accepted there is no peer connection yet: kept until setUpPeerConnection
            if pc == nil && negotiation == nil { pendingSignals.append(d) } else { serially { [weak self] in await self?.applySignal(d) } }
        case "call.peer_media":
            guard cid == callID else { return }
            peerMuted = (d["muted"] as? Bool) ?? false
        case "call.ended":
            guard cid == callID else { return }
            endReason = localReason ?? (d["reason"] as? String)
            finish()
        case "call.sync":
            let call = d["call"] as? [String: Any]
            // a newer server also says what became of the call that was asked about (sendSync): answered on another
            // device ({reason: "answered_elsewhere"}), or its final summary (the same `reason` words as call.ended, and a
            // `status`). An older server sends no `ended`: everything below is as before.
            let asked = syncAsked
            syncAsked = nil
            if call == nil, let ended = d["ended"] as? [String: Any], let endedID = (ended["call_id"] as? String) ?? asked {
                var reason = ended["reason"] as? String
                if reason == nil, let status = ended["status"] as? String {
                    // only the statuses that are one of the end reasons this app already shows
                    let known = ["missed": "no_answer", "declined": "declined", "canceled": "canceled", "busy": "busy",
                                 "failed": "failed", "completed": "hangup"]
                    reason = known[status]
                }
                let mine = lineInUse && endedID == callID
                if !mine, let key = CallManager.callUUID(endedID)?.uuidString, pushCalls.contains(key), let u = UUID(uuidString: key) {
                    // a ring a VoIP push started, not yet known here: it stops with the true reason (answered elsewhere is
                    // not a missed call in the system's eyes); nothing is posted for it
                    provider.reportCall(with: u, endedAt: Date(), reason: reason == "answered_elsewhere" ? .answeredElsewhere : .remoteEnded)
                    pushCalls.remove(key)
                    pushCallID[key] = nil
                }
                if mine, let reason {
                    // finish() posts no "Missed voice call" and tells CallKit .answeredElsewhere for "answered_elsewhere"
                    // (and .declinedElsewhere for a decline on another device); other reasons end as call.ended would
                    endReason = localReason ?? reason
                    finish()
                }
            }
            // a ring a VoIP push started for a call the server does not have (cancelled, answered elsewhere) ends now
            let live = (call?["call_id"] as? String).flatMap { CallManager.callUUID($0)?.uuidString }
            for k in pushCalls where k != live {
                if let u = UUID(uuidString: k) { provider.reportCall(with: u, endedAt: Date(), reason: .remoteEnded) }
                pushCalls.remove(k)
                pushCallID[k] = nil
            }
            // what the socket gap may have lost, decided in CallDecisions.syncActions (unit-tested there)
            let server = CallDecisions.Server(call)
            let ice = pc?.iceConnectionState
            let local = CallDecisions.Local(callID: callID, phase: phase, role: role, acknowledged: acknowledged,
                                            hasPeerConnection: pc != nil, mediaUp: ice == .connected || ice == .completed,
                                            endedHere: endedHere)
            for action in CallDecisions.syncActions(server: server, local: local) {
                switch action {
                case .endLost:
                    // the server knows no call for this device (not over the "Call ended" card: syncActions checks)
                    endReason = "connection_lost"
                    finish()
                case .resendInvite:
                    // our invite never reached the server (sent while the socket was down): the same call id, so a
                    // server that did get it answers with its state (call.outgoing / call.ended) instead of a second call
                    sendInvite()
                case .close(let op, let id):
                    // a call we ended while offline, or one left from before the app was killed (no peer connection
                    // survives a relaunch): closed now, not after the server's grace, and no CallKit call stays for it
                    send(op, ["call_id": id])
                    if let u = CallManager.callUUID(id), !(lineInUse && u == uuid) {
                        provider.reportCall(with: u, endedAt: Date(), reason: .remoteEnded)
                    }
                case .ring:
                    if let c = call, let id = server?.id { ringIncoming(c, id: id) }
                case .adoptMerge(let into):
                    adoptMerge(into: into)
                case .acknowledge:
                    acknowledged = true
                    CallTones.shared.ringback(true)
                case .resendAccept:
                    send("call.accept", ["call_id": callID ?? ""]) // our accept was lost: the server still rings us
                case .acceptedLost:
                    // call.accepted was lost in the gap: it rang ("Ringing...") or connected with no peer connection
                    // until the server's 30 s connect timeout
                    if let c = call { handle("call.accepted", c) }
                case .resume:
                    resumeAfterSocketGap()
                case .markActive:
                    // call.active was lost: the server has the call active, the connecting timer must not hang it up
                    markActive()
                case .resendConnected:
                    // call.connected was lost: without it the server fails the call at 30 s (failed/ice_timeout)
                    sendConnected()
                }
            }
        case "call.error":
            // only a refused invite ends the call (web callEngine.ts); a refused signal or media frame is only logged there
            guard cid == nil || cid == "" || cid == callID else { return }
            let op = d["op"] as? String
            if op == "call.invite" && phase == .outgoing {
                endReason = d["code"] as? String
                finish()
            } else if op == "call.accept" && phase == .connecting && pc == nil && cid == callID && callID != nil {
                // the server does not know the call (it restarted): "Connecting..." would wait 45 s for nothing
                endReason = d["code"] as? String
                finish()
            } else if (op == "call.hangup" || op == "call.cancel") && userEnding && cid == callID && callID != nil {
                // nothing left to hang up on the server: no call.ended will come, end now instead of after 5 s
                finish()
            }
        default:
            break
        }
    }

    private func ringIncoming(_ d: [String: Any], id: String) {
        beginCall()
        callID = id
        conversationID = d["conversation_id"] as? String
        role = .callee
        peerID = d["caller_id"] as? String
        uuid = CallManager.callUUID(id) ?? UUID()
        phase = .incoming
        peerName = NSLocalizedString("call.someone", comment: "")
        if let caller = d["caller_id"] as? String { Task { await lookUpName(caller) } }
        let update = callCapabilities()
        update.remoteHandle = CXHandle(type: .generic, value: peerName)
        update.localizedCallerName = peerName
        // the server's visible "Incoming call" alert (collapse id = the call id) is not needed while CallKit rings
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        let ringUUID = uuid, name = peerName, conv = conversationID
        pushCallID[uuid.uuidString] = nil
        if pushCalls.remove(uuid.uuidString) != nil {
            // a VoIP push already made CallKit ring: it only learns who is calling now
            provider.reportCall(with: uuid, updated: update)
        } else {
            provider.reportNewIncomingCall(with: uuid, update: update) { err in
                // CallKit refused to ring (not because of Do Not Disturb or a block): a plain notification instead
                guard let err else { return }
                let code = (err as? CXErrorCodeIncomingCallError)?.code
                guard code != .filteredByDoNotDisturb, code != .filteredByBlockList, code != .callUUIDAlreadyExists else { return }
                Task { @MainActor in
                    guard self.uuid == ringUUID, self.phase == .incoming else { return }
                    LocalNotifier.shared.incomingCallFallback(name: self.peerName.isEmpty ? name : self.peerName, callID: id, conversationID: conv)
                }
            }
        }
        showScreen = true
        arm(seconds: 50) { [weak self] in
            guard let self, self.phase == .incoming else { return }
            self.endReason = "no_answer"
            self.finish()
        }
        // answered or declined in the system call screen before the app knew the call (a VoIP push woke it)
        if pendingEnd == uuid { pendingEnd = nil; pendingAnswer = nil; decline() }
        else if pendingAnswer == uuid { pendingAnswer = nil; doAccept() }
    }

    private func lookUpName(_ userID: String) async {
        let call = uuid
        if let list = try? await APIClient.shared.conversations(token: token),
           let c = list.first(where: { $0.peer_id == userID }),
           uuid == call, lineInUse { // not a name arriving after the call ended (or into the next call)
            peerName = c.title
            let update = callCapabilities()
            update.localizedCallerName = c.title
            update.remoteHandle = CXHandle(type: .generic, value: c.title)
            provider.reportCall(with: uuid, updated: update)
        }
    }

    // MARK: WebRTC

    private func setUpPeerConnection() async {
        guard pc == nil, let id = callID else { return }
        let iceConfig = try? await APIClient.shared.iceConfig(token: token)
        let ice = iceConfig?.servers ?? []
        // the call may have ended while the TURN credentials were on their way
        guard pc == nil, callID == id, phase == .connecting || phase == .active else { return }
        let cfg = RTCConfiguration()
        cfg.iceServers = ice
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
        cfg.sdpSemantics = .unifiedPlan
        cfg.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        var made = Self.factory.peerConnection(with: cfg, constraints: constraints, delegate: self)
        if made == nil && !ice.isEmpty {
            // WebRTC refused the server list (the URLs are already checked with the server's own rule): the call goes on
            // without STUN/TURN (direct and local routes only) instead of failing
            callLog.error("call: ICE server list refused by WebRTC, connecting without it")
            cfg.iceServers = []
            made = Self.factory.peerConnection(with: cfg, constraints: constraints, delegate: self)
        }
        guard let conn = made else {
            fail("negotiation_failed")
            return
        }
        pc = conn
        scheduleIceRefresh(conn, after: CallDecisions.iceRefreshDelay(ttl: iceConfig?.ttl))
        let source = Self.factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: ["googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true"],
            optionalConstraints: nil))
        let track = Self.factory.audioTrack(with: source, trackId: "mic")
        track.isEnabled = !(muted || held)
        audioTrack = track
        if role == .caller {
            conn.add(track, streamIds: ["tf"]) // triggers negotiation: we make the first offer
            micAttached = true
        }
        let queued = pendingSignals
        pendingSignals = []
        for s in queued { await applySignal(s) }
    }

    /// Runs in the negotiation queue. A failed (re)negotiation never ends the call by itself (web callEngine.ts only logs
    /// it): the ICE restart loop and the server's connect timeout decide.
    private func makeOffer(_ conn: RTCPeerConnection) async {
        // not stable: an offer or answer is in progress; WebRTC asks again ("negotiation needed") once it is stable
        guard pc === conn, conn.signalingState == .stable else { return }
        makingOffer = true
        defer { makingOffer = false }
        do {
            let offer = try await conn.tfOffer()
            guard pc === conn, conn.signalingState == .stable else { return }
            try await conn.tfSetLocal(offer)
            sendDescription(offer)
            // the first offer (never answered yet) may be lost in a socket gap: sent again while unanswered
            if conn.remoteDescription == nil { resendFirstOfferWhileUnanswered(conn) }
        } catch {
            print("call: offer failed: \(error)")
        }
    }

    /// Every 4 s, at most 3 times, while our first offer has no answer (web callEngine does the same; the other side
    /// answers a repeated offer with its existing answer, see applySignal).
    private func resendFirstOfferWhileUnanswered(_ conn: RTCPeerConnection) {
        offerResend?.cancel()
        offerResend = Task { @MainActor [weak self] in
            for seconds in CallDecisions.offerResendDelays {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                guard let self, !Task.isCancelled, self.pc === conn, conn.remoteDescription == nil,
                      conn.signalingState == .haveLocalOffer, let offer = conn.localDescription else { return }
                self.sendDescription(offer)
            }
        }
    }

    /// Fresh TURN credentials during the call, before the old ones expire (server ttl_seconds; 600 s today, 12 h later):
    /// setConfiguration with the other settings kept, no ICE restart (media that flows is not touched).
    private func scheduleIceRefresh(_ conn: RTCPeerConnection, after delay: TimeInterval?) {
        iceRefresh?.cancel()
        iceRefresh = nil
        guard let delay else { return } // an older server gives no lifetime: no refresh, as before
        iceRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.pc === conn else { return }
            let fresh = try? await APIClient.shared.iceConfig(token: self.token)
            guard !Task.isCancelled, self.pc === conn else { return }
            guard let fresh, !fresh.servers.isEmpty else {
                self.scheduleIceRefresh(conn, after: 30) // offline or refused: again in 30 s
                return
            }
            self.applyIceServers(fresh.servers, to: conn)
            self.scheduleIceRefresh(conn, after: CallDecisions.iceRefreshDelay(ttl: fresh.ttl))
        }
    }

    private func applyIceServers(_ servers: [RTCIceServer], to conn: RTCPeerConnection) {
        let cfg = conn.configuration
        cfg.iceServers = servers
        if !conn.setConfiguration(cfg) { callLog.error("call: new ICE servers refused by WebRTC, the old ones stay") }
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
                // the same offer again (the web caller re-sends an offer whose answer it has not had): the answer already
                // made goes again; nothing is renegotiated, the connection stays as it is
                if CallDecisions.isRepeatedOffer(sdp, lastApplied: lastRemoteOffer, stable: pc.signalingState == .stable),
                   let answer = pc.localDescription, answer.type == .answer {
                    sendDescription(answer)
                    return
                }
                // both sides restarting ICE at once (both saw the same network blip) is normal: perfect negotiation
                let collision = makingOffer || pc.signalingState != .stable
                if collision && role == .caller { return } // impolite: ignore theirs, ours wins
                if collision && pc.signalingState == .haveLocalOffer {
                    try await pc.tfSetLocal(RTCSessionDescription(type: .rollback, sdp: "")) // polite: drop ours
                }
                try await pc.tfSetRemote(RTCSessionDescription(type: .offer, sdp: sdp))
                lastRemoteOffer = sdp
                attachMicIfNeeded()
                let answer = try await pc.tfAnswer()
                try await pc.tfSetLocal(answer)
                sendDescription(answer)
            } else if t == "answer" {
                // an answer to an offer we no longer have (rolled back, or a duplicate after a socket gap): nothing to do
                guard pc.signalingState == .haveLocalOffer else { return }
                try await pc.tfSetRemote(RTCSessionDescription(type: .answer, sdp: sdp))
            } else {
                return
            }
            let queued = pendingCandidates
            pendingCandidates = []
            for c in queued { try? await pc.tfAdd(c) }
        } catch {
            // the web logs this and goes on: the call ends only through ICE restarts running out or the server's timeout
            print("call: applying a \(t) failed: \(error)")
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
        switch state {
        case .connected:
            recovered()
            if !sentConnected, callID != nil {
                // counted as sent only when the socket took it: a lost one is sent again (sync, connect timer), or the
                // server fails a call whose audio flows at 30 s
                sendConnected()
                markActive()
            }
        case .failed:
            iceChanged(.failed)
        default:
            break
        }
    }

    /// Media flows again: no more "Reconnecting...", restarts counted from zero for the next blip.
    private func recovered() {
        restartTimer?.cancel(); restartTimer = nil
        labelTimer?.cancel(); labelTimer = nil
        socketWaitTimer?.cancel(); socketWaitTimer = nil
        restartWaitingForSocket = false
        socketWaits = 0
        reconnecting = false
        restarts = 0
        restartPending = false
    }

    /// Mirrors web callEngine.ts onIceState: "disconnected" often heals by itself, so it gets 3.5 s before an ICE restart
    /// and "Reconnecting..." only after 2 s; "failed" restarts at once. The call is never ended here.
    private func iceChanged(_ state: RTCIceConnectionState) {
        switch state {
        case .connected, .completed:
            if pc?.connectionState == .connected { recovered() }
        case .disconnected, .failed:
            guard phase == .connecting || phase == .active else { return }
            // the restart's offer goes over the live socket: prove it now (a dead one that still looks open swallowed every
            // offer until the heartbeat noticed, up to 35 s later, by when the restarts had run out)
            if restartTimer == nil { live?.proveForCall() }
            if phase == .active && !reconnecting {
                if state == .failed {
                    reconnecting = true
                } else if labelTimer == nil {
                    labelTimer = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard let self, !Task.isCancelled else { return }
                        self.labelTimer = nil
                        let now = self.pc?.iceConnectionState
                        if self.phase == .active && (now == .disconnected || now == .failed) { self.reconnecting = true }                    }
                }
            }
            if state == .failed {
                // a restart already under way gets its full 9 s; otherwise no need to wait out the grace
                if restartTimer != nil && restarts > 0 { return }
                scheduleRestart(after: 0)
            } else if restartTimer == nil {
                scheduleRestart(after: 3.5)
            }
        default:
            break
        }
    }

    private func scheduleRestart(after seconds: Double) {
        restartTimer?.cancel()
        restartTimer = Task { @MainActor [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            self.restartTimer = nil
            await self.restartIce()
        }
    }

    /// One ICE restart with fresh TURN credentials; the next one in 9 s if the connection is not back by then, and after
    /// three in a row the call is reported failed (web callEngine.ts restartIce).
    private func restartIce() async {
        guard let pc, phase == .connecting || phase == .active else { return }
        if pc.connectionState == .connected { recovered(); return }
        if !(live?.connected ?? false), restartWaitingForSocket || socketWaits < 5 {
            // the app's own socket is down: the offer could not leave, so no attempt is spent and no timer runs. The
            // restart is made the moment the socket is back (resumeAfterSocketGap). Bounded: 90 s per socket outage, then
            // the call ends (the server has given the call up by then), and at most five such waits before the media is
            // back (a socket that keeps coming and going): after that the attempts count again, three and it ends.
            // While still connecting the 45 s connect timer ends it sooner.
            if !restartWaitingForSocket { socketWaits += 1 }
            restartWaitingForSocket = true
            if phase == .active { reconnecting = true }
            if socketWaitTimer == nil {
                socketWaitTimer = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 90_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.socketWaitTimer = nil
                    guard self.restartWaitingForSocket, self.phase == .connecting || self.phase == .active else { return }
                    self.endReason = "connection_lost"
                    self.finish()
                }
            }
            return
        }
        restartWaitingForSocket = false
        if restarts >= 3 { fail("ice_failed"); return }
        restarts += 1
        if phase == .active { reconnecting = true }
        scheduleRestart(after: 9)
        if let ice = try? await APIClient.shared.iceServers(token: token), self.pc === pc {
            let cfg = pc.configuration
            cfg.iceServers = ice
            _ = pc.setConfiguration(cfg)
        }
        guard self.pc === pc, phase == .connecting || phase == .active else { return }
        if pc.connectionState == .connected { recovered(); return } // came back by itself meanwhile
        restartPending = true
        // in the negotiation queue, so it never overlaps an offer or answer that is being applied
        serially { [weak self] in
            guard let self, self.pc === pc, self.phase == .connecting || self.phase == .active else { return }
            if pc.signalingState == .haveLocalOffer {
                // the previous restart's offer was never answered (lost on the way, or its answer was): makeOffer only
                // offers from "stable", so every later restart did nothing. Take the old offer back first.
                do {
                    try await pc.tfSetLocal(RTCSessionDescription(type: .rollback, sdp: ""))
                } catch {
                    print("call: rolling back an unanswered offer failed: \(error)")
                }
                guard self.pc === pc else { return }
            }
            pc.restartIce() // fires "negotiation needed": a new offer from this side (perfect negotiation handles collisions)
        }
    }

    /// The socket was down and is back (call.sync answered with our call). An offer of ours sent meanwhile never arrived:
    /// send it again; a connection that is still down gets its ICE restart now instead of at the next step.
    private func resumeAfterSocketGap() {
        guard let conn = pc else { return }
        serially { [weak self] in
            guard let self, self.pc === conn else { return }
            // an ICE restart that waited for the socket (restartIce) is made now, whatever the count says
            let waited = self.restartWaitingForSocket
            self.restartWaitingForSocket = false
            self.socketWaitTimer?.cancel(); self.socketWaitTimer = nil
            if conn.signalingState == .haveLocalOffer, let offer = conn.localDescription {
                self.sendDescription(offer)
                // the offer that could not leave is on its way now: it gets one attempt's time (9 s) before the next
                // restart (which takes it back and makes a new one)
                if waited && self.restartTimer == nil { self.scheduleRestart(after: 9) }
                return
            }
            // first connection, our answer may be the frame that got lost: the caller then waited in have-local-offer
            // (no ICE checks, so no ICE restart either) until the server's connect timeout. An answer it already has
            // is ignored there (only applied in have-local-offer).
            if self.phase == .connecting, !self.sentConnected, conn.signalingState == .stable,
               let answer = conn.localDescription, answer.type == .answer {
                self.sendDescription(answer)
            }
            let ice = conn.iceConnectionState
            if (ice == .disconnected || ice == .failed) && (self.restarts == 0 || waited) { self.scheduleRestart(after: 0) }
        }
    }

    /// Runs `op` after every earlier negotiation step has finished.
    /// A step queued for a call that has ended meanwhile (or been replaced by the next one) is dropped.
    private func serially(_ op: @escaping @MainActor () async -> Void) {
        let previous = negotiation
        let call = uuid
        negotiation = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.uuid == call, self.callID != nil else { return }
            await op()
        }
    }

    private func fail(_ cls: String) {
        if let id = callID { send("call.failed", ["call_id": id, "class": cls]) }
        endReason = cls // "ice_failed" says "Couldn't connect", not a bare "failed"
        finish()
    }

    /// `call.connected` (our media is up), and our mute state with it.
    private func sendConnected() {
        guard let id = callID else { return }
        if send("call.connected", ["call_id": id]) { sentConnected = true }
        if muted { send("call.media", ["call_id": id, "muted": true]) }
    }

    /// Glare: our invite became the answer to the other person's call `into` (call.merged, or merged_from in a summary
    /// when call.merged was lost): this phone continues as its callee.
    private func adoptMerge(into: String) {
        callID = into
        role = .callee
        acknowledged = true
        phase = .connecting
        CallTones.shared.ringback(false)
        arm(seconds: 45) { [weak self] in self?.connectTimedOut() }
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
        // the server answered the other person's call with our invite: its "Call ended" alert follows, as for an answer
        LocalNotifier.shared.callAnsweredHere(callID: into)
    }

    /// The 45 s connecting timer ran out. A call whose own media is up only lost its call.active / call.connected on the
    /// way (a socket blip): call.connected again, a call.sync naming it, and one more period, instead of hanging up a
    /// call that works.
    private func connectTimedOut() {
        if phase == .connecting, !connectGraceUsed, let pc,
           pc.iceConnectionState == .connected || pc.iceConnectionState == .completed {
            connectGraceUsed = true
            sendConnected()
            sendSync()
            arm(seconds: 45) { [weak self] in self?.connectTimedOut() }
            return
        }
        localReason = "ice_timeout"
        hangUp()
    }

    private func markActive() {
        // End was pressed: the 5 s fallback that ends the call if call.ended never comes must not be cancelled here
        guard phase != .active, !userEnding else { return }
        phase = .active
        safetyTimer?.cancel()
        if connectedAt == nil { connectedAt = Date() }
        CallTones.shared.connected()
        logAudio("connected")
        // the CallKit call this phone started (also when a glare merge made us the callee): connected, the system clock runs
        if startedHere { provider.reportOutgoingCall(with: uuid, connectedAt: connectedAt) }
    }

    private func arm(seconds: Double, _ action: @escaping @MainActor () -> Void) {
        safetyTimer?.cancel()
        safetyTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { action() }
        }
    }

    /// Tests only: replaces the peer connection's close (which blocks until WebRTC's threads are done) to see where and
    /// that it runs. Called on the teardown queue, never on the main thread.
    static var closePeerConnection: (AnyObject?) -> Void = { ($0 as? RTCPeerConnection)?.close() }

    /// Closing a peer connection and resetting the audio session block for a while (hundreds of ms with TURN over TCP/TLS):
    /// done here, one call's teardown after the other, never on the main thread.
    private static let teardownQueue = DispatchQueue(label: "tf.call.teardown", qos: .userInitiated)

    /// The background half of finish(): the old peer connection is closed and the audio session put back. Touches nothing
    /// but what it is given and the shared audio session, and the audio part only while no newer call has started or
    /// switched its audio on (`generation`, checked and applied under the same lock that a new call's activation takes).
    nonisolated private static func tearDown(_ oldPC: AnyObject?, close: (AnyObject?) -> Void, resetSpeaker: Bool,
                                             releaseSession: Bool, generation: Int) {
        // the audio first: the microphone (and the orange dot) stops at once, whatever the close below takes (it can take
        // seconds with TURN over TCP/TLS)
        let t0 = CACurrentMediaTime()
        let applied = audioGeneration.ifCurrent(generation) {
            let s = RTCAudioSession.sharedInstance()
            if resetSpeaker {
                // the loudspeaker override outlives the call otherwise (the next call or voice note on the speaker)
                s.lockForConfiguration()
                try? s.overrideOutputAudioPort(.none)
                s.unlockForConfiguration()
            }
            // the microphone stops even if CallKit never sends didDeactivate (the orange dot stayed on)
            s.isAudioEnabled = false
            if releaseSession {
                s.lockForConfiguration()
                try? s.setActive(false)
                s.unlockForConfiguration()
            }
        }
        let t1 = CACurrentMediaTime()
        close(oldPC)
        let t2 = CACurrentMediaTime()
        let note = applied ? "" : " (skipped: a new call has the audio)"
        callLog.info("call end: audio reset in \(Int((t1 - t0) * 1000)) ms\(note, privacy: .public), peer connection closed in \(Int((t2 - t1) * 1000)) ms")
    }

    #if DEBUG
    /// Unit tests only (CallTeardownTests): a call on screen with no call id, peer connection, CallKit call or socket behind
    /// it, so hangUp() runs finish() without any system side effect.
    func testOnlyPretendCallOnScreen() {
        beginCall()
        phase = .connecting
        showScreen = true
    }
    #endif

    /// Ends locally: the screen goes at once, the microphone stops, CallKit is told; the peer connection and the audio
    /// session are taken down in the background (they block for a while).
    private func finish() {
        guard phase != .ended else { return }
        let started = CACurrentMediaTime()
        let hadCall = callID != nil
        // rang here and nobody answered on this phone: "Missed voice call" (not when declined or answered elsewhere)
        let wasMissed = hadCall && phase == .incoming && role == .callee && endReason != "declined"
            && endReason != "answered_elsewhere" && endReason != "mic_denied"
        // the microphone first (privacy): no more samples leave, whatever the teardown below takes
        audioTrack?.isEnabled = false
        // what the person sees, before anything slow. The compact notice under the header (RootView) says how a call ended
        // that the other side, the server or the network ended; nothing when this phone's own End did it (website).
        endedByMe = userEnding && localReason == nil
        lastDuration = connectedAt.map { Date().timeIntervalSince($0) }
        phase = .ended
        // the microphone refusal keeps its screen for the linger: its "Settings" button lives there (no teardown is slow
        // then: nothing was connected)
        if endReason != "mic_denied" { showScreen = false }
        let tapped = endTappedAt ?? started
        endTappedAt = nil
        callLog.info("call end: screen closed \(Int((CACurrentMediaTime() - tapped) * 1000)) ms after the tap")
        if wasMissed {
            LocalNotifier.shared.missedCall(name: peerName, peerID: peerID, conversationID: conversationID, callID: callID ?? "")
        }
        if let id = callID { LocalNotifier.shared.clearIncomingCall(callID: id, missed: wasMissed) }
        CallTones.shared.ringback(false)
        CallTones.shared.sessionActive = false
        if hadCall { if endReason == "busy" { CallTones.shared.busy() } else { CallTones.shared.end() } }
        safetyTimer?.cancel()
        restartTimer?.cancel(); restartTimer = nil
        labelTimer?.cancel(); labelTimer = nil
        socketWaitTimer?.cancel(); socketWaitTimer = nil
        restartWaitingForSocket = false
        socketWaits = 0
        negotiation = nil
        restartPending = false
        offerResend?.cancel(); offerResend = nil
        iceRefresh?.cancel(); iceRefresh = nil
        lastRemoteOffer = nil
        connectGraceUsed = false
        // a ring that came in while this phone placed this call: asked about again if ours never connected (CALL-7)
        let recheck = pendingIncoming.flatMap { p in
            CallDecisions.shouldRecheckIncoming(rememberedAt: p.at, now: Date(), ourCallConnected: connectedAt != nil) ? p.id : nil
        }
        pendingIncoming = nil
        // the peer connection leaves this object now (its late delegate callbacks are ignored: they check `pc ===`) and is
        // closed in the background with the audio session (tearDown)
        let oldPC = pc
        pc = nil
        audioTrack = nil
        remoteTrack = nil
        let resetSpeaker = speaker || wantSpeaker
        wantSpeaker = false
        let releaseSession = ownAudio
        ownAudio = false
        let generation = audioGeneration.value
        let close = Self.closePeerConnection
        Self.teardownQueue.async {
            CallManager.tearDown(oldPC, close: close, resetSpeaker: resetSpeaker, releaseSession: releaseSession,
                                 generation: generation)
        }
        micAttached = false
        makingOffer = false
        pendingSignals = []
        pendingCandidates = []
        sentConnected = false
        restarts = 0
        held = false
        answering = false
        if hadCall {
            // CallKit hears of the end exactly once: a transaction when this phone ended it, a report when the other side,
            // the server or a timeout did (both were sent, the second always failing)
            let ended = uuid
            if userEnding {
                callController.request(CXTransaction(action: CXEndCallAction(call: ended))) { [weak self] err in
                    // refused (CallKit reset, or the call is already gone there): a report instead, a no-op if it is gone
                    if err != nil { Task { @MainActor in self?.provider.reportCall(with: ended, endedAt: Date(), reason: .remoteEnded) } }
                }
            } else {
                let reason: CXCallEndedReason
                switch endReason {
                case "no_answer": reason = .unanswered
                case "answered_elsewhere": reason = .answeredElsewhere
                case "declined" where role == .callee: reason = .declinedElsewhere
                case "failed", "connection_lost", "ice_failed", "ice_timeout", "negotiation_failed", "offline": reason = .failed
                default: reason = .remoteEnded
                }
                provider.reportCall(with: ended, endedAt: Date(), reason: reason)
            }
        }
        if let id = callID, endedHere.insert(id).inserted {
            endedOrder.append(id)
            // the oldest goes (a Set's removeFirst() took any entry, possibly the one just added)
            while endedOrder.count > 50 { endedHere.remove(endedOrder.removeFirst()) }
        }
        callID = nil
        // still ringing on the server? call.sync names it; its answer rings it here (syncActions .ring: no call in hand now)
        if let recheck { sendSync(remembered: recheck) }
        linger?.cancel()
        linger = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if !Task.isCancelled && phase == .ended {
                phase = .idle
                showScreen = false
                endedByMe = false
                connectedAt = nil
                muted = false
                speaker = false
                wantSpeaker = false
                peerMuted = false
                ringing = false
                reconnecting = false
                peerID = nil
                endReason = nil
            }
        }
    }
}

// MARK: RTCPeerConnectionDelegate (called on WebRTC's thread: hop to the main actor)

extension CallManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let t = rtpReceiver.track as? RTCAudioTrack else { return }
        Task { @MainActor in
            // a connection that is not the current one (closing in the background after finish()) is ignored
            guard self.pc === peerConnection else { return }
            self.remoteTrack = t
            self.applyRemoteVolume()
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        Task { @MainActor in
            // the callee only negotiates for an ICE restart; its first answer comes from the caller's offer
            guard self.pc === peerConnection, self.role == .caller || self.restartPending else { return }
            self.serially { [weak self] in await self?.makeOffer(peerConnection) }
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
        // CallKit lost its calls (its daemon restarted): ours goes on, with the audio switched on by the app itself
        Task { @MainActor in
            if self.phase == .idle || self.phase == .ended { return }
            if self.phase == .incoming {
                // it ended here with no word to the server (the caller heard it ring 45 s more) and posted "Missed
                // call". It goes on ringing in the app instead: Accept answers without CallKit (accept()'s fallback).
                if let id = self.callID {
                    LocalNotifier.shared.incomingCallFallback(name: self.peerName, callID: id, conversationID: self.conversationID)
                }
                return
            }
            self.audioWithoutCallKit()
        }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        CallManager.configureAudioSession()
        action.fulfill()
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        CallManager.configureAudioSession()
        let u = action.callUUID
        Task { @MainActor in
            // only the call this action is for: a push ring the socket does not know must not answer another call
            if self.phase == .incoming, self.uuid == u { self.doAccept() }
            else if self.pushCalls.contains(u.uuidString) { self.pendingAnswer = u } // the socket has not told the app yet
        }
        action.fulfill()
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let u = action.callUUID
        Task { @MainActor in
            // the app's own call only when the action names it: ending a push ring the socket does not know must not
            // decline or hang up another call
            if self.uuid != u || self.phase == .idle || self.phase == .ended {
                if self.pushCalls.contains(u.uuidString) { self.pendingEnd = u }
            }
            else if self.phase == .incoming { self.decline() }
            else {
                if self.phase == .outgoing && !self.userEnding { self.localReason = "system_end" }
                self.hangUp()
            }
        }
        action.fulfill()
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        let onHold = action.isOnHold
        Task { @MainActor in self.applyHeld(onHold) }
        action.fulfill()
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let wantMuted = action.isMuted
        Task { @MainActor in self.applyMute(wantMuted) }
        action.fulfill()
    }
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // a previous call's teardown still queued must not switch this audio off (it waits here if it is resetting right now)
        audioGeneration.bump()
        let s = RTCAudioSession.sharedInstance()
        s.audioSessionDidActivate(audioSession)
        s.isAudioEnabled = true
        Task { @MainActor in
            CallTones.shared.sessionActive = true
            self.logAudio("didActivate")
            // Speaker tapped before CallKit switched the audio on: the override failed then; it applies now (and again a
            // moment later, when WebRTC's audio unit has started)
            guard self.lineInUse else { return }
            self.reapplySpeakerSoon()
        }
    }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        let s = RTCAudioSession.sharedInstance()
        s.audioSessionDidDeactivate(audioSession)
        Task { @MainActor in CallTones.shared.sessionActive = false }
        // after a CallKit reset the app runs the audio itself (audioWithoutCallKit): CallKit's late deactivation of the
        // call it forgot must not silence the call that goes on
        if !callAudioOwned.value { s.isAudioEnabled = false }
    }
}

/// CallManager.ownAudio for CallKit's audio callbacks, which must decide at once (not after a hop to the main actor:
/// a deactivate and an activate in a row, as on hold and resume, would run in the wrong order).
private let callAudioOwned = LockedFlag()

/// Bumped whenever a call starts or switches its audio on: a teardown queued by finish() for an earlier call resets the audio
/// session only while the number is still the one it saw (see CallManager.tearDown).
private let audioGeneration = AudioGeneration()

/// A counter readable from any thread. The check and the reset that depends on it run under the same lock as a bump, so a
/// new call's audio activation can never fall between them.
private final class AudioGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
    func bump() { lock.lock(); v &+= 1; lock.unlock() }
    /// Runs `body` only if no bump happened since `generation` was read; true when it ran.
    @discardableResult
    func ifCurrent(_ generation: Int, _ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard v == generation else { return false }
        body()
        return true
    }
}

/// A Bool readable from any thread (CallKit's delegate callbacks are nonisolated).
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
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
/// GET /calls/ice-servers: {ice_servers:[{urls,username,credential}], ttl_seconds, relay}. Read tolerantly: `urls` as a list
/// or one string, `ttl_seconds` missing (older server) or a number of any kind.
private struct IceServersResponse: Decodable {
    struct Server: Decodable {
        let urls: [String]
        let username: String?
        let credential: String?
        private enum CodingKeys: String, CodingKey { case urls, username, credential }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let many = try? c.decode([String].self, forKey: .urls) { urls = many }
            else if let one = try? c.decode(String.self, forKey: .urls) { urls = [one] }
            else { urls = [] }
            username = try? c.decodeIfPresent(String.self, forKey: .username)
            credential = try? c.decodeIfPresent(String.self, forKey: .credential)
        }
    }
    let ice_servers: [Server]
    let ttl_seconds: Int?
    private enum CodingKeys: String, CodingKey { case ice_servers, ttl_seconds }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ice_servers = (try? c.decode([Server].self, forKey: .ice_servers)) ?? []
        if let d = try? c.decodeIfPresent(Double.self, forKey: .ttl_seconds) { ttl_seconds = Int(d) } else { ttl_seconds = nil }
    }
}

/// The ICE servers of one connection and how long their TURN credentials last.
struct ICEConfig {
    let servers: [RTCIceServer]
    /// seconds; nil from an older server
    let ttl: Int?
}

extension APIClient {
    /// GET /calls/config: calls are on for this account (server switch and rollout list).
    func callsEnabled(token: String) async throws -> Bool {
        let data = try await getJSON("calls/config", token: token)
        return (try? JSONDecoder().decode(CallsConfig.self, from: data))?.enabled ?? false
    }

    /// GET /calls/ice-servers: STUN and short-lived TURN credentials, fetched fresh for every connection.
    func iceServers(token: String) async throws -> [RTCIceServer] {
        try await iceConfig(token: token).servers
    }

    /// The same, with the credentials' lifetime. A URL WebRTC would refuse (malformed) is dropped and the others kept; a
    /// `turns:…?transport=tcp` (TLS over TCP 443, coming) is kept like any other.
    func iceConfig(token: String) async throws -> ICEConfig {
        let data = try await getJSON("calls/ice-servers", token: token)
        let out = try JSONDecoder().decode(IceServersResponse.self, from: data)
        let servers: [RTCIceServer] = out.ice_servers.compactMap { s in
            let urls = s.urls.filter(CallDecisions.validICEURL)
            guard !urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: urls, username: s.username, credential: s.credential)
        }
        return ICEConfig(servers: servers, ttl: out.ttl_seconds)
    }
}
