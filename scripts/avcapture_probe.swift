import AVFoundation
import CoreMedia
import Foundation
import Darwin

setbuf(stdout, nil)

final class Delegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var buffers = 0
    var peak: Float = 0
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        buffers += 1
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let floatCount = length / MemoryLayout<Float>.size
        pointer.withMemoryRebound(to: Float.self, capacity: floatCount) { p in
            for i in 0..<floatCount { peak = max(peak, abs(p[i])) }
        }
    }
}

let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
print("[av] audio devices: \(devices.map { $0.localizedName })")
guard let device = devices.first(where: { $0.localizedName.uppercased().contains("EDIFIER") }) ?? AVCaptureDevice.default(for: .audio) else {
    print("[av] no audio device"); exit(1)
}
print("[av] using \(device.localizedName)")
let session = AVCaptureSession()
session.beginConfiguration()
let input = try AVCaptureDeviceInput(device: device)
if session.canAddInput(input) { session.addInput(input) } else { print("[av] cannot add input"); exit(1) }
let output = AVCaptureAudioDataOutput()
let delegate = Delegate()
let queue = DispatchQueue(label: "av.audio")
output.setSampleBufferDelegate(delegate, queue: queue)
if session.canAddOutput(output) { session.addOutput(output) } else { print("[av] cannot add output"); exit(1) }
session.commitConfiguration()
session.startRunning()
print("[av] running=\(session.isRunning)")
RunLoop.main.run(until: Date().addingTimeInterval(5))
print("[av] RESULT buffers=\(delegate.buffers) peak=\(delegate.peak)")
session.stopRunning()
