import Foundation
import UIKit
import Combine
import CoreLocation

// Pulse SOS after the safety audit (2026-11-21; contract docs/pulse/PULSE_CROSS_PLATFORM_HANDOFF.md, screens
// PULSE_SAFETY_RESPONSE_SPEC.md, iOS tasks PULSE_IOS_HANDOFF.md section 8). The truth is GET /pulse/sos; events are nudges.

struct PulseAlertRecipient: Decodable, Equatable {
    var user_id: String
    var live_at: Int64?
    var push_status: String?
    var push_at: Int64?
    var delivered_at: Int64?
    var seen_at: Int64?
    var responding_at: Int64?
}

/// One SOS as the server keeps it.
struct PulseEmergency: Decodable, Identifiable, Equatable {
    let id: String
    var circle_id: String?
    var circle_title: String?
    var circle_live: Bool?
    var user_id: String
    var kind: String?
    var reason: String?
    var created_at: Int64?
    var state: String?
    var resolved_at: Int64?
    var lat: Double?
    var lon: Double?
    var accuracy: Double?
    var location_at: Int64?
    var recipients: [PulseAlertRecipient]?
    var total: Int?
    var live: Int?
    var push_sent: Int?
    var delivered: Int?
    var seen: Int?
    var responding: Int?

    var isActive: Bool { (state ?? "active") == "active" }
    var hasPosition: Bool { lat != nil && lon != nil }
    var rows: [PulseAlertRecipient] { recipients ?? [] }
}

enum PulseSOSRules {
    /// The sender's delivery line (web sosDeliveryText): never "everyone was alerted".
    static func deliveryText(_ e: PulseEmergency?, responding: [String]) -> (line: String, detail: String) {
        guard let e else { return (NSLocalizedString("sos.dl.creating", comment: ""), "") }
        let total = e.total ?? e.rows.count
        if total == 0 { return (NSLocalizedString("sos.dl.nobody", comment: ""), NSLocalizedString("sos.dl.nobody.sub", comment: "")) }
        let reached = e.rows.filter { $0.live_at != nil || $0.delivered_at != nil || $0.push_status == "sent" || $0.push_status == "partial" }.count
        var parts = [String(format: NSLocalizedString("sos.dl.sent", comment: ""), reached, total)]
        if let d = e.delivered, d > 0 { parts.append(String(format: NSLocalizedString("sos.dl.received", comment: ""), d)) }
        if let s = e.seen, s > 0 { parts.append(String(format: NSLocalizedString("sos.dl.opened", comment: ""), s)) }
        let unconfirmed = total - (e.delivered ?? 0)
        let off = e.rows.filter { $0.live_at == nil && $0.delivered_at == nil && ["notifications_off", "no_device", "failed"].contains($0.push_status ?? "") }.count
        var bits: [String] = []
        if !responding.isEmpty {
            bits.append(String(format: NSLocalizedString(responding.count == 1 ? "sos.dl.responding.one" : "sos.dl.responding.n", comment: ""), names(responding)))
        }
        if unconfirmed > 0 { bits.append(String(format: NSLocalizedString("sos.dl.unconfirmed", comment: ""), unconfirmed)) }
        if off > 0 { bits.append(String(format: NSLocalizedString("sos.dl.off", comment: ""), off)) }
        return (parts.joined(separator: " · "), bits.joined(separator: " · "))
    }

    static func names(_ n: [String]) -> String {
        if n.count <= 2 { return n.joined(separator: NSLocalizedString("sos.and", comment: "")) }
        return String(format: NSLocalizedString("sos.names.more", comment: ""), n.prefix(2).joined(separator: ", "), n.count - 2)
    }

    /// Per recipient, for the sender's list (web recipientStateText).
    static func recipientState(_ r: PulseAlertRecipient) -> String {
        let key: String
        if r.responding_at != nil { key = "sos.rs.responding" }
        else if r.seen_at != nil { key = "sos.rs.opened" }
        else if r.delivered_at != nil { key = "sos.rs.received" }
        else if r.live_at != nil { key = "sos.rs.live" }
        else {
            switch r.push_status ?? "" {
            case "sent", "partial": key = "sos.rs.push"
            case "notifications_off": key = "sos.rs.off"
            case "no_device": key = "sos.rs.nodevice"
            case "failed": key = "sos.rs.failed"
            case "blocked": key = "sos.rs.blocked"
            default: key = "sos.rs.waiting"
            }
        }
        return NSLocalizedString(key, comment: "")
    }

