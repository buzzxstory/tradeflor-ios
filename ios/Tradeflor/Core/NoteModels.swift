import Foundation

// Shared Notes and the Meeting Notebook (2026-11-21): the server's data shapes (docs/notes/SHARED_NOTES_PROTOCOL.md, web
// desktop/src/shared/api/notes.ts). Every decoder is lenient: unknown fields are ignored, missing ones get defaults, an unknown
// block type reads as a paragraph and an unknown section as "notes".

extension KeyedDecodingContainer {
    fileprivate func v<T: Decodable>(_ k: K, _ d: T) -> T { ((try? decodeIfPresent(T.self, forKey: k)) ?? nil) ?? d }
    fileprivate func o<T: Decodable>(_ k: K) -> T? { (try? decodeIfPresent(T.self, forKey: k)) ?? nil }
}

struct NoteMeeting: Codable, Equatable {
    var call_id: String = ""
    var started_at: Int64?
    var ended_at: Int64?
    var duration_ms: Int64?
    var video: Bool?
    var status: String = ""
    var message_id: String?

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        call_id = c.v(.call_id, ""); started_at = c.o(.started_at); ended_at = c.o(.ended_at); duration_ms = c.o(.duration_ms)
        video = c.o(.video); status = c.v(.status, ""); message_id = c.o(.message_id)
    }
}

struct SharedNote: Codable, Equatable, Identifiable {
    var id: String = ""
    var conversation_id: String = ""
    var kind: String = "note"
    var title: String = ""
    var edit_policy: String = "everyone"
    var editors: [String]?
    var creator_id: String = ""
    var created_at: Int64 = 0
    var updated_at: Int64 = 0
    var updated_by: String?
    var rev: Int = 0
    var pinned_at: Int64?
    var meeting: NoteMeeting?
    var preview: String?
    var blocks: Int = 0
    var tasks: Int = 0
    var tasks_done: Int = 0
    var checks: Int = 0
    var checks_done: Int = 0
    var can_edit: Bool = false
    var can_manage: Bool = false
    var unavailable: Bool?
    /// only in a live note.change
    var deleted: Bool?
    var policy_changed: Bool?

    init(id: String = "", conversation_id: String = "", title: String = "", rev: Int = 0, can_edit: Bool = true, can_manage: Bool = true) {
        self.id = id; self.conversation_id = conversation_id; self.title = title; self.rev = rev
        self.can_edit = can_edit; self.can_manage = can_manage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, ""); conversation_id = c.v(.conversation_id, ""); kind = c.v(.kind, "note"); title = c.v(.title, "")
        edit_policy = c.v(.edit_policy, "everyone"); editors = c.o(.editors); creator_id = c.v(.creator_id, "")
        created_at = c.v(.created_at, 0); updated_at = c.v(.updated_at, 0); updated_by = c.o(.updated_by); rev = c.v(.rev, 0)
        pinned_at = c.o(.pinned_at); meeting = c.o(.meeting); preview = c.o(.preview); blocks = c.v(.blocks, 0)
        tasks = c.v(.tasks, 0); tasks_done = c.v(.tasks_done, 0); checks = c.v(.checks, 0); checks_done = c.v(.checks_done, 0)
        can_edit = c.v(.can_edit, false); can_manage = c.v(.can_manage, false); unavailable = c.o(.unavailable)
        deleted = c.o(.deleted); policy_changed = c.o(.policy_changed)
    }

    var isMeeting: Bool { kind == "meeting" }
    var isPinned: Bool { (pinned_at ?? 0) > 0 }
}

struct NoteBlock: Codable, Equatable, Identifiable {
    static let types = ["p", "h1", "h2", "h3", "bullet", "number", "check", "quote"]

    var id: String
    var section: String = "notes"
    var type: String = "p"
    var pos: String = ""
    var text: String = ""
    var checked: Bool = false
    var rev: Int = 0
    var note_rev: Int = 0
    var updated_by: String = ""
    var updated_at: Int64 = 0
    var deleted: Bool = false

    init(id: String, section: String = "notes", type: String = "p", pos: String = "V", text: String = "", checked: Bool = false,
         rev: Int = 0, note_rev: Int = 0, updated_by: String = "", updated_at: Int64 = 0, deleted: Bool = false) {
        self.id = id; self.section = section; self.type = type; self.pos = pos; self.text = text; self.checked = checked
        self.rev = rev; self.note_rev = note_rev; self.updated_by = updated_by; self.updated_at = updated_at; self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let s: String = c.v(.section, "notes")
        section = NoteRules.sectionOrder.contains(s) ? s : "notes"
        let t: String = c.v(.type, "p")
        type = Self.types.contains(t) ? t : "p"
        pos = c.v(.pos, ""); text = c.v(.text, ""); checked = c.v(.checked, false); rev = c.v(.rev, 0)
        note_rev = c.v(.note_rev, 0); updated_by = c.v(.updated_by, ""); updated_at = c.v(.updated_at, 0); deleted = c.v(.deleted, false)
    }
}

