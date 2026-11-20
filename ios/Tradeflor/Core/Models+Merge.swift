import Foundation

/// When an open chat tells the server it was read (one read-all / group read for the whole chat, never a receipt per
/// message): the first time, then only when someone else wrote something newer than what the server last took.
enum ReadMark {
    /// `marked` -1: nothing sent yet on this screen.
    static func due(newestIncoming: Int64, marked: Int64) -> Bool { marked < 0 || newestIncoming > marked }
}

/// How a new copy of a message the chat already holds replaces the old one (live `message` updates, a page reload, a send's
/// answer). Pure functions: unit tested in MessageMergeTests.
enum MessageMerge {
    /// The new copy, with the furthest delivery state either copy reached: "read" beats "delivered", and an older answer that
    /// arrives late (a send's 200, a page read before the receipt) never takes a tick back.
    static func keepingReceipts(old: Message, new: Message) -> Message {
        guard old.id == new.id else { return new }
        var out = new
        if (out.read_at ?? 0) <= 0, let r = old.read_at, r > 0 { out.read_at = r }
        if (out.delivered_at ?? 0) <= 0, let d = old.delivered_at, d > 0 { out.delivered_at = d }
        return out
    }

    /// The quote the server stores for a text message (backend messaging.go quoteOf): the text, at most 140 bytes of UTF-8,
    /// never cut inside a character.
    static func quote(ofText body: String) -> String {
        guard body.utf8.count > 140 else { return body }
        var out = String.UnicodeScalarView()
        var bytes = 0
        for s in body.unicodeScalars {
            let v = s.value
            let n = v < 0x80 ? 1 : (v < 0x800 ? 2 : (v < 0x10000 ? 3 : 4))
            if bytes + n > 140 { break }
            out.append(s)
            bytes += n
        }
        return String(out)
    }

    /// Replies in `list` take the quote the server now stores for them (backend SoftDeleteWithReplies and requoteReplies):
    /// none once the quoted message was deleted for everyone (a deleted PIN must not stay readable inside a quote), its new
    /// text once it was edited. Only replies that carry a quote change (as on the server). nil when nothing changed.
    static func requote(_ list: [Message], after changed: [Message]) -> [Message]? {
        // quoted message id -> its quote now ("" = no quote)
        var quoteNow: [String: String] = [:]
        for m in changed {
            if m.isDeleted {
                quoteNow[m.id] = ""
            } else if m.kind == "text", (m.edited_at ?? 0) > 0, !m.isSealed {
                quoteNow[m.id] = quote(ofText: m.body)
            }
        }
        guard !quoteNow.isEmpty else { return nil }
        var out = list
        var any = false
        for i in out.indices {
            guard let to = out[i].reply_to_id, let q = quoteNow[to], !out[i].isDeleted,
                  let current = out[i].reply_snippet, !current.isEmpty else { continue }
            let next: String? = q.isEmpty ? nil : q
            if current != next {
                out[i].reply_snippet = next
                any = true
            }
        }
        return any ? out : nil
    }
}
