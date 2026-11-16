import UIKit

/// Messages not yet accepted by the server, kept on this device per account and chat (website shared/lib/outbox.ts): they
/// survive leaving the chat or restarting the app, and are sent again with the same idempotency key, so a message that did
/// reach the server is never stored twice. Videos are not kept (they are re-encoded from the picked file).
enum OutboxStore {
    private struct Entry: Codable {
        let id: String
        let body: String
        let date: Date
        var jpeg: Data?
        var audio: Data?
        var durationMs: Int?
        var waveform: [Double]
        var replyTo: String
    }

    private static func file(_ account: String, _ conversation: String) -> URL? {
        guard !account.isEmpty, let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = dir.appendingPathComponent("outbox/\(account)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = conversation.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent("\(safe).json")
    }

    static func save(account: String, conversation: String, _ pending: [PendingMessage]) {
        guard let url = file(account, conversation) else { return }
        let entries = pending.filter { $0.video == nil }.map {
            Entry(id: $0.id, body: $0.body, date: $0.date, jpeg: $0.jpeg, audio: $0.audio, durationMs: $0.durationMs,
                  waveform: $0.waveform, replyTo: $0.replyTo)
        }
        if entries.isEmpty { try? FileManager.default.removeItem(at: url); return }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    static func load(account: String, conversation: String) -> [PendingMessage] {
        guard let url = file(account, conversation), let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.map { e in
            var p = PendingMessage(id: e.id, body: e.body, date: e.date)
            if let j = e.jpeg { p.jpeg = j; p.image = UIImage(data: j) }
            p.audio = e.audio
            p.durationMs = e.durationMs
            p.waveform = e.waveform
            p.replyTo = e.replyTo
            return p
        }
    }
}
