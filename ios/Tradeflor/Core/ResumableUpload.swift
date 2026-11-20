import Foundation
import SwiftUI

// Resumable uploads (Smart Media Upload V2, server 26e2154 uploads_routes.go; website shared/api/api.ts uploadResumable).
// A file of 4 MB or more goes in chunks: POST /uploads starts (or, with the same idempotency key, resumes) an upload; each chunk
// and the finish go through POST /messages/file. After a dropped connection the app asks the server how much arrived and
// continues from THE SERVER'S offset (never from what this device thinks it sent). Finishing twice answers the same message.
// Progress = bytes the server confirmed + the chunk in flight; it never reads 100% before the server has answered the finish.
// Foreground URLSession only: an upload stops when the app is suspended and resumes from the server's offset on the next try
// (the outbox / Retry sends again with the same key). No background-session restore.

/// What the pending bubble shows while a large file goes.
struct UploadProgress: Equatable {
    enum Phase: Equatable { case uploading, retrying, finishing }
    var sent: Int64
    var total: Int64
    /// Smoothed speed (bytes per second); 0 until measured, and outside `.uploading`.
    var bytesPerSecond: Double
    var phase: Phase

    var fraction: Double { total > 0 ? min(1, Double(sent) / Double(total)) : 0 }
    /// Never 100 before the server has answered the finish.
    var percent: Int { min(99, Int((fraction * 100).rounded())) }
    /// Seconds left at the measured speed (nil when unknown).
    var secondsLeft: Double? {
        guard phase == .uploading, bytesPerSecond > 0, total > sent else { return nil }
        return Double(total - sent) / bytesPerSecond
    }
}

/// Live progress per idempotency key (the pending message's id), for the pending rows. Main thread only.
final class UploadProgressCenter: ObservableObject {
    static let shared = UploadProgressCenter()
    @Published private(set) var byKey: [String: UploadProgress] = [:]

    func set(_ key: String, _ value: UploadProgress?) {
        if byKey[key] != value { byKey[key] = value }
    }
}

enum ResumableUploadError: Error {
    /// An older server: POST /uploads answered 404 or 405. Send with the one-request upload instead.
    case notSupported
}

/// Measures speed (EMA over windows of at least 250 ms) and passes progress to the main thread a few times a second.
private final class UploadMeter {
    private let key: String
    private let lock = NSLock()
    private var t = Date()
    private var sentAtT: Int64 = 0
    private var bps: Double = 0
    private var shown = Date.distantPast
    private var closed = false
    private var started = false

    init(key: String) { self.key = key }

    func report(_ sent: Int64, _ total: Int64, _ phase: UploadProgress.Phase) {
        lock.lock()
        let now = Date()
        let dt = now.timeIntervalSince(t)
        if !started || phase != .uploading || sent < sentAtT {
            // a new window: the first report (maybe a resumed offset), a wait after a drop, or the server's lower offset
            started = true
            t = now
            sentAtT = sent
        } else if dt >= 0.25 {
            let inst = Double(sent - sentAtT) / dt
            bps = bps > 0 ? bps * 0.7 + inst * 0.3 : inst
            t = now
            sentAtT = sent
        }
        // at most ~6 screen updates a second while bytes flow; stage changes always go
        if phase == .uploading && now.timeIntervalSince(shown) < 0.15 && sent < total { lock.unlock(); return }
        shown = now
        let value = UploadProgress(sent: sent, total: total, bytesPerSecond: phase == .uploading ? bps : 0, phase: phase)
        lock.unlock()
        let key = key
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosed else { return }
            UploadProgressCenter.shared.set(key, value)
        }
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    /// No more updates; the row's progress is cleared (queued after any update already on its way).
    func close() {
        lock.lock(); closed = true; lock.unlock()
        let key = key
        DispatchQueue.main.async { UploadProgressCenter.shared.set(key, nil) }
    }
}

/// Holds the URLSessionTask of a request in flight so a Swift Task cancellation cancels it (even before it started).
private final class InFlight {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    func set(_ task: URLSessionTask, _ observation: NSKeyValueObservation?) {
        lock.lock()
        self.task = task
        self.observation = observation
        let stop = cancelled
        lock.unlock()
        if stop { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }

