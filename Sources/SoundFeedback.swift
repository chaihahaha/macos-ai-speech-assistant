import AppKit

/// Audible cues so the user knows when capture failed / a retry is running.
enum SoundFeedback {
    static func warning() {
        if let sound = NSSound(named: NSSound.Name("Basso")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    static func ready() {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}
