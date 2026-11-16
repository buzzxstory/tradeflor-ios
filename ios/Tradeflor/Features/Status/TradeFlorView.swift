import SwiftUI

/// The TradeFlor tab (website TradeFlorView.tsx): search, the next high-impact event with a countdown, the London /
/// New York / Tokyo sessions, statuses as cards, "While you were away", and today's events with reminders.
struct TradeFlorView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var events: [CalendarEvent] = []
    @State private var saved: Set<String> = []
    @State private var groups: [StatusGroup] = []
    @State private var query = ""
    @State private var showAll = false
    @State private var open: StatusOpen?
    @State private var manage = false
    @State private var now = Date()

    private var token: String { store.session?.token ?? "" }
    private var today: [CalendarEvent] {
        let cal = Calendar.current
        let q = query.trimmingCharacters(in: .whitespaces)
        return events.filter { e in
            guard let d = e.date, cal.isDateInToday(d) else { return false }
            return q.isEmpty || e.event.localizedCaseInsensitiveContains(q) || e.currency.localizedCaseInsensitiveContains(q)
        }
    }
    private var nextHigh: CalendarEvent? {
        events.filter { $0.impact == "high" && ($0.date ?? .distantPast) > now }.min { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }
    private var statusPeople: [StatusGroup] {
        groups.filter { !($0.isMine && $0.group_id == nil) && !$0.posts.isEmpty }.sorted { $0.latest > $1.latest }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        HStack(spacing: 6) {
                            Image("BrandFlower").resizable().scaledToFit().frame(width: 30, height: 30)
                            (Text("Trade").foregroundColor(Theme.text) + Text("Flor").foregroundColor(Theme.wordmark))
                                .font(.system(size: 22, weight: .heavy))
                        }
                        .environment(\.layoutDirection, .leftToRight)
                        Spacer()
                        Button { manage = true } label: {
                            Image(systemName: "camera").font(.system(size: 15)).foregroundStyle(Theme.accent)
                                .frame(width: 34, height: 34).background(Theme.card, in: Circle())
                                .overlay(Circle().stroke(Theme.borderStrong, lineWidth: 1))
                        }
                        .accessibilityLabel(Text("status.post"))
                    }
                    SearchPill(placeholder: "tf.search", text: $query)
                    if let e = nextHigh, let d = e.date { nextCard(e, d) }
                    sessions
                    Text("status.title").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text).padding(.top, 4)
                    statusCards
                    awayCard
                    HStack {
                        Text("tf.today").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                        Spacer()
                    }
                    .padding(.top, 4)
                    eventsList
                }
                .padding(16)
            }
            .refreshable { await load() }
            .background(Starfield())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await load() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                now = Date()
            }
        }
        .fullScreenCover(item: $open) { o in
            StatusViewerScreen(groups: o.groups, startGroup: o.index, token: token) { Task { await load() } }
        }
        .sheet(isPresented: $manage, onDismiss: { Task { await load() } }) { StatusListView() }
    }

    // MARK: pieces

    private func nextCard(_ e: CalendarEvent, _ d: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(Theme.danger, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(e.currency) \(e.event)").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(String(format: NSLocalizedString("tf.next.sub", comment: ""), Self.hm.string(from: d)))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(Self.countdown(d.timeIntervalSince(now))).font(.system(size: 14, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.text)
        }
        .padding(12)
        .background(LinearGradient(colors: [Theme.hex(0x4A0F1E), Theme.hex(0x2A0A14)], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.danger.opacity(0.55), lineWidth: 1))
    }

    private var sessions: some View {
        HStack(spacing: 6) {
            session("London", tz: "Europe/London", open: (8, 0), close: (16, 30))
            session("New York", tz: "America/New_York", open: (9, 30), close: (16, 0))
            session("Tokyo", tz: "Asia/Tokyo", open: (9, 0), close: (15, 0))
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func session(_ name: String, tz: String, open: (Int, Int), close: (Int, Int)) -> some View {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz) ?? .current
        let c = cal.dateComponents([.weekday, .hour, .minute], from: now)
        let mins = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let weekday = c.weekday ?? 2
        let isWeekday = weekday >= 2 && weekday <= 6
        let o = open.0 * 60 + open.1, cl = close.0 * 60 + close.1
        let isOpen = isWeekday && mins >= o && mins < cl
        var label = "\(name) open"
        if !isOpen {
            var wait = o - mins
            if wait <= 0 || !isWeekday { wait += 24 * 60 }
            label = "\(name) \(wait / 60)h \(wait % 60)m"
        }
        return HStack(spacing: 4) {
            Circle().fill(isOpen ? Theme.buy : Theme.faint).frame(width: 5, height: 5)
            Text(label).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(isOpen ? Theme.hex(0x7FF0B8) : Theme.muted)
        .frame(maxWidth: .infinity, minHeight: 26)
        .background(isOpen ? Theme.hex(0x0B3B2A) : Theme.chip, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isOpen ? Theme.buy.opacity(0.5) : Theme.borderStrong, lineWidth: 1))
    }

    private var statusCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { manage = true } label: {
                    VStack(spacing: 8) {
                        ZStack(alignment: .bottomTrailing) {
                            Avatar(token: token, userID: store.session?.userID ?? "", avatarID: nil, title: store.session?.username ?? "?", size: 36)
                            Image(systemName: "plus").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.onAccent)
                                .frame(width: 14, height: 14).background(Theme.accent, in: Circle())
                        }
                        Text("tf.add.status").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    .frame(width: 76, height: 112)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .buttonStyle(.plain)
                ForEach(statusPeople) { g in
                    Button {
                        if let i = statusPeople.firstIndex(of: g) { open = StatusOpen(groups: statusPeople, index: i) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Avatar(token: token, userID: g.user_id, avatarID: nil, title: g.title, size: 30)
                                .overlay(Circle().stroke(g.all_seen ? Theme.faint.opacity(0.4) : Theme.accent, lineWidth: 2))
                            Spacer()
                            Text(g.title).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                            if let d = serverDate(g.latest) {
                                Text(ChatRow.timeLabel(d)).font(.system(size: 10)).foregroundStyle(Theme.faint)
                            }
                        }
                        .padding(8)
                        .frame(width: 76, height: 112, alignment: .leading)
                        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var awayCard: some View {
        let high = today.filter { $0.impact == "high" }.count
        return VStack(alignment: .leading, spacing: 8) {
            Text("tf.away").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(Theme.danger)
                    .frame(width: 22, height: 22).background(Theme.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                Text(String(format: NSLocalizedString("tf.away.high", comment: ""), high)).font(.system(size: 13)).foregroundStyle(Theme.text)
                Spacer()
            }
        }
        .padding(12)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderStrong, lineWidth: 1))
    }

    @ViewBuilder private var eventsList: some View {
        let list = showAll ? today : Array(today.prefix(5))
        VStack(spacing: 0) {
            ForEach(list) { e in
                HStack(spacing: 10) {
                    Text(e.date.map { Self.hm.string(from: $0) } ?? "")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint).frame(width: 42, alignment: .leading)
                    RoundedRectangle(cornerRadius: 2).fill(Self.impactColor(e.impact)).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(e.currency) \(e.event)").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(Self.values(e)).font(.system(size: 10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                    Spacer()
                    Button { Task { await toggle(e) } } label: {
                        Image(systemName: saved.contains(e.id) ? "bell.fill" : "bell").font(.system(size: 12))
                            .foregroundStyle(saved.contains(e.id) ? Theme.accent : Theme.faint)
                            .frame(width: 28, height: 28).overlay(Circle().stroke(Theme.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("calendar.save"))
                }
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.rowRule).frame(height: 1) }
            }
            if today.count > 5 && !showAll {
                Button { showAll = true } label: {
                    Text(String(format: NSLocalizedString("tf.more", comment: ""), today.count - 5))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderStrong, lineWidth: 1))
                }
                .padding(.top, 10)
            }
            if today.isEmpty {
                Text("calendar.empty").font(.system(size: 13)).foregroundStyle(Theme.faint).padding(.vertical, 20)
            }
        }
    }

    // MARK: data

    static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func countdown(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    static func impactColor(_ i: String) -> Color {
        switch i {
        case "high": return Theme.danger
        case "medium": return Theme.gold
        case "low": return Theme.hex(0x3B82F6)
        default: return Theme.faint
        }
    }

    static func values(_ e: CalendarEvent) -> String {
        var parts: [String] = []
        if let a = e.actual, !a.isEmpty { parts.append(NSLocalizedString("calendar.actual", comment: "") + " " + a) }
        if let f = e.forecast, !f.isEmpty { parts.append(NSLocalizedString("calendar.forecast", comment: "") + " " + f) }
        if let p = e.previous, !p.isEmpty { parts.append(NSLocalizedString("calendar.previous", comment: "") + " " + p) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard !token.isEmpty else { return }
        let start = Calendar.current.startOfDay(for: Date())
        async let ev = APIClient.shared.calendar(token: token, from: start, to: start.addingTimeInterval(3 * 86400))
        async let st = APIClient.shared.statusFeed(token: token)
        async let sv = APIClient.shared.savedEvents(token: token)
        events = (try? await ev) ?? events
        groups = (try? await st) ?? groups
        saved = Set(((try? await sv) ?? []).map(\.event_key))
    }

    private func toggle(_ e: CalendarEvent) async {
        if saved.contains(e.id) {
            if (try? await APIClient.shared.removeSavedEvent(token: token, key: e.id)) != nil { saved.remove(e.id) }
        } else if (try? await APIClient.shared.saveEvent(token: token, e)) != nil {
            saved.insert(e.id)
        }
    }
}
