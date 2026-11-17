import AVFoundation

/// A short, soft two-note chime (website shared/lib/chime.ts, 3c68bec), made in code so there is no sound file to ship: played
/// once for each new join request an owner or admin receives. Two sine notes, E6 1318.5 Hz from 0 s for 0.32 s and B6 1975.5 Hz
/// from 0.11 s for 0.45 s, volume 0.09, a 15 ms attack and an exponential decay.
@MainActor
enum JoinChime {
    private static var engine: AVAudioEngine?
    private static var player: AVAudioPlayerNode?
    private static var played: Set<String> = []

    /// Plays the chime once per (conversation, user); a second event for the same request stays silent.
    static func playOnce(conversation: String, user: String) {
        let key = conversation + "|" + user
        guard !played.contains(key) else { return }
        played.insert(key)
        if played.count > 500 { played.removeAll() }
        play()
    }

    static func play(volume: Double = 0.09) {
        let rate = 44_100.0
        let total = 0.11 + 0.45 + 0.05
        let frames = AVAudioFrameCount(rate * total)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        let count = Int(frames)
        for i in 0..<count { samples[i] = 0 }

        func note(_ freq: Double, at: Double, length: Double) {
            let attack = 0.015, floor = 0.0008, tail = 0.05
            let start = Int(at * rate)
            let end = min(Int((at + length + tail) * rate), count)
            guard start < end else { return }
            for i in start..<end {
                let t = Double(i - start) / rate
                let gain: Double
                if t < attack {
                    gain = volume * t / attack
                } else if t < length {
                    gain = volume * pow(floor / volume, (t - attack) / (length - attack))
                } else {
                    gain = floor * max(0, 1 - (t - length) / tail) // the last few ms fade to silence: no click
                }
                samples[i] += Float(gain * sin(2 * Double.pi * freq * t))
            }
        }
        note(1318.5, at: 0, length: 0.32)  // E6
        note(1975.5, at: 0.11, length: 0.45) // B6

        // A quiet sound: it mixes with music and follows the silent switch; never touch the session of a call in progress.
        let session = AVAudioSession.sharedInstance()
        if session.category == .soloAmbient { try? session.setCategory(.ambient, options: [.mixWithOthers]) }
        if session.category != .playAndRecord { try? session.setActive(true) }

        engine?.stop()
        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: format)
        do { try e.start() } catch { return } // no audio: the card and the notification still tell
        engine = e
        player = p
        let id = ObjectIdentifier(e)
        p.scheduleBuffer(buffer) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let cur = JoinChime.engine, ObjectIdentifier(cur) == id {
                    cur.stop()
                    JoinChime.engine = nil
                    JoinChime.player = nil
                }
            }
        }
        p.play()
    }
}
