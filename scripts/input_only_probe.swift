import AVFoundation
import Foundation

func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

// Recreate the post-TTS A2DP state
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
print("[probe] keep-alive stopped; input-only engine next")
wait(0.6)

let engine = AVAudioEngine()
let input = engine.inputNode
let fmt = input.inputFormat(forBus: 0)
print("[probe] input-only engine input format=\(fmt)")
var frames = 0; var peak: Float = 0
input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
    frames += 1
    if let ch = buffer.floatChannelData { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[0][i])) } }
}
do { try engine.start(); print("[probe] input-only engine started") } catch { print("[probe] start failed \(error)") }
wait(3)
print("[probe] input-only RESULT callbacks=\(frames) peak=\(peak) running=\(engine.isRunning)")
input.removeTap(onBus: 0); engine.stop(); engine.reset()
