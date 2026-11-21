import Foundation
import UIKit
import ImageIO
import Combine

// Stickers (2026-11-21; contract docs/stickers/STICKERS_PROTOCOL.md, iOS tasks IOS_STICKERS_IMPLEMENTATION.md). Stickers
// first, packs second: anyone who sees a sticker can save that one sticker and send it. Every decoder here is lenient:
// unknown fields are ignored, missing ones get defaults, w/h missing or <= 0 mean 512.

private extension KeyedDecodingContainer {
    func v<T: Decodable>(_ k: K, _ d: T) -> T { ((try? decodeIfPresent(T.self, forKey: k)) ?? nil) ?? d }
    func o<T: Decodable>(_ k: K) -> T? { (try? decodeIfPresent(T.self, forKey: k)) ?? nil }
}

/// A sticker message's reference (Message.signal of a kind "sticker" message, itself a JSON string).
struct StickerRef: Codable, Equatable {
    var stickerId: String
    var w: Int = 512
    var h: Int = 512
    var animated: Bool = false
    var emoji: String?
    var packId: String?

    enum CodingKeys: String, CodingKey { case stickerId = "sticker_id", w, h, animated, emoji, packId = "pack_id" }

    init(stickerId: String, w: Int = 512, h: Int = 512, animated: Bool = false, emoji: String? = nil, packId: String? = nil) {
        self.stickerId = stickerId; self.w = w > 0 ? w : 512; self.h = h > 0 ? h : 512
        self.animated = animated; self.emoji = emoji; self.packId = packId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stickerId = try c.decode(String.self, forKey: .stickerId)
        let w: Int = c.v(.w, 512), h: Int = c.v(.h, 512)
        self.w = w > 0 ? w : 512
        self.h = h > 0 ? h : 512
        animated = c.v(.animated, false)
        emoji = (c.o(.emoji) as String?).flatMap { $0.isEmpty ? nil : $0 }
        packId = (c.o(.packId) as String?).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The reference of a message's `signal`, or nil (not JSON, no id).
    static func parse(_ signal: String?) -> StickerRef? {
        guard let s = signal, !s.isEmpty, let r = try? JSONDecoder().decode(StickerRef.self, from: Data(s.utf8)),
              !r.stickerId.isEmpty else { return nil }
        return r
    }

    /// The box a sticker is drawn in: its own shape, the longest side `side` points (nothing jumps when the picture arrives).
    static func box(w: Int, h: Int, side: CGFloat = 150) -> CGSize {
        let w = CGFloat(w > 0 ? w : 512), h = CGFloat(h > 0 ? h : 512)
        let k = side / max(w, h)
        return CGSize(width: (w * k).rounded(), height: (h * k).rounded())
    }
}

extension Message {
    /// A sticker message's reference (nil for every other message, and for a sticker whose reference cannot be read).
    var stickerRef: StickerRef? { kind == "sticker" ? StickerRef.parse(signal) : nil }
}

struct Sticker: Codable, Identifiable, Equatable {
    var id: String
    var mime: String = "image/png"
    var animated: Bool = false
    var w: Int = 512
    var h: Int = 512
    var frames: Int?
    var durationMs: Int?
    var size: Int = 0
    var emoji: String?
    var createdAt: Int64 = 0
    var deleted: Bool = false
    var mine: Bool = false
    var favorite: Bool = false
    var usedAt: Int64?
    var addedAt: Int64?
    var ownerId: String?

    enum CodingKeys: String, CodingKey {
        case id, mime, animated, w, h, frames, durationMs = "duration_ms", size, emoji, createdAt = "created_at", deleted, mine,
             favorite, usedAt = "used_at", addedAt = "added_at", ownerId = "owner_id"
    }

    init(id: String, w: Int = 512, h: Int = 512, animated: Bool = false, emoji: String? = nil, favorite: Bool = false, mine: Bool = false) {
        self.id = id; self.w = w; self.h = h; self.animated = animated; self.emoji = emoji; self.favorite = favorite; self.mine = mine
        self.mime = animated ? "image/webp" : "image/png"
    }