struct NoteTask: Codable, Equatable, Identifiable {
    var id: String
    var pos: String = ""
    var title: String = ""
    var descr: String?
    var assignee_id: String?
    var due_at: Int64?
    var done: Bool = false
    var done_by: String?
    var done_at: Int64?
    var created_by: String = ""
    var created_at: Int64 = 0
    var updated_by: String = ""
    var updated_at: Int64 = 0
    var note_rev: Int = 0
    var deleted: Bool = false

    init(id: String, pos: String = "", title: String = "") { self.id = id; self.pos = pos; self.title = title }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pos = c.v(.pos, ""); title = c.v(.title, ""); descr = c.o(.descr); assignee_id = c.o(.assignee_id); due_at = c.o(.due_at)
        done = c.v(.done, false); done_by = c.o(.done_by); done_at = c.o(.done_at); created_by = c.v(.created_by, "")
        created_at = c.v(.created_at, 0); updated_by = c.v(.updated_by, ""); updated_at = c.v(.updated_at, 0)
        note_rev = c.v(.note_rev, 0); deleted = c.v(.deleted, false)
    }

    var isLate: Bool { !done && (due_at ?? 0) > 0 && (due_at ?? 0) < Int64(Date().timeIntervalSince1970 * 1000) }
}

struct NoteState: Decodable {
    var note: SharedNote
    var blocks: [NoteBlock] = []
    var tasks: [NoteTask] = []
    var full: Bool = true
    var since: Int?

    init(note: SharedNote, blocks: [NoteBlock], tasks: [NoteTask], full: Bool = true) {
        self.note = note; self.blocks = blocks; self.tasks = tasks; self.full = full
    }

    enum CodingKeys: String, CodingKey { case note, blocks, tasks, full, since }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        note = try c.decode(SharedNote.self, forKey: .note)
        blocks = ((c.o(.blocks) as [LenientItem<NoteBlock>]?) ?? []).compactMap(\.value)
        tasks = ((c.o(.tasks) as [LenientItem<NoteTask>]?) ?? []).compactMap(\.value)
        full = c.v(.full, true); since = c.o(.since)
    }
}

struct NoteSplice: Codable, Equatable {
    var block_id: String
    var block_rev: Int
    var from: Int
    var to: Int
    var insert: String
}

/// One edit (see NoteOp in the protocol for which fields each op uses). Nil fields are left out of the JSON.
struct NoteOp: Codable, Equatable {
    var op_id: String
    var op: String
    var id: String?
    var after: String?
    var section: String?
    var type: String?
    var text: String?
    var base_rev: Int?
    var from: Int?
    var to: Int?
    var insert: String?
    var checked: Bool?
    var title: String?
    var descr: String?
    var assignee: String?
    var due: Int64?
    var done: Bool?

    init(op_id: String = NoteRules.newItemID("op"), op: String, id: String? = nil) {
        self.op_id = op_id; self.op = op; self.id = id
    }
}

struct NoteOpResult: Decodable {
    var op_id: String
    var status: String
    var rev: Int?
    var block: NoteBlock?
    var task: NoteTask?

    init(op_id: String, status: String, rev: Int? = nil, block: NoteBlock? = nil, task: NoteTask? = nil) {
        self.op_id = op_id; self.status = status; self.rev = rev; self.block = block; self.task = task
    }
}

struct NoteOpsAnswer: Decodable {
    var note: SharedNote
    var results: [NoteOpResult]
}

/// The live "note.change" event's data.
struct NoteChange: Decodable {
    var note: SharedNote
    var by: String?
    var blocks: [NoteBlock]?
    var tasks: [NoteTask]?
    var splices: [NoteSplice]?
    var reset: Bool?
    var client: String?
}

struct NoteRevision: Decodable, Identifiable {
    struct Snapshot: Decodable {
        var title: String?
        var blocks: [NoteBlock]?
        var tasks: [NoteTask]?
    }
    var id: String
    var note_rev: Int?
    var created_at: Int64?
    var authors: [String]?
    var reason: String?
    var snapshot: Snapshot?
}

/// The chat card of a published meeting notebook (message kind "meeting_notes", payload in message.signal).
struct MeetingNotesCard: Decodable, Equatable {
    var note_id: String
    var call_id: String = ""
    var title: String?
    var duration_ms: Int64 = 0
    var video: Bool?
    var items: Int = 0
    var tasks: Int = 0
    var tasks_done: Int = 0
    var decisions: Int = 0
    var edited_at: Int64 = 0
    var contributors: Int = 0

    enum CodingKeys: String, CodingKey { case note_id, call_id, title, duration_ms, video, items, tasks, tasks_done, decisions, edited_at, contributors }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        note_id = try c.decode(String.self, forKey: .note_id)
        call_id = c.v(.call_id, ""); title = c.o(.title); duration_ms = c.v(.duration_ms, 0); video = c.o(.video)
        items = c.v(.items, 0); tasks = c.v(.tasks, 0); tasks_done = c.v(.tasks_done, 0); decisions = c.v(.decisions, 0)
        edited_at = c.v(.edited_at, 0); contributors = c.v(.contributors, 0)
    }

    /// The card payload of a meeting_notes message, or nil.
    static func parse(_ signal: String?) -> MeetingNotesCard? {
        guard let s = signal, !s.isEmpty, let card = try? JSONDecoder().decode(MeetingNotesCard.self, from: Data(s.utf8)),
              !card.note_id.isEmpty else { return nil }
        return card
    }
}

