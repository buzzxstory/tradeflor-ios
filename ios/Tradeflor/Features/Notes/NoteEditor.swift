import SwiftUI
import UIKit
import Combine

/// One open note on screen: the sync session (NoteSession) and what the screen shows. Live frames and reconnects feed it.
@MainActor
final class NoteEditorModel: ObservableObject {
    @Published private(set) var view: NoteSession.View
    let session: NoteSession
    private var subs = Set<AnyCancellable>()
    private var started = false
    private var redraw: Task<Void, Never>?

    init(token: String, me: String, noteID: String, initial: NoteState?) {
        let api = APIClient.shared
        let deps = NoteSession.Deps(
            getNote: { since in try await api.getNote(token: token, noteID: noteID, since: since) },
            sendOps: { ops, client in try await api.sendNoteOps(token: token, noteID: noteID, ops: ops, client: client) },
            watch: { await api.watchNote(token: token, noteID: noteID) },
            storage: NoteFileStore.shared)
        session = NoteSession(myId: me, noteId: noteID, deps: deps, initial: initial)
        view = session.view()
        session.onChange = { [weak self] in self?.refresh() }
        LiveConnection.shared.noteFrames.receive(on: RunLoop.main)
            .sink { [weak self] d in self?.session.onLive(d) }.store(in: &subs)
        LiveConnection.shared.opened.receive(on: RunLoop.main)
            .sink { [weak self] in guard let self else { return }; Task { await self.session.resync() } }.store(in: &subs)
    }

    /// The screen is redrawn once per run of the main loop, not once per change (typing stays light during a call).
    private func refresh() {
        guard redraw == nil else { return }
        redraw = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.redraw = nil
            self.view = self.session.view()
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        await session.start()
    }

    func close() {
        let s = session
        subs.removeAll()
        Task { @MainActor in
            await s.flushNow()
            s.dispose()
        }
    }
}

enum NoteText {
    static func isRTL(_ s: String) -> Bool {
        for u in s.unicodeScalars where CharacterSet.letters.contains(u) {
            let v = u.value
            return (0x0590...0x08FF).contains(v) || (0xFB1D...0xFEFC).contains(v)
        }
        return false
    }

    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        for seg in NoteRules.inlineSegments(text) {
            var a = AttributedString(seg.text)
            if seg.b { a.inlinePresentationIntent = .stronglyEmphasized }
            if seg.i { a.inlinePresentationIntent = .emphasized }
            if seg.u { a.underlineStyle = .single }
            if let h = seg.href, let url = URL(string: h) {
                a.link = url
                a.foregroundColor = Theme.accent
                a.underlineStyle = .single
            }
            out += a
        }
        return out
    }

    static func font(_ type: String) -> Font {
        switch type {
        case "h1": return .title2.weight(.bold)
        case "h2": return .title3.weight(.bold)
        case "h3": return .headline
        default: return .body
        }
    }

    static func uiFont(_ type: String) -> UIFont {
        let style: UIFont.TextStyle
        switch type {
        case "h1": style = .title2
        case "h2": style = .title3
        case "h3": style = .headline
        default: style = .body
        }
        let base = UIFont.preferredFont(forTextStyle: style)
        if type == "h1" || type == "h2", let d = base.fontDescriptor.withSymbolicTraits(.traitBold) { return UIFont(descriptor: d, size: 0) }
        if type == "quote", let d = base.fontDescriptor.withSymbolicTraits(.traitItalic) { return UIFont(descriptor: d, size: 0) }
        return base
    }

    static let typeKeys: [(String, String)] = [("p", "notes.type.p"), ("h1", "notes.type.h1"), ("h2", "notes.type.h2"), ("h3", "notes.type.h3"),
                                               ("bullet", "notes.type.bullet"), ("number", "notes.type.number"), ("check", "notes.type.check"),
                                               ("quote", "notes.type.quote")]
    static let sectionKeys: [(String, String)] = [("notes", "notes.sec.notes"), ("decisions", "notes.sec.decisions"), ("followup", "notes.sec.followup")]
}

enum NoteCommand { case type(String), section(String), delete, done }

