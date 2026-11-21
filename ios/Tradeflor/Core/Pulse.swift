import Foundation
import UIKit
import Combine
import CoreLocation

// TRADEFLOR Pulse (2026-11-21): the private live meetup map. Contract: docs/pulse/PULSE_API_PROTOCOL.md,
// PULSE_WEBSOCKET_EVENTS.md, PULSE_GPS_ACCURACY_STRATEGY.md; web reference desktop/src/features/pulse/.
// Joining never shares a location: sharing is its own step (permission, first fix, consent, then positions).

// MARK: shapes (every field optional where the server may leave it out; unknown fields are ignored)

struct PulseCircle: Decodable, Identifiable, Equatable {
    let id: String
    var creator_id: String?
    var title: String?
    var activity: String?
    var dest_name: String?
    var dest_lat: Double?
    var dest_lon: Double?
    var starts_at: Int64?
    var expires_at: Int64?
    var state: String?
    var policy: String?
    var party: Bool?
    var instant: Bool?
    var version: Int?

    var hasDest: Bool { dest_lat != nil && dest_lon != nil && !(dest_lat == 0 && dest_lon == 0) }
    var dest: CLLocationCoordinate2D? { hasDest ? CLLocationCoordinate2D(latitude: dest_lat!, longitude: dest_lon!) : nil }
    var isOpen: Bool { state != "ended" && state != "expired" }
    var icon: String { PulseRules.activityIcon[activity ?? ""] ?? "📍" }
    /// The drawn icon of the activity (the map markers keep the emoji).
    var symbol: String { PulseRules.activitySymbol[activity ?? ""] ?? "mappin" }
}

struct PulseStatus: Decodable, Equatable {
    var text: String?
    var emoji: String?
    var at: Int64?
    var until: Int64?
}

struct PulseMember: Decodable, Identifiable, Equatable {
    let user_id: String
    var role: String?
    var response: String?
    var invited_by: String?
    var arrived_at: Int64?
    var arrived_kind: String?
    var sharing: Bool?
    var share_until: Int64?
    var status: PulseStatus?
    var id: String { user_id }
    var arrived: Bool { (arrived_at ?? 0) > 0 }
}

struct PulseLocation: Decodable, Equatable {
    let user_id: String
    var lat: Double
    var lon: Double
    var accuracy: Double?
    var speed: Double?
    var heading: Double?
    var source: String?
    var measured_at: Int64
    var received_at: Int64?
    var quality: String?
    var until: Int64?
    var distance_m: Double?
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var approximate: Bool { quality == "approximate" || (accuracy ?? 0) > 100 }
}

struct PulsePerson: Decodable, Equatable {
    var user_id: String?
    var username: String?
    var display_name: String?
    var avatar_id: String?
    var name: String { (display_name?.isEmpty == false ? display_name : nil) ?? username ?? "" }
}

struct PulseBubble: Decodable, Identifiable, Equatable {
    let id: String
    var user_id: String?
    var text: String?
    var reply_to: String?
    var created_at: Int64?
}

struct PulseProposal: Decodable, Identifiable, Equatable {
    let id: String
    var user_id: String?
    var name: String?
    var lat: Double?
    var lon: Double?
    var state: String?
    var votes: [String: Bool]?
    var created_at: Int64?
}

struct PulseVoice: Decodable, Identifiable, Equatable {
    let id: String
    var user_id: String?
    var duration_ms: Int?
    var created_at: Int64?
}

struct PulseActivityItem: Decodable, Equatable {
    var kind: String?
    var user_id: String?
    var text: String?
    var at: Int64?
}

struct PulseView: Decodable, Equatable {
    var circle: PulseCircle
    var me: PulseMember?
    var members: [PulseMember]?
    var locations: [PulseLocation]?
    var bubbles: [PulseBubble]?
    var proposals: [PulseProposal]?
    var voice: [PulseVoice]?
    var activity: [PulseActivityItem]?
    var now: Int64?
    /// Active SOS this viewer sent or received (unresolved, under 2 h old).
    var sos: [PulseSOS]?
}

