import SwiftUI
import UIKit

// MARK: polls (styles/48-polls.css, groups/PollCard.tsx)

struct PollCard: View {
    let message: Message
    let me: String
    let canVote: Bool
    let onVote: ([Int]) -> Void

    private var def: (q: String, o: [String], multiple: Bool)? {
        guard let s = message.signal, let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let opts = o["o"] as? [String] else { return nil }
        return ((o["q"] as? String) ?? "", opts, (o["multiple"] as? Bool) ?? false)
    }
    private var votes: [String: [String]] {
        guard let r = message.reactions, let d = r.data(using: .utf8),
              let m = try? JSONDecoder().decode([String: [String]].self, from: d) else { return [:] }
        return m
    }

    var body: some View {
        if let p = def {
            let counts = p.o.indices.map { (votes[String($0)] ?? []).count }
            let mine = p.o.indices.filter { (votes[String($0)] ?? []).contains(me) }
            let total = counts.reduce(0, +)
            let voters = Set(votes.values.flatMap { $0 }).count
            let showResults = !mine.isEmpty || !canVote
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("poll.chip", systemImage: "chart.bar").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.accent.opacity(0.12), in: Capsule())
                    Spacer()
                    Text(LocalizedStringKey(p.multiple ? "poll.multiple" : "poll.single")).font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
                Text(p.q).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(p.o.enumerated()), id: \.offset) { i, option in
                    Button {
                        guard canVote else { return }
                        var next: [Int]
                        if p.multiple { next = mine.contains(i) ? mine.filter { $0 != i } : mine + [i] } else { next = mine.contains(i) ? [] : [i] }
                        onVote(next)
                    } label: {
                        ZStack(alignment: .leading) {
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(showResults ? 0.22 : 0))
                                    .frame(width: showResults && total > 0 ? g.size.width * CGFloat(counts[i]) / CGFloat(total) : 0)
                            }
                            HStack(spacing: 8) {
                                Text(String(Array("ABCDEFGHIJ")[min(i, 9)])).font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(mine.contains(i) ? Theme.onAccent : Theme.accent)
                                    .frame(width: 22, height: 22).background(mine.contains(i) ? Theme.accent : Theme.accent.opacity(0.12), in: Circle())
                                Text(option).font(.system(size: 14)).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                                Spacer()
                                if showResults && total > 0 {
                                    Text("\(Int((Double(counts[i]) / Double(total) * 100).rounded()))%").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                        }
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(mine.contains(i) ? Theme.borderActive : Theme.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Text(voters == 1 ? NSLocalizedString("poll.voted.one", comment: "") : String(format: NSLocalizedString("poll.voted", comment: ""), voters))
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
                Text(LocalizedStringKey(!canVote ? "poll.hint.off" : (mine.isEmpty ? (p.multiple ? "poll.hint.multi" : "poll.hint.tap") : "poll.hint.undo")))
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            .padding(12)
            .frame(maxWidth: 300)
            .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.borderStrong, lineWidth: 1))
        }
    }
}

struct PollComposer: View {
    let onSend: (String, [String], Bool) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var multiple = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("poll.question")) {
                    TextField("poll.question.ph", text: $question, axis: .vertical)
                }
                .listRowBackground(Theme.surface)
                Section(header: Text("poll.options")) {
                    ForEach(options.indices, id: \.self) { i in
                        HStack {
                            TextField(String(format: NSLocalizedString("poll.option.n", comment: ""), i + 1), text: $options[i])
                            if options.count > 2 {
                                Button { options.remove(at: i) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(Theme.danger) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if options.count < 10 {
                        Button { options.append("") } label: { Label("poll.add", systemImage: "plus") }
                    }
                }
                .listRowBackground(Theme.surface)
                Section { Toggle("poll.allow.multi", isOn: $multiple).tint(Theme.accent) }.listRowBackground(Theme.surface)
                if let error { Section { Text(error).foregroundStyle(Theme.danger) }.listRowBackground(Theme.surface) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.soul.ignoresSafeArea())
            .navigationTitle(Text("poll.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("poll.send") { Task { await send() } }.bold() }
                }
            }
        }
        .tfColorScheme()
    }

    private func send() async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let opts = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if q.isEmpty { error = NSLocalizedString("poll.err.q", comment: ""); return }
        if opts.count < 2 { error = NSLocalizedString("poll.err.two", comment: ""); return }
        if Set(opts.map { $0.lowercased() }).count != opts.count { error = NSLocalizedString("poll.err.dup", comment: ""); return }
        busy = true
        defer { busy = false }
        if let e = await onSend(q, opts, multiple) { error = e } else { dismiss() }
    }
}

