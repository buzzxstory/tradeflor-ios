import Foundation

/// Shared Notes (2026-11-21): one open note, kept in step with the server and with the other people editing it. A port of the
/// web's noteSession.ts (desktop/src/features/notes/noteSession.ts); its tests are ported in NoteSessionTests.
///
/// - Typing changes the screen at once; what changed goes a moment later (350 ms) as small operations, one request at a time.
/// - A request that got no answer is sent again AS IT WAS (same operation ids): the server applies each operation once.
/// - Someone else's change for a paragraph this device is typing in is merged (NoteRules.rebaseLocal). While this device's own
///   request for that paragraph is unanswered, their change is held until the answer is in (merging earlier typed my text
///   twice: the web's two-browser test).
/// - Changes not accepted yet are kept on the device (per account and note) until the server accepts them.
@MainActor
final class NoteSession {
    enum Status: String { case loading, saved, saving, offline, readonly, deleted, error }

    struct Deps {
        var getNote: (Int) async throws -> NoteState
        var sendOps: ([NoteOp], String) async throws -> NoteOpsAnswer
        var watch: () async -> Void
        var storage: NotePendingStore?
        var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
        /// run f after ms milliseconds; returns a handle for clearTimer
        var setTimer: (Int, @escaping @MainActor () async -> Void) -> AnyObject = NoteSession.defaultTimer
        var clearTimer: (AnyObject) -> Void = { ($0 as? TimerBox)?.task?.cancel() }
    }

    struct View {
        var note: SharedNote?
        var blocks: [NoteBlock]
        var tasks: [NoteTask]
        var status: Status
        var notice: String?
        /// people (not me) who changed the note in the last 15 s
        var activeEditors: [String]
        var pending: Int
    }

    private struct ServerBlock { var rev: Int; var text: String }

    struct Saved: Codable {
        struct Text: Codable { var baseRev: Int; var base: String; var local: String }
        var queue: [NoteOp]
        var inflight: [NoteOp]?
        var texts: [String: Text]
    }

    final class TimerBox { var task: Task<Void, Never>? }

