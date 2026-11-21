import XCTest
@testable import Tradeflor

/// Stickers (2026-11-21): the reference in a message, the library, the keyboard's tab, Favorites without duplicates, the
/// animation rule, the picture cache, the Maker's rules, the outbox, and the message menu.
@MainActor
final class StickerTests: XCTestCase {
    private func message(kind: String = "sticker", signal: String?) throws -> Message {
        var o: [String: Any] = ["id": "m1", "conversation_id": "dm_a_b", "sender_id": "a", "kind": kind, "body": "😀 Sticker", "seq": 1, "created_at": 1]
        if let signal { o["signal"] = signal }
        return try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: o))
    }

    // MARK: IOS-STICKER-004: the reference in `signal`

    func testReferenceIsReadFromSignal() throws {
        let m = try message(signal: #"{"sticker_id":"stk_1","w":290,"h":378,"animated":true,"emoji":"😀","pack_id":"spk_9","new":1}"#)
        let r = try XCTUnwrap(m.stickerRef)
        XCTAssertEqual(r.stickerId, "stk_1")
        XCTAssertEqual(r.w, 290)
        XCTAssertEqual(r.h, 378)
        XCTAssertTrue(r.animated)
        XCTAssertEqual(r.emoji, "😀")
        XCTAssertEqual(r.packId, "spk_9")
    }

    func testBadReferencesAreNotStickers() throws {
        XCTAssertNil(try message(signal: "not json").stickerRef)
        XCTAssertNil(try message(signal: #"{"w":10}"#).stickerRef, "no id")
        XCTAssertNil(try message(signal: nil).stickerRef)
        XCTAssertNil(try message(kind: "text", signal: #"{"sticker_id":"stk_1"}"#).stickerRef, "only kind sticker")
        let r = try XCTUnwrap(try message(signal: #"{"sticker_id":"stk_1","w":0,"h":-4}"#).stickerRef)
        XCTAssertEqual(r.w, 512, "missing or wrong sizes mean 512")
        XCTAssertEqual(r.h, 512)
        XCTAssertFalse(r.animated, "absent = still")
        XCTAssertNil(r.packId)
    }

    func testBoxKeepsTheShapeAndTheLongestSide() {
        XCTAssertEqual(StickerRef.box(w: 290, h: 378), CGSize(width: 115, height: 150))
        XCTAssertEqual(StickerRef.box(w: 512, h: 256), CGSize(width: 150, height: 75))
        XCTAssertEqual(StickerRef.box(w: 0, h: 0), CGSize(width: 150, height: 150))
    }

    /// An app without stickers shows the body (the row falls back to text, the chat list reads the body).
    func testBodyIsTheText() throws {
        XCTAssertEqual(try message(signal: #"{"sticker_id":"stk_1"}"#).body, "😀 Sticker")
    }

    // MARK: library and config

    func testLibraryDecodesWithMissingFields() throws {
        let json = #"{"favorites":[{"id":"stk_a","favorite":true},{"bad":1}],"recent":[],"packs":[{"id":"spk_1","name":"Trading","stickers":[{"id":"stk_b","animated":true,"w":-1}]}],"x":1}"#
        let lib = try JSONDecoder().decode(StickerLibrary.self, from: Data(json.utf8))
        XCTAssertEqual(lib.favorites.map(\.id), ["stk_a"], "an item that cannot be read is left out, the rest stays")
        XCTAssertTrue(lib.mine.isEmpty, "missing list = empty")
        XCTAssertEqual(lib.packs.first?.stickers?.first?.w, 512)
        XCTAssertEqual(lib.favorites.first?.mime, "image/png")
    }

    func testConfigDefaultsToOff() throws {
        XCTAssertFalse(StickerConfig().enabled, "a server without stickers (404) is off")
        let c = try JSONDecoder().decode(StickerConfig.self, from: Data(#"{"enabled":true,"animated":false,"max_upload_bytes":100}"#.utf8))
        XCTAssertTrue(c.enabled)
        XCTAssertFalse(c.animated)
        XCTAssertEqual(c.maxUploadBytes, 100)
        XCTAssertEqual(c.side, 512)
    }

    // MARK: IOS-STICKER-001: which tab opens

    func testTabChoice() {
        let s = Sticker(id: "stk_1")
        XCTAssertEqual(StickerPanel.chooseTab(remembered: "", library: StickerLibrary()), "favorites")
        XCTAssertEqual(StickerPanel.chooseTab(remembered: "", library: StickerLibrary(recent: [s])), "recent", "the first tab with stickers")
        XCTAssertEqual(StickerPanel.chooseTab(remembered: "", library: StickerLibrary(mine: [s])), "mine")
        XCTAssertEqual(StickerPanel.chooseTab(remembered: "explore", library: StickerLibrary(favorites: [s])), "explore", "the one used last")
        XCTAssertEqual(StickerPanel.chooseTab(remembered: "pack:gone", library: StickerLibrary(favorites: [s])), "favorites",
                       "a removed pack's tab is not reopened")
        let lib = StickerLibrary(packs: [StickerPack(id: "spk_1", installed: true, stickers: [s])])
        XCTAssertEqual(StickerPanel.chooseTab(remembered: "", library: lib), "pack:spk_1")
    }

    // MARK: IOS-STICKER-002/006/007: Favorites and packs in the store

    func testFavoriteAddTwiceLeavesOneNewestFirst() {
        var lib = StickerLibrary(favorites: [Sticker(id: "old")])
        lib = StickerStore.applying(lib, favorite: "new", on: true, sticker: Sticker(id: "new"))
        lib = StickerStore.applying(lib, favorite: "new", on: true, sticker: Sticker(id: "new"))
        XCTAssertEqual(lib.favorites.map(\.id), ["new", "old"])
        XCTAssertTrue(lib.favorites[0].favorite)
        lib = StickerStore.applying(lib, favorite: "new", on: false, sticker: nil)
        XCTAssertEqual(lib.favorites.map(\.id), ["old"])
    }

    func testRemovePackKeepsFavoritesAndUndoRestores() {
        let fav = Sticker(id: "stk_from_pack")
        let pack = StickerPack(id: "spk_1", name: "P", installed: true, stickers: [fav])
        var lib = StickerLibrary(favorites: [fav], packs: [pack])
        lib = StickerStore.applying(lib, pack: pack, installed: false)
        XCTAssertTrue(lib.packs.isEmpty)
        XCTAssertEqual(lib.favorites.map(\.id), ["stk_from_pack"], "a sticker saved from the pack stays in Favorites")
        lib = StickerStore.applying(lib, pack: pack, installed: true) // Undo
        lib = StickerStore.applying(lib, pack: pack, installed: true) // installing twice
        XCTAssertEqual(lib.packs.map(\.id), ["spk_1"], "install is idempotent")
    }

    @MainActor
    func testMenuShowsAddOrRemoveNeverBothAndViewPackOnlyWithAPack() throws {
        let store = StickerStore.shared
        store._testSet(config: StickerConfig(enabled: true), library: StickerLibrary(favorites: [Sticker(id: "stk_saved")]))
        defer { store.clear() }
        let saved = try message(signal: #"{"sticker_id":"stk_saved","pack_id":"spk_1"}"#)
        let fresh = try message(signal: #"{"sticker_id":"stk_new"}"#)
        XCTAssertEqual(MessageRow<EmptyView>.stickerItems(saved, viewPack: { _ in }).map(\.id), ["stk.fav.remove", "stk.pack.view"])
        XCTAssertEqual(MessageRow<EmptyView>.stickerItems(fresh, viewPack: { _ in }).map(\.id), ["stk.fav.add"], "no View pack without a pack")
        XCTAssertTrue(MessageRow<EmptyView>.stickerItems(try message(kind: "text", signal: nil), viewPack: nil).isEmpty)
        store._testSet(config: StickerConfig(enabled: false), library: StickerLibrary())
        XCTAssertTrue(MessageRow<EmptyView>.stickerItems(fresh, viewPack: nil).isEmpty, "stickers off: no sticker entries")
    }

    // MARK: IOS-STICKER-005: when an animation plays

    func testAnimationRule() {
        XCTAssertTrue(StickerMotion.shouldAnimate(visible: true, appActive: true, reduceMotion: false, lowPower: false, tapped: false))
        XCTAssertFalse(StickerMotion.shouldAnimate(visible: false, appActive: true, reduceMotion: false, lowPower: false, tapped: true), "never off screen")
        XCTAssertFalse(StickerMotion.shouldAnimate(visible: true, appActive: false, reduceMotion: false, lowPower: false, tapped: true), "never in the background")
        XCTAssertFalse(StickerMotion.shouldAnimate(visible: true, appActive: true, reduceMotion: true, lowPower: false, tapped: false), "Reduce Motion: still")
        XCTAssertTrue(StickerMotion.shouldAnimate(visible: true, appActive: true, reduceMotion: true, lowPower: false, tapped: true), "plays on tap")
        XCTAssertFalse(StickerMotion.shouldAnimate(visible: true, appActive: true, reduceMotion: false, lowPower: true, tapped: false), "Low Power: still")
    }

    // MARK: IOS-STICKER-011: the picture cache

    func testCacheEvictsLeastRecentlyUsedFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stk-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, name) in ["old", "mid", "new"].enumerated() {
            let u = dir.appendingPathComponent(name)
            try Data(repeating: 1, count: 1000).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i - 10) * 60)], ofItemAtPath: u.path)
        }
        XCTAssertEqual(StickerCache.trim(dir: dir, cap: 2000), 1)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, ["mid", "new"], "the least recently used goes first")
    }

    func testDamagedPictureDoesNotDecode() throws {
        XCTAssertNil(StickerCache.downsample(Data("not a picture".utf8), maxPixel: 100))
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { c in
            UIColor.red.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }.pngData())
        let img = try XCTUnwrap(StickerCache.downsample(png, maxPixel: 20))
        XCTAssertEqual(max(img.size.width, img.size.height), 20, "downsampled to the drawn size")
    }

    // MARK: IOS-STICKER-008/009: the Maker's rules

    func testExportIsTrimmedAndAtMost512() throws {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = false
        let img = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 1000), format: f).image { c in
            UIColor.blue.setFill()
            c.fill(CGRect(x: 100, y: 300, width: 800, height: 200))
        }
        let png = try XCTUnwrap(StickerExport.png(img))
        let out = try XCTUnwrap(UIImage(data: png))
        XCTAssertEqual(out.size.width, 512, accuracy: 1)
        XCTAssertEqual(out.size.height, 128, accuracy: 1, "trimmed to what is drawn, the shape kept")
        let empty = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50), format: f).image { _ in }
        XCTAssertNil(StickerExport.png(empty), "nothing drawn: nothing to make")
    }

    func testClipCutIsClamped() {
        XCTAssertEqual(StickerClip.clamp(start: 0, duration: 10, total: 20).duration, 3, "at most 3 s")
        XCTAssertEqual(StickerClip.clamp(start: 0, duration: 0.1, total: 20).duration, 0.3, accuracy: 0.001, "at least 0.3 s")
        XCTAssertEqual(StickerClip.clamp(start: 19, duration: 3, total: 20).start, 17, accuracy: 0.001, "inside the clip")
        XCTAssertEqual(StickerClip.clamp(start: 0, duration: 3, total: 1.2).duration, 1.2, accuracy: 0.001, "a short clip: the whole clip")
    }

    func testSquareCropFractions() {
        let land = StickerClip.squareCrop(width: 1920, height: 1080)
        XCTAssertEqual(land.width, 1080.0 / 1920.0, accuracy: 0.0001)
        XCTAssertEqual(land.minX, (1 - 1080.0 / 1920.0) / 2, accuracy: 0.0001)
        XCTAssertEqual(land.height, 1)
        let port = StickerClip.squareCrop(width: 1080, height: 1920)
        XCTAssertEqual(port.height, 1080.0 / 1920.0, accuracy: 0.0001)
        XCTAssertEqual(port.minY, (1 - 1080.0 / 1920.0) / 2, accuracy: 0.0001)
        XCTAssertEqual(StickerClip.squareCrop(width: 0, height: 0), CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: IOS-STICKER-011: a sticker waiting to be sent

    func testPendingStickerKeepsItsKeyAndIsFlushedAsASticker() throws {
        let account = "acct-stk-\(UUID().uuidString.prefix(8))"
        let conv = "c-stk"
        AccountGate.set(Session(token: "tf_test", userID: account, username: "t"))
        defer {
            OutboxStore.clear(account: account, conversation: conv)
            AccountGate.set(Keychain.load())
        }
        let key = UUID().uuidString.lowercased()
        var p = PendingMessage(id: key, body: "😀 Sticker", date: Date())
        p.sticker = StickerRef(stickerId: "stk_1", w: 300, h: 200, emoji: "😀")
        p.stickerPack = "spk_1"
        OutboxStore.save(account: account, conversation: conv, [p])
        let loaded = try XCTUnwrap(OutboxStore.load(account: account, conversation: conv).first)
        XCTAssertEqual(loaded.id, key, "the same key after a restart")
        XCTAssertEqual(loaded.sticker?.stickerId, "stk_1")
        XCTAssertEqual(loaded.sticker?.w, 300)
        XCTAssertEqual(loaded.stickerPack, "spk_1")
        let line = try XCTUnwrap(OutboxStore.lines(account: account).first)
        XCTAssertEqual(line.stickerID, "stk_1", "the background sender sends it as a sticker, never as its text")
        XCTAssertEqual(line.stickerPack, "spk_1")
    }

    func testSpokenLabel() {
        let r = StickerRef(stickerId: "s", emoji: "😀")
        XCTAssertTrue(StickerBubble.spoken(r, sender: "Sam", date: nil).hasPrefix("Sticker, 😀, from Sam"))
    }
}