/// The text of the block being edited: a UITextView (selection for bold/italic/underline, Return splits the block, Backspace
/// at the start joins it to the one above), sized to its text, with the formatting bar over the keyboard.
struct NoteTextView: UIViewRepresentable {
    var text: String
    var type: String
    var meeting: Bool
    /// where the caret goes when it opens (UTF-16), nil = the end
    var caret: Int?
    var onText: (String) -> Void
    var onReturn: (NSRange) -> Void
    var onBackspaceAtStart: () -> Void
    var onCommand: (NoteCommand) -> Void

    final class TV: UITextView {
        var onBackspaceAtStart: (() -> Void)?
        override func deleteBackward() {
            if selectedRange.location == 0 && selectedRange.length == 0 { onBackspaceAtStart?(); return }
            super.deleteBackward()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> TV {
        let tv = TV()
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.textAlignment = .natural
        tv.adjustsFontForContentSizeCategory = true
        tv.font = NoteText.uiFont(type)
        tv.textColor = UIColor(Theme.text)
        tv.tintColor = UIColor(Theme.accent)
        tv.text = text
        tv.delegate = context.coordinator
        let c = context.coordinator
        tv.onBackspaceAtStart = { [weak c] in c?.parent.onBackspaceAtStart() }
        tv.inputAccessoryView = context.coordinator.bar(for: tv)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let at = min(caret ?? (text as NSString).length, (text as NSString).length)
        DispatchQueue.main.async {
            tv.becomeFirstResponder()
            tv.selectedRange = NSRange(location: at, length: 0)
        }
        return tv
    }

    func updateUIView(_ tv: TV, context: Context) {
        context.coordinator.parent = self
        let f = NoteText.uiFont(type)
        if tv.font != f { tv.font = f }
        // someone else's text arrived: the caret stays where I was typing (not while a composition is open)
        if !NoteRules.same(tv.text ?? "", text), tv.markedTextRange == nil {
            let old = tv.text ?? ""
            let caret = NoteRules.moveCaret(old, text, tv.selectedRange.location)
            tv.text = text
            tv.selectedRange = NSRange(location: min(caret, (text as NSString).length), length: 0)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TV, context: Context) -> CGSize? {
        let w = proposal.width ?? UIScreen.main.bounds.width
        let s = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: max(30, s.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoteTextView
        init(_ p: NoteTextView) { parent = p }

        func textViewDidChange(_ tv: UITextView) { parent.onText(tv.text ?? "") }

        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText t: String) -> Bool {
            if t == "\n" {
                parent.onReturn(range)
                return false
            }
            return true
        }

        func bar(for tv: UITextView) -> UIToolbar {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            bar.tintColor = UIColor(Theme.accent)
            func item(_ icon: String, _ label: String, _ act: @escaping () -> Void) -> UIBarButtonItem {
                let b = UIBarButtonItem(image: UIImage(systemName: icon), primaryAction: UIAction { _ in act() })
                b.accessibilityLabel = NSLocalizedString(label, comment: "")
                return b
            }
            let types = UIMenu(children: NoteText.typeKeys.map { k in
                UIAction(title: NSLocalizedString(k.1, comment: "")) { [weak self] _ in self?.parent.onCommand(.type(k.0)) }
            })
            let typeItem = UIBarButtonItem(image: UIImage(systemName: "textformat.size"), menu: types)
            typeItem.accessibilityLabel = NSLocalizedString("notes.type", comment: "")
            var items: [UIBarButtonItem] = [
                typeItem,
                item("bold", "notes.bold") { [weak self, weak tv] in if let tv { self?.wrap(tv, "**") } },
                item("italic", "notes.italic") { [weak self, weak tv] in if let tv { self?.wrap(tv, "*") } },
                item("underline", "notes.underline") { [weak self, weak tv] in if let tv { self?.wrap(tv, "__") } },
            ]
            if parent.meeting {
                let secs = UIMenu(children: NoteText.sectionKeys.map { k in
                    UIAction(title: NSLocalizedString(k.1, comment: "")) { [weak self] _ in self?.parent.onCommand(.section(k.0)) }
                })
                let s = UIBarButtonItem(image: UIImage(systemName: "rectangle.stack"), menu: secs)
                s.accessibilityLabel = NSLocalizedString("notes.move.section", comment: "")
                items.append(s)
            }
            items.append(item("trash", "notes.block.delete") { [weak self] in self?.parent.onCommand(.delete) })
            items.append(UIBarButtonItem(systemItem: .flexibleSpace))
            items.append(UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.parent.onCommand(.done) }))
            bar.items = items
            bar.sizeToFit()
            return bar
        }

        private func wrap(_ tv: UITextView, _ marker: String) {
            let r = tv.selectedRange
            let out = NoteRules.toggleWrap(tv.text ?? "", r.location, r.location + r.length, marker)
            tv.text = out.text
            tv.selectedRange = NSRange(location: out.start, length: out.end - out.start)
            parent.onText(out.text)
        }
    }
}

/// The note editor (IOS-NOTES-003/005/010/011): title, blocks, tasks, status, history. In a call it carries a "Back to call"
/// bar and the meeting overview (IOS-NOTES-006/007).
struct NoteEditorScreen: View {
    let token: String
    let me: String
    let noteID: String
    let people: [NotePerson]
    let isGroup: Bool
    /// in a call: the bar that goes back to it (the call itself is never touched from here)
    var backToCall: (() -> Void)?

