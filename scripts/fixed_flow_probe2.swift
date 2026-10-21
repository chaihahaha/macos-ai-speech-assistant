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
    do { try e.start(); p.scheduleBuffer(buf, at: nil, options: .loops); p.volume = 0; p.play(); keepEngine = e
        print("[probe] keep-alive started running=\(e.isRunning)")
    } catch { print("[probe] keep-alive failed \(error)") }
}
func stopKeepAlive() { keepEngine?.stop(); keepEngine = nil; print("[probe] keep-alive stopped") }
func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

startKeepAlive(); wait(1); stopKeepAlive()

let engine = AVAudioEngine()
let input = engine.inputNode
let inFmt = input.inputFormat(forBus: 0)
let outFmt = engine.outputNode.inputFormat(forBus: 0)
print("[probe] pre-start input=\(inFmt) output=\(outFmt)")

// Attach the silent player BEFORE starting the engine.
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: outFmt)
if let buf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 1024), let ch = buf.floatChannelData {
    buf.frameLength = 1024
    let bytes = Int(1024 * outFmt.streamDescription.pointee.mBytesPerFrame)
    for i in 0..<Int(outFmt.channelCount) { memset(ch[i], 0, bytes) }
    player.scheduleBuffer(buf, at: nil, options: .loops)
    player.volume = 0
}

var frames = 0; var peak: Float = 0
input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { buffer, _ in
    frames += 1
    if let ch = buffer.floatChannelData { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[0][i])) } }
}
do { try engine.start(); print("[probe] recording engine started") } catch { print("[probe] recording engine failed \(error)") }
player.play()

wait(3)
print("[probe] recording: input callbacks=\(frames) peak=\(peak) engineRunning=\(engine.isRunning) playerPlaying=\(player.isPlaying)")

input.removeTap(onBus: 0)
player.stop()
engine.stop()
engine.reset()

startKeepAlive(); wait(1)
print("[probe] keep-alive after recording running=\(keepEngine?.isRunning ?? false)")
stopKeepAlive()
