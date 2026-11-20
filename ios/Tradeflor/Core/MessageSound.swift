import UIKit
import AudioToolbox
import UserNotifications
import AVFoundation

/// Tradeflor's own message sound (Resources/tf_message.wav: the owner's sound of 2026-11-20, 0.69 s) for notifications, and a
/// soft one-note tick (tf_inchat.wav) for a message that arrives in the chat on screen. System sounds follow the ring /
/// silent switch. Vibration is a light haptic and can be turned off on this phone.
@MainActor
enum MessageSound {
    static let notificationName = UNNotificationSoundName("tf_message.wav")
    /// Groups have their own sound (a wooden two-note "ba-dum"), so a group can be told from a person without looking.
    static let groupNotificationName = UNNotificationSoundName("tf_group.wav")

    static func notificationSound(group: Bool) -> UNNotificationSound {
        UNNotificationSound(named: group ? groupNotificationName : notificationName)
    }

    private static let vibrateKey = "tf.sound.vibrate"
    private static let inChatKey = "tf.sound.inchat"

    /// Vibrate when a message arrives while the app is open (default on).
    static var vibrate: Bool {
        get { UserDefaults.standard.object(forKey: vibrateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: vibrateKey) }
    }
    /// The soft sound for a message in the chat that is open (default on).
    static var inChat: Bool {
        get { UserDefaults.standard.object(forKey: inChatKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: inChatKey) }
    }

    private static var ids: [String: SystemSoundID] = [:]

    private static func play(_ name: String) {
        if CallManager.shared.lineInUse { return } // never over a call
        if ids[name] == nil, let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            var id: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError { ids[name] = id }
        }
        if let id = ids[name] { AudioServicesPlaySystemSound(id) }
    }

    private static let buzz = UINotificationFeedbackGenerator()

    static func haptic() {
        guard vibrate, !CallManager.shared.lineInUse, UIApplication.shared.applicationState == .active else { return }
        buzz.prepare()
        buzz.notificationOccurred(.success)
    }

    /// A message for the chat on screen: the soft tick and a light buzz.
    static func incomingInChat(soundOn: Bool) {
        if soundOn && inChat { play("tf_inchat") }
        haptic()
    }

    /// A message notification while the app is open: the sound (the ring / silent switch decides, as for any alert)
    /// and the buzz.
    static func incomingAlert(group: Bool, sound: Bool) {
        if sound { play(group ? "tf_group" : "tf_message") }
        haptic()
    }

    private static var previewPlayer: AVAudioPlayer?

    /// Settings: hear a sound. It plays even with the phone on silent (a button that seems to do nothing looks broken),
    /// over other audio, never during a call.
    static func preview(group: Bool = false) {
        guard !CallManager.shared.lineInUse,
              let url = Bundle.main.url(forResource: group ? "tf_group" : "tf_message", withExtension: "wav") else { return }
        let s = AVAudioSession.sharedInstance()
        if s.category != .playback { try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers]) }
        try? s.setActive(true)
        previewPlayer?.stop()
        previewPlayer = try? AVAudioPlayer(contentsOf: url)
        previewPlayer?.play()
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: vibrateKey)
        UserDefaults.standard.removeObject(forKey: inChatKey)
    }
}