/// An HTTP answer the notes code acts on (status 0 = no answer: offline, timeout).
struct NoteHTTPError: Error, Equatable { let status: Int }

extension APIClient {
    private func notesCall(_ path: String, method: String, token: String, body: [String: Any]? = nil) async throws -> Data {
        let req = request(path, method: method, token: token, body: body, rawQuery: path.contains("?"))
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await send(req) } catch { throw NoteHTTPError(status: 0) }
        guard (200..<300).contains(http.statusCode) else { throw NoteHTTPError(status: http.statusCode) }
        return data
    }

    private func notesDecode<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: d) } catch { throw NoteHTTPError(status: 502) }
    }

    private static func seg(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? s }

    func notesEnabled(token: String) async -> Bool {
        struct C: Decodable { let enabled: Bool? }
        guard let d = try? await notesCall("notes/config", method: "GET", token: token) else { return false }
        return (try? JSONDecoder().decode(C.self, from: d))?.enabled ?? false
    }

    func listNotes(token: String, conversationID: String, filter: String = "", q: String = "") async throws -> [SharedNote] {
        var parts: [String] = []
        if !filter.isEmpty { parts.append("filter=\(Self.seg(filter))") }
        if !q.isEmpty { parts.append("q=\(Self.seg(q))") }
        let path = "conversations/\(Self.seg(conversationID))/notes" + (parts.isEmpty ? "" : "?" + parts.joined(separator: "&"))
        struct L: Decodable { let notes: [LenientItem<SharedNote>]? }
        return (try notesDecode(L.self, try await notesCall(path, method: "GET", token: token)).notes ?? []).compactMap(\.value)
    }

    func createNote(token: String, conversationID: String, title: String, editPolicy: String = "") async throws -> NoteState {
        try notesDecode(NoteState.self, try await notesCall("conversations/\(Self.seg(conversationID))/notes", method: "POST", token: token,
                                                            body: ["title": title, "edit_policy": editPolicy]))
    }

    func getNote(token: String, noteID: String, since: Int = 0) async throws -> NoteState {
        try notesDecode(NoteState.self, try await notesCall("notes/\(Self.seg(noteID))?since=\(since)", method: "GET", token: token))
    }

    func sendNoteOps(token: String, noteID: String, ops: [NoteOp], client: String) async throws -> NoteOpsAnswer {
        let raw = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(ops))) as? [[String: Any]] ?? []
        return try notesDecode(NoteOpsAnswer.self, try await notesCall("notes/\(Self.seg(noteID))/ops", method: "POST", token: token,
                                                                       body: ["ops": raw, "client": client]))
    }

    func watchNote(token: String, noteID: String) async {
        _ = try? await notesCall("notes/\(Self.seg(noteID))/watch", method: "POST", token: token)
    }

    func deleteNote(token: String, noteID: String) async throws {
        _ = try await notesCall("notes/\(Self.seg(noteID))", method: "DELETE", token: token)
    }

    func pinNote(token: String, noteID: String, pinned: Bool) async throws -> SharedNote {
        try notesDecode(SharedNote.self, try await notesCall("notes/\(Self.seg(noteID))/pin", method: "POST", token: token, body: ["pinned": pinned]))
    }

    func setNotePolicy(token: String, noteID: String, policy: String, editors: [String]) async throws -> SharedNote {
        try notesDecode(SharedNote.self, try await notesCall("notes/\(Self.seg(noteID))/policy", method: "POST", token: token,
                                                             body: ["edit_policy": policy, "editors": editors]))
    }

    func noteRevisions(token: String, noteID: String) async throws -> [NoteRevision] {
        struct R: Decodable { let revisions: [LenientItem<NoteRevision>]? }
        return (try notesDecode(R.self, try await notesCall("notes/\(Self.seg(noteID))/revisions", method: "GET", token: token)).revisions ?? []).compactMap(\.value)
    }

    func noteRevision(token: String, noteID: String, revID: String) async throws -> NoteRevision {
        try notesDecode(NoteRevision.self, try await notesCall("notes/\(Self.seg(noteID))/revisions/\(Self.seg(revID))", method: "GET", token: token))
    }

    func restoreNoteRevision(token: String, noteID: String, revID: String) async throws {
        _ = try await notesCall("notes/\(Self.seg(noteID))/revisions/\(Self.seg(revID))/restore", method: "POST", token: token)
    }

    func openCallNotebook(token: String, callID: String) async throws -> NoteState {
        try notesDecode(NoteState.self, try await notesCall("calls/\(Self.seg(callID))/notebook", method: "POST", token: token))
    }
}
