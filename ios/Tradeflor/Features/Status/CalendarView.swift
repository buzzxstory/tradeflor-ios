import SwiftUI

/// The Economic Calendar (website approved-calendar/calendar.html|js): title, day summary (Today, High / Medium / Low,
/// Next Event countdown), LIVE badge, impact chips, Currencies / Countries / Time zone filters, day navigation,
/// event cards that expand ("About this event", "Release time", Set alert, Add to calendar), Load More,
/// Market Clock and Market Impact (Today), and the footer.
struct CalendarView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var events: [CalendarEvent] = []
    @State private var saved: Set<String> = []
    @State private var impact = "all" // all | high | medium | low
    @State private var currencies: Set<String> = []
    @State private var countries: Set<String> = []
    @State private var tzID = "" // "" = Auto (this device)
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var loading = true
    @State private var failed = false
    @State private var updatedAt: Date?
    @State private var now = Date()
    @State private var expanded: String?
    @State private var visible = 30
    @State private var picker: String? // "cur" | "cty"
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

    /// Low impact in the app's turquoise (web 0627f86: --lo #199CEB -> #2bb6c9); high red and medium amber unchanged.
    static let lowImpact = Theme.hex(0x2BB6C9)
    static func impactColor(_ i: String) -> Color { i == "low" ? lowImpact : TradeFlorView.impactColor(i) }

    private var token: String { store.session?.token ?? "" }
    private var zone: TimeZone { tzID.isEmpty ? .current : (TimeZone(identifier: tzID) ?? .current) }
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }
    private var dayEvents: [CalendarEvent] {
        events.filter { e in e.date.map { cal.isDate($0, inSameDayAs: day) } ?? false }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }
    private var filtered: [CalendarEvent] {
        dayEvents.filter { e in
            (impact == "all" || e.impact == impact)
                && (currencies.isEmpty || currencies.contains(e.currency))
                && (countries.isEmpty || countries.contains(e.country_code.uppercased()))
        }
    }
    private var next: CalendarEvent? {
        events.filter { ($0.date ?? .distantPast) > now }.min { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }
    private var seenCurrencies: [String] {
        Array(Set(Self.allCurrencies + events.map(\.currency).filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3, height: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("calendar.heading").font(.system(size: 28, weight: .heavy)).foregroundStyle(Theme.text)
                            Text("calendar.subtitle").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                    }
                    counters
                    if let n = next, let d = n.date { nextCard(n, d) }
                    liveBadge
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            FilterChip(title: NSLocalizedString("calendar.all", comment: ""), selected: impact == "all") { impact = "all" }
                            FilterChip(title: NSLocalizedString("calendar.high", comment: ""), icon: "circle.fill", iconColor: Theme.danger,
                                       selected: impact == "high") { impact = "high" }
                            FilterChip(title: NSLocalizedString("calendar.medium", comment: ""), icon: "circle.fill", iconColor: Theme.gold,
                                       selected: impact == "medium") { impact = "medium" }
                            FilterChip(title: NSLocalizedString("calendar.low", comment: ""), icon: "circle.fill", iconColor: Self.lowImpact,
                                       selected: impact == "low") { impact = "low" }
                            FilterChip(title: currencies.isEmpty ? NSLocalizedString("cal.currencies", comment: "")
                                        : String(format: NSLocalizedString("cal.currencies.n", comment: ""), currencies.count),
                                       icon: "chevron.down", iconColor: Theme.faint, selected: !currencies.isEmpty) { picker = "cur" }
                            FilterChip(title: countries.isEmpty ? NSLocalizedString("cal.countries", comment: "")
                                        : String(format: NSLocalizedString("cal.countries.n", comment: ""), countries.count),
                                       icon: "chevron.down", iconColor: Theme.faint, selected: !countries.isEmpty) { picker = "cty" }
                        }
                    }
                    dayNav
                    if loading && events.isEmpty {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 30)
                    } else if filtered.isEmpty {
                        VStack(spacing: 6) {
                            Text(LocalizedStringKey(failed ? "calendar.error" : "cal.nomatch")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("cal.nomatch.sub").font(.system(size: 12)).foregroundStyle(Theme.faint)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        TFCard {
                            let list = Array(filtered.prefix(visible))
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                                row(e)
                                if i < list.count - 1 { Rectangle().fill(Theme.rowRule).frame(height: 1) }
                            }
                        }
                        Text(String(format: NSLocalizedString("cal.showing", comment: ""), min(visible, filtered.count), filtered.count))
                            .font(.system(size: 12)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity)
                        Button { visible += 30 } label: {
                            Text(LocalizedStringKey(visible >= filtered.count ? "cal.allloaded" : "cal.loadmore"))
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderStrong, lineWidth: 1))
                        }
                        .disabled(visible >= filtered.count)
                    }
                    marketClock
                    marketImpact
                    Text("cal.footer").font(.system(size: 11)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity).padding(.top, 6)
                }
                .padding(16)
            }
            .refreshable { await load(manual: true) }
            .background(Starfield())
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.system(size: 13)).foregroundStyle(Theme.text).padding(12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderActive, lineWidth: 1))
                        .padding(16)
                        .onTapGesture { self.toast = nil }
                }
            }
        }
        .task(id: day) { await load(manual: false) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                now = Date()
            }
        }
        .sheet(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } })) {
            if picker == "cur" {
                MultiPickSheet(title: NSLocalizedString("cal.currencies", comment: ""),
                               options: seenCurrencies.map { ($0, $0) }, selection: $currencies)
            } else {
                MultiPickSheet(title: NSLocalizedString("cal.countries", comment: ""),
                               options: Self.allCountries.map { ($0.code, Self.flag($0.code) + " " + $0.name) }, selection: $countries)
            }
        }
    }

    // MARK: pieces

    private var counters: some View {
        let today = events.filter { e in e.date.map { cal.isDateInToday($0) } ?? false }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            counter(icon: "calendar", tint: Theme.accent, title: NSLocalizedString("calendar.today", comment: ""),
                    value: Date().formatted(Date.FormatStyle(calendar: Calendar(identifier: .gregorian), timeZone: zone).day().month(.abbreviated).year()))
            counter(icon: "chart.bar.fill", tint: Theme.danger, title: NSLocalizedString("calendar.high", comment: ""),
                    value: "\(today.filter { $0.impact == "high" }.count)")
            counter(icon: "chart.bar.fill", tint: Theme.gold, title: NSLocalizedString("calendar.medium", comment: ""),
                    value: "\(today.filter { $0.impact == "medium" }.count)")
            counter(icon: "chart.bar.fill", tint: Self.lowImpact, title: NSLocalizedString("calendar.low", comment: ""),
                    value: "\(today.filter { $0.impact == "low" }.count)")
        }
    }

    private func counter(icon: String, tint: Color, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(tint)
                .frame(width: 34, height: 34).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
                Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderStrong, lineWidth: 1))
    }

    private func nextCard(_ e: CalendarEvent, _ d: Date) -> some View {
        HStack(spacing: 10) {
            Text(Self.flag(e.country_code)).font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text("calendar.next").font(.system(size: 11)).foregroundStyle(Theme.faint)
                Text(e.event).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(time(d)) · \(TradeFlorView.countdown(d.timeIntervalSince(now)))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Circle().trim(from: 0, to: 0.75).stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 34, height: 34).rotationEffect(.degrees(-90))
        }
        .padding(12)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderStrong, lineWidth: 1))
    }

    private var liveBadge: some View {
        HStack(spacing: 8) {
            Menu {
                Button { tzID = "" } label: { Text(String(format: NSLocalizedString("cal.tz.auto", comment: ""), TimeZone.current.identifier)) }
                ForEach(Self.zones, id: \.self) { z in
                    Button(z.split(separator: "/").last.map { String($0).replacingOccurrences(of: "_", with: " ") } ?? z) { tzID = z }
                }
            } label: {
                Label(tzID.isEmpty ? String(format: NSLocalizedString("cal.tz.auto", comment: ""), TimeZone.current.identifier)
                                   : tzID.replacingOccurrences(of: "_", with: " "), systemImage: "globe")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 10).frame(height: 28).background(Theme.chip, in: Capsule())
                    .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
            }
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(failed ? Theme.gold : Theme.buy).frame(width: 6, height: 6)
                Text(failed ? NSLocalizedString("cal.stale", comment: "")
                     : String(format: NSLocalizedString("cal.live", comment: ""), updatedAt.map { time($0) } ?? "--:--"))
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(failed ? Theme.gold : Theme.buy)
            }
        }
    }

    private var dayNav: some View {
        HStack(spacing: 8) {
            navButton("chevron.backward", "cal.prev") { day = cal.date(byAdding: .day, value: -1, to: day) ?? day; visible = 30 }
            Button { day = cal.startOfDay(for: Date()); visible = 30 } label: {
                Text("calendar.today").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).frame(height: 32).background(Theme.chip, in: Capsule())
                    .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
            }
            DatePicker("cal.pick", selection: Binding(get: { day }, set: { day = cal.startOfDay(for: $0); visible = 30 }), displayedComponents: .date)
                .labelsHidden()
                .environment(\.calendar, Calendar(identifier: .gregorian))
                .tint(Theme.accent)
            Spacer()
            navButton("chevron.forward", "cal.next") { day = cal.date(byAdding: .day, value: 1, to: day) ?? day; visible = 30 }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func navButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                .frame(width: 32, height: 32).background(Theme.chip, in: Circle()).overlay(Circle().stroke(Theme.borderStrong, lineWidth: 1))
        }
        .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    private func row(_ e: CalendarEvent) -> some View {
        let open = expanded == e.id
        let released = !(e.actual ?? "").isEmpty
        let past = (e.date ?? .distantFuture) < now
        return VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded = open ? nil : e.id } } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e.date.map { time($0) } ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint)
                        HStack(spacing: 4) {
                            Text(Self.flag(e.country_code)).font(.system(size: 14))
                            Text(e.currency).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.text)
                        }
                    }
                    .frame(width: 62, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(e.event).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            if let d = e.date, abs(d.timeIntervalSince(now)) < 900, !released {
                                Text(LocalizedStringKey(d > now ? "cal.soon" : "cal.livetag")).font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(Theme.onAccent).padding(.horizontal, 5).padding(.vertical, 2).background(Theme.accent, in: Capsule())
                            }
                        }
                        HStack(spacing: 12) {
                            value("calendar.actual", e.actual, highlight: true)
                            value("calendar.forecast", e.forecast)
                            value("calendar.previous", e.previous)
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(spacing: 8) {
                        bars(e.impact)
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.faint)
                    }
                }
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 10) {
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
                    HStack(spacing: 10) {
                        Button { Task { await toggle(e) } } label: {
                            Label(LocalizedStringKey(saved.contains(e.id) ? "cal.alert.set" : "cal.alert"),
                                  systemImage: saved.contains(e.id) ? "bell.fill" : "bell")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(saved.contains(e.id) ? Theme.onAccent : Theme.accent)
                                .padding(.horizontal, 14).frame(height: 34)
                                .background(saved.contains(e.id) ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.chip), in: Capsule())
                                .overlay(Capsule().stroke(Theme.borderActive, lineWidth: 1))
                        }
                        .disabled(past)
                        if let url = Self.icsFile(e) {
                            ShareLink(item: url) {
                                Label("cal.addcal", systemImage: "calendar.badge.plus").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.accent).padding(.horizontal, 14).frame(height: 34)
                                    .background(Theme.chip, in: Capsule()).overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
                            }
                        }
                    }
                }
                .padding(.leading, 72)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func detailBlock(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title)).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent).textCase(.uppercase)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(r.0)).font(.system(size: 12)).foregroundStyle(Theme.faint).frame(width: 80, alignment: .leading)
                    Text(r.1).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                }
            }
        }
    }

    @ViewBuilder private func value(_ key: LocalizedStringKey, _ v: String?, highlight: Bool = false) -> some View {
        if let v, !v.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(key).font(.system(size: 9.5)).foregroundStyle(Theme.faint)
                Text(v).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(highlight ? (v.hasPrefix("-") ? Theme.danger : Theme.buy) : Theme.text)
            }
        }
    }

    /// Four rising bars, lit by impact (the website's impact meter).
    private func bars(_ impact: String) -> some View {
        let lit = impact == "high" ? 4 : (impact == "medium" ? 3 : (impact == "low" ? 2 : 0))
        let color = Self.impactColor(impact)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(i < lit ? color : Theme.faint.opacity(0.25)).frame(width: 3, height: CGFloat(5 + i * 3))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var marketClock: some View {
        let cities: [(String, String)] = [("Sydney", "Australia/Sydney"), ("Tokyo", "Asia/Tokyo"), ("London", "Europe/London"), ("New York", "America/New_York")]
        return VStack(alignment: .leading, spacing: 8) {
            Label("cal.clock", systemImage: "clock").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
            ForEach(Array(cities.enumerated()), id: \.offset) { _, c in
                HStack {
                    Text(c.0).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text(Self.clock(now, c.1)).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                }
            }
        }
        .padding(12)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderStrong, lineWidth: 1))
    }

    private var marketImpact: some View {
        let list = dayEvents
        let counts = [("high", list.filter { $0.impact == "high" }.count), ("medium", list.filter { $0.impact == "medium" }.count),
                      ("low", list.filter { $0.impact == "low" }.count)]
        let top = max(1, counts.map { $0.1 }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            Label("cal.impact.today", systemImage: "chart.pie").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
            ForEach(Array(counts.enumerated()), id: \.offset) { _, c in
                HStack(spacing: 8) {
                    Text(LocalizedStringKey("cal.impact." + c.0)).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 3).fill(Self.impactColor(c.0))
                            .frame(width: max(4, g.size.width * CGFloat(c.1) / CGFloat(top)))
                    }
                    .frame(height: 8)
                    Text("\(c.1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderStrong, lineWidth: 1))
    }

    // MARK: helpers

    private func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = zone
        return f.string(from: d)
    }

    static func clock(_ d: Date, _ tz: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: tz)
        return f.string(from: d)
    }

    static func utc(_ d: Date) -> String {
        let f = DateFormatter()
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

    private func load(manual: Bool) async {
        loading = true
        defer { loading = false }
        // the selected day, padded a day each side so other time zones still see their whole day
        let from = cal.date(byAdding: .day, value: -1, to: day) ?? day
        let to = cal.date(byAdding: .day, value: 2, to: day) ?? day
        do {
            events = try await APIClient.shared.calendar(token: token, from: from, to: to)
            failed = false
            updatedAt = Date()
            if manual { toast = NSLocalizedString("cal.refreshed", comment: "") }
        } catch {
            failed = true
            if manual { toast = NSLocalizedString("cal.refresh.failed", comment: "") }
        }
        saved = Set(((try? await APIClient.shared.savedEvents(token: token)) ?? []).map(\.event_key))
    }

    private func toggle(_ e: CalendarEvent) async {
        if saved.contains(e.id) {
            if (try? await APIClient.shared.removeSavedEvent(token: token, key: e.id)) != nil { saved.remove(e.id) }
        } else if (try? await APIClient.shared.saveEvent(token: token, e)) != nil {
            saved.insert(e.id)
            toast = NSLocalizedString("cal.alert.toast", comment: "")
        }
    }
}

/// Multi-select list with Clear / Show results (the calendar's Currencies and Countries filters).
struct MultiPickSheet: View {
    let title: String
    let options: [(String, String)]
    @Binding var selection: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                    Button {
                        if draft.contains(o.0) { draft.remove(o.0) } else { draft.insert(o.0) }
                    } label: {
                        HStack {
                            Text(o.1).foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: draft.contains(o.0) ? "checkmark.square.fill" : "square").foregroundStyle(Theme.accent)
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cal.clear") { draft = [] } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("cal.show") { selection = draft; dismiss() }.bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { draft = selection }
    }
}
