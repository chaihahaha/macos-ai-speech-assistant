import AVFoundation
import Foundation

let delay = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 0.5) : 0.5
func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

let keep = AVAudioEngine(); let kp = AVAudioPlayerNode()
let kf = keep.outputNode.inputFormat(forBus: 0)
keep.attach(kp); keep.connect(kp, to: keep.mainMixerNode, format: kf)
if let b = AVAudioPCMBuffer(pcmFormat: kf, frameCapacity: 1024), let ch = b.floatChannelData {
    b.frameLength = 1024
    let bytes = Int(1024 * kf.streamDescription.pointee.mBytesPerFrame)
    for i in 0..<Int(kf.channelCount) { memset(ch[i], 0, bytes) }
    try? keep.start(); kp.scheduleBuffer(b, at: nil, options: .loops); kp.volume = 0; kp.play()
}
wait(1)
let synth = AVSpeechSynthesizer()
let u = AVSpeechUtterance(string: "测试一下语音")
u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
synth.speak(u)
wait(4)
kp.stop(); keep.stop()
print("[probe] delay=\(delay)s, keep-alive stopped, TTS isSpeaking=\(synth.isSpeaking)")
wait(delay)

let engine = AVAudioEngine()
let input = engine.inputNode
let inFmt = input.inputFormat(forBus: 0)
let outFmt = engine.outputNode.inputFormat(forBus: 0)
print("[probe] recorder input=\(inFmt) output=\(outFmt)")
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: outFmt)
if let b = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 1024), let ch = b.floatChannelData {
    b.frameLength = 1024
    let bytes = Int(1024 * outFmt.streamDescription.pointee.mBytesPerFrame)
    for i in 0..<Int(outFmt.channelCount) { memset(ch[i], 0, bytes) }
    player.scheduleBuffer(b, at: nil, options: .loops); player.volume = 0
}
var frames = 0; var peak: Float = 0
input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { buffer, _ in
    frames += 1
    if let ch = buffer.floatChannelData { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[0][i])) } }
}
let t0 = Date()
try? engine.start()
print("[probe] engine.start took \(String(format: "%.3f", Date().timeIntervalSince(t0)))s")
player.play()
wait(3)
print("[probe] RESULT delay=\(delay) callbacks=\(frames) peak=\(peak) running=\(engine.isRunning)")
input.removeTap(onBus: 0); player.stop(); engine.stop(); engine.reset()