    func finish() {
        lock.lock()
        observation?.invalidate()
        observation = nil
        task = nil
        lock.unlock()
    }
}

final class ResumableUploader {
    static let shared = ResumableUploader()
    /// Files at least this large go in chunks; smaller ones keep the one-request upload.
    static let minBytes: Int64 = 4 * 1024 * 1024

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.urlCache = nil
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    // MARK: files on this device

    /// Where files waiting to be sent are kept (Application Support, so they survive a restart and are resumed with the
    /// same key). Old leftovers (over two days) are removed when the folder is first used.
    static let folder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-2 * 86400)
        let keep = OutboxStore.referencedFiles() // a pending message still points at these: never aged out
        if let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for u in items where !keep.contains(u.lastPathComponent) && ((try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()) < cutoff {
                try? FileManager.default.removeItem(at: u)
            }
        }
        return folder
    }()

    /// Writes `data` once to a file kept for sending (`key` names it, so a retry finds the same file).
    static func keep(_ data: Data, key: String, ext: String) -> URL? {
        let url = folder.appendingPathComponent("\(key).\(ext)")
        do { try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); return url } catch { return nil }
    }

    /// Copies a picked file (a document) into the folder, without reading it into memory.
    static func keepCopy(of source: URL, key: String) -> URL? {
        let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
        let url = folder.appendingPathComponent("\(key).\(ext)")
        try? FileManager.default.removeItem(at: url)
        do { try FileManager.default.copyItem(at: source, to: url); return url } catch { return nil }
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: upload

    /// Sends the file at `file` (of `fileName`, whose extension helps the server read its type) as one message.
    /// Throws `ResumableUploadError.notSupported` on an older server, `CancellationError` when the Task is cancelled
    /// (the server is told to drop what it has), `APIError` otherwise (`.network` after about six failed tries in a row:
    /// a later try with the same key resumes from the server's offset).
    func upload(token: String, conversationID: String, file: URL, fileName: String, key: String,
                caption: String = "", replyTo: String = "", poster: Data? = nil) async throws -> Message {
        let size = Self.fileSize(file)
        guard size > 0 else { throw APIError.refused("") }
        let meter = UploadMeter(key: key)
        defer { meter.close() }
        let api = APIClient.shared

        var uploadID: String?
        var chunkSize: Int64 = 4 * 1024 * 1024
        var confirmed: Int64 = 0
        var done = false
        var failures = 0
        var restarts = 0

        // seconds the server asked for with a 429 (Retry-After), at most 30: waited instead of the short backoff
        var retryAfter = 0.0

        func backoff() async throws {
            failures += 1
            if failures > 6 { throw APIError.network } // the row turns "Not sent · Retry"; the retry resumes
            meter.report(confirmed, size, .retrying)
            let delay = max(min(8.0, 0.5 * pow(2.0, Double(failures - 1))), retryAfter)
            retryAfter = 0
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        do {
            while true {
                try Task.checkCancellation()

                // 1. start, or resume with the same key
                if uploadID == nil {
                    do {
                        let s = try await start(token: token, conversationID: conversationID, size: size, name: fileName, key: key)
                        uploadID = s.upload_id
                        if let c = s.chunk_size, c > 0 { chunkSize = c }
                        confirmed = min(size, s.received ?? 0)
                        done = s.done ?? false
                        failures = 0
                        meter.report(confirmed, size, .uploading)
                    } catch APIError.network {
                        try await backoff()
                        continue
                    }
                }
                guard let id = uploadID else { continue }

                // 2. the chunks, from the server's offset
                if !done && confirmed < size {
                    let length = min(chunkSize, size - confirmed)
                    let offset = confirmed
                    do {
                        let (data, http) = try await sendChunk(token: token, uploadID: id, key: key, file: file,
                                                                offset: offset, length: length) { inFlight in
                            meter.report(min(size, offset + inFlight), size, .uploading)
                        }
                        switch http.statusCode {
                        case 200, 409:
                            // 409: the server is elsewhere (a chunk landed whose answer was lost): continue from it
                            if let r = Self.received(data) { confirmed = min(size, r) }
                            // a 200 that moved nothing, or a 409 that says the server is exactly where this chunk started
                            // (it refused the chunk and is not elsewhere): a failed try (backs off, asks the server, gives up after ~6)
                            if http.statusCode == 200 ? confirmed <= offset : confirmed == offset { throw APIError.network }
                            failures = 0
                            meter.report(confirmed, size, .uploading)
                        case 404:
                            // expired or dropped on the server: start over (a new upload; the same key is free again)
                            restarts += 1
                            if restarts > 2 { throw APIError.server(status: 404) }
                            uploadID = nil
                            confirmed = 0
                        case 408, 429, 500...:
                            if http.statusCode == 429, let v = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") {
                                retryAfter = min(30, max(0, v))
                            }
                            throw APIError.network
                        default:
                            try api.check(http, data)
                            throw APIError.server(status: http.statusCode)
                        }
                    } catch APIError.network {
                        // 3. after a drop: wait, then ask the server where it is
                        try await backoff()
                        if let st = try? await status(token: token, uploadID: id) {
                            if st.code == 404 {
                                restarts += 1
                                if restarts > 2 { throw APIError.server(status: 404) }
                                uploadID = nil
                                confirmed = 0
                            } else if let s = st.body {
                                confirmed = min(size, s.received ?? confirmed)
                                done = s.done ?? false
                            }
                        }
                    }
                    continue
                }

                // 4. finish (a file removed with its X after the last chunk is never posted: audit IOS-MSG-3)
                meter.report(size, size, .finishing)
                try Task.checkCancellation()
                let fin = try await finish(token: token, uploadID: id, key: key, caption: caption, replyTo: replyTo, poster: poster)
                switch fin {
                case .message(let m):
                    return m
                case .incomplete(let r):
                    confirmed = min(size, r ?? confirmed)
                    done = false
                    if confirmed >= size { throw APIError.server(status: 409) } // the server disagrees with itself: give up
                case .expired:
                    restarts += 1
                    if restarts > 2 { throw APIError.server(status: 404) }
                    uploadID = nil
                    confirmed = 0
                    done = false
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                // 5. cancelled by the person (the X): the server drops its chunks now, not in 24 hours
                if let id = uploadID { cancelOnServer(token: token, uploadID: id) }
                throw CancellationError()
            }
            throw error
        }
    }

    /// Picks the way for a media message: 4 MB or more in chunks (an older server: the one request, as before); smaller in one
    /// request. `file` (kept on this device) or `data` (written to a file once when it is large) holds the bytes.
    func send(token: String, conversationID: String, file: URL?, data: Data?, fileName: String, mime: String,
              caption: String, key: String, replyTo: String = "", poster: Data? = nil) async throws -> Message {
        var source = file
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        if source == nil, let data, Int64(data.count) >= Self.minBytes {
            let ext = (fileName as NSString).pathExtension
            temporary = Self.keep(data, key: "tmp-\(key)", ext: ext.isEmpty ? "bin" : ext)
            source = temporary
        }
        if let source, Self.fileSize(source) >= Self.minBytes {
            do {
                return try await upload(token: token, conversationID: conversationID, file: source, fileName: fileName, key: key,
                                        caption: caption, replyTo: replyTo, poster: poster)
            } catch ResumableUploadError.notSupported {
                // an older server: the one request below
            }
        }
        let bytes: Data
        if let data, !data.isEmpty {
            bytes = data
        } else if let source, let d = try? Data(contentsOf: source, options: .mappedIfSafe), !d.isEmpty { // mapped: not copied into memory first
            bytes = d
        } else {
            throw APIError.refused("")
        }
        try Task.checkCancellation() // removed with its X while the file was read: not sent
        return try await APIClient.shared.sendImage(token: token, conversationID: conversationID, jpeg: bytes, caption: caption,
                                                    key: key, fileName: fileName, mime: mime, poster: poster)
    }

    // MARK: steps

    private struct Started: Decodable {
        let upload_id: String
        let chunk_size: Int64?
        let received: Int64?
        let done: Bool?
    }

    private struct Status: Decodable {
        let received: Int64?
        let size: Int64?
        let done: Bool?
        let message_id: String?
    }

    private func start(token: String, conversationID: String, size: Int64, name: String, key: String) async throws -> Started {
        let api = APIClient.shared
        var req = api.request("uploads", method: "POST", token: token,
                              body: ["conversation_id": conversationID, "size": size, "name": name, "idempotency_key": key])
        req.timeoutInterval = 30
        let (data, http) = try await api.send(req)
        if http.statusCode == 404 || http.statusCode == 405 { throw ResumableUploadError.notSupported }
        if http.statusCode >= 500 || http.statusCode == 408 { throw APIError.network }
        try api.check(http, data)
        guard let s = try? JSONDecoder().decode(Started.self, from: data), !s.upload_id.isEmpty else { throw APIError.decoding }
        return s
    }

    private func status(token: String, uploadID: String) async throws -> (code: Int, body: Status?) {
        let api = APIClient.shared
        var req = api.request("uploads/\(Self.pathSafe(uploadID))", method: "GET", token: token, body: nil)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, http) = try await api.send(req)
        if http.statusCode == 200 { return (200, try? JSONDecoder().decode(Status.self, from: data)) }
        return (http.statusCode, nil)
    }

    private func cancelOnServer(token: String, uploadID: String) {
        let api = APIClient.shared
        var req = api.request("uploads/\(Self.pathSafe(uploadID))/cancel", method: "POST", token: token, body: nil)
        req.timeoutInterval = 15
        let r = req
        Task.detached { _ = try? await api.send(r) } // not tied to the cancelled Task
    }

    private enum Finished { case message(Message), incomplete(Int64?), expired }

    private func finish(token: String, uploadID: String, key: String, caption: String, replyTo: String,
                        poster: Data?) async throws -> Finished {
        let api = APIClient.shared
        let boundary = "tf-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        // fields first, the poster last
        field("upload_finish", uploadID)
        if ViewOnceSend.has(key) { field("view_once", "1") }
        if !caption.isEmpty { field("caption", caption) }
        if !replyTo.isEmpty { field("reply_to_id", replyTo) }
        if let poster, !poster.isEmpty, poster.count <= 512 * 1024 {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"poster\"; filename=\"poster.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            body.append(poster)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var req = api.request("messages/file", method: "POST", token: token, body: nil)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("\(key):finish", forHTTPHeaderField: "Idempotency-Key")
        req.timeoutInterval = 120 // the server joins the chunks into one file before it answers
        req.httpBody = body

        // finishing again is safe: the server answers the same message
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, http) = try await api.send(req)
                switch http.statusCode {
                case 200..<300:
                    do { return .message(try JSONDecoder().decode(Message.self, from: data)) } catch { throw APIError.decoding }
                case 409: return .incomplete(Self.received(data))
                case 404: return .expired
                case 415:
                    throw APIError.refused(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                case 500..., 408:
                    throw APIError.network
                default:
                    try api.check(http, data)
                    throw APIError.server(status: http.statusCode)
                }
            } catch APIError.network {
                attempt += 1
                if attempt > 3 { throw APIError.network }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }

    /// One chunk: multipart (upload_id, offset, then the part "chunk"), built into a temp file from the source file with a
    /// FileHandle (the whole file is never in memory) and sent with uploadTask(fromFile:). `onSent` gets the chunk's bytes
    /// sent so far (the multipart header excluded).
    private func sendChunk(token: String, uploadID: String, key: String, file: URL, offset: Int64, length: Int64,
                           onSent: @escaping (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        let boundary = "tf-\(UUID().uuidString)"
        let head = Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"upload_id\"\r\n\r\n\(uploadID)\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"offset\"\r\n\r\n\(offset)\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"chunk\"; filename=\"chunk\"\r\nContent-Type: application/octet-stream\r\n\r\n").utf8)
        let tail = Data("\r\n--\(boundary)--\r\n".utf8)

        let part = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: part) }
        do {
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw APIError.network }
            let out = try FileHandle(forWritingTo: part)
            defer { try? out.close() }
            let src = try FileHandle(forReadingFrom: file)
            defer { try? src.close() }
            try out.write(contentsOf: head)
            try src.seek(toOffset: UInt64(offset))
            var left = length
            while left > 0 {
                let n = Int(min(left, 1 << 20))
                guard let piece = try src.read(upToCount: n), !piece.isEmpty else { break }
                try out.write(contentsOf: piece)
                left -= Int64(piece.count)
            }
            if left > 0 { throw APIError.refused("") } // the file got shorter: cannot be sent as it was
            try out.write(contentsOf: tail)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.refused("") // the file on this device cannot be read
        }

        var req = APIClient.shared.request("messages/file", method: "POST", token: token, body: nil)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("\(key):\(offset)", forHTTPHeaderField: "Idempotency-Key")
        req.timeoutInterval = 60
        let headLen = Int64(head.count)
        return try await transfer(req, fromFile: part) { sent in onSent(max(0, min(length, sent - headLen))) }
    }

    private func transfer(_ req: URLRequest, fromFile body: URL, onSent: @escaping (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        let inFlight = InFlight()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let task = self.session.uploadTask(with: req, fromFile: body) { data, resp, err in
                    inFlight.finish()
                    if let err {
                        if (err as? URLError)?.code == .cancelled { cont.resume(throwing: CancellationError()) } else { cont.resume(throwing: APIError.network) }
                        return
                    }
                    guard let http = resp as? HTTPURLResponse else { cont.resume(throwing: APIError.network); return }
                    cont.resume(returning: (data ?? Data(), http))
                }
                let obs = task.observe(\.countOfBytesSent, options: [.new]) { t, _ in onSent(t.countOfBytesSent) }
                inFlight.set(task, obs)
                task.resume()
            }
        } onCancel: {
            inFlight.cancel()
        }
    }

    private static func received(_ data: Data) -> Int64? {
        struct R: Decodable { let received: Int64? }
        return (try? JSONDecoder().decode(R.self, from: data))?.received
    }

    private static func pathSafe(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? s
    }
}

