import SwiftUI

/// The Economic Calendar (website approved-calendar/calendar.html|js|css, its phone layout under 760 px): the title with its
/// glowing bar, the day summary (Today, Next Event with its ring, High / Medium / Low as filter buttons), the calendar card
/// (time zone, day switcher with Today, LIVE line, the impact / currency / country chips in a 3-column grid, one card per
/// event that opens to "About this event" / "Release time" / Set alert / Add to calendar, Load More), Market Clock,
/// Market Impact with its donut, and the footer.
struct CalendarView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var events: [CalendarEvent] = []
    /// The day|zone whose events are on screen (web shownKey); until it matches, the day shows a quiet skeleton, never zeros.
    @State private var shownKey = ""
    /// The day|zone whose first answer failed (the "temporarily unavailable" box instead of the skeleton).
    @State private var errorKey = ""
    @State private var nextList: [CalendarEvent] = []
    @State private var saved: Set<String> = []
    @State private var impact = "all" // all | high | medium | low
    @State private var currencies: Set<String> = []
    @State private var countries: Set<String> = []
    @State private var tzID = "" // "" = Auto (this device)
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var failed = false
    @State private var updatedAt: Date?
    @State private var now = Date()
    @State private var expanded: Set<String> = []
    @State private var visible = 10
    @State private var picker: String? // "cur" | "cty"
    @State private var pickingDay = false
    @State private var toast: String?

    static let allCurrencies = ["USD", "EUR", "GBP", "JPY", "AUD", "CAD", "CHF", "CNY", "NZD"]
    static let allCountries: [(code: String, name: String)] = [
        ("US", "United States"), ("EU", "Eurozone"), ("GB", "United Kingdom"), ("JP", "Japan"), ("AU", "Australia"),
        ("CA", "Canada"), ("CH", "Switzerland"), ("CN", "China"), ("NZ", "New Zealand"), ("DE", "Germany"),
        ("FR", "France"), ("IT", "Italy"), ("ES", "Spain"),
    ]
    static let zones = ["Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Istanbul", "Africa/Cairo", "Asia/Beirut", "Asia/Riyadh",
                        "Asia/Dubai", "Asia/Karachi", "Asia/Kolkata", "Asia/Bangkok", "Asia/Singapore", "Asia/Hong_Kong", "Asia/Tokyo",
                        "Australia/Sydney", "Pacific/Auckland", "America/Sao_Paulo", "America/New_York", "America/Chicago",
                        "America/Denver", "America/Los_Angeles"]

    /// The page's own palette (calendar.css :root, and calendar-light.css for the day theme).
    enum P {
        static let card = Theme.dyn(0x05202B, 0xF6F9FC)
        static let card2 = Theme.dyn(0x041A24, 0xEEF3F8)
        static let bd = Theme.dyn(0x0D3340, 0xD5E2EE)
        static let bd2 = Theme.dyn(0x15596A, 0xC6D6E7)
        static let chipBd = Theme.dyn(0x12404D, 0xC6D6E7)
        static let chipBg = Theme.dyn(0x041D26, 0xEAF0F7)
        static let chipTx = Theme.dyn(0xD3E6EA, 0x285D95)
        static let tx = Theme.dyn(0xEEF6F9, 0x1B2937)
        static let mu = Theme.dyn(0x93AAB4, 0x50687F)
        static let mu2 = Theme.dyn(0x7A949F, 0x6A8096)
        static let cyan = Theme.dyn(0x35E6F2, 0x0097A5)
        static let blue = Theme.hex(0x00C6C4)
        static let hi = Theme.hex(0xFF3D72)
        static let md = Theme.hex(0xFFB72E)
        static let lo = Theme.hex(0x2BB6C9)
        static let up = Theme.dyn(0x22E3A0, 0x0C9A5F)
        static let dn = Theme.dyn(0xFF5A7E, 0xD8404A)
        static let box = Theme.dyn(0x05202B, 0xEEF3F8, 0.8, 1)
        static let well = Theme.dyn(0x020E14, 0xF0F3F9, 0.45, 0.55)
        static let cardFill = LinearGradient(colors: [card, card2], startPoint: .top, endPoint: .bottom)
    }

    /// Low impact in the app's turquoise (web 0627f86: --lo #199CEB -> #2bb6c9); high #FF3D72, medium #FFB72E (calendar.css).
    static let lowImpact = P.lo
    static func impactColor(_ i: String) -> Color {
        switch i {
        case "high": return P.hi
        case "medium": return P.md
        case "low": return P.lo
        default: return Theme.faint
        }
    }

    private var token: String { store.session?.token ?? "" }
    private var zone: TimeZone { tzID.isEmpty ? .current : (TimeZone(identifier: tzID) ?? .current) }
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }
    private var key: String { "\(Int(day.timeIntervalSince1970))|\(tzID)" }
    private var loaded: Bool { shownKey == key }
    private var isToday: Bool { cal.isDate(day, inSameDayAs: now) }
    private var dayEvents: [CalendarEvent] {
        guard loaded else { return [] }
        return events.filter { e in
            ["high", "medium", "low"].contains(e.impact) && (e.date.map { cal.isDate($0, inSameDayAs: day) } ?? false)
        }
        .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }
    private var filtered: [CalendarEvent] {
        dayEvents.filter { e in
            (impact == "all" || e.impact == impact)
                && (currencies.isEmpty || currencies.contains(e.currency))
                && (countries.isEmpty || countries.contains(e.country_code.uppercased()))
        }
    }
    /// Next event: from now forward whichever day is open; medium or high first, else any (web tickNext).
    private var next: CalendarEvent? {
        let up = nextList.filter { ($0.date ?? .distantPast) > now }.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        return up.first { $0.impact != "low" } ?? up.first
    }
    private var seenCurrencies: [String] {
        Array(Set(Self.allCurrencies + events.map(\.currency).filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    hero
                    stats
                    calendarCard
                    marketClock
                    marketImpact
                    Text("cal.footer").font(.system(size: 12)).foregroundStyle(P.mu2).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.top, 8).padding(.horizontal, 4)
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .refreshable { await load(manual: true) }
            .background(
                ZStack {
                    Starfield()
                    // calendar.css body: radial-gradient(1100px 560px at 78% -8%, rgba(0,198,196,.16), transparent 60%)
                    RadialGradient(colors: [Theme.hex(0x00C6C4, 0.16), .clear], center: UnitPoint(x: 0.78, y: -0.08),
                                   startRadius: 0, endRadius: 460)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            )
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(P.tx).padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Theme.dyn(0x07223F, 0xFFFFFF), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(P.cyan, lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 14)
                        .padding(16)
                        .onTapGesture { self.toast = nil }
                        .task(id: toast) {
                            try? await Task.sleep(nanoseconds: 3_500_000_000)
                            if self.toast == toast { self.toast = nil }
                        }
                }
            }
        }
        .task(id: key) { await load(manual: false) }
        .task(id: tzID) { await loadNext() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                now = Date()
            }
        }
        .task {
            // quiet refresh, as the page does: same key, so nothing blinks
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await load(manual: false)
                await loadNext()
            }
        }
        .sheet(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } })) {
            if picker == "cur" {
                MultiPickSheet(title: NSLocalizedString("cal.currencies", comment: ""),
                               options: seenCurrencies.map { c in (c, c, dayEvents.filter { $0.currency == c }.count) },
                               selection: $currencies)
            } else {
                MultiPickSheet(title: NSLocalizedString("cal.countries", comment: ""),
                               options: Self.allCountries.map { c in
                                   (c.code, Self.flag(c.code) + "  " + c.name, dayEvents.filter { $0.country_code.uppercased() == c.code }.count)
                               },
                               selection: $countries)
            }
        }
        .sheet(isPresented: $pickingDay) {
            VStack(spacing: 0) {
                DatePicker("cal.pick", selection: Binding(get: { day }, set: { day = cal.startOfDay(for: $0); visible = 10; pickingDay = false }),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .environment(\.calendar, Calendar(identifier: .gregorian))
                    .environment(\.timeZone, zone)
                    .tint(Theme.accent)
                    .padding(16)
                Spacer(minLength: 0)
            }
            .background(Theme.ground.ignoresSafeArea())
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: hero and day summary

    /// .hero (phone): a 4 pt turquoise bar with its glow, "Economic Calendar" 28/800, the line under it 13.5 muted.
    private var hero: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [P.cyan, P.blue], startPoint: .top, endPoint: .bottom))
                .frame(width: 4)
                .shadow(color: Theme.hex(0x35E6F2, 0.7), radius: 8)
                .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 10) {
                Text("calendar.heading").font(.system(size: 28, weight: .heavy)).kerning(-0.5).foregroundStyle(P.tx)
                    .fixedSize(horizontal: false, vertical: true)
                Text("calendar.subtitle").font(.system(size: 13.5)).foregroundStyle(P.mu).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 22)
        .padding(.bottom, 6)
    }

    /// .stats (phone): Today across the top, Next Event under it, then High / Medium / Low in three columns.
    private var stats: some View {
        VStack(spacing: 10) {
            todayCard
            nextCard
            HStack(spacing: 10) {
                impactStat("high", "calendar.high", P.hi)
                impactStat("medium", "calendar.medium", P.md)
                impactStat("low", "calendar.low", P.lo)
            }
        }
    }

    private func statBox<Content: View>(border: Color = P.bd, glow: Color = .clear, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(P.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(border, lineWidth: 1))
            .shadow(color: glow, radius: 12)
    }

    private var todayCard: some View {
        statBox {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.checkmark").font(.system(size: 19, weight: .medium)).foregroundStyle(P.cyan)
                    .frame(width: 42, height: 42)
                    .background(Theme.hex(0x35E6F2, 0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hex(0x35E6F2, 0.35), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(isToday ? NSLocalizedString("calendar.today", comment: "") : dayString(day, "EEEE"))
                        .font(.system(size: 17, weight: .bold)).foregroundStyle(P.tx)
                    Text(dayString(day, "MMM d, yyyy")).font(.system(size: 13.5)).foregroundStyle(P.mu)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// .st.next: cyan edge and glow; "Next Event", flag + name (15 bold), "15:30 · 1h 12m" (12.5 mono), a 50 pt ring
    /// that fills over the last four hours.
    private var nextCard: some View {
        statBox(border: Theme.hex(0x35E6F2, 0.45), glow: Theme.hex(0x35E6F2, 0.18)) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("calendar.next").font(.system(size: 12, weight: .semibold)).foregroundStyle(P.mu)
                    HStack(spacing: 10) {
                        if let n = next, let d = n.date {
                            Text(Self.flag(n.country_code)).font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.event).font(.system(size: 15, weight: .bold)).foregroundStyle(P.tx).lineLimit(1)
                                Text("\(nextTime(d)) · \(Self.nextCountdown(d.timeIntervalSince(now)))")
                                    .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(P.mu).lineLimit(1)
                            }
                        } else if nextList.isEmpty && !loaded {
                            VStack(alignment: .leading, spacing: 6) {
                                QuietSkeleton(width: 170, height: 13, radius: 5)
                                QuietSkeleton(width: 110, height: 10, radius: 5)
                            }
                        } else {
                            Text("ux3.cal.noupcoming").font(.system(size: 15, weight: .bold)).foregroundStyle(P.tx)
                        }
                    }
                }
                Spacer(minLength: 4)
                ring
            }
        }
    }

    private var ring: some View {
        let left = next?.date.map { max(0, $0.timeIntervalSince(now)) } ?? (4 * 3600)
        let filled = 1 - min(left / (4 * 3600), 1)
        return ZStack {
            Circle().stroke(Theme.dyn(0x0D3340, 0xD5E2EE), lineWidth: 5)
            Circle().trim(from: 0, to: max(0.001, filled))
                .stroke(LinearGradient(colors: [P.blue, P.cyan], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(2.5)
        .frame(width: 50, height: 50)
    }

    /// High / Medium / Low (button.st, phone): bars over the label and a 21/800 mono count; tapping filters, a second tap clears.
    private func impactStat(_ imp: String, _ label: LocalizedStringKey, _ tint: Color) -> some View {
        let on = impact == imp
        let count = dayEvents.filter { $0.impact == imp }.count
        return Button { impact = on ? "all" : imp; visible = 10 } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach([CGFloat(0.4), 0.7, 1.0], id: \.self) { h in
                        RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 5, height: 20 * h)
                    }
                }
                .frame(height: 20, alignment: .bottom)
                .environment(\.layoutDirection, .leftToRight)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(P.mu).lineLimit(1).minimumScaleFactor(0.8)
                    if loaded {
                        Text("\(count)").font(.system(size: 21, weight: .heavy, design: .monospaced)).foregroundStyle(P.tx)
                    } else {
                        QuietSkeleton(width: 26, height: 21, radius: 5).padding(.vertical, 2)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(P.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(on ? tint : P.bd, lineWidth: on ? 2 : 1))
            .shadow(color: on ? tint.opacity(0.35) : .clear, radius: 10)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: calendar card

    /// .card.cal (phone): time zone, the day switcher, the LIVE line, the chips, then the events.
    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            tzMenu
            dayNav
            feedLine
            chips
            if failed && loaded {
                staleBanner.padding(.top, 6)
            }
            eventsBlock.padding(.top, 6)
        }
        .padding(12)
        .background(P.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(P.bd, lineWidth: 1))
    }

    private var tzMenu: some View {
        Menu {
            Button { tzID = ""; day = Calendar.current.startOfDay(for: Date()) } label: {
                Text(String(format: NSLocalizedString("cal.tz.auto", comment: ""), TimeZone.current.identifier))
            }
            ForEach(Self.zones, id: \.self) { z in
                Button(z.split(separator: "/").last.map { String($0).replacingOccurrences(of: "_", with: " ") } ?? z) {
                    tzID = z
                    var c = Calendar(identifier: .gregorian)
                    c.timeZone = TimeZone(identifier: z) ?? .current
                    day = c.startOfDay(for: Date())
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.system(size: 14)).foregroundStyle(P.cyan)
                Text(tzID.isEmpty ? String(format: NSLocalizedString("cal.tz.auto", comment: ""), TimeZone.current.identifier)
                                  : tzID.replacingOccurrences(of: "_", with: " "))
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(P.chipTx).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(P.mu)
            }
            .padding(.leading, 10).padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(P.chipBg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(P.chipBd, lineWidth: 1))
        }
    }

    /// .dnav (phone): one 38 pt segmented bar: ‹ | Today / "Tue, Nov 18" | › | Today.
    private var dayNav: some View {
        HStack(spacing: 0) {
            navButton("chevron.left", "cal.prev") { shift(-1) }
            Rectangle().fill(P.chipBd).frame(width: 1)
            Button { pickingDay = true } label: {
                Text(isToday ? NSLocalizedString("calendar.today", comment: "") : dayString(day, "EEE, MMM d"))
                    .font(.system(size: 13.5, weight: .bold)).foregroundStyle(P.tx).lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("cal.pick"))
            Rectangle().fill(P.chipBd).frame(width: 1)
            navButton("chevron.right", "cal.next") { shift(1) }
            Rectangle().fill(P.chipBd).frame(width: 1)
            Button { day = cal.startOfDay(for: Date()); visible = 10 } label: {
                Text("calendar.today").font(.system(size: 12.5, weight: .bold)).foregroundStyle(P.cyan)
                    .padding(.horizontal, 14).frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(isToday)
            .opacity(isToday ? 0.4 : 1)
        }
        .frame(height: 38)
        .background(P.chipBg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(P.chipBd, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .environment(\.layoutDirection, .leftToRight)
    }

    private func shift(_ n: Int) {
        day = cal.date(byAdding: .day, value: n, to: day) ?? day
        visible = 10
    }

    private func navButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(P.chipTx)
                .frame(width: 46).frame(maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    /// .feed: "LIVE · updated 13:43:05" in green, "STALE · …" in amber, "Connecting…" before the first answer.
    private var feedLine: some View {
        let state: (String, Color, Color) = {
            guard updatedAt != nil else {
                return (NSLocalizedString(failed ? "ux3.cal.offline" : "ux3.cal.connecting", comment: ""), P.mu, P.mu2)
            }
            if failed { return (NSLocalizedString("cal.stale", comment: ""), Theme.dyn(0xFFD48A, 0xA86A00), P.md) }
            return (String(format: NSLocalizedString("cal.live", comment: ""), updatedAt.map { time($0, seconds: true) } ?? ""),
                    Theme.dyn(0x9FF0CF, 0x0C7A4F), P.up)
        }()
        return HStack(spacing: 6) {
            Circle().fill(state.2).frame(width: 7, height: 7).shadow(color: updatedAt == nil ? .clear : state.2, radius: 4)
            Text(state.0).font(.system(size: 11.5, weight: .bold)).foregroundStyle(state.1).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 28)
    }

    /// .fl (phone): a 3-column grid: All Events, High Impact, Medium / Low, Currencies, Countries.
    private var chips: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
        let allOn = impact == "all" && currencies.isEmpty && countries.isEmpty
        return LazyVGrid(columns: cols, spacing: 6) {
            chip(NSLocalizedString("calendar.all", comment: ""), dot: nil, on: allOn) {
                impact = "all"; currencies = []; countries = []; visible = 10
            }
            chip(NSLocalizedString("calendar.high", comment: ""), dot: P.hi, on: impact == "high") { impact = impact == "high" ? "all" : "high"; visible = 10 }
            chip(NSLocalizedString("calendar.medium", comment: ""), dot: P.md, on: impact == "medium") { impact = impact == "medium" ? "all" : "medium"; visible = 10 }
            chip(NSLocalizedString("calendar.low", comment: ""), dot: P.lo, on: impact == "low") { impact = impact == "low" ? "all" : "low"; visible = 10 }
            chip(NSLocalizedString("cal.currencies", comment: ""), dot: nil, on: !currencies.isEmpty, count: currencies.count, menu: true) { picker = "cur" }
            chip(NSLocalizedString("cal.countries", comment: ""), dot: nil, on: !countries.isEmpty, count: countries.count, menu: true) { picker = "cty" }
        }
    }

    /// .chip: 34 high, radius 9, #12404d edge on #041d26, 12.5 semibold; pressed = cyan edge, soft cyan fill and glow.
    private func chip(_ title: String, dot: Color?, on: Bool, count: Int = 0, menu: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6).shadow(color: dot, radius: 4) }
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                if count > 0 {
                    Text("\(count)").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.hex(0x02141B))
                        .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
                        .background(P.cyan, in: Capsule())
                }
                if menu { Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)) }
            }
            .foregroundStyle(on ? P.tx : P.chipTx)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(on ? AnyShapeStyle(LinearGradient(colors: [Theme.hex(0x35E6F2, 0.16), Theme.hex(0x00C6C4, 0.08)],
                                                          startPoint: .top, endPoint: .bottom))
                           : AnyShapeStyle(P.chipBg),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(on ? P.cyan : P.chipBd, lineWidth: 1))
            .shadow(color: on ? Theme.hex(0x35E6F2, 0.3) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var staleBanner: some View {
        Text(String(format: NSLocalizedString("ux3.cal.stale.banner", comment: ""), updatedAt.map { time($0, seconds: true) } ?? "--:--"))
            .font(.system(size: 13)).foregroundStyle(Theme.dyn(0xFFE2AD, 0x7A4D00)).lineSpacing(2)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.hex(0xFFB72E, 0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.hex(0xFFB72E, 0.45), lineWidth: 1))
    }

    @ViewBuilder private var eventsBlock: some View {
        if !loaded && errorKey != key {
            // first answer for this day on its way: three quiet cards in the event cards' shape
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in skeletonCard }
            }
        } else if !loaded {
            emptyBox(title: "ux3.cal.unavailable", sub: "ux3.cal.unavailable.sub", retry: true)
        } else if filtered.isEmpty {
            if dayEvents.isEmpty { emptyBox(title: "ux3.cal.noevents", sub: "ux3.cal.noevents.sub") }
            else { emptyBox(title: "cal.nomatch", sub: "ux3.cal.nomatch.sub") }
        } else {
            let list = Array(filtered.prefix(visible))
            VStack(spacing: 10) {
                ForEach(list) { e in eventCard(e) }
            }
            loadMore
            Text(String(format: NSLocalizedString("cal.showing", comment: ""), list.count, filtered.count))
                .font(.system(size: 12.5)).foregroundStyle(P.mu).frame(maxWidth: .infinity).padding(.top, 2)
        }
    }

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                QuietSkeleton(width: 52, height: 22, radius: 7)
                QuietSkeleton(width: 56, height: 16, radius: 4)
                Spacer()
                QuietSkeleton(width: 26, height: 18, radius: 3)
            }
            QuietSkeleton(width: 200, height: 15, radius: 5)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in QuietSkeleton(width: 70, height: 40, radius: 9) }
            }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(P.bd, lineWidth: 1))
    }

    private func emptyBox(title: String, sub: String, retry: Bool = false) -> some View {
        VStack(spacing: 6) {
            Text(LocalizedStringKey(title)).font(.system(size: 16, weight: .bold)).foregroundStyle(P.tx).multilineTextAlignment(.center)
            Text(LocalizedStringKey(sub)).font(.system(size: 14)).foregroundStyle(P.mu).multilineTextAlignment(.center)
            if retry {
                Button { Task { await load(manual: true) } } label: { actionLabel("ux3.cal.retry", icon: "arrow.clockwise", on: false) }
                    .buttonStyle(.plain).padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.vertical, 50)
    }

    /// tbody.ev (phone card): time chip, flag + currency, impact meter, the 40 pt chevron; the name 15.5; Actual / Forecast /
    /// Previous in small boxes; open = cyan edge and the details box.
    private func eventCard(_ e: CalendarEvent) -> some View {
        let open = expanded.contains(e.id)
        let past = (e.date ?? .distantFuture) <= now
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    if open { expanded.remove(e.id) } else { expanded.insert(e.id) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Text(e.date.map { time($0) } ?? "")
                            .font(.system(size: 13.5, design: .monospaced))
                            .foregroundStyle(past ? P.mu2 : Theme.dyn(0xD6EEF2, 0x235D9B))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.hex(0x00C6C4, 0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        HStack(spacing: 8) {
                            Text(Self.flag(e.country_code)).font(.system(size: 16))
                            Text(e.currency).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(P.tx)
                        }
                        Spacer(minLength: 4)
                        bars(e.impact)
                        Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.dyn(0xA9C3DD, 0x285D95))
                            .rotationEffect(.degrees(open ? 180 : 0))
                            .frame(width: 40, height: 40)
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    nameLine(e, past: past)
                        .padding(.top, 8).padding(.bottom, 10).padding(.trailing, 8)
                    HStack(spacing: 8) {
                        valueBox("calendar.actual", e.actual, tint: actualTint(e))
                        valueBox("calendar.forecast", e.forecast, tint: nil)
                        valueBox("calendar.previous", e.previous, tint: nil)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.leading, 14).padding(.trailing, 6).padding(.top, 10).padding(.bottom, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(open ? Theme.hex(0x35E6F2, 0.06) : Color.clear)
            if open { details(e, past: past).padding(.horizontal, 12).padding(.bottom, 12) }
        }
        .background(P.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(open ? Theme.hex(0x35E6F2, 0.45) : P.bd, lineWidth: 1))
    }

    /// The name (15.5 semibold) with LIVE (pink, pulsing dot) for 15 minutes after the time until a figure is out, or SOON
    /// (cyan) in the last 30 minutes before.
    private func nameLine(_ e: CalendarEvent, past: Bool) -> some View {
        let d = e.date ?? .distantFuture
        let noActual = (e.actual ?? "").isEmpty
        let live = past && now.timeIntervalSince(d) < 15 * 60 && noActual
        let soon = !past && d.timeIntervalSince(now) < 30 * 60
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(e.event).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Theme.dyn(0xEEF6F9, 0x0059BE))
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            if live {
                HStack(spacing: 5) {
                    Circle().fill(P.hi).frame(width: 6, height: 6).opacity(Int(now.timeIntervalSince1970) % 2 == 0 ? 1 : 0.3)
                    Text("cal.livetag").font(.system(size: 10.5, weight: .heavy)).kerning(0.6)
                }
                .foregroundStyle(Theme.dyn(0xFF7C9D, 0xBE0030))
                .padding(.horizontal, 7).frame(height: 19)
                .background(Theme.hex(0xFF3D72, 0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if soon {
                Text("cal.soon").font(.system(size: 10.5, weight: .heavy)).kerning(0.4).foregroundStyle(P.cyan)
                    .padding(.horizontal, 7).frame(height: 19)
                    .background(Theme.hex(0x35E6F2, 0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    /// td.v (phone): an uppercase 10.5 label over the 14 mono figure, in a #05202b box (radius 9); "—" when missing.
    private func valueBox(_ key: LocalizedStringKey, _ v: String?, tint: Color?) -> some View {
        let has = !(v ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 3) {
            Text(key).font(.system(size: 10.5, weight: .bold)).kerning(0.6).textCase(.uppercase).foregroundStyle(P.mu).lineLimit(1)
            Text(has ? (v ?? "") : "—").font(.system(size: 14, design: .monospaced))
                .foregroundStyle(has ? (tint ?? Theme.dyn(0xDBE8F6, 0x265D98)) : P.mu2).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(P.box, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// Actual against forecast, same unit: up green, down pink (web dirOf).
    private func actualTint(_ e: CalendarEvent) -> Color? {
        guard let a = Self.num(e.actual), let f = Self.num(e.forecast), a.unit == f.unit else { return nil }
        return a.value > f.value ? P.up : (a.value < f.value ? P.dn : nil)
    }

    static func num(_ s: String?) -> (value: Double, unit: String)? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        var digits = ""
        var rest = Substring(s)
        while let c = rest.first, c.isNumber || c == "." || c == "-" || c == "+" || c == "," {
            if c != "," { digits.append(c) }
            rest = rest.dropFirst()
        }
        guard let v = Double(digits) else { return nil }
        return (v, rest.trimmingCharacters(in: .whitespaces).uppercased())
    }

    /// .det (phone): one column; cyan uppercase headings, muted terms, the two action buttons side by side.
    private func details(_ e: CalendarEvent, past: Bool) -> some View {
        let released = !(e.actual ?? "").isEmpty
        let on = saved.contains(e.id)
        return VStack(alignment: .leading, spacing: 14) {
            detailBlock("cal.about", [
                ("cal.country", Self.flag(e.country_code) + " " + e.country),
                ("cal.currency", e.currency.isEmpty ? "—" : e.currency),
                ("cal.impact", NSLocalizedString("cal.impact." + e.impact, comment: "")),
                ("cal.status", NSLocalizedString(released ? "cal.released" : (past ? "cal.awaiting" : "cal.scheduled"), comment: "")),
            ])
            if let d = e.date {
                detailBlock("cal.release", [
                    ("cal.yourzone", time(d) + " · " + zone.identifier.replacingOccurrences(of: "_", with: " ")),
                    ("UTC", Self.utc(d)),
                    ("cal.source", "MQLBlue"),
                ])
            }
            HStack(spacing: 8) {
                Button { Task { await toggle(e) } } label: {
                    actionLabel(on ? "cal.alert.set" : "cal.alert", icon: on ? "bell.fill" : "bell", on: on)
                }
                .buttonStyle(.plain)
                .disabled(past)
                .opacity(past ? 0.5 : 1)
                if let url = Self.icsFile(e) {
                    ShareLink(item: url) { actionLabel("cal.addcal", icon: "calendar.badge.plus", on: false) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.dyn(0x020E14, 0xF0F3F9, 0.55, 0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(P.bd, lineWidth: 1))
    }

    /// .ab: 42 high, radius 10, #1a4673 edge on #06203c, 13 semibold; pressed = cyan.
    private func actionLabel(_ key: String, icon: String, on: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 15))
            Text(LocalizedStringKey(key)).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .foregroundStyle(on ? P.cyan : Theme.dyn(0xDBECEF, 0x285D95))
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 42)
        .background(on ? Theme.hex(0x35E6F2, 0.1) : Theme.dyn(0x06203C, 0xEAF0F7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(on ? P.cyan : Theme.dyn(0x1A4673, 0xC6D6E7), lineWidth: 1))
    }

    private func detailBlock(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .semibold)).kerning(0.5).foregroundStyle(P.cyan).textCase(.uppercase)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(LocalizedStringKey(r.0)).font(.system(size: 13)).foregroundStyle(P.mu).frame(width: 84, alignment: .leading)
                    Text(r.1).font(.system(size: 13)).foregroundStyle(Theme.dyn(0xE3F0F2, 0x1D5CA1))
                }
            }
        }
    }

    /// .lm: a 46 pt pill with a cyan edge between two fading cyan rules; "All events loaded" when nothing is left.
    private var loadMore: some View {
        let done = visible >= filtered.count
        return HStack(spacing: 12) {
            LinearGradient(colors: [.clear, Theme.hex(0x35E6F2, 0.6)], startPoint: .leading, endPoint: .trailing).frame(height: 1)
            Button { visible += 10 } label: {
                HStack(spacing: 10) {
                    Text(LocalizedStringKey(done ? "cal.allloaded" : "cal.loadmore")).font(.system(size: 14.5, weight: .bold))
                    if !done { Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold)) }
                }
                .foregroundStyle(P.tx)
                .padding(.horizontal, 24).frame(height: 46)
                .background(Theme.hex(0x35E6F2, 0.06), in: Capsule())
                .overlay(Capsule().stroke(done ? Theme.dyn(0x1B4A75, 0xC6D6E7) : P.cyan, lineWidth: 1))
                .shadow(color: done ? .clear : Theme.hex(0x35E6F2, 0.35), radius: 10)
            }
            .buttonStyle(.plain)
            .disabled(done)
            .opacity(done ? 0.55 : 1)
            .fixedSize()
            LinearGradient(colors: [Theme.hex(0x35E6F2, 0.6), .clear], startPoint: .leading, endPoint: .trailing).frame(height: 1)
        }
        .padding(.top, 14)
    }

    /// Four rising bars, lit by impact (.imp: 5 pt wide, 35/58/80/100 % of 20).
    private func bars(_ impact: String) -> some View {
        let lit = impact == "high" ? 4 : (impact == "medium" ? 3 : (impact == "low" ? 2 : 0))
        let color = Self.impactColor(impact)
        let heights: [CGFloat] = [0.35, 0.58, 0.8, 1]
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5).fill(i < lit ? color : Theme.dyn(0x1D3653, 0xD5E2EE)).frame(width: 5, height: 20 * heights[i])
            }
        }
        .frame(height: 20, alignment: .bottom)
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: bottom cards

    private func bottomCard<Title: View, Content: View>(icon: String, @ViewBuilder title: () -> Title, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(P.cyan)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().stroke(P.cyan, lineWidth: 1.5))
                    .shadow(color: Theme.hex(0x35E6F2, 0.35), radius: 7)
                title()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(P.bd, lineWidth: 1))
    }

    /// Market Clock: London, New York, Dubai, Tokyo in a 2 × 2 grid (colour dot, 20 pt mono time, OPEN / CLOSED);
    /// "Your time 13:43" on the right of the title.
    private var marketClock: some View {
        let cities: [(String, String, UInt32, Double, Double)] = [
            ("London", "Europe/London", 0x35E6F2, 8, 16.5), ("New York", "America/New_York", 0xFF3D72, 9.5, 16),
            ("Dubai", "Asia/Dubai", 0x2BB6C9, 10, 14), ("Tokyo", "Asia/Tokyo", 0x2BB6C9, 9, 15),
        ]
        return bottomCard(icon: "clock") {
            HStack {
                Text("cal.clock").font(.system(size: 17, weight: .bold)).foregroundStyle(P.tx)
                Spacer(minLength: 4)
                Text(String(format: NSLocalizedString("ux3.cal.yourtime", comment: ""), time(now)))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(P.mu)
            }
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    cityCell(cities[0])
                    Rectangle().fill(P.bd).frame(width: 1)
                    cityCell(cities[1])
                }
                Rectangle().fill(P.bd).frame(height: 1)
                HStack(spacing: 0) {
                    cityCell(cities[2])
                    Rectangle().fill(P.bd).frame(width: 1)
                    cityCell(cities[3])
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.dyn(0x020E14, 0xF0F3F9, 0.4, 0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(P.bd, lineWidth: 1))
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    private func cityCell(_ c: (String, String, UInt32, Double, Double)) -> some View {
        var gc = Calendar(identifier: .gregorian)
        gc.timeZone = TimeZone(identifier: c.1) ?? .current
        let p = gc.dateComponents([.weekday, .hour, .minute], from: now)
        let hh = Double(p.hour ?? 0) + Double(p.minute ?? 0) / 60
        let wd = p.weekday ?? 2
        let open = wd != 1 && wd != 7 && hh >= c.3 && hh < c.4
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Theme.hex(c.2)).frame(width: 9, height: 9).shadow(color: Theme.hex(c.2), radius: 4)
                Text(c.0).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(P.tx).lineLimit(1)
            }
            Text(Self.clock(now, c.1)).font(.system(size: 20, weight: .semibold, design: .monospaced)).foregroundStyle(P.tx)
                .padding(.top, 8)
            Text(LocalizedStringKey(open ? "ux3.cal.open" : "ux3.cal.closed"))
                .font(.system(size: 11, weight: .bold)).kerning(0.6).textCase(.uppercase)
                .foregroundStyle(open ? P.up : P.mu2)
                .padding(.top, 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Market Impact: "(Today)" or "(Nov 18)", a 150 pt donut with the total and "Events", and the High / Medium / Low legend
    /// (dot, name, share, count) in 42 pt rows.
    private var marketImpact: some View {
        let list = dayEvents
        let counts: [(String, Int, Color)] = [("high", list.filter { $0.impact == "high" }.count, P.hi),
                                              ("medium", list.filter { $0.impact == "medium" }.count, P.md),
                                              ("low", list.filter { $0.impact == "low" }.count, P.lo)]
        let total = counts.reduce(0) { $0 + $1.1 }
        return bottomCard(icon: "chart.pie") {
            (Text("ux3.cal.mi").foregroundColor(P.tx)
             + Text(verbatim: " ")
             + Text(isToday ? NSLocalizedString("ux3.cal.mi.today", comment: "") : "(\(dayString(day, "MMM d")))")
                .font(.system(size: 17, weight: .medium)).foregroundColor(P.mu))
                .font(.system(size: 17, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.8)
        } content: {
            VStack(spacing: 16) {
                donut(counts, total: total)
                VStack(spacing: 0) {
                    ForEach(Array(counts.enumerated()), id: \.offset) { i, c in
                        HStack(spacing: 10) {
                            Circle().fill(c.2).frame(width: 10, height: 10)
                            Text(LocalizedStringKey("cal.impact." + c.0)).font(.system(size: 14.5)).foregroundStyle(P.tx)
                            Spacer(minLength: 4)
                            Text(loaded && total > 0 ? "\(Int((Double(c.1) / Double(total) * 100).rounded()))%" : "")
                                .font(.system(size: 12)).foregroundStyle(P.mu).frame(width: 44, alignment: .trailing)
                            if loaded {
                                Text("\(c.1)").font(.system(size: 17, weight: .bold, design: .monospaced)).foregroundStyle(P.tx)
                                    .frame(minWidth: 24, alignment: .trailing)
                            } else {
                                QuietSkeleton(width: 22, height: 16, radius: 4)
                            }
                        }
                        .frame(height: 42)
                        .overlay(alignment: .bottom) { if i < counts.count - 1 { Rectangle().fill(P.bd).frame(height: 1) } }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func donut(_ counts: [(String, Int, Color)], total: Int) -> some View {
        var segs: [(from: CGFloat, to: CGFloat, color: Color)] = []
        if total > 0 {
            var at: CGFloat = 0
            for c in counts where c.1 > 0 {
                let len = CGFloat(c.1) / CGFloat(total)
                let gap: CGFloat = len > 0.01 ? 0.0066 : 0
                segs.append((at, at + max(len - gap, 0), c.2))
                at += len
            }
        }
        return ZStack {
            Circle().stroke(Theme.dyn(0x0E2D4D, 0xDCE6F0), lineWidth: 12)
            ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                Circle().trim(from: s.from, to: s.to).stroke(s.color, lineWidth: 12).rotationEffect(.degrees(-90))
            }
            VStack(spacing: 4) {
                if loaded {
                    Text("\(total)").font(.system(size: 32, weight: .heavy, design: .monospaced)).foregroundStyle(P.tx)
                } else {
                    QuietSkeleton(width: 40, height: 30, radius: 6)
                }
                Text("ux3.cal.events").font(.system(size: 12.5)).foregroundStyle(P.mu)
            }
        }
        .padding(6)
        .frame(width: 150, height: 150)
        .shadow(color: Theme.hex(0x00C6C4, 0.3), radius: 8)
    }

    // MARK: helpers

    private func time(_ d: Date, seconds: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        f.timeZone = zone
        return f.string(from: d)
    }

    private func dayString(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate(format)
        f.timeZone = zone
        return f.string(from: d)
    }

    /// "15:30", or "Wed 15:30" when it is not today.
    private func nextTime(_ d: Date) -> String {
        cal.isDate(d, inSameDayAs: now) ? time(d) : dayString(d, "EEE") + " " + time(d)
    }

    /// "1h 12m", or "4m 05s" in the last hour (web tickNext).
    static func nextCountdown(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? "\(h)h \(m)m" : String(format: "%dm %02ds", m, sec)
    }

    static func clock(_ d: Date, _ tz: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: tz)
        return f.string(from: d)
    }

    static func utc(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    static func flag(_ code: String) -> String {
        let c = code.uppercased()
        if c == "EU" { return "🇪🇺" }
        guard c.count == 2, c.allSatisfy({ $0.isLetter && $0.isASCII }) else { return "🏳️" }
        return c.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map { String($0) }.joined()
    }

    /// A one-event .ics file for "Add to calendar" (shared to the Calendar app, like the website's download).
    static func icsFile(_ e: CalendarEvent) -> URL? {
        guard let d = e.date else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        let start = f.string(from: d), end = f.string(from: d.addingTimeInterval(1800))
        let title = "\(e.currency) \(e.event)".replacingOccurrences(of: ",", with: "\\,")
        let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//TRADEFLOR//Calendar//EN\r\nBEGIN:VEVENT\r\nUID:\(e.id)@tradeflor\r\nDTSTAMP:\(f.string(from: Date()))\r\nDTSTART:\(start)\r\nDTEND:\(end)\r\nSUMMARY:\(title)\r\nDESCRIPTION:Impact: \(e.impact)\r\nBEGIN:VALARM\r\nTRIGGER:-PT15M\r\nACTION:DISPLAY\r\nDESCRIPTION:\(title)\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let safe = e.id.replacingOccurrences(of: "/", with: "-").prefix(60)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tradeflor-\(safe).ics")
        try? ics.data(using: .utf8)?.write(to: url)
        return url
    }

    /// The open day (in the chosen zone). A new day or zone shows the skeleton until it arrives; the same key refreshes
    /// quietly, and a failed refresh keeps the last events with the STALE line (web load()).
    private func load(manual: Bool) async {
        guard !token.isEmpty else { return }
        let k = key
        let from = day
        let to = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        do {
            let list = try await APIClient.shared.calendar(token: token, from: from, to: to)
            guard k == key else { return }
            if shownKey != k { expanded = [] }
            events = list
            shownKey = k
            errorKey = ""
            failed = false
            updatedAt = Date()
            if manual { toast = NSLocalizedString("cal.refreshed", comment: "") }
        } catch {
            guard k == key else { return }
            failed = true
            if shownKey != k { errorKey = k }
            if manual { toast = NSLocalizedString("cal.refresh.failed", comment: "") }
        }
        if let s = try? await APIClient.shared.savedEvents(token: token) { saved = Set(s.map(\.event_key)) }
    }

    /// The next event, from an hour ago to 36 hours ahead, whichever day is open (web loadNext).
    private func loadNext() async {
        guard !token.isEmpty else { return }
        let n = Date()
        if let list = try? await APIClient.shared.calendar(token: token, from: n.addingTimeInterval(-3600), to: n.addingTimeInterval(36 * 3600)) {
            nextList = list
        }
    }

    private func toggle(_ e: CalendarEvent) async {
        if saved.contains(e.id) {
            if (try? await APIClient.shared.removeSavedEvent(token: token, key: e.id)) != nil {
                saved.remove(e.id)
                toast = NSLocalizedString("ux3.cal.alert.removed", comment: "")
            }
        } else if (try? await APIClient.shared.saveEvent(token: token, e)) != nil {
            saved.insert(e.id)
            toast = NSLocalizedString("cal.alert.toast", comment: "")
        }
    }
}

/// The filter sheet (web .pop on a phone: a bottom sheet with its title and Clear, 48 pt rows with a checkbox and the day's
/// count, and the full-width gradient "Show results").
struct MultiPickSheet: View {
    let title: String
    let options: [(String, String, Int)]
    @Binding var selection: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(CalendarView.P.mu)
                Spacer()
                Button("cal.clear") { draft = [] }.font(.system(size: 14, weight: .bold)).foregroundStyle(CalendarView.P.cyan)
            }
            .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 14)
            Rectangle().fill(CalendarView.P.bd).frame(height: 1)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                        Button {
                            if draft.contains(o.0) { draft.remove(o.0) } else { draft.insert(o.0) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: draft.contains(o.0) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 18)).foregroundStyle(CalendarView.P.cyan)
                                Text(o.1).font(.system(size: 15)).foregroundStyle(CalendarView.P.tx)
                                Spacer()
                                if o.2 > 0 {
                                    Text("\(o.2)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(CalendarView.P.mu)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            Rectangle().fill(CalendarView.P.bd).frame(height: 1)
            Button { selection = draft; dismiss() } label: {
                Text("cal.show").font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.hex(0x02141B))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(LinearGradient(colors: [Theme.hex(0x35E6F2), Theme.hex(0x00C6C4)], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .background(Theme.dyn(0x051F28, 0xFFFFFF).ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { draft = selection }
    }
}