    /// What a sticker message's reference knows (saving a sticker the library has never seen).
    init(ref: StickerRef) {
        self.init(id: ref.stickerId, w: ref.w, h: ref.h, animated: ref.animated, emoji: ref.emoji)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        mime = c.v(.mime, "image/png"); animated = c.v(.animated, false)
        let w: Int = c.v(.w, 512), h: Int = c.v(.h, 512)
        self.w = w > 0 ? w : 512; self.h = h > 0 ? h : 512
        frames = c.o(.frames); durationMs = c.o(.durationMs); size = c.v(.size, 0)
        emoji = (c.o(.emoji) as String?).flatMap { $0.isEmpty ? nil : $0 }
        createdAt = c.v(.createdAt, 0); deleted = c.v(.deleted, false); mine = c.v(.mine, false); favorite = c.v(.favorite, false)
        usedAt = c.o(.usedAt); addedAt = c.o(.addedAt); ownerId = c.o(.ownerId)
    }

    var ref: StickerRef { StickerRef(stickerId: id, w: w, h: h, animated: animated, emoji: emoji) }
}

struct StickerPack: Codable, Identifiable, Equatable {
    var id: String
    var ownerId: String = ""
    var name: String = ""
    var coverId: String?
    var visibility: String = "private"
    var version: Int = 0
    var count: Int = 0
    var installed: Bool = false
    var mine: Bool = false
    var stickers: [Sticker]?

    enum CodingKeys: String, CodingKey { case id, ownerId = "owner_id", name, coverId = "cover_id", visibility, version, count, installed, mine, stickers }

    init(id: String, name: String = "", installed: Bool = false, stickers: [Sticker]? = nil) {
        self.id = id; self.name = name; self.installed = installed; self.stickers = stickers; self.count = stickers?.count ?? 0
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ownerId = c.v(.ownerId, ""); name = c.v(.name, ""); coverId = c.o(.coverId); visibility = c.v(.visibility, "private")
        version = c.v(.version, 0); count = c.v(.count, 0); installed = c.v(.installed, false); mine = c.v(.mine, false)
        stickers = (c.o(.stickers) as [LenientItem<Sticker>]?)?.compactMap(\.value)
    }
}

struct StickerLibrary: Codable, Equatable {
    var favorites: [Sticker] = []
    var recent: [Sticker] = []
    var mine: [Sticker] = []
    var packs: [StickerPack] = []

    enum CodingKeys: String, CodingKey { case favorites, recent, mine, packs }

    init(favorites: [Sticker] = [], recent: [Sticker] = [], mine: [Sticker] = [], packs: [StickerPack] = []) {
        self.favorites = favorites; self.recent = recent; self.mine = mine; self.packs = packs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favorites = ((c.o(.favorites) as [LenientItem<Sticker>]?) ?? []).compactMap(\.value)
        recent = ((c.o(.recent) as [LenientItem<Sticker>]?) ?? []).compactMap(\.value)
        mine = ((c.o(.mine) as [LenientItem<Sticker>]?) ?? []).compactMap(\.value)
        packs = ((c.o(.packs) as [LenientItem<StickerPack>]?) ?? []).compactMap(\.value)
    }

    var isEmpty: Bool { favorites.isEmpty && recent.isEmpty && mine.isEmpty && packs.isEmpty }
}

struct StickerConfig: Decodable, Equatable {
    var enabled: Bool = false
    var animated: Bool = false
    var maxUploadBytes: Int = 8 << 20
    var side: Int = 512
    var maxSeconds: Int = 3

    enum CodingKeys: String, CodingKey { case enabled, animated, maxUploadBytes = "max_upload_bytes", side, maxSeconds = "max_seconds" }