// MARK: trading signals (groups/SignalCard.tsx, SignalComposer.tsx)

struct SignalInfo {
    let symbol, direction, entry, stopLoss, takeProfit: String
    let status: String?

    init?(_ m: Message) {
        guard m.kind == "signal", let s = m.signal, let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        func v(_ k: String) -> String { (o[k] as? String) ?? (o[k].map { "\($0)" } ?? "") }
        symbol = v("symbol"); direction = v("direction"); entry = v("entry"); stopLoss = v("stop_loss"); takeProfit = v("take_profit1")
        status = o["status"] as? String
    }

    var isBuy: Bool { direction.lowercased() == "buy" }
    var riskReward: String? {
        guard let e = Double(entry), let sl = Double(stopLoss), let tp = Double(takeProfit), e != sl else { return nil }
        let r = abs(tp - e) / abs(e - sl)
        return String(format: "1:%.2f", r)
    }
}

struct SignalCard: View {
    let info: SignalInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(info.symbol).font(.system(size: 18, weight: .heavy)).foregroundStyle(Theme.text)
                Text(info.isBuy ? "BUY" : "SELL").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(info.isBuy ? Theme.buy : Theme.danger, in: Capsule())
                Spacer()
                if let s = info.status, !s.isEmpty, s != "pending" {
                    Text(Self.statusLabel(s)).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.gold)
                        .padding(.horizontal, 7).padding(.vertical, 3).overlay(Capsule().stroke(Theme.gold.opacity(0.6), lineWidth: 1))
                }
            }
            HStack(spacing: 8) {
                cell("signal.entry", info.entry, Theme.text)
                cell("signal.sl", info.stopLoss, Theme.danger)
                cell("signal.tp", info.takeProfit, Theme.buy)
            }
            if let rr = info.riskReward {
                Text(String(format: NSLocalizedString("signal.rr", comment: ""), rr)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.gold)
            }
        }
        .padding(12)
        .frame(maxWidth: 300)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.gold.opacity(0.45), lineWidth: 1))
        .environment(\.layoutDirection, .leftToRight)
    }

    private func cell(_ key: LocalizedStringKey, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(.system(size: 10)).foregroundStyle(Theme.faint)
            Text(v).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8))
    }

    static func statusLabel(_ s: String) -> String {
        switch s {
        case "active": return "ACTIVE"
        case "tp_hit", "target_hit": return "TARGET HIT"
        case "sl_hit", "stop_hit": return "STOP LOSS HIT"
        case "closed": return "CLOSED"
        case "cancelled", "canceled": return "CANCELLED"
        default: return s.uppercased()
        }
    }
}

