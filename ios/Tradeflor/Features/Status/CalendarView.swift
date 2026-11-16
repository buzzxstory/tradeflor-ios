import SwiftUI

/// The Economic Calendar (website CalendarView / 12-calendar.css): title and subtitle, the Today / High / Medium /
/// Low counters, the next event, impact filters, and the events by day with flag, currency, impact bars and values.
struct CalendarView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var events: [CalendarEvent] = []
    @State private var saved: Set<String> = []
    @State private var impact = "all" // all | high | medium | low
    @State private var loading = true
    @State private var failed = false
    @State private var now = Date()

    private var token: String { store.session?.token ?? "" }
    private var todays: [CalendarEvent] { events.filter { $0.date.map { Calendar.current.isDateInToday($0) } ?? false } }
    private var filtered: [CalendarEvent] { impact == "all" ? events : events.filter { $0.impact == impact } }
    private var next: CalendarEvent? {
        events.filter { ($0.date ?? .distantPast) > now }.min { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    struct DayGroup: Identifiable {
        let day: Date
        let items: [CalendarEvent]
        var id: Date { day }
    }

    private var days: [DayGroup] {
        let cal = Calendar.current
        let g = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date ?? Date()) }
        return g.keys.sorted().map { k in DayGroup(day: k, items: (g[k] ?? []).sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) }
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
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            FilterChip(title: NSLocalizedString("calendar.all", comment: ""), selected: impact == "all") { impact = "all" }
                            FilterChip(title: NSLocalizedString("calendar.high", comment: ""), icon: "circle.fill", iconColor: Theme.danger,
                                       selected: impact == "high") { impact = "high" }
                            FilterChip(title: NSLocalizedString("calendar.medium", comment: ""), icon: "circle.fill", iconColor: Theme.gold,
                                       selected: impact == "medium") { impact = "medium" }
                            FilterChip(title: NSLocalizedString("calendar.low", comment: ""), icon: "circle.fill", iconColor: Theme.hex(0x3B82F6),
                                       selected: impact == "low") { impact = "low" }
                        }
                    }
                    if loading && events.isEmpty {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 40)
                    } else if days.isEmpty {
                        Text(LocalizedStringKey(failed ? "calendar.error" : "calendar.empty")).font(.system(size: 13))
                            .foregroundStyle(Theme.faint).frame(maxWidth: .infinity).padding(.top, 30)
                    }
                    ForEach(days) { d in
                        Text(d.day, format: Date.FormatStyle(calendar: Calendar(identifier: .gregorian)).weekday(.wide).day().month(.wide))
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint).textCase(.uppercase)
                            .padding(.top, 6)
                        TFCard {
                            ForEach(Array(d.items.enumerated()), id: \.element.id) { i, e in
                                row(e)
                                if i < d.items.count - 1 { Rectangle().fill(Theme.rowRule).frame(height: 1) }
                            }
                        }
                    }
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
    }

    private var counters: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            counter(icon: "calendar", tint: Theme.accent, title: NSLocalizedString("calendar.today", comment: ""),
                    value: Date().formatted(Date.FormatStyle(calendar: Calendar(identifier: .gregorian)).day().month(.abbreviated).year()))
            counter(icon: "chart.bar.fill", tint: Theme.danger, title: NSLocalizedString("calendar.high", comment: ""),
                    value: "\(todays.filter { $0.impact == "high" }.count)")
            counter(icon: "chart.bar.fill", tint: Theme.gold, title: NSLocalizedString("calendar.medium", comment: ""),
                    value: "\(todays.filter { $0.impact == "medium" }.count)")
            counter(icon: "chart.bar.fill", tint: Theme.hex(0x3B82F6), title: NSLocalizedString("calendar.low", comment: ""),
                    value: "\(todays.filter { $0.impact == "low" }.count)")
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
                Text("\(TradeFlorView.hm.string(from: d)) · \(TradeFlorView.countdown(d.timeIntervalSince(now)))")
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

    private func row(_ e: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(e.date.map { TradeFlorView.hm.string(from: $0) } ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint)
                HStack(spacing: 4) {
                    Text(Self.flag(e.country_code)).font(.system(size: 14))
                    Text(e.currency).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.text)
                }
            }
            .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(e.event).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    value("calendar.actual", e.actual, highlight: true)
                    value("calendar.forecast", e.forecast)
                    value("calendar.previous", e.previous)
                }
            }
            Spacer(minLength: 4)
            VStack(spacing: 8) {
                bars(e.impact)
                Button { Task { await toggle(e) } } label: {
                    Image(systemName: saved.contains(e.id) ? "star.fill" : "star").font(.system(size: 13)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("calendar.save"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        let color = TradeFlorView.impactColor(impact)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(i < lit ? color : Theme.faint.opacity(0.25)).frame(width: 3, height: CGFloat(5 + i * 3))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    static func flag(_ code: String) -> String {
        let c = code.uppercased()
        guard c.count == 2, c.allSatisfy({ $0.isLetter && $0.isASCII }) else { return "🏳️" }
        return c.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map { String($0) }.joined()
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let start = Calendar.current.startOfDay(for: Date())
        do {
            events = try await APIClient.shared.calendar(token: token, from: start, to: start.addingTimeInterval(7 * 86400))
            failed = false
        } catch {
            failed = true
        }
        saved = Set(((try? await APIClient.shared.savedEvents(token: token)) ?? []).map(\.event_key))
    }

    private func toggle(_ e: CalendarEvent) async {
        if saved.contains(e.id) {
            if (try? await APIClient.shared.removeSavedEvent(token: token, key: e.id)) != nil { saved.remove(e.id) }
        } else if (try? await APIClient.shared.saveEvent(token: token, e)) != nil {
            saved.insert(e.id)
        }
    }
}
