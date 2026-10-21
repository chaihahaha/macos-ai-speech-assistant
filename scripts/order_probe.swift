import AVFoundation
import Foundation

var outEngine: AVAudioEngine?
var outPlayer: AVAudioPlayerNode?

func startSilentOutput() {
    let e = AVAudioEngine()
    let p = AVAudioPlayerNode()
    let fmt = e.outputNode.inputFormat(forBus: 0)
    e.attach(p); e.connect(p, to: e.mainMixerNode, format: fmt)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024), let ch = buf.floatChannelData else { return }
    buf.frameLength = 1024
    let bytes = Int(1024 * fmt.streamDescription.pointee.mBytesPerFrame)
    for i in 0..<Int(fmt.channelCount) { memset(ch[i], 0, bytes) }
    do {
        try e.start()
        p.scheduleBuffer(buf, at: nil, options: .loops)
        p.volume = 0
        p.play()
        outEngine = e; outPlayer = p
        print("[probe] silent output started, running=\(e.isRunning), format=\(fmt)")
    } catch { print("[probe] silent output failed: \(error)") }
}

func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

// Replicate the app: silent output engine first (at launch), input later.
startSilentOutput()
wait(1)

let inEngine = AVAudioEngine()
let input = inEngine.inputNode
let fmt = input.inputFormat(forBus: 0)
print("[probe] input format=\(fmt)")
var frames = 0
var peak: Float = 0
input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
    frames += 1
    if let ch = buffer.floatChannelData { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[0][i])) } }
}
do { try inEngine.start(); print("[probe] input engine started, running=\(inEngine.isRunning)") } catch { print("[probe] input start failed: \(error)") }

wait(4)
print("[probe] output-first: input callbacks=\(frames) peak=\(peak) inRunning=\(inEngine.isRunning) outRunning=\(outEngine?.isRunning ?? false)")
inEngine.inputNode.removeTap(onBus: 0)
inEngine.stop()
outPlayer?.stop(); outEngine?.stop()
