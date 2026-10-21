import AVFoundation
import Foundation

print("[probe] authStatus(for: .audio).rawValue = \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)  (3 = authorized)")
let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.inputFormat(forBus: 0)
print("[probe] input format = \(format)")

final class Counter {
    var frames = 0
    var peak: Float = 0
}
let counter = Counter()
input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
    counter.frames += 1
    if let ch = buffer.floatChannelData {
        let n = Int(buffer.frameLength)
        for i in 0..<n { counter.peak = max(counter.peak, abs(ch[0][i])) }
    }
}
do {
    try engine.start()
    print("[probe] engine started")
} catch {
    print("[probe] engine start failed: \(error)")
}
RunLoop.main.run(until: Date().addingTimeInterval(4))
print("[probe] callbacks=\(counter.frames) peak=\(counter.peak)")
input.removeTap(onBus: 0)
engine.stop()