    init(enabled: Bool = false, animated: Bool = false) { self.enabled = enabled; self.animated = animated }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.v(.enabled, false); animated = c.v(.animated, false); maxUploadBytes = c.v(.maxUploadBytes, 8 << 20)
        side = c.v(.side, 512); maxSeconds = c.v(.maxSeconds, 3)
    }
}

/// An HTTP answer the sticker code acts on (status 0 = no answer: offline, timeout). `text` is the server's plain message.
struct StickerHTTPError: Error, Equatable {
    let status: Int
    var text = ""

    /// What the person is told (the product spec's sentences).
    var message: String {
        switch status {
        case 0: return NSLocalizedString("stk.err.offline", comment: "")
        case 404: return NSLocalizedString("stk.err.404", comment: "")
        case 409: return NSLocalizedString("stk.err.409", comment: "")
        case 410: return NSLocalizedString("stk.err.410", comment: "")
        case 413: return NSLocalizedString("stk.err.413", comment: "")
        case 422: return NSLocalizedString("stk.err.422", comment: "")
        case 429: return NSLocalizedString("stk.err.429", comment: "")
        case 503: return NSLocalizedString("stk.err.503", comment: "")
        default: return NSLocalizedString("stk.err.other", comment: "")
        }
    }
}

// MARK: API

