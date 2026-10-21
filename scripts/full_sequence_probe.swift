import AVFoundation
import Foundation

func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

func startKeepAlive() -> (AVAudioEngine, AVAudioPlayerNode) {
    let e = AVAudioEngine(); let p = AVAudioPlayerNode()
    let f = e.outputNode.inputFormat(forBus: 0)
    e.attach(p); e.connect(p, to: e.mainMixerNode, format: f)
    if let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 1024), let ch = b.floatChannelData {
        b.frameLength = 1024
        let bytes = Int(1024 * f.streamDescription.pointee.mBytesPerFrame)
        for i in 0..<Int(f.channelCount) { memset(ch[i], 0, bytes) }
        try? e.start(); p.scheduleBuffer(b, at: nil, options: .loops); p.volume = 0; p.play()
    }
    print("[probe] keep-alive started output=\(f)")
    return (e, p)
}

let synth = AVSpeechSynthesizer()

func runCycle(label: String, delayBeforeRecord: TimeInterval, playerUsesInputFormat: Bool) {
    var (keep, kp) = startKeepAlive()
    wait(1)
    let u = AVSpeechUtterance(string: "测试一下语音")
    u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
    u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
    synth.speak(u)
    wait(4)   // TTS plays while keep-alive is running
    print("[probe] \(label) TTS isSpeaking=\(synth.isSpeaking), keepRunning=\(keep.isRunning)")

    kp.stop(); keep.stop()
    if delayBeforeRecord > 0 { wait(delayBeforeRecord) }

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inFmt = input.inputFormat(forBus: 0)
    let outFmt = playerUsesInputFormat ? inFmt : engine.outputNode.inputFormat(forBus: 0)
    print("[probe] \(label) recorder input=\(inFmt) playerFormat=\(outFmt)")
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
    try? engine.start()
    player.play()
    wait(3)
    print("[probe] \(label) RESULT callbacks=\(frames) peak=\(peak) running=\(engine.isRunning)")
    input.removeTap(onBus: 0); player.stop(); engine.stop(); engine.reset()
}

runCycle(label: "A-immediate-outFmt", delayBeforeRecord: 0, playerUsesInputFormat: false)
runCycle(label: "B-delay200-outFmt", delayBeforeRecord: 0.2, playerUsesInputFormat: false)
runCycle(label: "C-immediate-inFmt", delayBeforeRecord: 0, playerUsesInputFormat: true)