/// An active Meetup SOS (server 57db6394).
struct PulseSOS: Decodable, Identifiable, Equatable {
    let id: String
    var user_id: String
    var text: String?
    var lat: Double?
    var lon: Double?
    var accuracy: Double?
    var created_at: Int64?
}

struct PulseInvitation: Decodable, Equatable {
    var circle: PulseCircle
    var invited_by: String?
    var response: String?
    var going: Int?
}

struct PulseCircleDetail: Decodable {
    var view: PulseView?
    var invitation: PulseInvitation?
    var people: [String: PulsePerson]?
}

struct PulseCircleEntry: Decodable, Identifiable, Equatable {
    var circle: PulseCircle
    var role: String?
    var response: String?
    var going: Int?
    var sharing: Int?
    var invited_by: String?
    var id: String { circle.id }
}

struct PulseConfig: Decodable, Equatable {
    var enabled: Bool = false
    var style_url: String?
    var min_update_ms: Int?
    var max_stale_ms: Int?
    var approx_accuracy_m: Double?
    var arrive_radius_m: Double?
    var voice_max_ms: Int?
    var max_members: Int?
    var status_max: Int?
    var bubble_max: Int?

    init() {}
}

struct PulseCodePreview: Decodable, Equatable {
    var circle_id: String
    var title: String?
    var activity: String?
    var dest_name: String?
    var starts_at: Int64?
    var expires_at: Int64?
    var organizer_id: String?
    var approval: Bool?
    var people: Int?
}

struct PulseAlert: Decodable, Identifiable, Equatable {
    let id: String
    var circle_id: String?
    var sender_id: String?
    var kind: String?
    var text: String?
    var position: PulseAlertPosition?
    var created_at: Int64?
}

struct PulseAlertPosition: Decodable, Equatable {
    var lat: Double
    var lon: Double
    var accuracy: Double?
}

struct PulseAlertDelivery: Decodable, Equatable {
    var user_id: String
    var pushed_at: Int64?
    var seen_at: Int64?
}

struct PulseCapsuleItem: Decodable, Identifiable, Equatable {
    let id: String
    var user_id: String?
    var mime: String?
    var caption: String?
    var created_at: Int64?
}

/// An HTTP answer Pulse acts on (status 0 = no answer).
struct PulseHTTPError: Error, Equatable {
    let status: Int
    var text = ""
    var retryAfter: Double?
}

// MARK: the rules (port of desktop/src/features/pulse/pulseRules.ts)

enum PulseRules {
    enum Freshness: String { case live, lagging, stale }
    static let liveMs: Int64 = 40_000
    static let staleMs: Int64 = 120_000

    static func freshness(_ measuredAt: Int64, now: Int64) -> Freshness {
        let age = now - measuredAt
        if age <= liveMs { return .live }
        if age <= staleMs { return .lagging }
        return .stale
    }

    static func agoText(_ measuredAt: Int64, now: Int64) -> String {
        let s = max(0, Int((Double(now - measuredAt) / 1000).rounded()))
        if s < 10 { return NSLocalizedString("pulse.ago.now", comment: "") }
        if s < 60 { return String(format: NSLocalizedString("pulse.ago.s", comment: ""), s) }
        let m = Int((Double(s) / 60).rounded())
        if m < 60 { return String(format: NSLocalizedString("pulse.ago.m", comment: ""), m) }
        return String(format: NSLocalizedString("pulse.ago.hm", comment: ""), m / 60, m % 60)
    }