    @StateObject private var model: NoteEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var focused: String?
    @State private var caret: Int?
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @State private var newTask = ""
    @State private var showHistory = false
    @State private var showPolicy = false

    init(token: String, me: String, noteID: String, initial: NoteState? = nil, people: [NotePerson], isGroup: Bool,
         backToCall: (() -> Void)? = nil) {
        self.token = token
        self.me = me
        self.noteID = noteID
        self.people = people
        self.isGroup = isGroup
        self.backToCall = backToCall
        _model = StateObject(wrappedValue: NoteEditorModel(token: token, me: me, noteID: noteID, initial: initial))
    }

    private var v: NoteSession.View { model.view }
    private var canEdit: Bool { v.note?.can_edit == true && v.status != .deleted }
    private var isMeeting: Bool { v.note?.isMeeting == true }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let backToCall {
                    Button(action: backToCall) {
                        Label("notes.backtocall", systemImage: "phone.fill").font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Theme.hex(0x0A8FA0)).foregroundStyle(.white)
                    }
                    .accessibilityLabel(Text("notes.backtocall"))
                }
                statusLine
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            titleField
                            if isMeeting, let n = v.note { MeetingOverview(note: n, people: people) }
                            sections
                            tasksSection
                        }
                        .padding(.horizontal, 16).padding(.bottom, 40)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: focused) { id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            .background(Theme.soul.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close() } label: { Image(systemName: backToCall == nil ? "chevron.backward" : "chevron.down").frame(width: 44, height: 44) }
                        .accessibilityLabel(Text("notes.close"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showHistory = true } label: { Label("notes.history", systemImage: "clock.arrow.circlepath") }
                        if isGroup && v.note?.can_manage == true {
                            Button { showPolicy = true } label: { Label("notes.policy", systemImage: "person.2.badge.gearshape") }
                        }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                        .accessibilityLabel(Text("notes.more"))
                }
            }
            .toolbarBackground(Theme.soul, for: .navigationBar)
        }
        .tint(Theme.accent)
        .task { await model.start() }
        .onAppear { title = v.note?.title ?? "" }
        .onChange(of: v.note?.title ?? "") { t in if !titleFocused && t != title { title = t } }
        .onDisappear { model.close() }
        .sheet(isPresented: $showHistory) {
            NoteHistorySheet(token: token, noteID: noteID, canRestore: canEdit, people: people, me: me) {
                Task { await model.session.resync() }
            }
        }
        .sheet(isPresented: $showPolicy) {
            if let n = v.note {
                NotePolicySheet(token: token, note: n, people: people, isAdmin: true) { _ in Task { await model.session.resync() } }
            }
        }
    }

    private func close() {
        if let backToCall { backToCall() } else { dismiss() }
    }

    @ViewBuilder private var statusLine: some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey("notes.status." + v.status.rawValue)).foregroundStyle(v.status == .offline ? Theme.gold : Theme.faint)
            if !v.activeEditors.isEmpty {
                Text(verbatim: "· " + String(format: NSLocalizedString("notes.editing", comment: ""),
                                             v.activeEditors.map { id in people.first { $0.id == id }?.name ?? "" }.filter { !$0.isEmpty }.joined(separator: ", ")))
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        if let n = v.notice {
            Button { model.session.clearNotice() } label: {
                Text(verbatim: n).font(.footnote).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Theme.active, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 16)
            .onAppear { UIAccessibility.post(notification: .announcement, argument: n) }
        }
    }

    private var titleField: some View {
        TextField(NSLocalizedString(isMeeting ? "notes.meeting.untitled" : "notes.title.placeholder", comment: ""), text: $title, axis: .vertical)
            .font(.title.weight(.bold))
            .foregroundStyle(Theme.text)
            .focused($titleFocused)
            .disabled(!canEdit)
            .multilineTextAlignment(NoteText.isRTL(title) ? .trailing : .leading)
            .onChange(of: title) { t in
                let cut = String(t.unicodeScalars.prefix(200).map(Character.init))
                if titleFocused, cut != v.note?.title { model.session.setTitle(cut) }
            }
            .padding(.vertical, 12)
            .accessibilityLabel(Text("notes.title.label"))
    }

    // MARK: blocks

    private var shownSections: [(String, String)] {
        if isMeeting { return NoteText.sectionKeys }
        return NoteText.sectionKeys.filter { s in s.0 == "notes" || v.blocks.contains { $0.section == s.0 } }
    }

    @ViewBuilder private var sections: some View {
        ForEach(shownSections, id: \.0) { sec in
            let list = v.blocks.filter { $0.section == sec.0 }
            if isMeeting || sec.0 != "notes" {
                Text(LocalizedStringKey(sec.1)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
                    .padding(.top, 14).accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, b in
                blockRow(b, number: numberFor(list, i)).id(b.id)
            }
            if canEdit {
                Button {
                    if let id = model.session.insertBlock(after: list.last?.id ?? "", section: sec.0, type: "p") { caret = 0; focused = id }
                } label: {
                    Label("notes.add.text", systemImage: "plus").font(.subheadline).foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityLabel(Text(LocalizedStringKey(sec.0 == "notes" ? "notes.add.text" : "notes.add.to." + sec.0)))
            } else if list.isEmpty && !isMeeting {
                Text("notes.empty.note").font(.callout).foregroundStyle(Theme.faint).padding(.vertical, 8)
            }
        }
    }

    private func numberFor(_ list: [NoteBlock], _ i: Int) -> Int {
        var n = 1
        var k = i - 1
        while k >= 0 && list[k].type == "number" { n += 1; k -= 1 }
        return n
    }

    @ViewBuilder private func blockRow(_ b: NoteBlock, number: Int) -> some View {
        let rtl = NoteText.isRTL(b.text)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch b.type {
            case "bullet": Text(verbatim: "•").font(.body.weight(.bold)).foregroundStyle(Theme.accent).accessibilityHidden(true)
            case "number": Text(verbatim: "\(number).").font(.body.monospacedDigit()).foregroundStyle(Theme.accent).accessibilityHidden(true)
            case "check":
                Button { model.session.setBlock(b.id, checked: !b.checked) } label: {
                    Image(systemName: b.checked ? "checkmark.square.fill" : "square").font(.title3)
                        .foregroundStyle(b.checked ? Theme.accent : Theme.faint).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
                .accessibilityLabel(Text(b.checked ? "notes.checked" : "notes.unchecked"))
                .padding(.vertical, -10)
            case "quote": Rectangle().fill(Theme.accent).frame(width: 3).accessibilityHidden(true)
            default: EmptyView()
            }
            if canEdit && focused == b.id {
                NoteTextView(text: b.text, type: b.type, meeting: isMeeting, caret: caret,
                             onText: { model.session.setBlockText(b.id, $0) },
                             onReturn: { split(b.id, $0) },
                             onBackspaceAtStart: { joinUp(b.id) },
                             onCommand: { command($0, b.id) })
                    .accessibilityLabel(Text("notes.block.label"))
            } else {
                Group {
                    if b.text.isEmpty {
                        Text("notes.placeholder").foregroundStyle(Theme.faint)
                    } else {
                        Text(NoteText.attributed(b.text))
                            .strikethrough(b.checked && b.type == "check")
                            .italic(b.type == "quote")
                            .foregroundColor(b.type == "quote" ? Theme.muted : (b.checked && b.type == "check" ? Theme.faint : Theme.text))
                    }
                }
                .font(NoteText.font(b.type))
                .multilineTextAlignment(rtl ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { if canEdit { caret = nil; focused = b.id } }
                .accessibilityAddTraits(canEdit ? .isButton : [])
                .accessibilityHint(canEdit ? Text("notes.tap.edit") : Text(""))
            }
        }
        .frame(minHeight: 30)
        .contextMenu {
            if canEdit {
                Button(role: .destructive) { model.session.deleteBlock(b.id) } label: { Label("notes.block.delete", systemImage: "trash") }
            }
            Button { UIPasteboard.general.string = b.text } label: { Label("notes.copy", systemImage: "doc.on.doc") }
        }
    }

    private static let listTypes: Set<String> = ["bullet", "number", "check"]

    private func split(_ id: String, _ range: NSRange) {
        guard let b = model.session.block(id) else { return }
        let ns = b.text as NSString
        let loc = min(range.location, ns.length)
        let before = ns.substring(to: loc)
        let after = ns.substring(from: min(ns.length, loc + range.length))
        if before.isEmpty && after.isEmpty && (Self.listTypes.contains(b.type) || b.type == "quote") {
            model.session.setBlock(id, type: "p") // Return on an empty list item ends the list
            return
        }
        model.session.setBlockText(id, before)
        let t = Self.listTypes.contains(b.type) ? b.type : "p"
        if let n = model.session.insertBlock(after: id, section: b.section, type: t, text: after) {
            caret = 0
            focused = n
        }
    }

    private func joinUp(_ id: String) {
        guard let b = model.session.block(id) else { return }
        if b.type != "p" { model.session.setBlock(id, type: "p"); return }
        let list = model.view.blocks.filter { $0.section == b.section }
        guard let i = list.firstIndex(where: { $0.id == id }), i > 0, let prev = model.session.block(list[i - 1].id) else { return }
        let len = (prev.text as NSString).length
        model.session.setBlockText(prev.id, prev.text + b.text)
        model.session.deleteBlock(id)
        caret = len
        focused = prev.id
    }

    private func command(_ c: NoteCommand, _ id: String) {
        switch c {
        case .type(let t): model.session.setBlock(id, type: t)
        case .section(let s):
            model.session.setBlock(id, section: s)
        case .delete:
            let list = model.view.blocks
            let i = list.firstIndex { $0.id == id }
            model.session.deleteBlock(id)
            if let i, i > 0 { caret = nil; focused = list[i - 1].id } else { focused = nil }
        case .done:
            focused = nil
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    // MARK: tasks

    @ViewBuilder private var tasksSection: some View {
        if isMeeting || !v.tasks.isEmpty || canEdit {
            HStack {
                Text("notes.tasks").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent).accessibilityAddTraits(.isHeader)
                Spacer()
                let done = v.tasks.filter(\.done).count
                if !v.tasks.isEmpty {
                    Text(verbatim: String(format: NSLocalizedString("notes.progress", comment: ""), done, v.tasks.count))
                        .font(.caption).foregroundStyle(Theme.faint)
                }
            }
            .padding(.top, 18)
            ForEach(v.tasks) { t in
                NoteTaskRow(task: t, me: me, people: people, canEdit: canEdit, session: model.session)
            }
            if canEdit {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle").foregroundStyle(Theme.faint)
                    TextField(NSLocalizedString("notes.task.add", comment: ""), text: $newTask)
                        .submitLabel(.done)
                        .onSubmit {
                            let t = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            model.session.upsertTask(nil, .init(title: String(t.unicodeScalars.prefix(500).map(Character.init))))
                            newTask = ""
                        }
                }
                .frame(minHeight: 44)
            }
        }
    }
}

/// One task: tick, title, who it is for, when it is due (late in red), who did it.
struct NoteTaskRow: View {
    let task: NoteTask
    let me: String
    let people: [NotePerson]
    let canEdit: Bool
    let session: NoteSession
    @State private var title = ""
    @State private var showDue = false
    @State private var due = Date()
    @FocusState private var editing: Bool

    private func name(_ id: String?) -> String? {
        guard let id else { return nil }
        if id == me { return NSLocalizedString("chat.you", comment: "") }
        return people.first { $0.id == id }?.name
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { session.upsertTask(task.id, .init(done: !task.done)) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(task.done ? Theme.accent : Theme.faint).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!(canEdit || task.assignee_id == me))
            .accessibilityLabel(Text(task.done ? "notes.task.done" : "notes.task.open"))
            VStack(alignment: .leading, spacing: 3) {
                if canEdit {
                    TextField("", text: $title, axis: .vertical)
                        .focused($editing)
                        .strikethrough(task.done)
                        .foregroundStyle(task.done ? Theme.faint : Theme.text)
                        .onSubmit(commit)
                        .onChange(of: editing) { on in if !on { commit() } }
                        .accessibilityLabel(Text("notes.task.title"))
                } else {
                    Text(verbatim: task.title).strikethrough(task.done).foregroundStyle(task.done ? Theme.faint : Theme.text)
                }
                HStack(spacing: 8) {
                    if canEdit {
                        Menu {
                            Button("notes.task.nobody") { session.upsertTask(task.id, .init(assignee: "")) }
                            ForEach(people) { p in Button(p.id == me ? NSLocalizedString("chat.you", comment: "") : p.name) { session.upsertTask(task.id, .init(assignee: p.id)) } }
                        } label: { assigneeLabel }
                        Button { due = task.due_at.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date(); showDue = true } label: { dueLabel }
                    } else {
                        assigneeLabel
                        dueLabel
                    }
                    if task.done, let by = name(task.done_by) {
                        Text(verbatim: String(format: NSLocalizedString("notes.task.doneby", comment: ""), by)).foregroundStyle(Theme.faint)
                    }
                }
                .font(.caption)
            }
        }
        .onAppear { title = task.title }
        .onChange(of: task.title) { t in if !editing { title = t } }
        .contextMenu {
            if canEdit {
                Button(role: .destructive) { session.deleteTask(task.id) } label: { Label("notes.task.delete", systemImage: "trash") }
            }
        }
        .sheet(isPresented: $showDue) {
            NavigationStack {
                DatePicker("notes.task.due", selection: $due).datePickerStyle(.graphical).padding()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("notes.task.nodue") { session.upsertTask(task.id, .init(due: 0)); showDue = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("notes.save") { session.upsertTask(task.id, .init(due: Int64(due.timeIntervalSince1970 * 1000))); showDue = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var assigneeLabel: some View {
        Label(name(task.assignee_id) ?? NSLocalizedString("notes.task.nobody", comment: ""), systemImage: "person")
            .foregroundStyle(Theme.muted)
            .frame(minHeight: 30)
    }

    @ViewBuilder private var dueLabel: some View {
        if let d = task.due_at {
            Label { Text(Date(timeIntervalSince1970: Double(d) / 1000), style: .date) } icon: { Image(systemName: "calendar") }
                .foregroundStyle(task.isLate ? Theme.danger : Theme.muted)
                .frame(minHeight: 30)
        } else if canEdit {
            Label("notes.task.setdue", systemImage: "calendar").foregroundStyle(Theme.faint).frame(minHeight: 30)
        }
    }

    private func commit() {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(500).map(Character.init))
        if !t.isEmpty && t != task.title { session.upsertTask(task.id, .init(title: t)) }
    }
}

/// The meeting's date, live length, who is in it and who can read it.
struct MeetingOverview: View {
    let note: SharedNote
    let people: [NotePerson]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label { Text(Date(timeIntervalSince1970: Double(note.meeting?.started_at ?? note.created_at) / 1000), style: .date) }
                    icon: { Image(systemName: note.meeting?.video == true ? "video" : "phone") }
                if note.meeting?.status == "open", let s = note.meeting?.started_at, s > 0 {
                    CallClock(since: Date(timeIntervalSince1970: Double(s) / 1000))
                } else if let d = note.meeting?.duration_ms, d > 0 {
                    Text(verbatim: NoteRules.meetingDuration(d))
                }
            }
            if !people.isEmpty {
                Label(people.map(\.name).joined(separator: ", "), systemImage: "person.2")
            }
            Label("notes.meeting.private", systemImage: "lock")
        }
        .font(.caption)
        .foregroundStyle(Theme.muted)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soulCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Version history (IOS-NOTES-010): the saved versions, a read-only preview, and Restore for editors.
struct NoteHistorySheet: View {
    let token: String
    let noteID: String
    let canRestore: Bool
    let people: [NotePerson]
    let me: String
    let onRestored: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var revisions: [NoteRevision] = []
    @State private var loading = true
    @State private var preview: NoteRevision?

    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView() }
                ForEach(revisions) { r in
                    Button { Task { preview = try? await APIClient.shared.noteRevision(token: token, noteID: noteID, revID: r.id) } } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Date(timeIntervalSince1970: Double(r.created_at ?? 0) / 1000), style: .date)
                                + Text(verbatim: " ") + Text(Date(timeIntervalSince1970: Double(r.created_at ?? 0) / 1000), style: .time)
                            Text(verbatim: (r.authors ?? []).map { a in a == me ? NSLocalizedString("chat.you", comment: "") : (people.first { $0.id == a }?.name ?? "") }
                                .filter { !$0.isEmpty }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(Theme.faint)
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            .navigationTitle(Text("notes.history"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("notes.close") { dismiss() } } }
        }
        .task {
            revisions = (try? await APIClient.shared.noteRevisions(token: token, noteID: noteID)) ?? []
            loading = false
        }
        .sheet(item: $preview) { r in
            NoteRevisionPreview(token: token, noteID: noteID, revision: r, canRestore: canRestore) {
                onRestored()
                preview = nil
                dismiss()
            }
        }
    }
}

struct NoteRevisionPreview: View {
    let token: String
    let noteID: String
    let revision: NoteRevision
    let canRestore: Bool
    let onRestored: () -> Void
    @State private var confirm = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: revision.snapshot?.title ?? "").font(.title2.weight(.bold))
                    ForEach(NoteRules.sortByPos(revision.snapshot?.blocks ?? [], pos: \.pos, id: \.id, section: \.section).filter { !$0.deleted }) { b in
                        Text(NoteText.attributed((b.type == "bullet" ? "• " : b.type == "check" ? (b.checked ? "☑ " : "☐ ") : "") + b.text))
                            .font(NoteText.font(b.type))
                            .frame(maxWidth: .infinity, alignment: NoteText.isRTL(b.text) ? .trailing : .leading)
                    }
                    ForEach((revision.snapshot?.tasks ?? []).filter { !$0.deleted }) { t in
                        Label(t.title, systemImage: t.done ? "checkmark.circle.fill" : "circle")
                    }
                    if failed { Text("notes.error").foregroundStyle(Theme.danger) }
                }
                .padding(16)
            }
            .navigationTitle(Text("notes.version"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canRestore {
                    ToolbarItem(placement: .confirmationAction) { Button("notes.restore") { confirm = true } }
                }
            }
            .confirmationDialog(Text("notes.restore.q"), isPresented: $confirm, titleVisibility: .visible) {
                Button("notes.restore") {
                    Task {
                        do {
                            try await APIClient.shared.restoreNoteRevision(token: token, noteID: noteID, revID: revision.id)
                            onRestored()
                        } catch { failed = true }
                    }
                }
            } message: { Text("notes.restore.msg") }
        }
    }
}
