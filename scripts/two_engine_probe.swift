import AVFoundation
import Foundation

final class SilentOut {
    var engine: AVAudioEngine?
    var player: AVAudioPlayerNode?
    func start() {
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
            engine = e; player = p
            print("[probe] silent output started, running=\(e.isRunning), format=\(fmt)")
        } catch { print("[probe] silent output start failed: \(error)") }
    }
    func stop() { player?.stop(); engine?.stop(); engine = nil; player = nil }
}

let out = SilentOut()

let inEngine = AVAudioEngine()
let input = inEngine.inputNode
let fmt = input.inputFormat(forBus: 0)
var total = 0
var peak: Float = 0
input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
    total += 1
    if let ch = buffer.floatChannelData { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[0][i])) } }
}
print("[probe] input format=\(fmt)")
do { try inEngine.start(); print("[probe] input engine started, running=\(inEngine.isRunning)") } catch { print("[probe] input start failed: \(error)") }

func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

wait(2)
let phase1 = total
print("[probe] phase1 input-only callbacks=\(phase1) peak=\(peak)")

out.start()
wait(2)
let phase2 = total - phase1
print("[probe] phase2 with silent-output-engine callbacks=\(phase2) peak=\(peak) outRunning=\(out.engine?.isRunning ?? false)")

out.stop()
out.start()   // simulate the keep-alive watchdog restart
wait(2)
let phase3 = total - phase1 - phase2
print("[probe] phase3 after output restart callbacks=\(phase3) peak=\(peak) outRunning=\(out.engine?.isRunning ?? false)")

inEngine.inputNode.removeTap(onBus: 0)
inEngine.stop()
out.stop()