    nonisolated static func defaultTimer(_ ms: Int, _ f: @escaping @MainActor () async -> Void) -> AnyObject {
        let box = TimerBox()
        box.task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
            if !Task.isCancelled { await f() }
        }
        return box
    }

    static let flushMS = 350
    static let watchMS = 25_000
    static let storagePrefix = "tf.notes.pending."

    private(set) var note: SharedNote?
    private var blocks: [String: NoteBlock] = [:]
    private var tasks: [String: NoteTask] = [:]
    private var server: [String: ServerBlock] = [:]
    private var queue: [NoteOp] = []
    private var inflight: [NoteOp]?
    private var inflightTexts: [String: String] = [:]
    private var deferred: [String: (block: NoteBlock, splices: [NoteSplice])] = [:]
    private(set) var status: Status = .loading
    private(set) var notice: String?
    private var editors: [String: Int64] = [:]
    var onChange: (() -> Void)?
    private var flushTimer: AnyObject?
    private var watchTimer: AnyObject?
    private var retryTimer: AnyObject?
    private var retryMs = 1500
    /// a request is on its way now (a network that comes back never sends the same batch a second time alongside it)
    private var sending = false
    private var disposed = false
    let client = NoteRules.newItemID("dev")
    private let key: String
    private let myId: String
    let noteId: String
    private let d: Deps

    init(myId: String, noteId: String, deps: Deps, initial: NoteState? = nil) {
        self.myId = myId
        self.noteId = noteId
        self.d = deps
        self.key = Self.storagePrefix + myId + "." + noteId
        self.initial = initial
    }

    /// a state already in hand (a note just created, a call's notebook just opened): no first load
    private var initial: NoteState?

    // MARK: lifecycle

    func start() async {
        await load()
        heartbeat()
    }

    func dispose() {
        disposed = true
        for t in [flushTimer, watchTimer, retryTimer].compactMap({ $0 }) { d.clearTimer(t) }
        onChange = nil
    }

    func clearNotice() { notice = nil; emit() }

    func view() -> View {
        let now = d.now()
        let active = editors.filter { $0.key != myId && now - $0.value < 15_000 }.map(\.key).sorted()
        let pending = queue.count + (inflight?.count ?? 0) + textPendingIds().count
        // never "Saved" while anything is unsent (queued, in flight, or on-screen text the server does not have)
        let shown: Status = status == .saved && pending > 0 ? .saving : status
        return View(note: note,
                    blocks: NoteRules.sortByPos(blocks.values.filter { !$0.deleted }, pos: \.pos, id: \.id, section: \.section),
                    tasks: NoteRules.sortByPos(tasks.values.filter { !$0.deleted }, pos: \.pos, id: \.id, section: { _ in "notes" }),
                    status: shown, notice: notice, activeEditors: active, pending: pending)
    }

    private func emit() { if !disposed { onChange?() } }

    private func later(_ ms: Int, _ f: @escaping @MainActor () async -> Void) -> AnyObject { d.setTimer(ms, f) }

    private func heartbeat() {
        if disposed { return }
        let w = d.watch
        Task { await w() }
        watchTimer = later(Self.watchMS) { [weak self] in self?.heartbeat() }
    }

    private func load() async {
        let st: NoteState
        if let i = initial {
            st = i
            initial = nil
        } else {
            do { st = try await d.getNote(0) } catch {
                status = (error as? NoteHTTPError)?.status == 404 ? .deleted : .offline
                emit()
                if status == .offline { retryLater { [weak self] in await self?.load() } }
                return
            }
        }
        if disposed { return }
        adopt(st)
        restoreSaved()
        status = note?.can_edit == true ? (hasPending() ? .saving : .saved) : .readonly
        emit()
        if inflight != nil { await sendInflight() } // the batch whose answer was lost goes first, as it was
        else if hasPending() { scheduleFlush(0) }
    }

    /// Back online: fetch what changed and merge.
    func resync() async {
        guard !disposed, let n = note else { return }
        let st: NoteState
        do { st = try await d.getNote(n.rev) } catch { return }
        if st.full {
            let locals = Dictionary(uniqueKeysWithValues: textPendingIds().map { ($0, blocks[$0]!.text) })
            let bases = server
            blocks.removeAll(); tasks.removeAll(); server.removeAll()
            adopt(st)
            for (id, local) in locals { mergeRemote(id, bases[id]?.text ?? "", local) }
        } else {
            note = st.note
            for b in st.blocks { applyRemoteBlock(b, []) }
            for t in st.tasks { tasks[t.id] = t }
        }
        emit()
        if hasPending() { scheduleFlush(0) }
    }

    private func adopt(_ st: NoteState) {
        note = st.note
        for b in st.blocks {
            blocks[b.id] = b
            server[b.id] = ServerBlock(rev: b.rev, text: b.text)
        }
        for t in st.tasks { tasks[t.id] = t }
    }

    // MARK: what the person does

    var canEdit: Bool { note?.can_edit == true && status != .deleted }

    func setTitle(_ title: String) {
        guard canEdit, note != nil else { return }
        note?.title = title
        // the newest title queued replaces an older one not sent yet
        queue.removeAll { $0.op == "title" }
        var o = NoteOp(op: "title")
        o.text = title
        queue.append(o)
        changed()
    }

    func setBlockText(_ id: String, _ text: String) {
        guard var b = blocks[id], canEdit else { return }
        b.text = text
        blocks[id] = b
        changed()
    }

    func block(_ id: String) -> NoteBlock? { blocks[id] }

    @discardableResult
    func insertBlock(after: String, section: String, type: String, text: String = "") -> String? {
        guard canEdit else { return nil }
        let id = NoteRules.newItemID("b")
        let list = NoteRules.sortByPos(blocks.values.filter { !$0.deleted && $0.section == section }, pos: \.pos, id: \.id, section: \.section)
        let i = after.isEmpty ? -1 : (list.firstIndex { $0.id == after } ?? -1)
        let lo = i >= 0 ? list[i].pos : ""
        let hi = i + 1 < list.count ? list[i + 1].pos : ""
        let pos = !after.isEmpty && i < 0 ? NoteRules.posBetween(list.last?.pos ?? "", "") : NoteRules.posBetween(lo, hi)
        blocks[id] = NoteBlock(id: id, section: section, type: type, pos: pos, text: text, updated_by: myId, updated_at: d.now())
        server[id] = ServerBlock(rev: 0, text: text)
        var o = NoteOp(op: "block.insert", id: id)
        o.after = i >= 0 ? after : (!after.isEmpty ? list.last?.id ?? "" : "")
        o.section = section
        o.type = type
        o.text = text
        queue.append(o)
        changed()
        return id
    }

    func setBlock(_ id: String, type: String? = nil, checked: Bool? = nil, section: String? = nil) {
        guard var b = blocks[id], canEdit else { return }
        if let type { b.type = type }
        if let checked { b.checked = checked }
        if let section { b.section = section }
        blocks[id] = b
        var o = NoteOp(op: "block.set", id: id)
        o.type = type; o.checked = checked; o.section = section
        queue.append(o)
        changed()
    }

    func deleteBlock(_ id: String) {
        guard var b = blocks[id], canEdit else { return }
        b.deleted = true
        blocks[id] = b
        queue.append(NoteOp(op: "block.delete", id: id))
        changed()
    }

    func moveBlock(_ id: String, after: String) {
        guard var b = blocks[id], canEdit, id != after else { return }
        let list = NoteRules.sortByPos(blocks.values.filter { !$0.deleted && $0.section == b.section && $0.id != id }, pos: \.pos, id: \.id, section: \.section)
        let i = after.isEmpty ? -1 : (list.firstIndex { $0.id == after } ?? -1)
        b.pos = NoteRules.posBetween(i >= 0 ? list[i].pos : "", i + 1 < list.count ? list[i + 1].pos : "")
        blocks[id] = b
        var o = NoteOp(op: "block.move", id: id)
        o.after = after
        queue.append(o)
        changed()
    }

    struct TaskFields {
        var title: String?
        var descr: String?
        var assignee: String?
        var due: Int64?
        var done: Bool?
    }

    /// Create (nil id) or change a task. A person who may not edit can still tick a task given to them.
    @discardableResult
    func upsertTask(_ id: String?, _ f: TaskFields) -> String? {
        let mine = id.flatMap { tasks[$0]?.assignee_id } == myId
        let tickOnly = f.done != nil && f.title == nil && f.descr == nil && f.assignee == nil && f.due == nil
        guard canEdit || (mine && tickOnly) else { return nil }
        let tid = id ?? NoteRules.newItemID("t")
        let now = d.now()
        let lastPos = NoteRules.sortByPos(Array(tasks.values), pos: \.pos, id: \.id, section: { _ in "notes" }).last?.pos ?? ""
        var t = tasks[tid] ?? {
            var n = NoteTask(id: tid, pos: NoteRules.posBetween(lastPos, ""))
            n.created_by = myId
            n.created_at = now
            return n
        }()
        if let v = f.title { t.title = v }
        if let v = f.descr { t.descr = v }
        if let v = f.assignee { t.assignee_id = v.isEmpty ? nil : v }
        if let v = f.due { t.due_at = v == 0 ? nil : v }
        if let v = f.done { t.done = v; t.done_by = v ? myId : nil; t.done_at = v ? now : nil }
        t.updated_by = myId
        t.updated_at = now
        tasks[tid] = t
        var o = NoteOp(op: "task.upsert", id: tid)
        o.title = f.title; o.descr = f.descr; o.assignee = f.assignee; o.due = f.due; o.done = f.done
        queue.append(o)
        changed()
        return tid
    }

    func deleteTask(_ id: String) {
        guard var t = tasks[id], canEdit else { return }
        t.deleted = true
        tasks[id] = t
        queue.append(NoteOp(op: "task.delete", id: id))
        changed()
    }

    /// The network went away or came back (NWPathMonitor). Gone with unsent changes: "Offline" at once. Back: the unanswered
    /// batch goes again at once, unchanged (not after the retry timer), or what waits is sent.
    func connectivity(_ up: Bool) {
        guard !disposed, note != nil else { return }
        if !up {
            if hasPending() && status != .deleted && status != .readonly { status = .offline; emit() }
            return
        }
        guard status == .offline, !sending else { return }
        if let t = retryTimer { d.clearTimer(t) }
        retryTimer = nil
        retryMs = 1500
        if inflight != nil {
            Task { await self.sendInflight() }
        } else if hasPending() {
            status = .saving
            emit()
            scheduleFlush(0)
        }
    }

    /// Send now (closing the note, ending a call).
    func flushNow() async {
        if let t = flushTimer { d.clearTimer(t) }
        flushTimer = nil
        await flush()
    }

    // MARK: sending

    private func changed() {
        if status == .saved { status = .saving }
        save()
        emit()
        scheduleFlush(Self.flushMS)
    }

    private func scheduleFlush(_ ms: Int) {
        if flushTimer != nil || disposed { return }
        flushTimer = later(ms) { [weak self] in
            self?.flushTimer = nil
            await self?.flush()
        }
    }

    private func textPendingIds() -> [String] {
        blocks.compactMap { id, b in
            guard !b.deleted, let s = server[id], s.rev > 0, !NoteRules.same(s.text, b.text) else { return nil }
            return id
        }
    }

    var hasPendingChanges: Bool { hasPending() }

    private func hasPending() -> Bool { !queue.isEmpty || inflight != nil || !textPendingIds().isEmpty }

    private func buildBatch() -> [NoteOp] {
        var ops = Array(queue.prefix(80))
        queue.removeFirst(ops.count)
        inflightTexts.removeAll()
        // a block inserted in this batch carries its text in the insert; every other changed block sends one splice
        let insertedNow = Set(ops.filter { $0.op == "block.insert" }.compactMap(\.id))
        for k in ops.indices where ops[k].op == "block.insert" {
            if let id = ops[k].id, let b = blocks[id] {
                ops[k].text = b.text
                inflightTexts[id] = b.text
            }
        }
        for id in textPendingIds() {
            if insertedNow.contains(id) || ops.count >= 100 { continue }
            let s = server[id]!
            let local = blocks[id]!.text
            guard let df = NoteRules.diffSplice(s.text, local) else { continue }
            var o = NoteOp(op: "block.text", id: id)
            o.base_rev = s.rev; o.from = df.from; o.to = df.to; o.insert = df.insert
            ops.append(o)
            inflightTexts[id] = local
        }
        return ops
    }

    private func flush() async {
        guard !disposed, inflight == nil, let n = note else { return }
        if !n.can_edit && !queue.contains(where: { $0.op == "task.upsert" }) { return }
        let ops = buildBatch()
        if ops.isEmpty {
            status = n.can_edit ? .saved : .readonly
            save()
            emit()
            return
        }
        inflight = ops
        status = .saving
        save()
        emit()
        await sendInflight()
    }

    private func sendInflight() async {
        guard let ops = inflight, !disposed, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            let res = try await d.sendOps(ops, client)
            if disposed { return }
            retryMs = 1500
            accept(res.note, res.results)
        } catch {
            if disposed { return }
            let st = (error as? NoteHTTPError)?.status ?? 0
            if st == 0 || st == 429 || st >= 500 {
                // not delivered (or not answered): the SAME batch goes again later; nothing is lost or applied twice
                status = .offline
                emit()
                retryLater { [weak self] in await self?.sendInflight() }
                return
            }
            await refused(st)
        }
    }

    private func retryLater(_ f: @escaping @MainActor () async -> Void) {
        if let t = retryTimer { d.clearTimer(t) }
        retryTimer = later(retryMs) { [weak self] in
            self?.retryTimer = nil
            await f()
        }
        retryMs = min(retryMs * 2, 20_000)
    }

    private func accept(_ n: SharedNote, _ results: [NoteOpResult]) {
        let ops = inflight ?? []
        inflight = nil
        var nn = n
        if queue.contains(where: { $0.op == "title" }) { nn.title = note?.title ?? n.title }
        note = nn
        for (i, r) in results.enumerated() {
            let op = i < ops.count ? ops[i] : nil
            if let b = r.block {
                let sent = inflightTexts[b.id]
                let shown = blocks[b.id]
                // what I typed after sending is carried over onto the server's text
                let text = sent != nil && shown != nil ? NoteRules.carryTyping(sent!, shown!.text, b.text) : b.text
                if let cur = server[b.id] {
                    if b.rev >= cur.rev { server[b.id] = ServerBlock(rev: b.rev, text: b.text) }
                } else { server[b.id] = ServerBlock(rev: b.rev, text: b.text) }
                var nb = b
                nb.text = shown.map { !$0.deleted } == true ? text : b.text
                nb.deleted = (shown?.deleted ?? false) || b.deleted
                blocks[b.id] = nb
            } else if op?.op == "block.delete", let id = op?.id {
                server[id] = nil
            }
            if let t = r.task, !queue.contains(where: { $0.id == t.id }) { tasks[t.id] = t }
            // an edit the server had already applied (its answer was lost): only what was typed after it stays, on the server's
            // current text -- never the same edit twice
            if r.status == "duplicate", op?.op == "block.text", let id = op?.id, let sent = inflightTexts[id], var shown = blocks[id],
               let srv = server[id] {
                shown.text = NoteRules.carryTyping(sent, shown.text, srv.text)
                blocks[id] = shown
            }
        }
        inflightTexts.removeAll()
        // what others changed meanwhile, now on top of the answer
        let held = deferred.values.sorted { $0.block.rev < $1.block.rev }
        deferred.removeAll()
        for h in held { applyRemoteBlock(h.block, h.splices) }
        save()
        status = hasPending() ? .saving : (note?.can_edit == true ? .saved : .readonly)
        emit()
        if hasPending() { scheduleFlush(Self.flushMS) }
    }

    /// The server refused the batch (400/403/404/409). Never silent: what can be kept is kept, and the person is told.
    private func refused(_ st: Int) async {
        let ops = inflight ?? []
        inflight = nil
        deferred.removeAll()
        inflightTexts.removeAll()
        if st == 403 {
            queue = []
            status = .readonly
            notice = NSLocalizedString("notes.notice.readonly", comment: "")
            await resyncFull()
            return
        }
        if st == 404, !(await stillThere()) {
            status = .deleted
            notice = NSLocalizedString("notes.notice.deleted", comment: "")
            save(clear: true)
            emit()
            return
        }
        if st == 423 {
            // Chat Lock: the chat must be unlocked first; the batch waits as it is
            inflight = ops
            status = .offline
            emit()
            return
        }
        // 409 (history the server no longer keeps) or 404 (a block deleted under me): reload, keep my text, send it again
        var typed: [(String, String)] = []
        for o in ops where o.op == "block.text" || o.op == "block.insert" {
            guard let id = o.id else { continue }
            typed.append((id, blocks[id]?.text ?? o.text ?? ""))
        }
        let typedIds = Set(typed.map(\.0))
        let structural = ops.filter { $0.op != "block.text" }
        let sections = Dictionary(typed.map { ($0.0, blocks[$0.0]?.section ?? "notes") }, uniquingKeysWith: { a, _ in a })
        await resyncFull()
        for (id, text) in typed {
            if var b = blocks[id], !b.deleted {
                b.text = text
                blocks[id] = b
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // the block is gone on the server: its text comes back as a new paragraph rather than being dropped
                if insertBlock(after: "", section: sections[id] ?? "notes", type: "p", text: text) != nil {
                    notice = NSLocalizedString("notes.notice.kept", comment: "")
                }
            }
        }
        if st == 400 {
            // a change the server cannot take (too long, too many items): kept on screen, not sent again in a loop
            notice = NSLocalizedString("notes.notice.toolong", comment: "")
        } else {
            queue = structural.filter { $0.op != "block.insert" || !typedIds.contains($0.id ?? "") } + queue
        }
        save()
        emit()
        if st != 400 { scheduleFlush(Self.flushMS) }
    }

    private func stillThere() async -> Bool {
        do {
            _ = try await d.getNote(note?.rev ?? 0)
            return true
        } catch {
            return (error as? NoteHTTPError)?.status != 404
        }
    }

    private func resyncFull() async {
        if let st = try? await d.getNote(0) {
            blocks.removeAll(); tasks.removeAll(); server.removeAll()
            adopt(st)
        }
        status = note?.can_edit == true ? (hasPending() ? .saving : .saved) : .readonly
        emit()
    }

    // MARK: others' changes

    /// One live frame (the whole {"type","data"} envelope as received).
    func onLive(_ raw: Data) {
        struct Env: Decodable { let type: String?; let data: NoteChange? }
        guard let ev = try? JSONDecoder().decode(Env.self, from: raw), ev.type == "note.change", let ch = ev.data,
              ch.note.id == noteId else { return }
        receive(ch)
    }

    func receive(_ ch: NoteChange) {
        if disposed { return }
        if let c = ch.client, c == client { return } // this device's own change (the answer already applied it)
        if ch.note.deleted == true {
            status = .deleted
            notice = NSLocalizedString("notes.notice.deleted", comment: "")
            save(clear: true)
            emit()
            return
        }
        if let by = ch.by { editors[by] = d.now() }
        if ch.reset == true || ch.note.policy_changed == true {
            Task { await self.resyncAfterReset() }
            return
        }
        if let n = note, ch.note.rev > n.rev {
            var nn = ch.note
            if queue.contains(where: { $0.op == "title" }) { nn.title = n.title }
            note = nn
        }
        for b in ch.blocks ?? [] { applyRemoteBlock(b, (ch.splices ?? []).filter { $0.block_id == b.id }) }
        for t in ch.tasks ?? [] {
            if queue.contains(where: { $0.id == t.id }) { continue } // my own change to it is on its way
            tasks[t.id] = t
        }
        emit()
    }

    private func resyncAfterReset() async {
        let locals = textPendingIds().map { ($0, blocks[$0]!.text) }
        await resyncFull()
        if !locals.isEmpty { notice = NSLocalizedString("notes.notice.restored", comment: "") }
        for (id, text) in locals {
            if var b = blocks[id] { b.text = text; blocks[id] = b }
        }
        emit()
        if hasPending() { scheduleFlush(Self.flushMS) }
    }

    /// A block as the server has it now (from a live change or a delta), with the splices that led there when known.
    private func applyRemoteBlock(_ b: NoteBlock, _ splices: [NoteSplice]) {
        if inflight != nil && inflightTexts[b.id] != nil {
            let old = deferred[b.id]
            deferred[b.id] = (block: old == nil || b.rev > old!.block.rev ? b : old!.block, splices: (old?.splices ?? []) + splices)
            return
        }
        let prev = server[b.id]
        if let prev, b.rev <= prev.rev, !b.deleted { return } // already have this or newer
        let shown = blocks[b.id]
        if b.deleted {
            if let shown, textPendingIds().contains(b.id), !shown.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // deleted while I was writing in it: my text stays, as a new paragraph
                blocks[b.id] = nil
                server[b.id] = nil
                insertBlock(after: "", section: shown.section, type: "p", text: shown.text)
                notice = NSLocalizedString("notes.notice.kept", comment: "")
                return
            }
            var gone = shown ?? b
            gone.deleted = true
            blocks[b.id] = gone
            server[b.id] = nil
            return
        }
        guard let shown, let prev, !NoteRules.same(shown.text, prev.text) else {
            blocks[b.id] = b
            server[b.id] = ServerBlock(rev: b.rev, text: b.text)
            return
        }
        let known = splices.filter { $0.block_rev > prev.rev }.sorted { $0.block_rev < $1.block_rev }
        let continuous = !known.isEmpty && known[0].block_rev == prev.rev + 1 && known.last!.block_rev == b.rev
        let text = continuous
            ? NoteRules.rebaseLocal(prev.text, shown.text, known.map { NoteRules.TextSplice(from: $0.from, to: $0.to, insert: $0.insert) }, b.text)
            : mergeText(prev.text, shown.text, b.text)
        server[b.id] = ServerBlock(rev: b.rev, text: b.text)
        var nb = b
        nb.text = text
        blocks[b.id] = nb
    }

    /// Without the exact splices (a delta after a reconnect): the server's change as one splice, my typing placed over it.
    private func mergeText(_ base: String, _ local: String, _ server: String) -> String {
        guard let theirs = NoteRules.diffSplice(base, server) else { return local }
        return NoteRules.rebaseLocal(base, local, [theirs], server)
    }

    private func mergeRemote(_ id: String, _ base: String, _ local: String) {
        guard var b = blocks[id] else {
            if !local.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { insertBlock(after: "", section: "notes", type: "p", text: local) }
            return
        }
        b.text = mergeText(base, local, b.text)
        blocks[id] = b
    }

    // MARK: kept on the device until accepted

    private func save(clear: Bool = false) {
        guard let st = d.storage else { return }
        if clear || !hasPending() {
            st.remove(key)
            return
        }
        var texts: [String: Saved.Text] = [:]
        for id in textPendingIds() {
            let s = server[id]!
            texts[id] = Saved.Text(baseRev: s.rev, base: s.text, local: blocks[id]!.text)
        }
        if let data = try? JSONEncoder().encode(Saved(queue: queue, inflight: inflight, texts: texts)) { st.set(key, data) }
    }

    private func restoreSaved() {
        guard let st = d.storage, let raw = st.get(key), let saved = try? JSONDecoder().decode(Saved.self, from: raw) else { return }
        // an unanswered batch goes first, unchanged (the server skips any operation it already applied); its texts are what the
        // screen showed when it was sent, so the same typing is never turned into a second edit
        var inflightText = Set<String>()
        if let inf = saved.inflight, !inf.isEmpty {
            inflight = inf
            inflightTexts.removeAll()
            for o in inf {
                guard let id = o.id else { continue }
                if o.op == "block.text" {
                    let base = saved.texts[id]?.base ?? server[id]?.text ?? ""
                    inflightTexts[id] = NoteRules.applySplice(base, o.from ?? 0, o.to ?? 0, o.insert ?? "")
                    inflightText.insert(id)
                } else if o.op == "block.insert" {
                    inflightTexts[id] = o.text ?? ""
                }
            }
        }
        queue.append(contentsOf: saved.queue)
        for o in (saved.inflight ?? []) + queue where o.op == "block.insert" {
            guard let id = o.id, blocks[id] == nil else { continue }
            let last = NoteRules.sortByPos(Array(blocks.values), pos: \.pos, id: \.id, section: { _ in "notes" }).last?.pos ?? ""
            blocks[id] = NoteBlock(id: id, section: o.section ?? "notes", type: o.type ?? "p", pos: NoteRules.posBetween(last, ""),
                                   text: o.text ?? "", updated_by: myId, updated_at: d.now())
            server[id] = ServerBlock(rev: 0, text: o.text ?? "")
        }
        for (id, t) in saved.texts {
            guard var b = blocks[id] else {
                if !t.local.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { insertBlock(after: "", section: "notes", type: "p", text: t.local) }
                continue
            }
            let cur = server[id]
            // my typing, placed on whatever the block has become since (a block with an unanswered edit is settled by its answer)
            b.text = !inflightText.contains(id) && cur != nil && cur!.rev != t.baseRev ? mergeText(t.base, t.local, cur!.text) : t.local
            blocks[id] = b
        }
        if inflight != nil || !queue.isEmpty || !saved.texts.isEmpty { notice = NSLocalizedString("notes.notice.resending", comment: "") }
    }
}