extension APIClient {
    private func stickerCall(_ path: String, method: String, token: String, body: [String: Any]? = nil) async throws -> Data {
        let req = request(path, method: method, token: token, body: body, rawQuery: path.contains("?"))
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await send(req) } catch { throw StickerHTTPError(status: 0) }
        if http.statusCode == 401 { throw APIError.badCredentials }
        guard (200..<300).contains(http.statusCode) else {
            throw StickerHTTPError(status: http.statusCode, text: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        return data
    }

    private static func stkSeg(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? s
    }

    /// nil = no answer (offline): what was known stays. 404 = a server without stickers: off.
    func stickerConfig(token: String) async -> StickerConfig? {
        do {
            let d = try await stickerCall("stickers/config", method: "GET", token: token)
            return (try? JSONDecoder().decode(StickerConfig.self, from: d)) ?? StickerConfig()
        } catch let e as StickerHTTPError where e.status == 404 {
            return StickerConfig()
        } catch {
            return nil
        }
    }

    func stickerLibrary(token: String) async throws -> StickerLibrary {
        let d = try await stickerCall("stickers/library", method: "GET", token: token)
        guard let lib = try? JSONDecoder().decode(StickerLibrary.self, from: d) else { throw StickerHTTPError(status: 502) }
        return lib
    }

    func stickerFavorite(token: String, id: String, on: Bool) async throws {
        _ = try await stickerCall("stickers/\(Self.stkSeg(id))/favorite", method: on ? "POST" : "DELETE", token: token, body: on ? [:] : nil)
    }

    func stickerClearRecent(token: String) async throws {
        _ = try await stickerCall("stickers/recent", method: "DELETE", token: token)
    }

    func stickerDelete(token: String, id: String) async throws {
        _ = try await stickerCall("stickers/\(Self.stkSeg(id))", method: "DELETE", token: token)
    }

    func stickerPack(token: String, id: String) async throws -> StickerPack {
        let d = try await stickerCall("sticker-packs/\(Self.stkSeg(id))", method: "GET", token: token)
        guard let p = try? JSONDecoder().decode(StickerPack.self, from: d) else { throw StickerHTTPError(status: 502) }
        return p
    }

    func stickerExplore(token: String) async throws -> [StickerPack] {
        struct E: Decodable { let packs: [LenientItem<StickerPack>]? }
        let d = try await stickerCall("sticker-packs/explore", method: "GET", token: token)
        return ((try? JSONDecoder().decode(E.self, from: d))?.packs ?? []).compactMap(\.value)
    }

    func stickerPackInstall(token: String, id: String, on: Bool) async throws {
        _ = try await stickerCall("sticker-packs/\(Self.stkSeg(id))/install", method: on ? "POST" : "DELETE", token: token, body: on ? [:] : nil)
    }

    /// Makes a pack from my own stickers (visibility "private" or "shared").
    func stickerPackCreate(token: String, name: String, visibility: String, ids: [String]) async throws -> StickerPack {
        let d = try await stickerCall("sticker-packs", method: "POST", token: token, body: ["name": name, "visibility": visibility, "sticker_ids": ids])
        guard let p = try? JSONDecoder().decode(StickerPack.self, from: d) else { throw StickerHTTPError(status: 502) }
        return p
    }

    func stickerPackUpdate(token: String, id: String, name: String, visibility: String, ids: [String]) async throws -> StickerPack {
        let d = try await stickerCall("sticker-packs/\(Self.stkSeg(id))", method: "PUT", token: token,
                                      body: ["name": name, "visibility": visibility, "sticker_ids": ids])
        guard let p = try? JSONDecoder().decode(StickerPack.self, from: d) else { throw StickerHTTPError(status: 502) }
        return p
    }

    func stickerPackDelete(token: String, id: String) async throws {
        _ = try await stickerCall("sticker-packs/\(Self.stkSeg(id))", method: "DELETE", token: token)
    }

    /// The picture (or, `still`, the PNG still frame). 404: not (or no longer) yours to see.
    func stickerMedia(token: String, id: String, still: Bool) async throws -> Data {
        try await stickerCall("stickers/\(Self.stkSeg(id))/media" + (still ? "?still=1" : ""), method: "GET", token: token)
    }

    /// Makes a sticker: a finished PNG (still), or a GIF / short video (animated: start and duration in seconds, crop as
    /// fractions 0..1). `timeout`: a conversion may take up to 90 s.
    func stickerCreate(token: String, file: Data, fileName: String, mime: String, emoji: String?, animated: Bool = false,
                       start: Double? = nil, duration: Double? = nil, crop: CGRect? = nil) async throws -> Sticker {
        let boundary = "tf-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        if let emoji, !emoji.isEmpty { field("emoji", emoji) }
        if animated {
            field("animated", "1")
            if let start { field("start", String(format: "%.3f", max(0, start))) }
            if let duration { field("duration", String(format: "%.3f", max(0.3, min(3, duration)))) }
            if let crop {
                field("crop_x", String(format: "%.4f", crop.minX)); field("crop_y", String(format: "%.4f", crop.minY))
                field("crop_w", String(format: "%.4f", crop.width)); field("crop_h", String(format: "%.4f", crop.height))
            }
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = request("stickers", method: "POST", token: token, body: nil)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 95
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await send(req) } catch { throw StickerHTTPError(status: 0) }
        if http.statusCode == 401 { throw APIError.badCredentials }
        guard (200..<300).contains(http.statusCode) else {
            throw StickerHTTPError(status: http.statusCode, text: String(data: data, encoding: .utf8) ?? "")
        }
        guard let s = try? JSONDecoder().decode(Sticker.self, from: data) else { throw StickerHTTPError(status: 502) }
        return s
    }

    /// Sends a sticker: the ordinary message send (same Idempotency-Key rules; the server writes the text itself).
    func sendSticker(token: String, conversationID: String, stickerID: String, packID: String?, key: String, replyTo: String = "") async throws -> Message {
        var fields: [String: Any] = ["ConversationID": conversationID, "Body": "Sticker", "ReplyToID": replyTo, "sticker_id": stickerID]
        if let packID, !packID.isEmpty { fields["sticker_pack_id"] = packID }
        var req = request("messages", method: "POST", token: token, body: fields)
        req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        let (data, http) = try await send(req)
        if [403, 404, 410].contains(http.statusCode) {
            // refused for good (deleted by its maker, not allowed here): "Not sent" with the reason, never retried by itself
            let why = StickerHTTPError(status: http.statusCode).message
            throw APIError.refused(http.statusCode == 403 ? (String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? why) : why)
        }
        try check(http, data)
        do { return try JSONDecoder().decode(Message.self, from: data) } catch { throw APIError.decoding }
    }
}

// MARK: pictures (memory + protected disk cache)

/// Sticker pictures on this device: per account, in Application Support (file protection until the first unlock, not in
/// backups), capped at 100 MB with least-recently-used eviction; decoded images in memory, bounded. The server answers
/// `private, no-store`: URLCache never keeps them (the API session has no URL cache).
final class StickerCache {
    static let shared = StickerCache()
    static let capBytes = 100 << 20

