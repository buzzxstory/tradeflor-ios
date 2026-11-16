import SwiftUI
import AVKit

// MARK: TRADEFLOR Official

/// The verified "TRADEFLOR Official" ring in the Status tab: posts from the TRADEFLOR team (photo or video,
/// a title, a caption and sometimes a button to a link).
struct OfficialRow: View {
    let token: String
    @State private var channel: OfficialChannel?
    @State private var open = false

    var body: some View {
        Group {
            if let c = channel, let posts = c.posts, !posts.isEmpty {
                Button { open = true } label: {
                    HStack(spacing: 12) {
                        StatusRing(seen: c.all_seen, count: posts.count) {
                            ZStack {
                                Theme.surface
                                Image("BrandMark").resizable().scaledToFill()
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(c.name).font(.body.weight(.semibold)).foregroundStyle(.white)
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.accent).font(.caption)
                            }
                            Text("official.subtitle").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .fullScreenCover(isPresented: $open, onDismiss: { Task { await load() } }) {
                    OfficialViewer(token: token, posts: posts)
                }
            }
        }
        .task { await load() }
    }

    private func load() async { channel = try? await APIClient.shared.official(token: token) }
}

struct OfficialViewer: View {
    let token: String
    let posts: [OfficialPost]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var index = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(posts.enumerated()), id: \.element.id) { i, p in
                    OfficialPage(token: token, post: p) { url in openURL(url) }.tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
            }
            .padding()
            .accessibilityLabel(Text("chat.close"))
        }
        .onChange(of: index) { i in seen(i) }
        .onAppear { seen(0) }
    }

    private func seen(_ i: Int) {
        guard posts.indices.contains(i), !posts[i].seen else { return }
        let id = posts[i].id
        Task { await APIClient.shared.officialSeen(token: token, id: id) }
    }
}

private struct OfficialPage: View {
    let token: String
    let post: OfficialPost
    let onOpen: (URL) -> Void
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Group {
                if post.kind == "video" {
                    if let player { VideoPlayer(player: player) } else { ProgressView().tint(.white) }
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxHeight: 520)
            if let t = post.title, !t.isEmpty { Text(t).font(.title3.bold()).foregroundStyle(.white).multilineTextAlignment(.center) }
            if let c = post.caption, !c.isEmpty { Text(c).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center) }
            if let label = post.cta_label, !label.isEmpty, let s = post.cta_url, let url = URL(string: s) {
                Button(label) { onOpen(url) }
                    .font(.headline).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 26).padding(.vertical, 12).background(Theme.accent, in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
        .task {
            if post.kind == "video" {
                let asset = AVURLAsset(url: APIClient.shared.statusMediaURL(id: "official-" + post.id),
                                       options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]])
                let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player = p
                p.play()
            } else if let d = await APIClient.shared.statusMedia(token: token, id: "official-" + post.id) {
                image = UIImage(data: d)
            }
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: economic calendar

/// The economic calendar (same data as the website's Calendar): this week's events by day, filter by impact,
/// star an event to save it (the server reminds you 15 minutes before).
struct CalendarView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var events: [CalendarEvent] = []
    @State private var saved: Set<String> = []
    @State private var impact = "all" // all | high | medium
    @State private var loading = true
    @State private var failed = false

    private var token: String { store.session?.token ?? "" }

    private var filtered: [CalendarEvent] {
        events.filter { e in
            switch impact {
            case "high": return e.impact == "high"
            case "medium": return e.impact == "high" || e.impact == "medium"
            default: return true
            }
        }
    }

    struct DayGroup: Identifiable {
        let day: Date
        let items: [CalendarEvent]
        var id: Date { day }
    }

    private var days: [DayGroup] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date ?? Date()) }
        return groups.keys.sorted().map { k in
            DayGroup(day: k, items: (groups[k] ?? []).sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("calendar.impact", selection: $impact) {
                        Text("calendar.all").tag("all")
                        Text("calendar.medium").tag("medium")
                        Text("calendar.high").tag("high")
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                ForEach(days) { d in
                    Section(header: Text(d.day, format: .dateTime.weekday(.wide).day().month())) {
                        ForEach(d.items) { e in row(e) }
                    }
                    .listRowBackground(Theme.surface)
                }
                if !loading && days.isEmpty {
                    Text(LocalizedStringKey(failed ? "calendar.error" : "calendar.empty")).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .toolbarBackground(Theme.ground, for: .navigationBar)
            .navigationTitle(Text("calendar.title"))
            .refreshable { await load() }
            .overlay { if loading && events.isEmpty { ProgressView() } }
        }
        .task { await load() }
    }

    private func row(_ e: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color(e.impact)).frame(width: 9, height: 9).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if let d = e.date { Text(d, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Text(e.currency).font(.caption.bold()).foregroundStyle(Theme.accent)
                }
                Text(e.event).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    value("calendar.actual", e.actual)
                    value("calendar.forecast", e.forecast)
                    value("calendar.previous", e.previous)
                }
                .font(.caption2)
            }
            Spacer()
            Button { Task { await toggleSave(e) } } label: {
                Image(systemName: saved.contains(e.id) ? "star.fill" : "star").foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("calendar.save"))
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func value(_ key: LocalizedStringKey, _ v: String?) -> some View {
        if let v, !v.isEmpty {
            HStack(spacing: 3) { Text(key).foregroundStyle(.secondary); Text(v).foregroundStyle(.white) }
        }
    }

    private func color(_ impact: String) -> Color {
        switch impact {
        case "high": return .red
        case "medium": return .orange
        case "low": return .yellow
        default: return .gray
        }
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

    private func toggleSave(_ e: CalendarEvent) async {
        if saved.contains(e.id) {
            if (try? await APIClient.shared.removeSavedEvent(token: token, key: e.id)) != nil { saved.remove(e.id) }
        } else {
            if (try? await APIClient.shared.saveEvent(token: token, e)) != nil { saved.insert(e.id) }
        }
    }
}
