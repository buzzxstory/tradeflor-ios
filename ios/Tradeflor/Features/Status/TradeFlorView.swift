import SwiftUI

/// The TradeFlor tab (website TradeFlorView.tsx, styles 51-tradeflor.css): search, the next high-impact event with a countdown,
/// the London / New York / Tokyo sessions, statuses as cards, "While you were away", and today's events with reminders.
struct TradeFlorView: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject private var badges = BadgeStore.shared
    /// nil until the first answer arrives (the web's `events === null`): a quiet skeleton, never "0 high-impact" or "no events"
    @State private var events: [CalendarEvent]? = TradeFlorView.lastEvents
    @State private var saved: Set<String> = []
    @State private var toggling: Set<String> = []
    @State private var groups: [StatusGroup] = TradeFlorView.lastGroups
    @State private var query = ""
    /// Today's events are shown five at a time (website todayEvents.ts TODAY_PAGE).
    @State private var shownCount = 5
    @State private var open: StatusOpen?
    @State private var manage = false
    @State private var now = Date()

    /// The last answers, kept across a rebuilt tab so it never starts empty again (the web keeps its state too).
    private static var lastEvents: [CalendarEvent]?
    private static var lastGroups: [StatusGroup] = []

    private var token: String { store.session?.token ?? "" }
    private var myID: String { store.session?.userID ?? "" }
    private var needle: String { query.trimmingCharacters(in: .whitespaces) }

    /// Today's high and medium impact events (web: low impact is not listed here), high first, each in time order.
    private var today: [CalendarEvent] {
        let cal = Calendar.current
        let q = needle
        func rank(_ i: String) -> Int { i == "high" ? 0 : 1 }
        return (events ?? []).filter { e in
            guard let d = e.date, cal.isDateInToday(d), e.impact == "high" || e.impact == "medium" else { return false }
            return q.isEmpty || "\(e.event) \(e.currency) \(e.country)".localizedCaseInsensitiveContains(q)
        }
        .sorted { a, b in
            rank(a.impact) != rank(b.impact) ? rank(a.impact) < rank(b.impact) : (a.date ?? .distantPast) < (b.date ?? .distantPast)
        }
    }
    /// Today's high-impact events, whatever the search says (web highToday).
    private var highToday: [CalendarEvent] {
        (events ?? []).filter { $0.impact == "high" && ($0.date.map { Calendar.current.isDateInToday($0) } ?? false) }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }
    /// The next high-impact event still to come (web nextHighImpact: not yet released, no figure published).
    private var nextHigh: CalendarEvent? {
        (events ?? []).filter { $0.impact == "high" && !Self.isReleased($0, now) }
            .min { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }
    /// Personal statuses only (web: `!g.group_id`).
    private var personal: [StatusGroup] { groups.filter { $0.group_id == nil && !$0.posts.isEmpty } }
    private var mine: StatusGroup? { personal.first { $0.isMine || $0.user_id == myID } }
    /// In the server's order (web): people with something new first, then the ones already watched, newest first in each.
    private var people: [StatusGroup] {
        personal.filter { !($0.isMine || $0.user_id == myID) }
    }
    private var shownPeople: [StatusGroup] {
        needle.isEmpty ? people : people.filter { $0.username.localizedCaseInsensitiveContains(needle) }
    }
    /// What the viewer pages through: my status first, then the people's.
    private var viewerGroups: [StatusGroup] { (mine.map { [$0] } ?? []) + people }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.top, 2).padding(.bottom, 12)
                    SearchPill(placeholder: "tf.search", text: $query).padding(.bottom, 12)
                    nextSlot.padding(.bottom, 10)
                    sessions.padding(.bottom, 18)
                    sectionTitle("status.title").padding(.bottom, 10)
                    statusCards.padding(.bottom, 16)
                    awayCard.padding(.bottom, 18)
                    HStack {
                        sectionTitle("tf.today")
                        Spacer()
                        Button { Self.go("calendar") } label: {
                            Text("calendar.title").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 10)
                    eventsList.padding(.bottom, 16)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await load() }
            .background(
                ZStack {
                    Starfield()
                    // web .tf-home: radial-gradient(120% 50% at 100% 0%, rgba(0,201,211,.12), transparent 55%)
                    RadialGradient(colors: [Theme.hex(0x00C9D3, 0.12), .clear], center: .topTrailing, startRadius: 0, endRadius: 420)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            )
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await load() }
        .task {
            while !Task.isCancelled {
                // the page itself only needs the minute (released events, sessions, "5m ago"); the seconds of the
                // countdown tick inside TickText, so the whole page is not redrawn every second (that made it lag)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                now = Date()
            }
        }
        .task {
            // the web asks again every five minutes (events) and two minutes (status)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                await load()
            }
        }
        .fullScreenCover(item: $open) { o in
            StatusViewerScreen(groups: o.groups, startGroup: o.index, token: token) {}
        }
        .fullScreenCover(isPresented: $manage) {
            StatusCreatorSheet { NotificationCenter.default.post(name: .tfStatusChanged, object: nil) }
        }
        // a status watched, posted or deleted anywhere: the cards and their rings change at once
        .onReceive(NotificationCenter.default.publisher(for: .tfStatusChanged)) { _ in Task { await loadStatus() } }
    }

    // MARK: pieces

    /// .tf-home__top: 40 pt orb with its glow, "Trade" + "Flor" in the turquoise-to-gold gradient (28, 800), 40 pt camera button.
    private var header: some View {
        HStack(spacing: 10) {
            Image("BrandFlower").resizable().scaledToFit().frame(width: 40, height: 40)
                .shadow(color: Theme.hex(0x3CF0EE, 0.35), radius: 6)
            HStack(spacing: 0) {
                Text(verbatim: "Trade").foregroundStyle(Theme.text)
                Text(verbatim: "Flor").foregroundStyle(LinearGradient(colors: [Theme.hex(0x3CF0EE), Theme.hex(0xF3C95C)],
                                                                      startPoint: .leading, endPoint: .trailing))
            }
            .font(.system(size: 28, weight: .heavy))
            .kerning(-0.5)
            .lineLimit(1)
            Spacer(minLength: 0)
            Button { manage = true } label: {
                Image(systemName: "camera").font(.system(size: 17, weight: .regular)).foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.hex(0x00C9D3, 0.08), in: Circle())
                    .overlay(Circle().stroke(Theme.dyn(0x1F6B78, 0x9FD3DC), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("status.post"))
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.system(size: 19, weight: .heavy)).foregroundStyle(Theme.text)
    }

    /// The next-event card, its quiet "none" form once events are known, or a skeleton of the same size before.
    @ViewBuilder private var nextSlot: some View {
        if let e = nextHigh, let d = e.date {
            Button { Self.go("calendar") } label: { nextCard(e, d) }.buttonStyle(.plain)
        } else if events != nil {
            HStack {
                Text("ux3.tf.next.none").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(.horizontal, 14).frame(minHeight: 62)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.border, lineWidth: 1))
        } else {
            QuietSkeleton(height: 62, radius: 18)
        }
    }

    /// .tf-next: 40 pt #ff5d6c pulse tile (radius 12), white 15.5 title, #f2b3bb 12.5 line, #ffd0d6 16 mono countdown,
    /// gradient #3a0f1a → #1e0c12 with a #8a2a3a edge, radius 18.
    private func nextCard(_ e: CalendarEvent, _ d: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(Theme.hex(0xFF5D6C), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(e.currency) \(e.event)").font(.system(size: 15.5, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                Text(String(format: NSLocalizedString("tf.next.sub", comment: ""), Self.hm.string(from: d)))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.hex(0xF2B3BB)).lineLimit(1)
            }
            Spacer(minLength: 4)
            TickText { Self.countdown(d.timeIntervalSince($0)) }.font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.hex(0xFFD0D6)).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(LinearGradient(colors: [Theme.hex(0x3A0F1A), Theme.hex(0x1E0C12)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hex(0x8A2A3A), lineWidth: 1))
        .contentShape(Rectangle())
    }

    /// .tf-sess: three equal pills (34 high, radius 12, 12.5 semibold); open = green, before opening = "London 2h 5m",
    /// after closing or at the weekend = "London closed". Hours as the web's marketSessions.ts.
    private var sessions: some View {
        HStack(spacing: 7) {
            session("London", tz: "Europe/London", open: 8 * 60, close: 17 * 60)
            session("New York", tz: "America/New_York", open: 8 * 60, close: 17 * 60)
            session("Tokyo", tz: "Asia/Tokyo", open: 9 * 60, close: 18 * 60)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func session(_ name: String, tz: String, open: Int, close: Int) -> some View {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz) ?? .current
        let c = cal.dateComponents([.weekday, .hour, .minute], from: now)
        let mins = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let weekday = c.weekday ?? 2
        let isWeekday = weekday >= 2 && weekday <= 6
        let isOpen = isWeekday && mins >= open && mins < close
        let soon = isWeekday && mins < open
        let label: String
        if isOpen { label = String(format: NSLocalizedString("ux3.tf.sess.open", comment: ""), name) }
        else if soon { label = "\(name) \(Self.shortSpan(open - mins))" }
        else { label = String(format: NSLocalizedString("ux3.tf.sess.closed", comment: ""), name) }
        let openGreen = Theme.hex(0x2BF29A)
        return HStack(spacing: 7) {
            Circle()
                .fill(isOpen ? openGreen : Color.clear)
                .overlay(Circle().strokeBorder(lineWidth: 1.5).opacity(isOpen ? 0 : 1))
                .frame(width: 7, height: 7)
                .shadow(color: isOpen ? openGreen : .clear, radius: 4)
            Text(label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(isOpen ? Theme.dyn(0x6FF0B8, 0x0D7A4F) : (soon ? Theme.muted : Theme.faint))
        .opacity(!isOpen && !soon ? 0.8 : 1)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(isOpen ? Theme.dyn(0x0C3A2E, 0xE3F7EE) : Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isOpen ? Theme.dyn(0x1F7A5A, 0x8BD7B4) : Theme.border, lineWidth: 1))
    }

    /// .tf-st: 92 × 140 cards (radius 16). "Add status" / "My status" with a dashed #2a6b78 edge and a 48 pt face with its
    /// 20 pt turquoise "+"; people's cards in three gradients, a 42 pt ring top-left, the name and "5m ago" at the bottom.
    private var statusCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    if mine != nil { open = StatusOpen(groups: viewerGroups, index: 0) } else { manage = true }
                } label: {
                    VStack(spacing: 10) {
                        ZStack(alignment: .bottomTrailing) {
                            Avatar(token: token, userID: myID, avatarID: nil, title: store.session?.username ?? "?", size: 48)
                            Text(verbatim: "+").font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.hex(0x03222A))
                                .frame(width: 20, height: 20).background(Theme.hex(0x3FE4E2), in: Circle())
                                .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                                .offset(x: 3, y: 3)
                        }
                        Text(LocalizedStringKey(mine != nil ? "status.mine" : "tf.add.status"))
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .frame(width: 92, height: 140)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Theme.dyn(0x2A6B78, 0x9FD3DC), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .buttonStyle(.plain)
                ForEach(Array(shownPeople.enumerated()), id: \.element.id) { k, g in
                    Button {
                        if let i = viewerGroups.firstIndex(of: g) { open = StatusOpen(groups: viewerGroups, index: i) }
                    } label: { personCard(g, palette: k % 3) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(g.username))
                }
                if shownPeople.isEmpty {
                    Text(LocalizedStringKey(needle.isEmpty ? "ux3.tf.nostatus" : "ux3.tf.nostatus.match"))
                        .font(.system(size: 13.5)).foregroundStyle(Theme.faint)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, -16)
    }

    private func personCard(_ g: StatusGroup, palette: Int) -> some View {
        let fills: [(UInt32, UInt32)] = [(0x1E4B63, 0x0D2431), (0x4A3A5E, 0x191427), (0x25503F, 0x0C211A)]
        let f = fills[palette]
        return ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: Theme.hex(f.0), location: 0), .init(color: Theme.hex(f.1), location: 0.75)],
                           startPoint: .top, endPoint: .bottom)
            Avatar(token: token, userID: g.user_id, avatarID: nil, title: g.username, size: 38)
                .overlay(Circle().strokeBorder(Theme.dyn(0x06141B, 0xFFFFFF), lineWidth: 2))
                .padding(2)
                .background(
                    Circle().fill(g.all_seen
                                  ? AnyShapeStyle(Theme.hex(0x5F777F))
                                  : AnyShapeStyle(AngularGradient(stops: [.init(color: Theme.hex(0x3FE4E2), location: 0),
                                                                          .init(color: Theme.hex(0x3FE4E2), location: 0.805),
                                                                          .init(color: Theme.hex(0xC9A85A), location: 0.806),
                                                                          .init(color: Theme.hex(0xC9A85A), location: 1)],
                                                                  center: .center, startAngle: .degrees(-90), endAngle: .degrees(270))))
                )
                .padding(9)
            VStack(alignment: .leading, spacing: 1) {
                Spacer()
                Text(g.username).font(.system(size: 13.5, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                if let d = serverDate(g.latest) {
                    Text(Self.ago(d, now)).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                }
            }
            .padding(.leading, 10).padding(.trailing, 8).padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(width: 92, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private struct AwayRow: Identifiable {
        let id: String
        let icon: String
        let tint: UInt32
        let text: String
        let end: String
        let go: String
    }

    private var awayRows: [AwayRow] {
        var rows: [AwayRow] = []
        let c = badges.chats, g = badges.groups
        if c > 0 {
            rows.append(AwayRow(id: "c", icon: "bubble.left", tint: 0x3CD6D8,
                                text: String(format: NSLocalizedString(c == 1 ? "ux3.tf.unread.chat" : "ux3.tf.unread.chats", comment: ""), c),
                                end: "", go: "chats"))
        }
        if g > 0 {
            rows.append(AwayRow(id: "g", icon: "person.2", tint: 0x2BF29A,
                                text: String(format: NSLocalizedString(g == 1 ? "ux3.tf.unread.group" : "ux3.tf.unread.groups", comment: ""), g),
                                end: "", go: "groups"))
        }
        let h = highToday
        if !h.isEmpty {
            let first = h[0]
            rows.append(AwayRow(id: "e", icon: "calendar", tint: 0xFF7D8A,
                                text: String(format: NSLocalizedString(h.count == 1 ? "ux3.tf.away.high1" : "tf.away.high", comment: ""), h.count),
                                end: first.date.map { "\(first.currency) \(Self.hm.string(from: $0))" } ?? "", go: "calendar"))
        }
        return rows
    }

    /// .tf-away: radius 18, #0b3340 → #071d26, #1d5a68 edge; 15 bold #7ff3f3 title ("You're all caught up" when nothing
    /// waits); rows with a 30 pt tinted icon tile, 14.5 text and a dim end note, ruled between.
    private var awayCard: some View {
        let rows = awayRows
        let loading = events == nil
        return VStack(alignment: .leading, spacing: 0) {
            Text(LocalizedStringKey(rows.isEmpty && !loading ? "ux3.tf.caughtup" : "tf.away"))
                .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.dyn(0x7FF3F3, 0x067F8A))
                .padding(.bottom, 6)
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                Button { Self.go(r.go) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: r.icon).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.hex(r.tint))
                            .frame(width: 30, height: 30)
                            .background(Theme.hex(r.tint, 0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text(r.text).font(.system(size: 14.5)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 4)
                        if !r.end.isEmpty {
                            Text(r.end).font(.system(size: 12.5)).foregroundStyle(Theme.faint).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .overlay(alignment: .top) {
                        if i > 0 { Rectangle().fill(Theme.hex(0x1D5A68, 0.55)).frame(height: 1) }
                    }
                }
                .buttonStyle(.plain)
            }
            if loading && rows.isEmpty {
                HStack(spacing: 11) {
                    QuietSkeleton(width: 30, height: 30, radius: 9)
                    QuietSkeleton(width: 170, height: 12, radius: 6)
                    Spacer()
                }
                .padding(.vertical, 9)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Theme.dyn(0x0B3340, 0xE4F5F8), Theme.dyn(0x071D26, 0xF2FAFC)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.dyn(0x1D5A68, 0xA9DDE6), lineWidth: 1))
    }

    /// .tf-ev: 14 bold mono time (46 wide), a 4 pt impact bar, 15.5 title, 13 values line, a 40 pt bell (lit when set,
    /// greyed once released); rows ruled between; "Load more (N more)" in a soft turquoise box.
    @ViewBuilder private var eventsList: some View {
        let all = today
        let list = needle.isEmpty ? Array(all.prefix(shownCount)) : all
        VStack(spacing: 0) {
            if events == nil {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 12) {
                        QuietSkeleton(width: 42, height: 12, radius: 4)
                        QuietSkeleton(width: 4, height: 34, radius: 2)
                        VStack(alignment: .leading, spacing: 6) {
                            QuietSkeleton(width: 180, height: 13, radius: 5)
                            QuietSkeleton(width: 120, height: 10, radius: 5)
                        }
                        Spacer()
                        QuietSkeleton(width: 40, height: 40, radius: 20)
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) } }
                }
            } else if all.isEmpty {
                Text(LocalizedStringKey(needle.isEmpty ? "ux3.tf.noevents" : "ux3.tf.nomatch"))
                    .font(.system(size: 14)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4).padding(.bottom, 8)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                eventRow(e).overlay(alignment: .top) { if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) } }
            }
            if needle.isEmpty && all.count > 5 {
                Button {
                    withAnimation { shownCount = shownCount < all.count ? shownCount + 5 : 5 }
                } label: {
                    Text(shownCount < all.count
                         ? String(format: NSLocalizedString("tf.more", comment: ""), all.count - shownCount)
                         : NSLocalizedString("tf.showless", comment: ""))
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 12).padding(.horizontal, 16)
                        .background(Theme.hex(0x00D4DF, 0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hex(0x00D4DF, 0.28), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
        }
    }

    private func eventRow(_ e: CalendarEvent) -> some View {
        let out = Self.isReleased(e, now)
        let on = saved.contains(e.id)
        return HStack(spacing: 12) {
            Text(e.date.map { Self.hm.string(from: $0) } ?? "")
                .font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Theme.muted)
                .frame(width: 46, alignment: .leading)
                .opacity(out ? 0.6 : 1)
            RoundedRectangle(cornerRadius: 2).fill(e.impact == "high" ? Theme.hex(0xFF5D6C) : Theme.hex(0xF3C95C))
                .frame(width: 4).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(e.currency) \(e.event)").font(.system(size: 15.5, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                let v = Self.homeValues(e, released: out)
                if !v.isEmpty {
                    Text(v).font(.system(size: 13)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            .opacity(out ? 0.6 : 1)
            Spacer(minLength: 4)
            Button { Task { await toggle(e) } } label: {
                Image(systemName: on ? "bell.fill" : "bell").font(.system(size: 16, weight: .regular))
                    .foregroundStyle(on ? Theme.accent : Theme.muted)
                    .frame(width: 40, height: 40)
                    .background(on ? Theme.hex(0x00D4DF, 0.12) : Color.clear, in: Circle())
                    .overlay(Circle().stroke(on ? Theme.accent : Theme.dyn(0x2A5866, 0xB9D3DC), lineWidth: 1))
                    .shadow(color: on ? Theme.hex(0x00D4DF, 0.25) : .clear, radius: 6)
            }
            .buttonStyle(.plain)
            .disabled(out)
            .opacity(out ? 0.35 : 1)
            .accessibilityLabel(Text(LocalizedStringKey(out ? "ux3.tf.released" : "calendar.save")))
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 12)
    }

    // MARK: data

    static let hm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "02:14:36", or "1d 03:10:00" past a day (web marketSessions.ts countdown).
    static func countdown(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        let d = t / 86400
        let hms = String(format: "%02d:%02d:%02d", (t % 86400) / 3600, (t % 3600) / 60, t % 60)
        return d > 0 ? "\(d)d \(hms)" : hms
    }

    /// "1h 12m", "2h", "45m" (web shortSpan).
    static func shortSpan(_ min: Int) -> String {
        let m = max(0, min), h = m / 60
        return h > 0 ? (m % 60 > 0 ? "\(h)h \(m % 60)m" : "\(h)h") : "\(m)m"
    }

    /// "just now", "5m ago", "3h ago" (web TradeFlorView ago()).
    static func ago(_ d: Date, _ now: Date) -> String {
        let m = max(0, Int(now.timeIntervalSince(d) / 60))
        if m < 1 { return NSLocalizedString("ux3.ago.now", comment: "") }
        if m < 60 { return String(format: NSLocalizedString("ux3.ago.m", comment: ""), m) }
        return String(format: NSLocalizedString("ux3.ago.h", comment: ""), m / 60)
    }

    /// Out once its time has passed or a figure has been published (web isReleased).
    static func isReleased(_ e: CalendarEvent, _ now: Date) -> Bool {
        if let a = e.actual, !a.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        guard let d = e.date else { return true }
        return d <= now
    }

    static func impactColor(_ i: String) -> Color {
        switch i {
        case "high": return Theme.danger
        case "medium": return Theme.gold
        case "low": return Theme.hex(0x2BB6C9) // turquoise, the calendar's new "low" (web 0627f86)
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

    /// The home list's line: "Actual" only once released, then Forecast and Previous.
    static func homeValues(_ e: CalendarEvent, released: Bool) -> String {
        var parts: [String] = []
        if released, let a = e.actual, !a.isEmpty { parts.append(NSLocalizedString("calendar.actual", comment: "") + " " + a) }
        if let f = e.forecast, !f.isEmpty { parts.append(NSLocalizedString("calendar.forecast", comment: "") + " " + f) }
        if let p = e.previous, !p.isEmpty { parts.append(NSLocalizedString("calendar.previous", comment: "") + " " + p) }
        return parts.joined(separator: " · ")
    }

    /// Asks the app to open another tab ("chats", "groups", "calendar"); RootView listens for `tfGoTab`.
    static func go(_ tab: String) {
        NotificationCenter.default.post(name: .tfGoTab, object: tab)
    }

    private func load() async {
        guard !token.isEmpty else { return }
        let start = Calendar.current.startOfDay(for: Date())
        async let ev = APIClient.shared.calendar(token: token, from: start, to: start.addingTimeInterval(3 * 86400))
        async let st = APIClient.shared.statusFeed(token: token)
        async let sv = APIClient.shared.savedEvents(token: token)
        if let e = try? await ev {
            events = e
            Self.lastEvents = e
        } else if events == nil {
            events = [] // a failed first answer stops the skeleton (web: setEvents(prev => prev ?? []))
        }
        if let g = try? await st {
            groups = g
            Self.lastGroups = g
        }
        if let s = try? await sv { saved = Set(s.map(\.event_key)) }
    }

    /// Only the statuses (after one was watched, posted or deleted), not the calendar.
    private func loadStatus() async {
        guard !token.isEmpty else { return }
        await StatusSeenQueue.shared.drain()
        if let g = try? await APIClient.shared.statusFeed(token: token) {
            groups = g
            Self.lastGroups = g
        }
    }

    /// Forgets the cached answers (sign-out): the next account never sees the previous one's statuses.
    static func forgetCache() {
        lastEvents = nil
        lastGroups = []
    }

    private func toggle(_ e: CalendarEvent) async {
        // one request per bell at a time: a quick double tap no longer saves and removes in a race
        guard !toggling.contains(e.id) else { return }
        toggling.insert(e.id)
        defer { toggling.remove(e.id) }
        if saved.contains(e.id) {
            saved.remove(e.id)
            if (try? await APIClient.shared.removeSavedEvent(token: token, key: e.id)) == nil { saved.insert(e.id) }
        } else {
            saved.insert(e.id)
            if (try? await APIClient.shared.saveEvent(token: token, e)) == nil { saved.remove(e.id) }
        }
    }
}

extension Notification.Name {
    /// Posted with the tab id ("chats", "groups", "calendar", "settings") as `object` to switch the dock's tab.
    static let tfGoTab = Notification.Name("tf.go.tab")
}

/// A quiet placeholder block (no spinner, no zeros) while the first data is on its way; it breathes softly.
struct QuietSkeleton: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var radius: CGFloat = 8
    @State private var dim = false

    var body: some View {
        // the breathing is scoped to the fill's opacity only: a repeatForever started with withAnimation in onAppear
        // also animated the block's position, so skeletons (and the rows around them) drifted up and down by themselves
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.faint.opacity(0.14))
            .opacity(dim ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
}


/// Text that changes every second (a countdown, a clock): only this text is redrawn each second, not its page.
struct TickText: View {
    let make: (Date) -> String
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { tl in Text(make(tl.date)) }
    }
}