    private let lock = NSLock()
    private let root: URL
    private let images = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<Data?, Never>] = [:]
    private var sinceTrim = 0

    init(root: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.root = root ?? base.appendingPathComponent("StickerCache", isDirectory: true)
        images.countLimit = 160
        images.totalCostLimit = 48 << 20
    }

    private func dir(_ account: String) -> URL {
        let safe = account.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? String($0) : "_" }.joined()
        return root.appendingPathComponent(safe.isEmpty ? "_" : safe, isDirectory: true)
    }

    func fileURL(account: String, id: String, still: Bool) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? String($0) : "_" }.joined()
        return dir(account).appendingPathComponent(safe + (still ? ".still" : ".pic"))
    }

    func readDisk(account: String, id: String, still: Bool) -> Data? {
        let u = fileURL(account: account, id: id, still: still)
        guard let d = try? Data(contentsOf: u), !d.isEmpty else { return nil }
        // used now: least-recently-used eviction keeps it
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        return d
    }

    func writeDisk(account: String, id: String, still: Bool, _ data: Data) {
        guard AccountGate.isCurrent(account: account) else { return }
        let d = dir(account)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var r = root
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? r.setResourceValues(v)
        }
        try? data.write(to: fileURL(account: account, id: id, still: still), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        lock.lock()
        sinceTrim += 1
        let trim = sinceTrim >= 20
        if trim { sinceTrim = 0 }
        lock.unlock()
        if trim { Self.trim(dir: d, cap: Self.capBytes) }
    }

    func dropDisk(account: String, id: String, still: Bool) {
        try? FileManager.default.removeItem(at: fileURL(account: account, id: id, still: still))
    }

    /// Least recently used files go until the folder is under `cap` bytes.
    @discardableResult
    static func trim(dir: URL, cap: Int) -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []).compactMap { u -> (URL, Int, Date)? in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return (u, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(0) { $0 + $1.1 }
        var removed = 0
        for f in files.sorted(by: { $0.2 < $1.2 }) where total > cap {
            try? FileManager.default.removeItem(at: f.0)
            total -= f.1
            removed += 1
        }
        return removed
    }

    func image(_ key: String) -> UIImage? { images.object(forKey: key as NSString) }

    func setImage(_ img: UIImage, _ key: String) {
        let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
        images.setObject(img, forKey: key as NSString, cost: cost)
    }

    /// The bytes of a picture: the disk copy, or one download shared by everyone asking at the same moment.
    func data(token: String, account: String, id: String, still: Bool) async -> Data? {
        let key = account + "|" + id + (still ? "|s" : "|a")
        if let d = readDisk(account: account, id: id, still: still) { return d }
        let task: Task<Data?, Never> = lock.withLock {
            if let t = inflight[key] { return t }
            let t = Task<Data?, Never> {
                guard let d = try? await APIClient.shared.stickerMedia(token: token, id: id, still: still), !d.isEmpty else { return nil }
                self.writeDisk(account: account, id: id, still: still, d)
                return d
            }
            inflight[key] = t
            return t
        }
        let out = await task.value
        lock.withLock { inflight[key] = nil }
        return out
    }

    /// A still picture, decoded off the main thread and downsampled to `maxPixel`. A cached file that cannot be decoded is
    /// deleted and fetched again once.
    func still(token: String, account: String, id: String, animated: Bool, maxPixel: Int) async -> UIImage? {
        let key = "\(account)|\(id)|\(maxPixel)"
        if let img = image(key) { return img }
        // the still frame of an animated sticker is its own PNG; a still sticker is its own picture
        for attempt in 0..<2 {
            guard let d = await data(token: token, account: account, id: id, still: animated) else { return nil }
            if let img = await Task.detached(priority: .userInitiated, operation: { Self.downsample(d, maxPixel: maxPixel) }).value {
                setImage(img, key)
                return img
            }
            dropDisk(account: account, id: id, still: animated)
            if attempt == 1 { return nil }
        }
        return nil
    }

    static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        let t = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                 kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixel)] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, t) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Clear sticker cache: the pictures (memory and disk) of every account; Favorites and packs are not touched.
    func clearAll() {
        images.removeAllObjects()
        try? FileManager.default.removeItem(at: root)
    }

    /// Sign-out: everything of every account goes.
    static func forgetAll() { shared.clearAll() }

    var diskBytes: Int {
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var n = 0
        while let u = en?.nextObject() as? URL { n += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return n
    }
}

