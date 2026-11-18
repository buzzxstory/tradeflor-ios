import AVFoundation

/// Call sounds synthesised in memory, like the website's Web Audio tones (desktop/src/features/calls/tones.ts):
/// the outgoing ringback (425 Hz, 1 s on / 3 s off), connected chime, end tone and busy signal. The incoming ring is the
/// system's (CallKit).
@MainActor
final class CallTones {
    static let shared = CallTones()
    private var loop: AVAudioPlayer?
    private var oneShot: AVAudioPlayer?
    private static let rate = 16_000.0

    /// segments: (frequencies, milliseconds, volume); an empty frequency list is silence.
    private static func wav(_ segments: [([Double], Double, Double)]) -> Data {
        var samples: [Int16] = []
        for (freqs, ms, vol) in segments {
            let n = Int(rate * ms / 1000)
            let fade = min(n / 2, Int(rate * 0.012))
            for i in 0..<n {
                var v = 0.0
                for f in freqs { v += sin(2 * .pi * f * Double(i) / rate) }
                if !freqs.isEmpty { v /= Double(freqs.count) }
                var env = 1.0
                if fade > 0 { env = min(1, Double(i) / Double(fade), Double(n - i) / Double(fade)) }
                samples.append(Int16(max(-1, min(1, v * vol * env)) * 32_767))
            }
        }
        var d = Data()
        func u32(_ x: UInt32) { var v = x.littleEndian; d.append(Data(bytes: &v, count: 4)) }
        func u16(_ x: UInt16) { var v = x.littleEndian; d.append(Data(bytes: &v, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }

    private lazy var ringbackData = Self.wav([([425], 1000, 0.35), ([], 3000, 0)])
    private lazy var connectedData = Self.wav([([660], 90, 0.3), ([], 10, 0), ([990], 120, 0.3)])
    private lazy var endData = Self.wav([([480], 160, 0.35), ([], 40, 0), ([360], 220, 0.35)])
    private lazy var busyData = Self.wav([([480, 620], 250, 0.35), ([], 250, 0), ([480, 620], 250, 0.35), ([], 250, 0), ([480, 620], 250, 0.35)])

    /// True between CallKit's didActivate and the end of the call: the ringback is played in the call's own audio session
    /// (earpiece, the call volume), never before it (the session was then whatever the last screen left: a status video's
    /// loudspeaker playback, or nothing).
    var sessionActive = false {
        didSet { if sessionActive, wantRingback { startLoop() } }
    }
    private var wantRingback = false

    func ringback(_ on: Bool) {
        wantRingback = on
        if !on { loop?.stop(); loop = nil; return }
        if sessionActive { startLoop() } // else it starts when the session is switched on
    }

    private func startLoop() {
        guard loop == nil, let p = try? AVAudioPlayer(data: ringbackData) else { return }
        p.numberOfLoops = -1
        p.play()
        loop = p
    }

    func connected() { play(connectedData) }
    func end() { wantRingback = false; play(endData) }
    func busy() { play(busyData) }

    private func play(_ data: Data) {
        loop?.stop()
        loop = nil
        oneShot = try? AVAudioPlayer(data: data)
        oneShot?.play()
    }
}
