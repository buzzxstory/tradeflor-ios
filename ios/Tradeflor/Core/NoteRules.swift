import Foundation

/// Shared Notes (2026-11-21): the pure editing rules, a 1:1 port of the web's noteRules.ts (and so the server's
/// sharednotes_text.go). Positions count Unicode code points (`unicodeScalars`), never UTF-16 units or grapheme clusters:
/// an emoji or an Arabic letter with a mark counts the same here, on the web (Array.from) and on the server (Go []rune).
enum NoteRules {
    struct Splice: Equatable {
        var from: Int
        var to: Int
        /// code points inserted (only the count is needed to move positions)
        var ins: Int
    }

    struct TextSplice: Equatable {
        var from: Int
        var to: Int
        var insert: String
    }

    static func cps(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }
    static func join<S: Sequence>(_ c: S) -> String where S.Element == Unicode.Scalar {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: c)
        return String(v)
    }
    static func cpLen(_ s: String) -> Int { s.unicodeScalars.count }

    /// The server's mapPoint: where a position on the text before s is on the text after it.
    static func mapPoint(_ p: Int, _ s: Splice) -> Int {
        if p < s.from { return p }
        if p == s.from { return s.from == s.to ? p + s.ins : p }
        if p >= s.to { return p + s.ins - (s.to - s.from) }
        return s.from + s.ins
    }

    /// The server's transformSplice: a splice written against an older text, moved over the splices accepted since.
    static func transformSplice(_ mine: Splice, _ accepted: [Splice]) -> Splice {
        var from = mine.from, to = mine.to
        for s in accepted {
            let f = mapPoint(from, s)
            let t = from == to ? f : mapPoint(to, s)
            from = f
            to = t
        }
        return Splice(from: from, to: to, ins: mine.ins)
    }

    /// Replace code points [from, to) of text with insert (clamped like the server).
    static func applySplice(_ text: String, _ from: Int, _ to: Int, _ insert: String) -> String {
        let c = cps(text)
        let f = max(0, min(from, c.count))
        let t = max(f, min(to, c.count))
        return join(c[0..<f]) + insert + join(c[t...])
    }

    /// The one splice that turns base into local (common prefix and suffix kept): what a device sends for its typing.
    static func diffSplice(_ base: String, _ local: String) -> TextSplice? {
        let a = cps(base), b = cps(local)
        if a == b { return nil }
        var p = 0
        while p < a.count && p < b.count && a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p && s < b.count - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        return TextSplice(from: p, to: a.count - s, insert: join(b[p..<(b.count - s)]))
    }

    /// Someone else's change arrived for a block this device is typing in: the server's text with this device's own typing
    /// placed on it (nothing of either is lost).
    static func rebaseLocal(_ base: String, _ local: String, _ remote: [TextSplice], _ serverText: String) -> String {
        guard let mine = diffSplice(base, local) else { return serverText }
        let moved = transformSplice(Splice(from: mine.from, to: mine.to, ins: cpLen(mine.insert)),
                                    remote.map { Splice(from: $0.from, to: $0.to, ins: cpLen($0.insert)) })
        return applySplice(serverText, moved.from, moved.to, mine.insert)
    }

    /// The server's answer for a change this device sent came back with another text (someone else typed in between): the
    /// typing done since sending is placed on the server's text by the same rule.
    static func carryTyping(_ sent: String, _ now: String, _ server: String) -> String {
        if same(sent, server) { return now }
        guard let later = diffSplice(sent, now) else { return server }
        let moves = diffSplice(sent, server).map { [Splice(from: $0.from, to: $0.to, ins: cpLen($0.insert))] } ?? []
        let m = transformSplice(Splice(from: later.from, to: later.to, ins: cpLen(later.insert)), moves)
        return applySplice(server, m.from, m.to, later.insert)
    }

    /// Exact text equality by code points (Swift's == treats canonically equivalent texts as equal; the server does not).
    static func same(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }

    /// Map a caret (UTF-16 units, as UITextView reports it) through a text change, so it stays where the person was typing.
    static func moveCaret(_ oldText: String, _ newText: String, _ caret: Int) -> Int {
        if same(oldText, newText) { return caret }
        guard let d = diffSplice(oldText, newText) else { return caret }
        let u = Array(oldText.utf16)
        let prefix = String(utf16CodeUnits: Array(u[0..<max(0, min(caret, u.count))]), count: max(0, min(caret, u.count)))
        let cpCaret = cpLen(prefix)
        let moved = mapPoint(cpCaret, Splice(from: d.from, to: d.to, ins: cpLen(d.insert)))
        // the caret is ours: when the change was inserted exactly at it, the caret stays before the other person's text
        let at = d.from == d.to && cpCaret == d.from ? cpCaret : moved
        return join(cps(newText).prefix(at)).utf16.count
    }

    // MARK: order

    static let sectionOrder = ["notes", "decisions", "followup"]

    static func sectionRank(_ s: String) -> Int { sectionOrder.firstIndex(of: s) ?? 0 }

    /// Byte-wise compare (as the server compares positions).
    static func bytesLess(_ a: String, _ b: String) -> Bool { Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8)) }

    /// Items in display order: by section, then position (byte order), then id.
    static func sortByPos<T>(_ items: [T], pos: (T) -> String, id: (T) -> String, section: (T) -> String) -> [T] {
        items.sorted { a, b in
            let sa = sectionRank(section(a)), sb = sectionRank(section(b))
            if sa != sb { return sa < sb }
            let pa = pos(a), pb = pos(b)
            if pa != pb { return bytesLess(pa, pb) }
            return bytesLess(id(a), id(b))
        }
    }

    private static let posDigits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// The server's posBetween (a provisional position for an item shown before the server's answer).
    static func posBetween(_ a: String, _ bIn: String) -> String {
        let ac = Array(a)
        var bc = Array(bIn)
        var out = ""
        let n = posDigits.count
        func idx(_ c: Character) -> Int { posDigits.firstIndex(of: c) ?? -1 }
        var i = 0
        while true {
            var da = i < ac.count ? idx(ac[i]) : 0
            var db = !bc.isEmpty && i < bc.count ? idx(bc[i]) : n
            if da < 0 { da = 0 }
            if db < 0 || (db <= da && !bc.isEmpty && i >= bc.count) { db = n }
            if da == db {
                out.append(posDigits[da])
                i += 1
                continue
            }
            let mid = (da + db) / 2
            if mid > da { return out + String(posDigits[mid]) }
            out.append(posDigits[da])
            bc = []
            i += 1
        }
    }

    /// A fresh id for a block, task or operation (the server accepts 8-64 of [A-Za-z0-9_-]).
    static func newItemID(_ prefix: String) -> String {
        String((prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()).prefix(40))
    }

    // MARK: inline formatting

    /// **bold**, *italic*, __underline__ and [label](https://link); plain text stays plain, an unfinished marker as typed.
    struct InlineSeg: Equatable {
        var text: String
        var b = false
        var i = false
        var u = false
        var href: String?
    }

    private static let inlineRE = try! NSRegularExpression(
        pattern: #"\*\*([^*\n]+)\*\*|__([^_\n]+)__|\*([^*\n]+)\*|\[([^\]\n]{1,200})\]\((https?://[^\s)]{1,500})\)"#)

    static func inlineSegments(_ text: String) -> [InlineSeg] {
        let ns = text as NSString
        var out: [InlineSeg] = []
        var last = 0
        for m in inlineRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { out.append(InlineSeg(text: ns.substring(with: NSRange(location: last, length: m.range.location - last)))) }
            func g(_ k: Int) -> String? { m.range(at: k).location == NSNotFound ? nil : ns.substring(with: m.range(at: k)) }
            if let t = g(1) { out.append(InlineSeg(text: t, b: true)) }
            else if let t = g(2) { out.append(InlineSeg(text: t, u: true)) }
            else if let t = g(3) { out.append(InlineSeg(text: t, i: true)) }
            else { out.append(InlineSeg(text: g(4) ?? "", href: g(5))) }
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append(InlineSeg(text: ns.substring(from: last))) }
        return out
    }

    /// Wrap the selection [start, end) (UTF-16) with a marker, or unwrap it when it already is.
    static func toggleWrap(_ text: String, _ start: Int, _ end: Int, _ marker: String) -> (text: String, start: Int, end: Int) {
        let ns = text as NSString
        let before = ns.substring(to: start), sel = ns.substring(with: NSRange(location: start, length: end - start)), after = ns.substring(from: end)
        let m = (marker as NSString).length
        if before.hasSuffix(marker) && after.hasPrefix(marker) {
            return ((before as NSString).substring(to: (before as NSString).length - m) + sel + (after as NSString).substring(from: m), start - m, end - m)
        }
        return (before + marker + sel + marker + after, start + m, end + m)
    }

    /// A call's length as the card shows it: "32 min", "1 h 05 min", "45 sec".
    static func meetingDuration(_ ms: Int64) -> String {
        let s = Int((Double(ms) / 1000).rounded())
        if s < 60 { return String(format: NSLocalizedString("notes.dur.sec", comment: ""), s) }
        let m = Int((Double(s) / 60).rounded())
        if m < 60 { return String(format: NSLocalizedString("notes.dur.min", comment: ""), m) }
        return String(format: NSLocalizedString("notes.dur.hmin", comment: ""), m / 60, String(format: "%02d", m % 60))
    }
}