/// Where a note's unsent changes wait (per account and note).
protocol NotePendingStore: AnyObject {
    func get(_ key: String) -> Data?
    func set(_ key: String, _ data: Data)
    func remove(_ key: String)
    func removeAll(prefix: String)
}

/// Unsent note changes on disk: Application Support/NotesPending, protected until the first unlock, never in backups.
/// Sign-out deletes all of it (NoteFileStore.forgetAll).
final class NoteFileStore: NotePendingStore {
    static let shared = NoteFileStore()
    private let dir: URL
    private let lock = NSLock()

    init(dir: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.dir = dir ?? base.appendingPathComponent("NotesPending", isDirectory: true)
    }

    private func url(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" ? String($0) : "_" }.joined()
        return dir.appendingPathComponent(safe + ".json")
    }

    func get(_ key: String) -> Data? { lock.withLock { try? Data(contentsOf: url(key)) } }

    func set(_ key: String, _ data: Data) {
        lock.withLock {
            var d = dir
            if !FileManager.default.fileExists(atPath: d.path) {
                try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                var v = URLResourceValues()
                v.isExcludedFromBackup = true
                try? d.setResourceValues(v)
            }
            try? data.write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func remove(_ key: String) { lock.withLock { try? FileManager.default.removeItem(at: url(key)) } }

    func removeAll(prefix: String) {
        lock.withLock {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Sign-out: no note text of the previous account stays on this device.
    static func forgetAll() { shared.removeAll(prefix: NoteSession.storagePrefix) }
}
