import AppKit

/// Audible cues so the user knows when capture failed / a retry is running.
enum SoundFeedback {
    private static func play(_ name: String) {
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    static func start() { play("Pop") }
    static func waiting() { play("Tink") }
    static func transcribe() { play("Morse") }
    static func timeout() { play("Basso") }
    static func warning() { play("Basso") }
    static func ready() { play("Glass") }
}