/// Should an animated sticker on screen play now? (IOS-STICKER-005)
enum StickerMotion {
    static func shouldAnimate(visible: Bool, appActive: Bool, reduceMotion: Bool, lowPower: Bool, tapped: Bool) -> Bool {
        guard visible, appActive else { return false }
        if reduceMotion || lowPower { return tapped }
        return true
    }
}

// MARK: the library store

/// The one sticker library of the signed-in account (IOS-STICKER-001/002/010): config, Favorites, Recent, My stickers and
/// added packs. Loaded after sign-in when stickers are on; reloaded on the `stickers` live event (debounced), on reconnect,
/// on coming back to the app and each time the keyboard opens; cleared on sign-out. Favorite changes show at once and are
/// put back if the server refuses; the next reload is the truth.
@MainActor
final class StickerStore: ObservableObject {
    static let shared = StickerStore()

    @Published private(set) var config = StickerConfig()
    @Published private(set) var library = StickerLibrary()
    @Published private(set) var loaded = false
    @Published private(set) var loadFailed = false
    /// A short line over the chat ("Added to Favorites", "Removed from Favorites" with Undo, an error).
    @Published var toast: StickerToast?

    private(set) var token = ""
    private(set) var account = ""
    private var subs = Set<AnyCancellable>()
    private var reloadTask: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    /// favorite changes made here and not yet answered (a reload that crosses them keeps them)
    private var pendingFav: [String: Bool] = [:]

    struct StickerToast: Equatable {
        let id = UUID()
        let text: String
        var undo: (() -> Void)?
        static func == (a: StickerToast, b: StickerToast) -> Bool { a.id == b.id }
    }

    var enabled: Bool { config.enabled }

