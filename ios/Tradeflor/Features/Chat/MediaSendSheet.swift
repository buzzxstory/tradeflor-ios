import AVFoundation
import AVKit
import PhotosUI
import SwiftUI

// Sending photos and videos like WhatsApp (website shared/components/MediaSendSheet.tsx): pick several, review them full screen,
// a caption for each, add more (+) or remove one, HD (the original size) or standard (1600 px), Send with the count.

struct MediaDraft: Identifiable {
    let id = UUID()
    var image: UIImage?      // a photo, or a video's first frame
    var videoURL: URL?
    var caption = ""
    var isVideo: Bool { videoURL != nil }
}

enum MediaDrafts {
    static func load(_ items: [PhotosPickerItem]) async -> [MediaDraft] {
        var out: [MediaDraft] = []
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    out.append(MediaDraft(image: await poster(movie.url), videoURL: movie.url))
                }
            } else if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                out.append(MediaDraft(image: img))
            }
        }
        return out
    }

    static func poster(_ url: URL) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 900, height: 900)
        return await withCheckedContinuation { cont in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, cg, _, _, _ in
                cont.resume(returning: cg.map(UIImage.init(cgImage:)))
            }
        }
    }
}

struct MediaSendSheet: View {
    @State var items: [MediaDraft]
    let title: String
    let onSend: ([MediaDraft], _ hd: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var hd = false
    @State private var adding: [PhotosPickerItem] = []
    @State private var showAdd = false
    @State private var player: AVPlayer?

    private var current: MediaDraft? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                TabView(selection: $index) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, d in
                        page(d).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                strip
                captionBar
            }
        }
        .preferredColorScheme(.dark)
        .photosPicker(isPresented: $showAdd, selection: $adding, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: adding) { picked in
            guard !picked.isEmpty else { return }
            adding = []
            Task {
                let more = await MediaDrafts.load(picked)
                items.append(contentsOf: more)
                if !more.isEmpty { index = items.count - more.count }
            }
        }
        .onChange(of: index) { _ in player?.pause(); player = nil }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("grp.cancel"))
            Spacer()
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Spacer()
            Button { hd.toggle() } label: {
                Text("HD").font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(hd ? .black : .white)
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(hd ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.15)), in: RoundedRectangle(cornerRadius: 7))
            }
            .accessibilityLabel(Text(LocalizedStringKey(hd ? "media.hd.on" : "media.hd.off")))
            .accessibilityAddTraits(hd ? .isSelected : [])
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder private func page(_ d: MediaDraft) -> some View {
        if let url = d.videoURL {
            ZStack {
                if let p = player, current?.id == d.id {
                    VideoPlayer(player: p)
                } else {
                    if let img = d.image { Image(uiImage: img).resizable().scaledToFit() }
                    Button {
                        let p = AVPlayer(url: url)
                        player = p
                        p.play()
                    } label: {
                        Image(systemName: "play.circle.fill").font(.system(size: 64)).foregroundStyle(.white.opacity(0.9))
                    }
                    .accessibilityLabel(Text("media.play"))
                }
            }
        } else if let img = d.image {
            Image(uiImage: img).resizable().scaledToFit()
        }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, d in
                    ZStack(alignment: .topTrailing) {
                        Button { index = i } label: {
                            ZStack {
                                if let img = d.image { Image(uiImage: img).resizable().scaledToFill() } else { Color.gray }
                                if d.isVideo { Image(systemName: "video.fill").font(.system(size: 11)).foregroundStyle(.white).padding(4)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
                            }
                            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(i == index ? Theme.hex(0x00D4DF) : .clear, lineWidth: 2))
                        }
                        .accessibilityLabel(Text(String(format: NSLocalizedString("media.item", comment: ""), i + 1, items.count)))
                        if i == index && items.count > 1 {
                            Button {
                                player?.pause(); player = nil
                                items.remove(at: i)
                                index = min(index, items.count - 1)
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, .black.opacity(0.7))
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel(Text("media.remove"))
                        }
                    }
                }
                if items.count < 30 {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 56, height: 56).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel(Text("media.add"))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var captionBar: some View {
        HStack(spacing: 10) {
            TextField("", text: Binding(get: { current?.caption ?? "" }, set: { v in if items.indices.contains(index) { items[index].caption = v } }),
                      prompt: Text("media.caption").foregroundColor(.white.opacity(0.55)), axis: .vertical)
                .lineLimit(1...4)
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
            Button {
                player?.pause()
                onSend(items, hd)
                dismiss()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "paperplane.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 50, height: 50).background(Theme.sendGradient, in: Circle())
                    if items.count > 1 {
                        Text("\(items.count)").font(.system(size: 11, weight: .heavy)).foregroundStyle(.black)
                            .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20).background(.white, in: Capsule()).offset(x: 4, y: -4)
                    }
                }
            }
            .disabled(items.isEmpty)
            .accessibilityLabel(Text(String(format: NSLocalizedString("media.send.n", comment: ""), items.count)))
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
}

struct MediaBatch: Identifiable {
    let id = UUID()
    let items: [MediaDraft]
}