// MARK: the pending bubble's lines

/// "Uploading video · 42%", "12.3 MB / 30 MB", "1.2 MB/s · About 15 s left"; "Connection lost · resuming…"; "Finishing…".
/// Shown only while a chunked upload reports progress (the one-request upload keeps the plain ring).
struct UploadStatusLines: View {
    let key: String
    /// "video", "photo" or "file"
    let what: String
    var onDark = true
    /// On a picture: in a small dark box, inset from the corner.
    var boxed = false
    @ObservedObject private var center = UploadProgressCenter.shared

    var body: some View {
        if let p = center.byKey[key] {
            if boxed {
                lines(p)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .padding(6)
            } else {
                lines(p)
            }
        }
    }

    private func lines(_ p: UploadProgress) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.stage(p, what: what)).font(.system(size: 12, weight: .semibold))
            Text(String(format: NSLocalizedString("up.bytes", comment: ""), CIV3.bytes(p.sent), CIV3.bytes(p.total)))
                .font(.system(size: 11)).monospacedDigit()
            if let speed = Self.speedLine(p) {
                Text(speed).font(.system(size: 11)).monospacedDigit()
            }
        }
        .foregroundStyle(onDark ? Color.white : Theme.text)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }

    static func stage(_ p: UploadProgress, what: String) -> String {
        switch p.phase {
        case .retrying: return NSLocalizedString("up.retrying", comment: "")
        case .finishing: return NSLocalizedString("up.finishing", comment: "")
        case .uploading: return String(format: NSLocalizedString("up.uploading.\(what)", comment: ""), p.percent)
        }
    }

    static func speedLine(_ p: UploadProgress) -> String? {
        guard p.phase == .uploading, p.bytesPerSecond > 0 else { return nil }
        let speed = String(format: NSLocalizedString("up.speed", comment: ""), CIV3.bytes(Int64(p.bytesPerSecond)))
        guard let left = p.secondsLeft else { return speed }
        let leftText = left < 60
            ? String(format: NSLocalizedString("up.left.seconds", comment: ""), max(1, Int(left.rounded())))
            : String(format: NSLocalizedString("up.left.minutes", comment: ""), max(1, Int((left / 60).rounded())))
        return speed + " · " + leftText
    }
}

/// The ring on a pending photo or video: fills with the upload's progress while a chunked upload reports it, turns otherwise.
struct UploadRing: View {
    let key: String
    @ObservedObject private var center = UploadProgressCenter.shared

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
            if let p = center.byKey[key], p.phase == .uploading {
                Circle().trim(from: 0, to: max(0.02, min(0.99, p.fraction)))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: p.fraction)
            } else {
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.5)
            }
        }
    }
}