    private init() {
        LiveConnection.shared.opened.receive(on: RunLoop.main).sink { [weak self] in self?.refreshAll() }.store(in: &subs)
        LiveConnection.shared.stickersChanged.receive(on: RunLoop.main).sink { [weak self] in self?.reloadSoon() }.store(in: &subs)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAll() }.store(in: &subs)
    }

    /// Sign-in (or the app starting signed in): this account's library; another account's is dropped first.
    func attach(token: String, account: String) {
        guard !token.isEmpty, token != self.token || account != self.account else { return }
        if account != self.account { clear() }
        self.token = token
        self.account = account
        if let cached = Self.readCached(account) { library = cached; loaded = true }
        refreshAll()
    }

    /// Sign-out or account switch: nothing of the previous account stays.
    func clear() {
        reloadTask?.cancel(); poll?.cancel(); toastTask?.cancel()
        token = ""; account = ""
        config = StickerConfig(); library = StickerLibrary(); loaded = false; loadFailed = false; toast = nil
        pendingFav = [:]
    }

    nonisolated static func forget() {
        Task { @MainActor in StickerStore.shared.clear() }
        StickerCache.forgetAll()
        try? FileManager.default.removeItem(at: libraryFolder)
    }

    private func refreshAll() {
        guard !token.isEmpty else { return }
        let tok = token
        Task {
            if let c = await APIClient.shared.stickerConfig(token: tok), tok == token {
                if c != config { config = c }
            }
            keepAsking()
            if config.enabled { await reload() }
        }
    }

    /// while off: asked again every 2 minutes (a server updated meanwhile turns stickers on without a restart)
    private func keepAsking() {
        poll?.cancel()
        poll = nil
        guard !config.enabled, !token.isEmpty else { return }
        poll = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !Task.isCancelled { self?.refreshAll() }
        }
    }

    func reloadSoon() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { await self?.reload() }
        }
    }

    /// The server's library (the truth). A reload that fails keeps what is shown; an answer for another account is dropped.
    func reload() async {
        guard !token.isEmpty, config.enabled else { return }
        let tok = token, acc = account
        do {
            var lib = try await APIClient.shared.stickerLibrary(token: tok)
            guard tok == token, acc == account else { return } // signed out or switched meanwhile
            // a favorite change still on its way stays as the person made it
            for (id, on) in pendingFav { lib = Self.applying(lib, favorite: id, on: on, sticker: lookup(id)) }
            if lib != library { library = lib }
            loaded = true
            loadFailed = false
            Self.writeCached(acc, lib)
        } catch {
            guard tok == token else { return }
            if !loaded { loadFailed = true }
        }
    }

    func lookup(_ id: String) -> Sticker? {
        library.favorites.first { $0.id == id } ?? library.recent.first { $0.id == id } ?? library.mine.first { $0.id == id }
            ?? library.packs.lazy.compactMap { $0.stickers?.first { $0.id == id } }.first
    }

    func isFavorite(_ id: String) -> Bool { library.favorites.contains { $0.id == id } }

    /// The library with one sticker added to (first) or taken out of Favorites; adding twice leaves one.
    static func applying(_ lib: StickerLibrary, favorite id: String, on: Bool, sticker: Sticker?) -> StickerLibrary {
        var out = lib
        out.favorites.removeAll { $0.id == id }
        if on, var s = sticker {
            s.favorite = true
            out.favorites.insert(s, at: 0)
        }
        return out
    }

    /// Add to / Remove from Favorites: at once, put back if the server refuses. Removing offers Undo for 6 seconds.
    func setFavorite(_ sticker: Sticker, _ on: Bool, undoable: Bool = true) {
        guard !token.isEmpty else { return }
        let before = library
        pendingFav[sticker.id] = on
        library = Self.applying(library, favorite: sticker.id, on: on, sticker: sticker)
        if on {
            show(NSLocalizedString("stk.fav.added", comment: ""))
        } else if undoable {
            show(NSLocalizedString("stk.fav.removed", comment: "")) { [weak self] in self?.setFavorite(sticker, true, undoable: false) }
        }
        let tok = token
        Task {
            do {
                try await APIClient.shared.stickerFavorite(token: tok, id: sticker.id, on: on)
                guard tok == token else { return }
                if pendingFav[sticker.id] == on { pendingFav[sticker.id] = nil }
                Self.writeCached(account, library)
            } catch {
                guard tok == token else { return }
                if pendingFav[sticker.id] == on { pendingFav[sticker.id] = nil }
                library = before
                show((error as? StickerHTTPError)?.message ?? NSLocalizedString("stk.err.other", comment: ""))
            }
        }
    }

    func clearRecent() {
        let before = library
        library.recent = []
        let tok = token
        Task {
            do { try await APIClient.shared.stickerClearRecent(token: tok) } catch {
                guard tok == token else { return }
                library = before
                show((error as? StickerHTTPError)?.message ?? NSLocalizedString("stk.err.other", comment: ""))
            }
        }
    }

    /// Add pack / Remove pack: at once; Remove offers Undo (= add again). Favorites and messages are never touched.
    func setPackInstalled(_ pack: StickerPack, _ on: Bool, undoable: Bool = true) {
        guard !token.isEmpty else { return }
        let before = library
        library = Self.applying(library, pack: pack, installed: on)
        if !on && undoable {
            show(NSLocalizedString("stk.pack.removed", comment: "")) { [weak self] in self?.setPackInstalled(pack, true, undoable: false) }
        } else if on {
            show(NSLocalizedString("stk.pack.added", comment: ""))
        }
        let tok = token
        Task {
            do {
                try await APIClient.shared.stickerPackInstall(token: tok, id: pack.id, on: on)
                guard tok == token else { return }
                await reload()
            } catch {
                guard tok == token else { return }
                library = before
                show(on ? ((error as? StickerHTTPError)?.status == 404 ? NSLocalizedString("stk.pack.404", comment: "")
                                                                     : (error as? StickerHTTPError)?.message ?? "")
                        : NSLocalizedString("stk.pack.notremoved", comment: ""))
            }
        }
    }

    static func applying(_ lib: StickerLibrary, pack: StickerPack, installed: Bool) -> StickerLibrary {
        var out = lib
        out.packs.removeAll { $0.id == pack.id }
        if installed {
            var p = pack
            p.installed = true
            out.packs.append(p)
        }
        return out
    }

    /// Delete my sticker (asked once by the screen): messages already sent keep it, people who saved it keep it.
    func deleteMine(_ sticker: Sticker) {
        let before = library
        library.mine.removeAll { $0.id == sticker.id }
        library.favorites.removeAll { $0.id == sticker.id }
        library.recent.removeAll { $0.id == sticker.id }
        let tok = token
        Task {
            do {
                try await APIClient.shared.stickerDelete(token: tok, id: sticker.id)
                await reload()
            } catch {
                guard tok == token else { return }
                library = before
                show((error as? StickerHTTPError)?.message ?? NSLocalizedString("stk.err.other", comment: ""))
            }
        }
    }

    /// A sticker just made: first in My stickers at once.
    func madeSticker(_ s: Sticker) {
        library.mine.removeAll { $0.id == s.id }
        var m = s
        m.mine = true
        library.mine.insert(m, at: 0)
        reloadSoon()
    }

    /// A sticker sent from here: first in Recent at once (the server's answer corrects it).
    func used(_ s: Sticker) {
        library.recent.removeAll { $0.id == s.id }
        library.recent.insert(s, at: 0)
        if library.recent.count > 30 { library.recent.removeLast(library.recent.count - 30) }
    }

    func show(_ text: String, undo: (() -> Void)? = nil) {
        guard !text.isEmpty else { return }
        let t = StickerToast(text: text, undo: undo)
        toast = t
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: undo != nil ? 6_000_000_000 : 2_200_000_000)
            if !Task.isCancelled, self?.toast == t { self?.toast = nil }
        }
    }

    /// Unit tests only: a known state without the network.
    func _testSet(config: StickerConfig, library: StickerLibrary) {
        self.config = config
        self.library = library
        loaded = true
    }

    // MARK: the last library answer, per account (shown at once, also offline)

    nonisolated static var libraryFolder: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("StickerLibrary", isDirectory: true)
    }

    private static func libraryFile(_ account: String) -> URL {
        let safe = account.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? String($0) : "_" }.joined()
        return libraryFolder.appendingPathComponent(safe + ".json")
    }

    static func readCached(_ account: String) -> StickerLibrary? {
        guard !account.isEmpty, let d = try? Data(contentsOf: libraryFile(account)) else { return nil }
        return try? JSONDecoder().decode(StickerLibrary.self, from: d)
    }

    static func writeCached(_ account: String, _ lib: StickerLibrary) {
        guard AccountGate.isCurrent(account: account), let d = try? JSONEncoder().encode(lib) else { return }
        try? FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
        try? d.write(to: libraryFile(account), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
