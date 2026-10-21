import AVFoundation
import Foundation

var keepEngine: AVAudioEngine?
func startKeepAlive() {
    let e = AVAudioEngine(); let p = AVAudioPlayerNode()
    let fmt = e.outputNode.inputFormat(forBus: 0)
    e.attach(p); e.connect(p, to: e.mainMixerNode, format: fmt)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024), let ch = buf.floatChannelData else { return }
    buf.frameLength = 1024
    let bytes = Int(1024 * fmt.streamDescription.pointee.mBytesPerFrame)
    for i in 0..<Int(fmt.channelCount) { memset(ch[i], 0, bytes) }
    do { try e.start(); p.scheduleBuffer(buf, at: nil, options: .loops); p.volume = 0; p.play(); keepEngine = e } catch { print("[probe] keep-alive failed \(error)") }
}
func stopKeepAlive() { keepEngine?.stop(); keepEngine = nil }
func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

func cycle(engine: AVAudioEngine, label: String) -> (Int, Float) {
    let input = engine.inputNode
    let inFmt = input.inputFormat(forBus: 0)
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: engine.outputNode.inputFormat(forBus: 0))
    if let buf = AVAudioPCMBuffer(pcmFormat: engine.outputNode.inputFormat(forBus: 0), frameCapacity: 1024), let ch = buf.floatChannelData {
        buf.frameLength = 1024
        let bytes = Int(1024 * buf.format.streamDescription.pointee.mBytesPerFrame)
        for i in 0..<Int(buf.format.channelCount) { memset(ch[i], 0, bytes) }
        player.scheduleBuffer(buf, at: nil, options: .loops)
        player.volume = 0
    }
    var frames = 0; var peak: Float = 0
    input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { buffer, _ in
        frames += 1
        if let ch = buffer.floatChannelData { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[0][i])) } }
    }
    do { try engine.start() } catch { print("[probe] \(label) start failed \(error)") }
    player.play()
    wait(2)
    print("[probe] \(label): callbacks=\(frames) peak=\(peak) running=\(engine.isRunning)")
    input.removeTap(onBus: 0)
    player.stop()
    engine.stop()
    engine.reset()
    return (frames, peak)
}

// A: same engine reused across two cycles
print("[probe] === A: same engine reused ===")
stopKeepAlive()
let shared = AVAudioEngine()
_ = cycle(engine: shared, label: "A cycle1")
startKeepAlive(); wait(1); stopKeepAlive()
_ = cycle(engine: shared, label: "A cycle2")
startKeepAlive(); wait(1); stopKeepAlive()

// B: fresh engine each cycle
print("[probe] === B: fresh engine per cycle ===")
_ = cycle(engine: AVAudioEngine(), label: "B cycle1")
startKeepAlive(); wait(1); stopKeepAlive()
_ = cycle(engine: AVAudioEngine(), label: "B cycle2")
startKeepAlive(); wait(1); stopKeepAlive()