struct SignalComposer: View {
    let onSend: (String, String, String, String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var symbol = ""
    @State private var buy = true
    @State private var entry = ""
    @State private var sl = ""
    @State private var tp = ""
    @State private var error: String?
    @State private var busy = false

    private var hint: String? {
        guard let e = Double(entry), let s = Double(sl), let t = Double(tp) else { return nil }
        if buy && !(s < e && t > e) { return NSLocalizedString("signal.hint.buy", comment: "") }
        if !buy && !(s > e && t < e) { return NSLocalizedString("signal.hint.sell", comment: "") }
        return String(format: NSLocalizedString("signal.rr", comment: ""), String(format: "1:%.2f", abs(t - e) / abs(e - s)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("signal.symbol", text: $symbol).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .onChange(of: symbol) { v in symbol = String(v.uppercased().prefix(16)) }
                    Picker("signal.direction", selection: $buy) {
                        Text("▲ Buy").tag(true)
                        Text("▼ Sell").tag(false)
                    }
                    .pickerStyle(.segmented)
                    TextField("signal.entry", text: $entry).keyboardType(.decimalPad)
                    TextField("signal.sl.long", text: $sl).keyboardType(.decimalPad)
                    TextField("signal.tp.long", text: $tp).keyboardType(.decimalPad)
                }
                .listRowBackground(Theme.surface)
                if let hint { Section { Text(hint).foregroundStyle(Theme.gold) }.listRowBackground(Theme.surface) }
                if let error { Section { Text(error).foregroundStyle(Theme.danger) }.listRowBackground(Theme.surface) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.soul.ignoresSafeArea())
            .navigationTitle(Text("signal.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("poll.send") { Task { await send() } }.bold()
                            .disabled(symbol.isEmpty || entry.isEmpty || sl.isEmpty || tp.isEmpty)
                    }
                }
            }
        }
        .tfColorScheme()
    }

    private func send() async {
        busy = true
        defer { busy = false }
        if let e = await onSend(symbol, buy ? "buy" : "sell", entry, sl, tp) { error = e } else { dismiss() }
    }
}

// MARK: group post comments (groups/CommentsPanel.tsx)

struct CommentsSheet: View {
    let token: String
    let groupID: String
    let postID: String
    let me: String
    let isAdmin: Bool
    let names: [String: String]
    @Environment(\.dismiss) private var dismiss
    @State private var items: [GroupComment] = []
    @State private var text = ""
    @State private var replyTo: GroupComment?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Text("comments.discussion").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint).textCase(.uppercase)
                        if !loading && items.isEmpty {
                            Text("comments.empty").font(.system(size: 13)).foregroundStyle(Theme.faint).padding(.top, 20)
                        }
                        ForEach(items) { c in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(c.sender_id == me ? NSLocalizedString("chat.you", comment: "") : (names[c.sender_id] ?? "…"))
                                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                                    if let d = serverDate(c.created_at) { Text(ChatRow.timeLabel(d)).font(.system(size: 11)).foregroundStyle(Theme.faint) }
                                }
                                if let r = c.reply_to_id, !r.isEmpty, let parent = items.first(where: { $0.id == r }) {
                                    Text(parent.body).font(.system(size: 12)).foregroundStyle(Theme.faint).lineLimit(1)
                                        .padding(.leading, 6).overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 2) }
                                }
                                Text(c.body).font(.system(size: 15)).foregroundStyle(Theme.text)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.bubbleIn, in: RoundedRectangle(cornerRadius: 12))
                            .contextMenu {
                                Button { replyTo = c } label: { Label("chat.reply", systemImage: "arrowshape.turn.up.left") }
                                if c.sender_id == me || isAdmin {
                                    Button(role: .destructive) {
                                        Task {
                                            try? await APIClient.shared.chDeleteComment(token: token, groupID: groupID, commentID: c.id)
                                            await load()
                                        }
                                    } label: { Label("chat.delete.me", systemImage: "trash") }
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                VStack(spacing: 6) {
                    if let r = replyTo {
                        HStack {
                            Text(r.body).font(.system(size: 12)).foregroundStyle(Theme.faint).lineLimit(1)
                            Spacer()
                            Button { replyTo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }
                        }
                    }
                    HStack {
                        TextField("comments.write", text: $text, axis: .vertical).lineLimit(1...4).foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Theme.inputGradient, in: RoundedRectangle(cornerRadius: 22))
                            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.borderStrong, lineWidth: 1))
                        Button {
                            Task {
                                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !t.isEmpty else { return }
                                text = ""
                                try? await APIClient.shared.chAddComment(token: token, groupID: groupID, postID: postID, body: t, replyTo: replyTo?.id ?? "")
                                replyTo = nil
                                await load()
                            }
                        } label: {
                            Image(systemName: "paperplane.fill").foregroundStyle(.white).frame(width: 42, height: 42).background(Theme.sendGradient, in: Circle())
                        }
                        .accessibilityLabel(Text("comments.post"))
                    }
                }
                .padding(10)
                .background(Theme.header)
            }
            .background(Starfield())
            .navigationTitle(Text("comments.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .tfColorScheme()
        .task { await load() }
    }

    private func load() async {
        items = (try? await APIClient.shared.chComments(token: token, groupID: groupID, postID: postID)) ?? items
        loading = false
    }
}