    static func distanceM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371008.8
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = pow(sin(dp / 2), 2) + cos(p1) * cos(p2) * pow(sin(dl / 2), 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    static func distanceText(_ m: Double) -> String {
        guard m.isFinite else { return "" }
        if m < 1000 { return String(format: NSLocalizedString("pulse.dist.m", comment: ""), max(0, Int((m / 10).rounded()) * 10)) }
        return String(format: NSLocalizedString(m < 10_000 ? "pulse.dist.km1" : "pulse.dist.km0", comment: ""), m / 1000)
    }

    static let detour = 1.3
    static let walk = 1.35
    static let drive = 8.0

    /// "~8 min", "< 1 min", or nil without a distance. Always an estimate from the straight line.
    static func eta(distance: Double?, speed: Double?, arrived: Bool) -> String? {
        if arrived { return NSLocalizedString("pulse.arrived", comment: "") }
        guard let d = distance, d.isFinite else { return nil }
        let v = (speed ?? 0) > 3 ? drive : walk
        let min = d * detour / v / 60
        if min < 1 { return NSLocalizedString("pulse.eta.lt1", comment: "") }
        if min < 60 { return String(format: NSLocalizedString("pulse.eta.m", comment: ""), Int(min.rounded())) }
        return String(format: NSLocalizedString("pulse.eta.hm", comment: ""), Int(min / 60), Int(min.truncatingRemainder(dividingBy: 60).rounded()))
    }

    static func progress(first: Double?, now: Double?, arrived: Bool) -> Int {
        if arrived { return 100 }
        guard let f = first, let n = now, f > 0 else { return 0 }
        return Int(min(99, max(0, (1 - n / f) * 100)).rounded())
    }

    // when to send

    struct Fix: Equatable {
        var lat: Double
        var lon: Double
        var accuracy: Double
        var speed: Double?
        var at: Int64
    }

    enum Motion: Equatable { case still, walking, driving, near }
    static let nearM = 300.0

    static func cadence(_ m: Motion) -> (everyMs: Int64, movedM: Double) {
        switch m {
        case .still: return (25_000, 15)
        case .walking: return (10_000, 15)
        case .driving: return (5_000, 40)
        case .near: return (4_000, 8)
        }
    }

    static func motion(_ fix: Fix, last: Fix?, destDistance: Double?) -> Motion {
        if let d = destDistance, d < nearM { return .near }
        var v = fix.speed
        if (v == nil || v! < 0), let last {
            let dt = Double(fix.at - last.at) / 1000
            if dt > 0 { v = distanceM(last.lat, last.lon, fix.lat, fix.lon) / dt }
        }
        guard let speed = v, speed >= 0.6 else { return .still }
        return speed > 3 ? .driving : .walking
    }

    static func shouldSend(_ fix: Fix, lastSent: Fix?, destDistance: Double?, minGapMs: Int64 = 2000) -> Bool {
        guard let last = lastSent else { return true }
        let gap = fix.at - last.at
        if gap < minGapMs { return false }
        let c = cadence(motion(fix, last: last, destDistance: destDistance))
        if gap >= c.everyMs { return true }
        if distanceM(last.lat, last.lon, fix.lat, fix.lon) >= max(c.movedM, fix.accuracy / 2) { return true }
        // a much better reading than the last one sent (out of a building, GPS locked)
        return fix.accuracy < last.accuracy * 0.5 && last.accuracy > 30
    }

    // motion on the map: between two real positions, never predicted

    static let maxGlideMs = 1500.0
    static let teleportM = 2000.0

    static func glideMs(prev: PulseLocation?, next: PulseLocation, reduceMotion: Bool) -> Double {
        guard let prev, !reduceMotion else { return 0 }
        if distanceM(prev.lat, prev.lon, next.lat, next.lon) > teleportM { return 0 }
        let between = Double(next.measured_at - prev.measured_at)
        if between <= 0 { return 0 }
        return min(maxGlideMs, max(300, between * 0.6))
    }

    // crowded maps

    struct ScreenPoint { var id: String; var x: CGFloat; var y: CGFloat; var priority: Int }
    struct Cluster: Equatable { var ids: [String]; var x: CGFloat; var y: CGFloat }

    static func clusterPoints(_ points: [ScreenPoint], radius: CGFloat = 46) -> [Cluster] {
        let sorted = points.sorted { a, b in a.priority != b.priority ? a.priority > b.priority : a.id < b.id }
        var out: [Cluster] = []
        for p in sorted {
            if let i = out.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < radius }) {
                out[i].ids.append(p.id)
            } else {
                out.append(Cluster(ids: [p.id], x: p.x, y: p.y))
            }
        }
        return out
    }

    static let maxStatusBubbles = 6

    static func visibleStatuses(_ clusters: [Cluster], statusAt: [String: Int64], selected: String? = nil) -> Set<String> {
        let single = clusters.filter { $0.ids.count == 1 }.map { $0.ids[0] }
        let ranked = single.filter { statusAt[$0] != nil }.sorted { a, b in
            if a == selected { return true }
            if b == selected { return false }
            return (statusAt[a] ?? 0) > (statusAt[b] ?? 0)
        }
        return Set(ranked.prefix(maxStatusBubbles))
    }

    /// The accuracy circle as a polygon of (lat, lon).
    static func circlePolygon(lat: Double, lon: Double, radiusM: Double, steps: Int = 48) -> [CLLocationCoordinate2D] {
        let dLat = radiusM / 111_320
        let dLon = radiusM / (111_320 * max(0.01, cos(lat * .pi / 180)))
        return (0...steps).map { i in
            let a = Double(i) / Double(steps) * 2 * .pi
            return CLLocationCoordinate2D(latitude: lat + dLat * sin(a), longitude: lon + dLon * cos(a))
        }
    }

    static func countdown(_ ms: Int64) -> String {
        if ms <= 0 { return "0:00" }
        let s = ms / 1000
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// The header's time: "2h 46m", "2h", "46m" or "40s" (never a ticking hh:mm:ss).
    static func shortLeft(_ ms: Int64) -> String {
        let s = Int(max(0, ms / 1000))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return m > 0 ? String(format: NSLocalizedString("pulse.left.hm", comment: ""), h, m) : String(format: NSLocalizedString("pulse.left.h", comment: ""), h) }
        if m > 0 { return String(format: NSLocalizedString("pulse.left.m", comment: ""), m) }
        return String(format: NSLocalizedString("pulse.left.s", comment: ""), s)
    }

    /// How much of the meetup is left (1 = all of it, 0 = over): the header's ring.
    static func leftFraction(now: Int64, starts: Int64?, expires: Int64?) -> Double {
        guard let e = expires, e > 0 else { return 0 }
        let s = starts ?? 0
        if now < s { return 1 }
        let total = Double(e - s)
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(e - now) / total))
    }

    static let quickStatuses: [(text: String, emoji: String)] = [
        ("On my way!", "🚗"), ("Stuck in traffic", "😩"), ("5 min away", "⏱️"), ("I'm here!", "☕"), ("Running late", "🙏"), ("Order for me", "🥤"),
    ]

    static let activityIcon: [String: String] = [
        "coffee": "☕", "food": "🍔", "gaming": "🎮", "business": "💼", "road-trip": "🚙", "hangout": "🎉", "party": "🎊", "custom": "📍",
    ]

    static let activities = ["coffee", "food", "gaming", "business", "road-trip", "hangout"]

    /// The activities as line icons (web PulseIcons.tsx).
    static let activitySymbol: [String: String] = [
        "coffee": "cup.and.saucer.fill", "food": "fork.knife", "gaming": "gamecontroller.fill", "business": "briefcase.fill",
        "road-trip": "car.fill", "hangout": "person.2.fill", "party": "sparkles", "custom": "mappin",
    ]

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: API