    /// The emergency numbers to pick from (never dialled by themselves): the device's country first.
    struct Line: Identifiable, Equatable { let id: String; let label: String; let number: String; let local: Bool }

    static func lines(region: String?) -> [Line] {
        let all: [(String, String, String)] = [
            ("LB", "sos.em.lb.112", "112"), ("LB", "sos.em.lb.140", "140"), ("LB", "sos.em.lb.175", "175"),
            ("EU", "sos.em.eu", "112"), ("GB", "sos.em.uk", "999"), ("US", "sos.em.us", "911"), ("AU", "sos.em.au", "000"),
        ]
        let eu: Set<String> = ["AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL",
                               "PL", "PT", "RO", "SK", "SI", "ES", "SE"]
        var r = (region ?? "").uppercased()
        if eu.contains(r) { r = "EU" }
        if r == "CA" { r = "US" }
        let rows = all.enumerated().map { i, x in Line(id: "\(i)", label: NSLocalizedString(x.1, comment: ""), number: x.2, local: x.0 == r) }
        return rows.filter(\.local) + rows.filter { !$0.local }
    }

    /// A new idempotency key for a confirmation screen (8-64 of [A-Za-z0-9_-]).
    static func newKey() -> String { "sos_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}

/// Every active SOS this account sent or may see, on every screen: reloaded on start, every reconnect, every foreground and
/// after each SOS event; a received one is acknowledged (delivered) once and opens the emergency screen.
@MainActor
final class SOSCenter: ObservableObject {
    static let shared = SOSCenter()

    @Published private(set) var active: [PulseEmergency] = []
    @Published private(set) var people: [String: PulsePerson] = [:]
    /// The emergency screen on show (nil = closed or minimized).
    @Published var shown: String?
    @Published var toast: String?

    private var token = ""
    private(set) var me = ""
    private var delivered = Set<String>()
    private var seenSent = Set<String>()
    private var opened = Set<String>()
    private var subs = Set<AnyCancellable>()
    private var reloadTask: Task<Void, Never>?

    private init() {
        LiveConnection.shared.opened.receive(on: RunLoop.main).sink { [weak self] in self?.reloadSoon() }.store(in: &subs)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadSoon() }.store(in: &subs)
        PulseStore.shared.frames.receive(on: RunLoop.main).sink { [weak self] d in self?.frame(d) }.store(in: &subs)
    }

    func attach(token: String, me: String) {
        guard !token.isEmpty, token != self.token else { return }
        if me != self.me { clear() }
        self.token = token
        self.me = me
        reloadSoon()
    }

    func clear() {
        reloadTask?.cancel()
        token = ""; me = ""
        active = []; people = [:]; shown = nil; toast = nil
        delivered = []; seenSent = []; opened = []
    }

    var incoming: [PulseEmergency] { active.filter { $0.user_id != me && $0.isActive } }
    func emergency(_ id: String) -> PulseEmergency? { active.first { $0.id == id } }
    func name(_ id: String) -> String { id == me ? NSLocalizedString("chat.you", comment: "") : (people[id]?.name ?? PulseStore.shared.name(id)) }

    func reloadSoon() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { await self?.reload() }
        }
    }

    func reload() async {
        guard !token.isEmpty else { return }
        let tok = token
        struct R: Decodable { var sos: [LenientItem<PulseEmergency>]?; var people: [String: PulsePerson]? }
        guard let d = try? await APIClient.shared.pulseCall("pulse/sos", token: tok),
              let r = try? JSONDecoder().decode(R.self, from: d), tok == token else { return }
        let list = (r.sos ?? []).compactMap(\.value)
        people.merge(r.people ?? [:]) { _, n in n }
        PulseStore.shared.noteName(r.people ?? [:])
        let gone = Set(active.map(\.id)).subtracting(list.map(\.id))
        active = list
        if let s = shown, gone.contains(s) { shown = nil }
        for e in list where e.user_id != me && e.isActive {
            acknowledge(e.id)
            // a new one opens the screen by itself (once); one I already opened stays where I left it
            if !opened.contains(e.id), e.rows.first(where: { $0.user_id == me })?.seen_at == nil {
                open(e.id)
            }
        }
    }

    /// The app received this SOS (event, push or list): told once.
    private func acknowledge(_ id: String) {
        guard !delivered.contains(id), !token.isEmpty else { return }
        delivered.insert(id)
        let tok = token
        Task { _ = try? await APIClient.shared.pulseCall("pulse/alerts/\(APIClient.pSeg(id))/delivered", method: "POST", token: tok, body: [:]) }
    }

    func open(_ id: String) {
        opened.insert(id)
        shown = id
    }

    /// The screen is on show: seen, once.
    func markSeen(_ id: String) {
        guard let e = emergency(id), e.user_id != me, !seenSent.contains(id), !token.isEmpty else { return }
        seenSent.insert(id)
        let tok = token
        Task { _ = try? await APIClient.shared.pulseCall("pulse/alerts/\(APIClient.pSeg(id))/seen", method: "POST", token: tok, body: [:]); reloadSoon() }
    }

    /// A push tapped (pulse-alert-<id>): find it and open it.
    func openFromPush(_ id: String?) {
        Task {
            await reload()
            if let id, emergency(id) != nil { open(id) } else if let first = incoming.first { open(first.id) }
        }
    }

    func setResponding(_ id: String, _ on: Bool) async {
        _ = try? await APIClient.shared.pulseCall("pulse/alerts/\(APIClient.pSeg(id))/responding", method: "POST", token: token, body: ["on": on])
        await reload()
    }

    func resolve(_ id: String, how: String) async -> Bool {
        do {
            _ = try await APIClient.shared.pulseCall("pulse/alerts/\(APIClient.pSeg(id))/resolve", method: "POST", token: token, body: ["how": how])
            await reload()
            await PulseStore.shared.reload()
            return true
        } catch { return false }
    }

    /// Sends an SOS: the same key for up to 3 tries; the server makes one alert (a replay returns the one already made).
    /// The answer is the alert's id, nil when it could not be sent.
    func send(circle: String, reason: String, key: String, position: [String: Any]?) async -> String? {
        var body: [String: Any] = ["kind": "sos", "text": reason, "key": key]
        if let position { body["position"] = position }
        struct Ref: Decodable { let id: String }
        struct R: Decodable { var alert: Ref?; var emergency: Ref? }
        for attempt in 0..<3 {
            do {
                let d = try await APIClient.shared.pulsePost(token: token, circle: circle, "alerts", body: body)
                let r = try? JSONDecoder().decode(R.self, from: d)
                await reload()
                return r?.emergency?.id ?? r?.alert?.id ?? ""
            } catch let e as PulseHTTPError where e.status == 0 || e.status >= 500 {
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 800_000_000)
            } catch {
                return nil
            }
        }
        return nil
    }

    /// The one snapshot an SOS may carry (only when "Attach my current location" stayed on).
    static func snapshot(_ l: CLLocation) -> [String: Any] {
        ["lat": l.coordinate.latitude, "lon": l.coordinate.longitude, "accuracy": min(5000, max(1, l.horizontalAccuracy)),
         "source": "ios", "seq": 0, "measured_at": Int64(l.timestamp.timeIntervalSince1970 * 1000)]
    }

    private func frame(_ d: [String: Any]) {
        guard let e = d["e"] as? String else { return }
        switch e {
        case "alert":
            guard let a = d["alert"] as? [String: Any], (a["kind"] as? String) == "sos", let id = a["id"] as? String else { return }
            acknowledge(id)
            Task { await reload(); open(id) }
        case "alert-delivery", "alert-seen":
            reloadSoon()
        case "sos-responding":
            if let u = d["user_id"] as? String, u != me, (d["on"] as? Bool) == true {
                toast = String(format: NSLocalizedString("sos.toast.responding", comment: ""), name(u))
            }
            reloadSoon()
        case "sos-resolved":
            let u = d["user_id"] as? String ?? ""
            let how = d["how"] as? String ?? "safe"
            let key = how == "cancelled" ? "sos.toast.cancelled" : how == "lapsed" ? "sos.toast.lapsed" : "sos.toast.safe"
            if u != me { toast = String(format: NSLocalizedString(key, comment: ""), name(u)) }
            if let id = d["alert_id"] as? String, shown == id { shown = nil }
            reloadSoon()
        default: break
        }
    }
}
