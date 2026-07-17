import AVFoundation
import Foundation
import SpeechVAD

final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0

    var onSpeechEnded: (() -> Void)?

    private let engine: AVAudioEngine
    private var samples: [Float] = []
    private let lock = NSLock()
    private let targetSampleRate: Double

    private let vadProcessor: StreamingVADProcessor
    private var speechActive = false
    private var tapFireCount: Int = 0

    init(targetSampleRate: Double = 16000, vadProcessor: StreamingVADProcessor, engine: AVAudioEngine) {
        self.targetSampleRate = targetSampleRate
        self.vadProcessor = vadProcessor
        self.engine = engine
    }

    func startRecording() {
        print("[AudioRecorder] startRecording called, engine.running=\(engine.isRunning)")
        lock.lock()
        samples.removeAll()
        lock.unlock()

        speechActive = false
        tapFireCount = 0
        vadProcessor.reset()
        print("[AudioRecorder] VAD reset")

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        print("[AudioRecorder] input device: \(engine.inputNode), format=\(inputFormat)")

        if !engine.isRunning {
            do {
                try engine.start()
                print("[AudioRecorder] engine started")
            } catch {
                print("[AudioRecorder] engine start failed: \(error)")
                return
            }
        }

        let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: targetSampleRate,
                                            channels: 1,
                                            interleaved: false)!

        let converter = AVAudioConverter(from: inputFormat, to: recordingFormat)!

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, when in
            guard let self else { return }
            self.tapFireCount += 1
            if self.tapFireCount == 1 {
                print("[AudioRecorder] TAP: first callback, sampleRate=\(buffer.format.sampleRate), channels=\(buffer.format.channelCount)")
            }

            let targetFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * recordingFormat.sampleRate / inputFormat.sampleRate)
            guard let converted = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: targetFrameCount) else { return }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            converter.convert(to: converted, error: &error, withInputFrom: inputBlock)

            guard let channelData = converted.floatChannelData else { return }
            let floatPtr = channelData[0]
            let data = Array(UnsafeBufferPointer(start: floatPtr, count: Int(converted.frameLength)))

            var sum: Float = 0
            for s in data { sum += s * s }
            let rms = sqrt(sum / max(Float(data.count), 1))

            self.lock.lock()
            self.samples.append(contentsOf: data)
            self.lock.unlock()

            DispatchQueue.main.async {
                self.audioLevel = rms
            }

            let events = self.vadProcessor.process(samples: data)
            for event in events {
                switch event {
                case .speechStarted(let time):
                    print("[VAD] Speech started at \(String(format: "%.2f", time))s")
                    self.speechActive = true
                case .speechEnded(let segment):
                    print("[VAD] Speech ended at \(String(format: "%.2f", segment.endTime))s (duration: \(String(format: "%.2f", segment.duration))s)")
                    self.speechActive = false
                    DispatchQueue.main.async {
                        self.onSpeechEnded?()
                    }
                }
            }
        }

        isRecording = true
        print("[AudioRecorder] capture started (AVAudioEngine tap)")
    }

    func stopRecording() -> [Float] {
        print("[AudioRecorder] stopRecording called, isRecording=\(isRecording), tapFireCount=\(tapFireCount)")
        engine.inputNode.removeTap(onBus: 0)
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
}