extension APIClient {
    func pulseCall(_ path: String, method: String = "GET", token: String, body: [String: Any]? = nil) async throws -> Data {
        let req = request(path, method: method, token: token, body: body, rawQuery: path.contains("?"))
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await send(req) } catch { throw PulseHTTPError(status: 0) }
        if http.statusCode == 401 { throw APIError.badCredentials }
        guard (200..<300).contains(http.statusCode) else {
            let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            throw PulseHTTPError(status: http.statusCode, text: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", retryAfter: ra)
        }
        return data
    }

    func pulseDecode<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: d) } catch { throw PulseHTTPError(status: 502) }
    }

    static func pSeg(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? s }

    /// nil = no answer (what was known stays); 404 = a server without Pulse (off).
    func pulseConfig(token: String) async -> PulseConfig? {
        do { return try pulseDecode(PulseConfig.self, try await pulseCall("pulse/config", token: token)) } catch let e as PulseHTTPError where e.status == 404 {
            return PulseConfig()
        } catch { return nil }
    }

    func pulseCircles(token: String, ended: Bool = false) async throws -> (circles: [PulseCircleEntry], people: [String: PulsePerson]) {
        struct L: Decodable { var circles: [PulseCircleEntry]?; var people: [String: PulsePerson]? }
        let l = try pulseDecode(L.self, try await pulseCall("pulse/circles" + (ended ? "?ended=1" : ""), token: token))
        return (l.circles ?? [], l.people ?? [:])
    }

    func pulseCreate(token: String, body: [String: Any]) async throws -> PulseCircle {
        try pulseDecode(PulseCircle.self, try await pulseCall("pulse/circles", method: "POST", token: token, body: body))
    }

    func pulseCircle(token: String, id: String) async throws -> PulseCircleDetail {
        try pulseDecode(PulseCircleDetail.self, try await pulseCall("pulse/circles/\(Self.pSeg(id))", token: token))
    }

    func pulsePost(token: String, circle: String, _ what: String, body: [String: Any]? = [:]) async throws -> Data {
        try await pulseCall("pulse/circles/\(Self.pSeg(circle))/\(what)", method: "POST", token: token, body: body)
    }

    func pulseDelete(token: String, path: String) async throws {
        _ = try await pulseCall(path, method: "DELETE", token: token)
    }

    func pulseCodePreview(token: String, code: String) async throws -> (PulseCodePreview, [String: PulsePerson]) {
        struct P: Decodable { var preview: PulseCodePreview; var people: [String: PulsePerson]? }
        let p = try pulseDecode(P.self, try await pulseCall("pulse/codes/\(Self.pSeg(code))", token: token))
        return (p.preview, p.people ?? [:])
    }

    /// A multipart upload (walkie-talkie clip, Time Capsule photo).
    func pulseUpload(token: String, path: String, fields: [String: String], fileField: String, fileName: String, mime: String, data: Data) async throws -> Data {
        let boundary = "tf-\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = request(path, method: "POST", token: token, body: nil)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 60
        let out: Data, http: HTTPURLResponse
        do { (out, http) = try await send(req) } catch { throw PulseHTTPError(status: 0) }
        if http.statusCode == 401 { throw APIError.badCredentials }
        guard (200..<300).contains(http.statusCode) else { throw PulseHTTPError(status: http.statusCode, text: String(data: out, encoding: .utf8) ?? "") }
        return out
    }
}

