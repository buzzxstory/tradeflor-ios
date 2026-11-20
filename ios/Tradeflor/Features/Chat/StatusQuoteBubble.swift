import SwiftUI
import UIKit

/// A reaction or a reply to a status, as WhatsApp draws it (owner request 2026-11-20; server contract "status_quote"):
/// a quote card with a coloured bar, "<Name> · Status" and what the status was, the status itself small on the right
/// (44 × 64), and under it the reaction big or the reply text.
struct StatusQuote: Codable, Equatable {
    let id: String
    let kind: String
    let owner_id: String
    var react: Bool? = nil
}

/// GET /status/{id}/quote: what the card shows while the status lasts (404 once it is gone).
struct StatusQuotePreview: Decodable {
    let id: String
    let kind: String
    var caption: String? = nil
    var text: String? = nil
    var style: String? = nil
    var poster: Bool? = nil
    var expires_at: Int64? = nil
}

extension APIClient {
    func statusQuote(token: String, id: String) async -> StatusQuotePreview? {
        guard let d = try? await getJSON("status/\(id)/quote", token: token) else { return nil }
        return try? JSONDecoder().decode(StatusQuotePreview.self, from: d)
    }
}

/// The previews and thumbnails read so far (a chat redraws its bubbles often).
@MainActor
final class StatusQuoteCache {
    static let shared = StatusQuoteCache()
    var previews: [String: StatusQuotePreview] = [:]
    var gone: Set<String> = []
    var thumbs: [String: UIImage] = [:]
}

struct StatusQuoteBubble: View {
    let token: String
    let message: Message
    let quote: StatusQuote
    let mine: Bool
    let me: String
    /// The status owner's name when it is not me.
    let ownerName: String
    var state: Bubble.Delivery?

    @State private var preview: StatusQuotePreview?
    @State private var gone = false
    @State private var thumb: UIImage?

    private var isReaction: Bool { quote.react == true }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                card
                if isReaction {
                    Text(message.body).font(.system(size: 42))
                        .padding(.horizontal, 4)
                } else if !message.body.isEmpty {
                    Text(message.body).font(.system(size: 16)).foregroundStyle(Theme.text)
                        .frame(maxWidth: 250, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                HStack(spacing: 4) {
                    if let d = message.date { Text(d, style: .time) }
                    if let state { Bubble.tickView(state) }
                }
                .font(.caption2).foregroundStyle(Theme.faint)
                .padding(.horizontal, 4)
            }
            .padding(8)
            .tfBubble(mine: mine)
            if !mine { Spacer(minLength: 48) }
        }
        .task(id: quote.id) { await load() }
    }

    private var card: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Theme.accent).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: (quote.owner_id == me ? NSLocalizedString("chat.you", comment: "") : ownerName) + " · "
                     + NSLocalizedString("sq.status", comment: ""))
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: Self.icon(quote.kind)).font(.system(size: 11, weight: .semibold))
                    Text(verbatim: line).lineLimit(1)
                }
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            Spacer(minLength: 4)
            mini.padding(4)
        }
        .frame(width: 250, height: 72)
        .background(Theme.dyn(0x000000, 0x0A8FA0, 0.18, 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(gone ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    /// The status itself, small and upright.
    @ViewBuilder private var mini: some View {
        ZStack {
            if let thumb, !gone {
                Image(uiImage: thumb).resizable().scaledToFill()
            } else if quote.kind == "text", let p = preview, !gone {
                StatusStyle.background(p.style)
                Text(verbatim: p.text ?? "").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).padding(3).lineLimit(5)
            } else {
                Theme.dyn(0x0B3A46, 0xDDF6F7)
                Image(systemName: Self.icon(quote.kind)).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .frame(width: 44, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var line: String {
        if !gone, let p = preview {
            let t = (quote.kind == "text" ? p.text : p.caption)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !t.isEmpty { return t }
        }
        switch quote.kind {
        case "image": return NSLocalizedString("sq.photo", comment: "")
        case "video": return NSLocalizedString("sq.video", comment: "")
        case "voice": return NSLocalizedString("sq.voice", comment: "")
        default: return NSLocalizedString("sq.status", comment: "")
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "image": return "photo"
        case "video": return "video"
        case "voice": return "mic"
        default: return "text.bubble"
        }
    }

    private func load() async {
        let cache = StatusQuoteCache.shared
        if cache.gone.contains(quote.id) { gone = true; return }
        if let p = cache.previews[quote.id] { preview = p } else if let p = await APIClient.shared.statusQuote(token: token, id: quote.id) {
            cache.previews[quote.id] = p
            preview = p
        } else {
            cache.gone.insert(quote.id)
            gone = true
            return
        }
        if let t = cache.thumbs[quote.id] { thumb = t; return }
        let wantsImage = quote.kind == "image" || (quote.kind == "video" && preview?.poster == true)
        guard wantsImage, let data = await APIClient.shared.statusMedia(token: token, id: quote.id, poster: quote.kind == "video"),
              let img = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 132, height: 192)) else { return }
        cache.thumbs[quote.id] = img
        thumb = img
    }
}
