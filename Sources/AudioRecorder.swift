import AVFoundation
import Foundation
import SpeechVAD

final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0

    var onSpeechEnded: (() -> Void)?

    private var session: AVCaptureSession?
    private var samples: [Float] = []
    private let lock = NSLock()
    private let targetSampleRate: Double

    private let vadProcessor: StreamingVADProcessor
    private var speechActive = false
    private var tapFireCount: Int = 0

    init(targetSampleRate: Double = 16000, vadProcessor: StreamingVADProcessor) {
        self.targetSampleRate = targetSampleRate
        self.vadProcessor = vadProcessor
        super.init()
    }

    func startRecording() {
        print("[AudioRecorder] startRecording called")
        lock.lock()
        samples.removeAll()
        lock.unlock()

        speechActive = false
        tapFireCount = 0
        vadProcessor.reset()
        print("[AudioRecorder] VAD reset")

        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .audio) else {
            print("[AudioRecorder] ERROR: no audio capture device")
            return
        }
        print("[AudioRecorder] device: \(device.localizedName)")

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            print("[AudioRecorder] ERROR: cannot create device input")
            return
        }

        guard session.canAddInput(input) else {
            print("[AudioRecorder] ERROR: cannot add audio input to session")
            return
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        let queue = DispatchQueue(label: "audio.capture.queue")
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            print("[AudioRecorder] ERROR: cannot add audio output to session")
            return
        }
        session.addOutput(output)

        self.session = session
        session.startRunning()
        isRecording = true
        print("[AudioRecorder] capture session started")
    }

    func stopRecording() -> [Float] {
        print("[AudioRecorder] stopRecording called, isRecording=\(isRecording), tapFireCount=\(tapFireCount)")
        session?.stopRunning()
        session = nil
        isRecording = false
        audioLevel = 0

        lock.lock()
        let result = samples
        let count = result.count
        samples.removeAll()
        lock.unlock()
        print("[AudioRecorder] stopRecording returning \(count) samples, tapFireCount=\(tapFireCount)")
        return result
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        tapFireCount += 1
        if tapFireCount == 1 {
            if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)
                print("[AudioRecorder] TAP: first callback, sampleRate=\(asbd?.pointee.mSampleRate ?? 0), channels=\(asbd?.pointee.mChannelsPerFrame ?? 0)")
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer,
                                    atOffset: 0,
                                    lengthAtOffsetOut: nil,
                                    totalLengthOut: &length,
                                    dataPointerOut: &dataPointer)

        guard let data = dataPointer, length > 0 else { return }

        let floatCount = length / MemoryLayout<Float>.stride
        let floatPointer = data.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }
        let buffer = UnsafeBufferPointer(start: floatPointer, count: floatCount)
        let audioChunk = Array(buffer)

        var sum: Float = 0
        for s in audioChunk { sum += s * s }
        let rms = sqrt(sum / max(Float(audioChunk.count), 1))

        lock.lock()
        samples.append(contentsOf: audioChunk)
        lock.unlock()

        DispatchQueue.main.async {
            self.audioLevel = rms
        }

        let events = vadProcessor.process(samples: audioChunk)
        for event in events {
            switch event {
            case .speechStarted(let time):
                print("[VAD] Speech started at \(String(format: "%.2f", time))s")
                speechActive = true
            case .speechEnded(let segment):
                print("[VAD] Speech ended at \(String(format: "%.2f", segment.endTime))s (duration: \(String(format: "%.2f", segment.duration))s)")
                speechActive = false
                DispatchQueue.main.async {
                    self.onSpeechEnded?()
                }
            }
        }
    }
}
