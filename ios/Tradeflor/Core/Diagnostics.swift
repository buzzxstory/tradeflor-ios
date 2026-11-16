import Combine
import Foundation

/// Settings › About › Live delivery (website shared/lib/deliveryStats.ts): how fast messages arrive over the live connection
/// on this device, and how often it had to reconnect. Kept in memory only.
@MainActor
final class DeliveryStats: ObservableObject {
    static let shared = DeliveryStats()
    @Published private(set) var samples: [Int] = []
    @Published private(set) var reconnects = 0
    @Published private(set) var lastReconnectMs: Int?
    private var subs = Set<AnyCancellable>()
    private var droppedAt: Date?
    private var everConnected = false

    func attach(_ live: LiveConnection, me: String) {
        subs.removeAll()
        live.messages.receive(on: RunLoop.main).sink { [weak self] m in
            guard let self, m.sender_id != me else { return }
            let sent = m.created_at > 100_000_000_000 ? Double(m.created_at) / 1000 : Double(m.created_at)
            let ms = Int((Date().timeIntervalSince1970 - sent) * 1000)
            guard ms >= 0, ms < 120_000 else { return } // an old message replayed after a gap is not a delivery time
            self.samples.append(ms)
            if self.samples.count > 200 { self.samples.removeFirst(self.samples.count - 200) }
        }.store(in: &subs)
        live.$connected.receive(on: RunLoop.main).sink { [weak self] up in
            guard let self else { return }
            if up {
                if self.everConnected, let d = self.droppedAt {
                    self.reconnects += 1
                    self.lastReconnectMs = Int(Date().timeIntervalSince(d) * 1000)
                }
                self.everConnected = true
                self.droppedAt = nil
            } else if self.everConnected && self.droppedAt == nil {
                self.droppedAt = Date()
            }
        }.store(in: &subs)
    }

    func percentile(_ p: Double) -> Int? {
        guard !samples.isEmpty else { return nil }
        let s = samples.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }

    static func ms(_ v: Int?) -> String {
        guard let v else { return "–" }
        return v < 1000 ? "\(v) ms" : String(format: "%.1f s", Double(v) / 1000)
    }

    var summary: String {
        var parts: [String] = []
        if samples.isEmpty {
            parts.append(NSLocalizedString("about.measuring", comment: ""))
        } else {
            parts.append(String(format: NSLocalizedString("about.delivery", comment: ""), Self.ms(percentile(0.5)), Self.ms(percentile(0.95))))
        }
        var rc = String(format: NSLocalizedString("about.reconnects", comment: ""), reconnects)
        if let l = lastReconnectMs { rc += String(format: NSLocalizedString("about.reconnects.last", comment: ""), Self.ms(l)) }
        parts.append(rc)
        return parts.joined(separator: " · ")
    }
}

/// Settings › About › Status video log (website shared/lib/mediaLog.ts): what the last video statuses did while opening on
/// this device, to copy and send to support by hand. Kept on this device only.
enum MediaLog {
    private static let key = "tf.mediaLog"

    struct Entry: Codable {
        let at: Date
        let id: String
        let ok: Bool
        let ms: Int
    }

    static func read() -> [Entry] {
        guard let d = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return list
    }

    static func record(id: String, ok: Bool, ms: Int) {
        var list = read()
        list.append(Entry(at: Date(), id: id, ok: ok, ms: ms))
        if list.count > 10 { list.removeFirst(list.count - 10) }
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    static func diagnose(_ e: Entry) -> String {
        e.ok ? String(format: NSLocalizedString("about.medialog.ok", comment: ""), DeliveryStats.ms(e.ms))
             : String(format: NSLocalizedString("about.medialog.fail", comment: ""), DeliveryStats.ms(e.ms))
    }

    static func text(_ list: [Entry]) -> String {
        let f = ISO8601DateFormatter()
        return list.map { "\(f.string(from: $0.at)) status \($0.id) \($0.ok ? "ready" : "failed") \($0.ms) ms" }.joined(separator: "\n")
    }
}