// MARK: the store

/// Pulse for the signed-in account: the switch, the list of meetups, the live frames, an incoming safety alert and a code
/// opened by a link. Asked again on reconnect, on foreground and every 2 minutes while off.
@MainActor
final class PulseStore: ObservableObject {
    static let shared = PulseStore()

    @Published private(set) var config = PulseConfig()
    @Published private(set) var circles: [PulseCircleEntry] = []
    @Published private(set) var people: [String: PulsePerson] = [:]
    @Published private(set) var loaded = false
    /// A safety alert sent to me: shown over everything until "I've seen it".
    @Published var incomingAlert: PulseAlert?
    /// A Pulse code opened from a link or a scanned QR: the join preview.
    @Published var joinCode: PulseJoinCode?
    /// A meetup to open (a notification tapped, a code joined).
    @Published var openCircle: String?
    /// Every Pulse frame's data (the open meetup screen reads its own).
    let frames = PassthroughSubject<[String: Any], Never>()

    struct PulseJoinCode: Identifiable { let id: String }

    private(set) var token = ""
    private(set) var me = ""
    private var subs = Set<AnyCancellable>()
    private var poll: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?

    var enabled: Bool { config.enabled }

    private init() {
        LiveConnection.shared.pulseFrames.receive(on: RunLoop.main).sink { [weak self] d in self?.handle(d) }.store(in: &subs)
        LiveConnection.shared.opened.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }.store(in: &subs)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subs)
    }

    func attach(token: String, me: String) {
        guard !token.isEmpty, token != self.token else { return }
        if me != self.me { clear() }
        self.token = token
        self.me = me
        refresh()
    }

    func clear() {
        poll?.cancel(); reloadTask?.cancel()
        token = ""; me = ""
        config = PulseConfig(); circles = []; people = [:]; loaded = false
        incomingAlert = nil; joinCode = nil; openCircle = nil
    }

    /// Sign-out: sharing stops everywhere (on the server too, while the session still works) and measuring stops.
    func signOut(token: String) async {
        if !token.isEmpty, PulseSharer.shared.isSharingAnywhere {
            _ = try? await APIClient.shared.pulseCall("pulse/stop-all", method: "POST", token: token)
        }
        PulseSharer.shared.forgetAll()
        clear()
    }

    func refresh() {
        guard !token.isEmpty else { return }
        let tok = token
        Task {
            if let c = await APIClient.shared.pulseConfig(token: tok), tok == token, c != config { config = c }
            keepAsking()
            if config.enabled { await reload() }
        }
    }

    private func keepAsking() {
        poll?.cancel()
        poll = nil
        guard !config.enabled, !token.isEmpty else { return }
        poll = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !Task.isCancelled { self?.refresh() }
        }
    }

    func reloadSoon() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { await self?.reload() }
        }
    }

    func reload() async {
        guard !token.isEmpty, config.enabled else { return }
        let tok = token
        guard let r = try? await APIClient.shared.pulseCircles(token: tok), tok == token else { return }
        circles = r.circles
        people.merge(r.people) { _, new in new }
        loaded = true
        // a consent this device holds for a meetup that no longer lists me as sharing: measuring stops
        let live = Set(r.circles.filter { ($0.circle.isOpen) }.map(\.id))
        for id in PulseSharer.shared.sharingCircles where !live.contains(id) { PulseSharer.shared.stopLocally(id) }
    }

    func noteName(_ people: [String: PulsePerson]) { self.people.merge(people) { _, new in new } }

    func name(_ id: String) -> String {
        if id == me { return NSLocalizedString("chat.you", comment: "") }
        return people[id]?.name ?? ""
    }

    /// One `{"type":"pulse","data":{...}}` frame.
    private func handle(_ raw: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], let d = obj["data"] as? [String: Any],
              let e = d["e"] as? String else { return }
        let circle = d["circle_id"] as? String ?? ""
        switch e {
        case "removed", "ended":
            PulseSharer.shared.stopLocally(circle)
            reloadSoon()
        case "sharing":
            if (d["user_id"] as? String) == me, (d["sharing"] as? Bool) == false { PulseSharer.shared.stopLocally(circle) }
        case "invited", "circle", "arrived", "request":
            reloadSoon()
        case "alert":
            if let a = d["alert"], let raw = try? JSONSerialization.data(withJSONObject: a),
               let alert = try? JSONDecoder().decode(PulseAlert.self, from: raw) {
                incomingAlert = alert
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        default: break
        }
        frames.send(d)
    }
}
