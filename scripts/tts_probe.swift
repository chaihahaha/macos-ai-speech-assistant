import AVFoundation
import Foundation

// Diagnostic only: verifies that AVSpeechSynthesizer resolves a Chinese voice
// and actually starts/finishes an utterance. Does not play through the app.
let synth = AVSpeechSynthesizer()

final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        print("[probe] didStart voice=\(utterance.voice?.name ?? "nil") lang=\(utterance.voice?.language ?? "nil") rate=\(utterance.rate) volume=\(utterance.volume)")
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print("[probe] didFinish")
        exit(0)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        print("[probe] didCancel")
        exit(0)
    }
}

let delegate = Delegate()
synth.delegate = delegate

print("[probe] zh-CN voice = \(AVSpeechSynthesisVoice(language: "zh-CN")?.name ?? "nil")")
print("[probe] en-US voice = \(AVSpeechSynthesisVoice(language: "en-US")?.name ?? "nil")")
let chineseVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
print("[probe] zh voices: \(chineseVoices.map { "\($0.name)/\($0.language)" }.joined(separator: ", "))")

let utterance = AVSpeechUtterance(string: "你好！有什么我可以帮你的吗？")
utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
utterance.volume = 1.0
print("[probe] speaking (isSpeaking before=\(synth.isSpeaking))")
let start = Date()
synth.speak(utterance)
RunLoop.current.run(until: Date().addingTimeInterval(10))
print("[probe] timeout after \(String(format: "%.2f", Date().timeIntervalSince(start)))s isSpeaking=\(synth.isSpeaking)")