// MARK: call entries in the timeline (calls/CallEntryRow.tsx)

struct CallEntryRow: View {
    let message: Message
    let me: String
    let onCallBack: (() -> Void)?

    private var entry: [String: Any] {
        guard let s = message.signal, let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    var body: some View {
        let outgoing = (entry["caller_id"] as? String) == me
        let status = (entry["status"] as? String) ?? ""
        let duration = Int64((entry["duration_ms"] as? Double) ?? Double((entry["duration_ms"] as? Int) ?? 0))
        let missed = !outgoing && ["missed", "canceled", "busy"].contains(status)
        HStack(spacing: 12) {
            Image(systemName: outgoing ? "phone.arrow.up.right" : (missed ? "phone.down" : "phone.arrow.down.left"))
                .font(.system(size: 16)).foregroundStyle(missed ? Theme.danger : Theme.accent)
                .frame(width: 36, height: 36).background((missed ? Theme.danger : Theme.accent).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(missed ? "callrow.missed" : (outgoing ? "callrow.out" : "callrow.in")))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(missed ? Theme.danger : Theme.text)
                Text(status == "completed" ? VoiceBubble.length(duration) : NSLocalizedString("callrow.status." + (status.isEmpty ? "ended" : status), comment: ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 8)
            if let d = message.date { Text(d, style: .time).font(.system(size: 11)).foregroundStyle(Theme.faint) }
            if let onCallBack {
                Button(action: onCallBack) {
                    Image(systemName: "phone.fill").font(.system(size: 14)).foregroundStyle(Theme.onAccent)
                        .frame(width: 34, height: 34).background(Theme.accent, in: Circle())
                }
                .accessibilityLabel(Text("callrow.back"))
            }
        }
        .padding(10)
        .frame(maxWidth: 300)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderStrong, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }
}

// MARK: link preview (shared/components/LinkPreview.tsx)

struct LinkPreviewCard: View {
    let token: String
    let url: String
    @State private var data: LinkPreviewData?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let d = data {
                Link(destination: URL(string: d.url ?? url) ?? URL(string: "https://app.tradeflor.com")!) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill().frame(height: 120).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        if let s = d.site, !s.isEmpty { Text(s).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent) }
                        if let t = d.title, !t.isEmpty { Text(t).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text).lineLimit(2) }
                        if let ds = d.description, !ds.isEmpty { Text(ds).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(3) }
                    }
                    .padding(8)
                    .frame(maxWidth: 260, alignment: .leading)
                    .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 3) }
                }
            }
        }
        .task(id: url) {
            data = await APIClient.shared.chLinkPreview(token: token, url: url)
            if let p = data?.image, !p.isEmpty, let d = await APIClient.shared.chLinkImage(token: token, path: p) { image = UIImage(data: d) }
        }
    }

    static func firstURL(in text: String) -> String? {
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return det.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url?.absoluteString
    }
}

// MARK: emoji picker (shared/components/EmojiPicker.tsx categories)

