import UIKit

/// Messages not yet accepted by the server, kept on this device per account and chat (website shared/lib/outbox.ts): they
/// survive leaving the chat or restarting the app, and are sent again with the same idempotency key, so a message that did
/// reach the server is never stored twice. A video or large document kept as a file (ResumableUploader.folder) is kept too, by
/// its file name, so after a restart its chunked upload resumes from the server's offset (same key); a video still being
/// re-encoded is not kept.
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
        // a video or document kept as a file (optional: entries saved before these fields still load)
        var fileName: String?
        var isVideo: Bool?
        var docName: String?
        var docMime: String?
        var poster: Data?
        /// The server refused it for good (not a passing error): kept as "Not sent", never sent again by itself.
        var failed: Bool?
        /// A video note's file name (optional: entries saved before this field still load).
        var noteName: String?
    }

    private static func file(_ account: String, _ conversation: String) -> URL? {
        guard !account.isEmpty, let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = dir.appendingPathComponent("outbox/\(account)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = conversation.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent("\(safe).json")
    }

    /// Encoding photos and voice notes (base64 in JSON) and writing the file took seconds on the main thread with a few HD
    /// photos: done on a serial queue, and a burst of changes is one write of the last state.
    private static let queue = DispatchQueue(label: "tf.outbox", qos: .utility)
    private static var waiting: [URL: [Entry]] = [:] // touched on `queue` only

    private static func write(_ entries: [Entry], _ url: URL) {
        if entries.isEmpty { try? FileManager.default.removeItem(at: url); return }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    static func save(account: String, conversation: String, _ pending: [PendingMessage]) {
        guard let url = file(account, conversation) else { return }
        let entries = pending.filter { !$0.missing && ($0.video == nil || $0.file != nil) }.map {
            Entry(id: $0.id, body: $0.body, date: $0.date, jpeg: $0.jpeg, audio: $0.audio, durationMs: $0.durationMs,
                  waveform: $0.waveform, replyTo: $0.replyTo, fileName: $0.file?.lastPathComponent,
                  isVideo: $0.file != nil ? $0.video != nil : nil, docName: $0.docName.isEmpty ? nil : $0.docName,
                  docMime: $0.docMime.isEmpty ? nil : $0.docMime, poster: $0.poster,
                  failed: $0.refused ? true : nil, noteName: $0.noteName.isEmpty ? nil : $0.noteName)
        }
        queue.async {
            let first = waiting[url] == nil
            waiting[url] = entries
            guard first else { return }
            queue.asyncAfter(deadline: .now() + 0.3) {
                if let e = waiting.removeValue(forKey: url) { write(e, url) }
            }
        }
    }

    /// File names (in ResumableUploader.folder) that saved outbox entries still need.
    static func referencedFiles() -> Set<String> {
        struct Ref: Decodable { let fileName: String? }
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let en = FileManager.default.enumerator(at: dir.appendingPathComponent("outbox", isDirectory: true), includingPropertiesForKeys: nil) else { return [] }
        var out = Set<String>()
        for case let u as URL in en where u.pathExtension == "json" {
            if let d = try? Data(contentsOf: u), let rs = try? JSONDecoder().decode([Ref].self, from: d) {
                for r in rs { if let n = r.fileName { out.insert(n) } }
            }
        }
        return out
    }

    /// A text or voice message waiting in a saved outbox: what OutboxFlusher sends when no chat screen is open.
    struct QueuedLine {
        let conversation: String
        let id: String
        let body: String
        let date: Date
        let audio: Data?
        let durationMs: Int?
        let waveform: [Double]
        let replyTo: String
    }

    /// Every text / voice message of this account still waiting (not the ones the server refused, not photos / videos /
    /// documents: those resume from their own files when their chat opens).
    static func lines(account: String) -> [QueuedLine] {
        guard !account.isEmpty, let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
        let folder = dir.appendingPathComponent("outbox/\(account)", isDirectory: true)
        return queue.sync { () -> [QueuedLine] in
            for (u, e) in waiting { write(e, u) } // writes still waiting go first
            waiting.removeAll()
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            var out: [QueuedLine] = []
            for u in files where u.pathExtension == "json" {
                guard let data = try? Data(contentsOf: u), let entries = try? JSONDecoder().decode([Entry].self, from: data) else { continue }
                let conv = u.deletingPathExtension().lastPathComponent
                for e in entries where e.failed != true && e.fileName == nil && e.jpeg == nil && e.docName == nil && e.isVideo != true {
                    out.append(QueuedLine(conversation: conv, id: e.id, body: e.body, date: e.date, audio: e.audio,
                                          durationMs: e.durationMs, waveform: e.waveform, replyTo: e.replyTo))
                }
            }
            return out
        }
    }

    private static func mutate(_ account: String, _ conversation: String, _ change: (inout [Entry]) -> Void) {
        guard let url = file(account, conversation) else { return }
        queue.sync { () -> Void in
            if let e = waiting.removeValue(forKey: url) { write(e, url) }
            guard let data = try? Data(contentsOf: url), var entries = try? JSONDecoder().decode([Entry].self, from: data) else { return }
            change(&entries)
            write(entries, url)
        }
    }

    /// Sent: it leaves the saved outbox.
    static func remove(account: String, conversation: String, id: String) {
        mutate(account, conversation) { entries in entries.removeAll { $0.id == id } }
    }

    /// Refused for good: kept, shown as "Not sent" when the chat opens, never sent again by itself.
    static func markFailed(account: String, conversation: String, id: String) {
        mutate(account, conversation) { entries in
            for i in entries.indices where entries[i].id == id { entries[i].failed = true }
        }
    }

    /// The whole outbox of one chat goes (e.g. I am no longer a member of that group).
    static func clear(account: String, conversation: String) {
        guard let url = file(account, conversation) else { return }
        queue.sync { () -> Void in
            waiting.removeValue(forKey: url)
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func load(account: String, conversation: String) -> [PendingMessage] {
        guard let url = file(account, conversation),
              let data = queue.sync(execute: { () -> Data? in
                  if let e = waiting.removeValue(forKey: url) { write(e, url) } // a write still waiting goes first
                  return try? Data(contentsOf: url)
              }),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { (e: Entry) -> PendingMessage? in
            var p = PendingMessage(id: e.id, body: e.body, date: e.date)
            p.refused = e.failed == true
            p.failed = p.refused
            if let name = e.fileName {
                // the file must still be there (it is removed once sent); without it the entry cannot be sent
                let url = ResumableUploader.folder.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    // said, not dropped: the bubble tells that it was not sent and can be removed
                    p.missing = true; p.failed = true; p.refused = true
                    return p
                }
                p.file = url
                if e.isVideo == true { p.video = Data() }
                p.docName = e.docName ?? ""
                p.docMime = e.docMime ?? ""
                p.noteName = e.noteName ?? ""
                p.poster = e.poster
                if let poster = e.poster { p.image = UIImage(data: poster) }
            }
            if let j = e.jpeg { p.jpeg = j; p.image = UIImage(data: j) }
            p.audio = e.audio
            p.durationMs = e.durationMs
            p.waveform = e.waveform
            p.replyTo = e.replyTo
            return p
        }
    }
}

/// What was typed and not sent, per account and chat: kept when the chat is left or the app goes to the background, put
/// back when the chat opens, gone with the account on sign-out. (Locked chats keep none.)
enum ChatDrafts {
    private static let key = "tf.chatDrafts"

    private static func name(_ account: String, _ conversation: String) -> String { account + "|" + conversation }

    static func get(account: String, conversation: String) -> String {
        let all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        return all[name(account, conversation)] ?? ""
    }

    static func set(account: String, conversation: String, _ text: String) {
        guard !account.isEmpty else { return }
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        let kept: String? = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(text.prefix(4000))
        all[name(account, conversation)] = kept
        UserDefaults.standard.set(all, forKey: key)
    }

    static func clearAll() { UserDefaults.standard.removeObject(forKey: key) }
}
