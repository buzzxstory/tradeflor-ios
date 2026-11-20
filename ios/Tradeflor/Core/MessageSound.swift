import UIKit
import AudioToolbox
import UserNotifications

/// Tradeflor's own message sound (Resources/tf_message.wav: a rising glassy C6, G6, E7 figure) for notifications, and a
/// soft one-note tick (tf_inchat.wav) for a message that arrives in the chat on screen. System sounds follow the ring /
/// silent switch. Vibration is a light haptic and can be turned off on this phone.
@MainActor
enum MessageSound {
    static let notificationName = UNNotificationSoundName("tf_message.wav")

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

    static func haptic() {
        guard vibrate, !CallManager.shared.lineInUse else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// A message for the chat on screen: the soft tick and a light buzz.
    static func incomingInChat(soundOn: Bool) {
        if soundOn && inChat { play("tf_inchat") }
        haptic()
    }

    /// Settings: hear the message sound.
    static func preview() { play("tf_message") }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: vibrateKey)
        UserDefaults.standard.removeObject(forKey: inChatKey)
    }
}