struct EmojiPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    static let sets: [(String, String)] = [
        ("emoji.trading", "📈📉💹💰💵💶💷💴🪙💎🏦🏛️📊🧾⚖️🚀🔥✅❌⚠️🎯🔔🕒🐂🐻"),
        ("emoji.smileys", "😀😃😄😁😆😅😂🤣😊😇🙂😉😍🥰😘😋😎🤩🥳😏😒😞😔😟😕🙁😣😖😫😩🥺😢😭😤😠😡🤯😳🥵🥶😱😨😰😥😓🤗🤔🤭🤫🤥😶😐😑😬🙄😯😦😧😮😲🥱😴🤤😪😵🤐🥴🤢🤮🤧😷🤒🤕👍👎👏🙌👐🤝🙏✌️🤞🤟🤘👌🤌👋💪"),
        ("emoji.animals", "🐶🐱🐭🐹🐰🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵🐔🐧🐦🦅🦉🐺🐴🦄🐝🦋🐌🐞🐢🐍🐙🐬🐳🌵🌲🌴🌱🌿🍀🌸🌹🌻🌼🌞🌙⭐🌈"),
        ("emoji.food", "🍏🍎🍐🍊🍋🍌🍉🍇🍓🍒🍑🥭🍍🥥🥝🍅🥑🍆🥕🌽🍞🧀🍗🍔🍟🍕🌮🥙🍣🍰🎂🍩🍪🍫🍿☕🍵🥤🍺🍷"),
        ("emoji.activity", "⚽🏀🏈⚾🎾🏐🎱🏓🥊🏆🥇🎮🎲🧩🎯🎳🎨🎬🎤🎧🎹🥁🎸"),
        ("emoji.travel", "🚗🚕🚌🏎️🚓🚑🚒✈️🚀🛳️⛵🚲🏍️🗽🗼🏰🏝️🏔️🌋🏙️🌉🌃"),
        ("emoji.objects", "⌚📱💻⌨️🖥️🖨️📷🎥📞☎️📺⏰💡🔦📚📝✏️📌📎🔑🔒🔓🛠️⚙️🧲💊🎁🎈"),
        ("emoji.symbols", "❤️🧡💛💚💙💜🖤🤍🤎💔❣️💕💞💓💗💖💘💝💯✔️☑️➕➖✖️➗♾️‼️⁉️❓❗🔴🟠🟡🟢🔵🟣⚫⚪"),
        ("emoji.flags", "🇺🇸🇪🇺🇬🇧🇯🇵🇨🇳🇨🇭🇨🇦🇦🇺🇳🇿🇩🇪🇫🇷🇮🇹🇪🇸🇸🇦🇦🇪🇱🇧🇪🇬🇹🇷🇮🇳🇧🇷"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.sets.indices, id: \.self) { i in
                        FilterChip(title: NSLocalizedString(Self.sets[i].0, comment: ""), selected: tab == i) { tab = i }
                    }
                }
                .padding(10)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                    ForEach(Array(Self.sets[tab].1.map { String($0) }.enumerated()), id: \.offset) { _, e in
                        Button { onPick(e) } label: { Text(e).font(.system(size: 30)) }.buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
        }
        .background(Theme.panel.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .tfColorScheme()
    }
}

// MARK: share live location sheet (location/ShareLocationSheet.tsx)

struct ShareLocationSheet: View {
    let onShare: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 15

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $minutes) {
                    Text("location.15m").tag(15)
                    Text("location.1h").tag(60)
                    Text("location.8h").tag(480)
                }
                .pickerStyle(.segmented)
                Text("location.note").font(.system(size: 13)).foregroundStyle(Theme.faint)
                Button {
                    onShare(minutes)
                    dismiss()
                } label: {
                    Text("location.share.go").bold().foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 48).background(Theme.accent, in: Capsule())
                }
                Spacer()
            }
            .padding(16)
            .background(Theme.panel.ignoresSafeArea())
            .navigationTitle(Text("location.share"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .presentationDetents([.height(260)])
        .tfColorScheme()
    }
}

/// "Today", "Yesterday", a weekday within the week, else "16 November 2026" (the website's day separators).
enum DayLabel {
    static func text(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return NSLocalizedString("calendar.today", comment: "") }
        if cal.isDateInYesterday(d) { return NSLocalizedString("time.yesterday", comment: "") }
        let f = DateFormatter()
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, days < 7 {
            f.setLocalizedDateFormatFromTemplate("EEEE")
        } else if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
            f.setLocalizedDateFormatFromTemplate("dMMMM")
        } else {
            f.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        }
        return f.string(from: d)
    }
}
