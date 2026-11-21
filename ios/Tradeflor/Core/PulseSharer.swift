import Foundation
import CoreLocation
import UIKit

/// Pulse location sharing on this device (PULSE_IOS_HANDOFF.md §3). The order is mandatory: the person taps Share → the
/// system permission → the first fix → POST /share (consent) → positions. Never a consent without a working permission.
/// Measuring stops on Stop, my own `sharing:false`, `removed`, `ended`, a 409 / 410 / 404 answer, the consent's time
/// limit and sign-out. Adaptive cadence (PulseRules.shouldSend); Low Power Mode uses the still settings at most.
@MainActor
final class PulseSharer: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = PulseSharer()

    struct Share: Equatable {
        var until: Int64? // nil = until the circle ends
        var dest: CLLocationCoordinate2D?
        var lastSent: PulseRules.Fix?
        var holdUntil: Int64 = 0 // after a 429
        var sending = false
        static func == (a: Share, b: Share) -> Bool { a.until == b.until && a.lastSent == b.lastSent }
    }

    @Published private(set) var shares: [String: Share] = [:]
    /// The latest reading. Not published: with readings every second it redrew every screen observing the sharer (the
    /// meetup, Home) once a second for nothing; the meetup reads it on its own 1 s tick.
    private(set) var lastFix: CLLocation?
    @Published private(set) var reducedAccuracy = false
    /// Stopped on this device, the server has not confirmed yet (offline): retried every 5 s; never resumed meanwhile and no
    /// position is kept for later.
    @Published private(set) var stopPending: Set<String> = []
    private var stopRetry: [String: Task<Void, Never>] = [:]

    private let manager = CLLocationManager()
    private var permissionWaiters: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    /// One waiter per caller: a caller's own time limit ends only its own wait (audit 13).
    private var fixWaiters: [UUID: CheckedContinuation<CLLocation?, Never>] = [:]
    /// Bumped by a Stop in that meetup (and `allEpoch` by stop-all / sign-out): a start() that was still asking when the
    /// person stopped does not switch sharing back on; a Stop in another meetup no longer cancels it (web: a ticket per meetup).
    private var stopEpochs: [String: Int] = [:]
    private var allEpoch = 0
    private func epoch(_ circle: String) -> [Int] { [stopEpochs[circle] ?? 0, allEpoch] }
    private var expiryTimer: Timer?
    /// When Core Location last delivered a reading (the watchdog restarts the updates when they went quiet).
    private var lastDelivery = Date.distantPast
    private var token: String { PulseStore.shared.token }

    var sharingCircles: [String] { Array(shares.keys) }
    var isSharingAnywhere: Bool { !shares.isEmpty }
    func isSharing(_ circle: String) -> Bool { shares[circle] != nil }

    private override init() {
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
    }

    enum ShareError: Error { case denied, noFix, server(Int) }

    /// Share my location in this meetup (0 minutes = until it ends). Throws `denied` when the system permission is not
    /// given, `noFix` when no position came, `server` when the consent was refused; nothing is shared then.
    func start(circle: String, minutes: Int, dest: CLLocationCoordinate2D?) async throws {
        let started = epoch(circle)
        // 1-2. the system permission (asked only now, after the person tapped Share)
        // a stop the server has not confirmed comes first: sharing never resumes while it is pending
        if stopPending.contains(circle) {
            await confirmStop(circle)
            if stopPending.contains(circle) { throw ShareError.server(0) }
        }
        let status = await permission()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { throw ShareError.denied }
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        // 3. a first fix
        guard let first = await firstFix() else { throw ShareError.noFix }
        // 4. the consent
        let tok = token
        let data: Data
        do {
            data = try await APIClient.shared.pulsePost(token: tok, circle: circle, "share", body: ["minutes": minutes])
        } catch let e as PulseHTTPError {
            throw ShareError.server(e.status)
        }
        // Stop (here or everywhere) while this was asking: the stop wins, the consent just given is taken back (audit 14)
        guard started == epoch(circle) else {
            stopPending.insert(circle)
            await confirmStop(circle)
            throw ShareError.server(0)
        }
        struct U: Decodable { var until: Int64? }
        let until = (try? JSONDecoder().decode(U.self, from: data))?.until
        shares[circle] = Share(until: (until ?? 0) > 0 ? until : nil, dest: dest)
        Self.startedHere.insert(circle)
        // 5. positions
        updateMeasuring()
        await consider(first, for: circle)
    }

    /// Stop Sharing: the server deletes my position at once (never rate limited); measuring stops here first.
    /// Without an answer: "Stopped on this device. Waiting for the server to confirm..." and retried until it answers.
    func stop(_ circle: String) async {
        stopEpochs[circle, default: 0] += 1
        stopLocally(circle)
        stopPending.insert(circle)
        await confirmStop(circle)
    }

    private func confirmStop(_ circle: String) async {
        stopRetry[circle]?.cancel()
        stopRetry[circle] = nil
        let tok = token
        guard !tok.isEmpty else { stopPending.remove(circle); return }
        do {
            try await APIClient.shared.pulseDelete(token: tok, path: "pulse/circles/\(APIClient.pSeg(circle))/share")
            stopPending.remove(circle)
        } catch let e as PulseHTTPError where [404, 409, 410].contains(e.status) {
            stopPending.remove(circle) // the meetup is over or gone: nothing left to revoke
        } catch is PulseHTTPError {
            guard stopPending.contains(circle) else { return }
            stopRetry[circle] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled { await self?.confirmStop(circle) }
            }
        } catch {
            stopPending.remove(circle) // signed out
        }
    }

    /// Stop sharing everywhere (offline: each meetup is stopped one by one as soon as the server answers).
    func stopAll() async {
        allEpoch += 1
        let ids = Array(shares.keys)
        shares = [:]
        Self.startedHere = []
        updateMeasuring()
        do {
            _ = try await APIClient.shared.pulseCall("pulse/stop-all", method: "POST", token: token)
        } catch is PulseHTTPError {
            // every meetup retried at the same time, not one after the other (audit 15)
            for id in ids {
                stopPending.insert(id)
                Task { await self.confirmStop(id) }
            }
        } catch {}
    }

    /// The server or the circle ended it (409/410/404, removed, ended, my own sharing:false): measuring stops, no call.
    func stopLocally(_ circle: String) {
        Self.startedHere.remove(circle)
        guard shares[circle] != nil else { return }
        shares[circle] = nil
        updateMeasuring()
    }

    /// Sign-out: nothing keeps measuring.
    func forgetAll() {
        allEpoch += 1
        shares = [:]
        Self.startedHere = []
        for t in stopRetry.values { t.cancel() }
        stopRetry = [:]
        stopPending = []
        updateMeasuring()
        lastFix = nil
    }

    func setDestination(_ circle: String, _ dest: CLLocationCoordinate2D?) {
        shares[circle]?.dest = dest
    }

    /// The server still has my consent but this phone is not sending (the app was closed by iOS, crashed or was updated):
    /// sending starts again by itself when the permission is already given, never with a prompt (web maybeResume).
    /// `ask: true` is the person's own "Resume" tap: then the permission may be asked. false = not resumed (the screen says
    /// "paused").
    @discardableResult
    func resume(circle: String, until: Int64?, dest: CLLocationCoordinate2D?, ask: Bool = false) async -> Bool {
        if shares[circle] != nil { return true }
        guard !stopPending.contains(circle) else { return false } // stopped here, the server has not heard yet: never resume
        // only on the device that gave the consent: the consent is per account, and an iPad or a second phone opening the
        // meetup must not start sending its own position (maybe home) without a tap there ("Resume" is that tap)
        guard ask || Self.startedHere.contains(circle) else { return false }
        if let u = until, u > 0, u <= PulseRules.nowMs() { return false }
        let started = epoch(circle)
        let s = ask ? await permission() : manager.authorizationStatus
        guard s == .authorizedWhenInUse || s == .authorizedAlways else { return false }
        guard started == epoch(circle), shares[circle] == nil, !stopPending.contains(circle) else { return shares[circle] != nil }
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        shares[circle] = Share(until: (until ?? 0) > 0 ? until : nil, dest: dest)
        Self.startedHere.insert(circle)
        updateMeasuring()
        return true
    }

    /// The meetups whose sharing this device started (kept across launches, ids only): only these resume by themselves.
    nonisolated private static let startedKey = "tf.pulse.startedHere"
    private static var startedHere: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: startedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.prefix(50)), forKey: startedKey) }
    }

    /// One reading for a screen ("Near me" when creating a meetup): never shared.
    func readOnce() async -> CLLocation? {
        let status = await permission()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        return await firstFix()
    }

    /// The one position an SOS or a safety alert may carry (audit 3, 11): never a permission prompt in an emergency, at most
    /// `maxWait` seconds, and never an old reading (older than 2 minutes = none). nil = the alert goes without a position.
    func snapshotFix(maxWait: Double = 3) async -> CLLocation? {
        let s = manager.authorizationStatus
        guard s == .authorizedWhenInUse || s == .authorizedAlways else { return nil }
        if let l = lastFix, -l.timestamp.timeIntervalSinceNow < 30 { return l }
        let l = await firstFix(timeout: maxWait) ?? lastFix
        guard let l, -l.timestamp.timeIntervalSinceNow < 120 else { return nil }
        return l
    }

    // MARK: permission and fixes

    private func permission() async -> CLAuthorizationStatus {
        let s = manager.authorizationStatus
        if s != .notDetermined { return s }
        return await withCheckedContinuation { c in
            permissionWaiters.append(c)
            manager.requestWhenInUseAuthorization()
        }
    }

    private func firstFix(timeout: Double = 20) async -> CLLocation? {
        if let l = lastFix, abs(l.timestamp.timeIntervalSinceNow) < 20 { return l }
        let id = UUID()
        return await withCheckedContinuation { c in
            fixWaiters[id] = c
            // while sharing, the running updates bring the next reading within a second or two: a one-shot request then
            // could end those updates once it is answered, and sharing would go quiet
            if shares.isEmpty {
                manager.desiredAccuracy = kCLLocationAccuracyBest
                manager.requestLocation()
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finishWaiter(id)
            }
        }
    }

    private func finishWaiter(_ id: UUID) {
        fixWaiters.removeValue(forKey: id)?.resume(returning: nil)
    }

    private func finishFixWaiters(_ l: CLLocation?) {
        let w = fixWaiters
        fixWaiters = [:]
        for c in w.values { c.resume(returning: l) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            guard s != .notDetermined else { return }
            // precise location switched off (or on) in Settings while sharing: the positions say "network" from now on
            self.reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
            let w = self.permissionWaiters
            self.permissionWaiters = []
            for c in w { c.resume(returning: s) }
            // permission taken away in Settings while sharing: stop everywhere
            if (s == .denied || s == .restricted), !self.shares.isEmpty { await self.stopAll() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in
            self.lastDelivery = Date()
            self.lastFix = l
            self.finishFixWaiters(l)
            // each meetup sends on its own: one slow answer (up to 8 s) no longer holds the reading back for the others
            for id in Array(self.shares.keys) { Task { await self.consider(l, for: id) } }
            self.updateAccuracy()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishFixWaiters(nil) }
    }

    // MARK: sending

    private func consider(_ l: CLLocation, for circle: String) async {
        guard var s = shares[circle], !s.sending else { return }
        let now = PulseRules.nowMs()
        if let until = s.until, now >= until { stopLocally(circle); return } // the consent's time limit
        if now < s.holdUntil { return }
        guard l.horizontalAccuracy > 0, l.horizontalAccuracy <= 5000 else { return }
        // a cached reading handed out again is not where the person is now (and the server refuses it after 2 minutes)
        guard PulseRules.recentEnough(Int64(l.timestamp.timeIntervalSince1970 * 1000), now: now) else { return }
        let fix = PulseRules.Fix(lat: l.coordinate.latitude, lon: l.coordinate.longitude, accuracy: l.horizontalAccuracy,
                                 speed: l.speed >= 0 ? l.speed : nil, at: Int64(l.timestamp.timeIntervalSince1970 * 1000))
        let destD = s.dest.map { PulseRules.distanceM($0.latitude, $0.longitude, fix.lat, fix.lon) }
        guard PulseRules.shouldSend(fix, lastSent: s.lastSent, destDistance: destD) else { return }
        // the time on the server's clock: a phone whose clock runs minutes behind would otherwise look "Last seen 2 min ago"
        // to everyone, or be refused as too old (ServerClock corrects only differences above 30 s)
        let at = fix.at + Int64((ServerClock.now.timeIntervalSince1970 - Date().timeIntervalSince1970) * 1000)
        var body: [String: Any] = ["lat": fix.lat, "lon": fix.lon, "accuracy": fix.accuracy, "seq": at, "measured_at": at,
                                   "source": reducedAccuracy || l.horizontalAccuracy > 100 ? "network" : "gps"]
        if let v = fix.speed { body["speed"] = v }
        if l.course >= 0, (fix.speed ?? 0) > 1 { body["heading"] = l.course }
        s.sending = true
        shares[circle] = s
        let tok = token
        let payload = body // a constant: a @Sendable closure cannot capture a var
        do {
            _ = try await Self.within(PulseRules.locationPostTimeoutS) {
                try await APIClient.shared.pulsePost(token: tok, circle: circle, "location", body: payload)
            }
            shares[circle]?.lastSent = fix
            shares[circle]?.sending = false
        } catch let e as PulseHTTPError {
            shares[circle]?.sending = false
            if PulseRules.refusalStopsSharing(status: e.status, text: e.text) {
                stopLocally(circle) // not sharing any more, ended, gone
            } else {
                // 429: what the server asked; 409 "an older position arrived after a newer one", 422 (too old, implausible
                // jump), 400, 5xx, offline, no answer within 8 s: this reading is dropped and the next try waits 3 s (readings
                // come every second: no radio woken every second, no run into the 40 a minute limit)
                shares[circle]?.holdUntil = now + PulseRules.retryHoldMs(status: e.status, retryAfter: e.retryAfter)
            }
        } catch APIError.badCredentials {
            // the session is gone (401): sending stops here at once, not a try every 3 s until the socket notices
            shares[circle]?.sending = false
            stopLocally(circle)
        } catch {
            shares[circle]?.sending = false
            shares[circle]?.holdUntil = now + PulseRules.retryHoldMs(status: 0, retryAfter: nil)
        }
    }

    /// The answer of `op` within `seconds`, else PulseHTTPError(status: 0) and the request is cancelled: one position stuck on
    /// a half-dead connection (a cell handover) no longer holds every reading after it for the 20 s request timeout.
    private static func within(_ seconds: Double, _ op: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { g in
            g.addTask { try await op() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PulseHTTPError(status: 0)
            }
            defer { g.cancelAll() }
            guard let first = try await g.next() else { throw PulseHTTPError(status: 0) }
            return first
        }
    }

    // MARK: measuring on / off and its accuracy

    private func updateMeasuring() {
        if shares.isEmpty {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            manager.showsBackgroundLocationIndicator = false
            expiryTimer?.invalidate()
            expiryTimer = nil
            return
        }
        // while sharing (started by the person in the app), the phone keeps measuring with the app in the background; the
        // blue indicator shows it. It stops at the time limit, the end, or Stop.
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        updateAccuracy()
        manager.startUpdatingLocation()
        lastDelivery = Date()
        if expiryTimer == nil {
            expiryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkExpiry() }
            }
        }
    }

    private func checkExpiry() {
        let now = PulseRules.nowMs()
        for (id, s) in shares where (s.until ?? .max) <= now { stopLocally(id) }
        // a still person stays "live" (audit 4): readings come with no distance filter, so the cadence (25 s still) decides
        // what is sent. Updates that went quiet anyway (no reading for 15 s) are restarted, which hands out a fresh reading;
        // never requestLocation() here: answering it can end the running updates, and sharing went "Last seen 2 min ago".
        guard !shares.isEmpty else { return }
        if PulseRules.updatesWentQuiet(lastDeliveryAgoS: Date().timeIntervalSince(lastDelivery)) {
            // a full restart only in front: stopping in the background ends the background location session, and with
            // "While Using" permission a new one cannot begin from the background (sharing would stay dead until the app
            // is opened); there, the running updates are only asked again
            if UIApplication.shared.applicationState == .active { manager.stopUpdatingLocation() }
            manager.startUpdatingLocation()
            lastDelivery = Date()
        }
    }

    /// The finest accuracy any shared meetup needs now; Low Power Mode: the still settings at most.
    private func updateAccuracy() {
        guard !shares.isEmpty else { return }
        // no distance filter: a still phone otherwise gets no reading at all and turns "Last seen"; what is sent is decided by
        // PulseRules.shouldSend (25 s still, 10 s walking, 5 s driving, 4 s near the place)
        if manager.distanceFilter != kCLDistanceFilterNone { manager.distanceFilter = kCLDistanceFilterNone }
        // Low Power Mode: ten metres at most too (a hundred metres is served from Wi-Fi with readings far apart, the restart
        // hands back the cached one, which is not sent: a still phone sent nothing); the cadence still keeps the radio calm
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            if manager.desiredAccuracy != kCLLocationAccuracyNearestTenMeters { manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters }
            return
        }
        var best: PulseRules.Motion = .still
        if let l = lastFix {
            let fix = PulseRules.Fix(lat: l.coordinate.latitude, lon: l.coordinate.longitude, accuracy: l.horizontalAccuracy,
                                     speed: l.speed >= 0 ? l.speed : nil, at: Int64(l.timestamp.timeIntervalSince1970 * 1000))
            for s in shares.values {
                let d = s.dest.map { PulseRules.distanceM($0.latitude, $0.longitude, fix.lat, fix.lon) }
                let m = PulseRules.motion(fix, last: s.lastSent, destDistance: d)
                if m == .near { best = .near } else if m == .driving && best != .near { best = .driving } else if m == .walking && best == .still { best = .walking }
            }
        }
        // set only when it changes: writing it on every reading can make Core Location reconfigure each second
        let want: CLLocationAccuracy
        switch best {
        case .near, .driving: want = kCLLocationAccuracyBest
        // still: GPS-grade too (a "hundred metres" request is served from Wi-Fi now and then, with readings far apart)
        case .walking, .still: want = kCLLocationAccuracyNearestTenMeters
        }
        if manager.desiredAccuracy != want { manager.desiredAccuracy = want }
    }
}
