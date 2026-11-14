import AudioToolbox
import UIKit

/// The tick for a keystroke that could not be sent (`BridgeClient.keystrokeWasDropped`,
/// already throttled to one per burst and gated on `AppSettings.dropCueEnabled`).
///
/// Two channels, because neither is reliable alone: the vibration is what
/// reaches a phone in a pocket or on silent, the sound is what reaches a phone
/// lying on the desk. The error vibration is a pattern the key pad never uses,
/// so it can't be mistaken for exploring a key.
///
/// The sound is a system sound: it mixes over a podcast or VoiceOver instead
/// of interrupting them, needs no audio session, and follows the silent switch.
/// The `SystemSoundID` is created once, up front — the first play of a fresh
/// one pays a load delay.
@MainActor
final class DropCue {
    static let shared = DropCue()

    private let haptic = UINotificationFeedbackGenerator()
    private var soundID: SystemSoundID = 0

    private init() {
        if let url = Bundle.main.url(forResource: "DropTick", withExtension: "wav") {
            AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        }
        haptic.prepare()
    }

    func play() {
        haptic.notificationOccurred(.error)
        haptic.prepare()
        if soundID != 0 { AudioServicesPlaySystemSound(soundID) }
    }
}
