import AVFoundation
import Foundation
import SpeechVAD

/// Captures microphone audio through an `AVAudioEngine` tap, converts it to
/// 16 kHz mono float samples and feeds it to the streaming VAD.
///
/// The lifecycle is deliberately idempotent: `startRecording()` on an already
/// running recorder is a no-op (installing a second tap on the same bus raises
/// an Objective-C exception), and `stopRecording()` on a stopped recorder
/// returns no samples instead of removing a tap that was never installed.
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0

    var onSpeechEnded: (() -> Void)?

    private let engine: AVAudioEngine
    private var samples: [Float] = []
    /// Protects `samples`.
    private let sampleLock = NSLock()
    /// Protects `vadProcessor` (touched from the audio thread and from main).
    private let vadLock = NSLock()
    /// Protects `isRecording` / `tapFireCount`.
    private let stateLock = NSLock()
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
        stateLock.lock()
        if isRecording {
            stateLock.unlock()
            print("[AudioRecorder] startRecording ignored (already recording)")
            return
        }
        isRecording = true
        tapFireCount = 0
        stateLock.unlock()

        print("[AudioRecorder] startRecording called, engine.running=\(engine.isRunning)")

        sampleLock.lock()
        samples.removeAll()
        sampleLock.unlock()

        speechActive = false
        vadLock.lock()
        vadProcessor.reset()
        vadLock.unlock()
        print("[AudioRecorder] VAD reset")

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        print("[AudioRecorder] input device: \(inputNode), format=\(inputFormat)")

        if !engine.isRunning {
            do {
                try engine.start()
                print("[AudioRecorder] engine started")
            } catch {
                print("[AudioRecorder] engine start failed: \(error)")
                stateLock.lock()
                isRecording = false
                stateLock.unlock()
                return
            }
        }

        guard let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: targetSampleRate,
                                                  channels: 1,
                                                  interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            print("[AudioRecorder] failed to create converter \(inputFormat) -> \(targetSampleRate)Hz mono")
            stateLock.lock()
            isRecording = false
            stateLock.unlock()
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.stateLock.lock()
            let active = self.isRecording
            self.stateLock.unlock()
            guard active else { return }
            self.handleTap(buffer: buffer, converter: converter, recordingFormat: recordingFormat)
        }

        print("[AudioRecorder] capture started (AVAudioEngine tap)")
    }

    /// Runs on the audio render thread.
    private func handleTap(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, recordingFormat: AVAudioFormat) {
        stateLock.lock()
        tapFireCount += 1
        let fireCount = tapFireCount
        stateLock.unlock()

        if fireCount == 1 {
            print("[AudioRecorder] TAP: first callback, sampleRate=\(buffer.format.sampleRate), channels=\(buffer.format.channelCount)")
        }

        let inputFormat = buffer.format
        let targetFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * recordingFormat.sampleRate / inputFormat.sampleRate)
        guard targetFrameCount > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: targetFrameCount) else {
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        converter.convert(to: converted, error: &error, withInputFrom: inputBlock)

        guard let channelData = converted.floatChannelData else { return }
        let floatPtr = channelData[0]
        let data = Array(UnsafeBufferPointer(start: floatPtr, count: Int(converted.frameLength)))
        guard !data.isEmpty else { return }

        var sum: Float = 0
        for s in data { sum += s * s }
        let rms = sqrt(sum / max(Float(data.count), 1))

        sampleLock.lock()
        samples.append(contentsOf: data)
        sampleLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = rms
        }

        vadLock.lock()
        let events = vadProcessor.process(samples: data)
        vadLock.unlock()

        for event in events {
            switch event {
            case .speechStarted(let time):
                print("[VAD] Speech started at \(String(format: "%.2f", time))s")
                self.speechActive = true
            case .speechEnded(let segment):
                print("[VAD] Speech ended at \(String(format: "%.2f", segment.endTime))s (duration: \(String(format: "%.2f", segment.duration))s)")
                self.speechActive = false
                DispatchQueue.main.async { [weak self] in
                    self?.onSpeechEnded?()
                }
            }
        }
    }

    @discardableResult
    func stopRecording() -> [Float] {
        stateLock.lock()
        guard isRecording else {
            stateLock.unlock()
            return []
        }
        isRecording = false
        let fireCount = tapFireCount
        stateLock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        audioLevel = 0
        print("[AudioRecorder] stopRecording called, tapFireCount=\(fireCount)")

        sampleLock.lock()
        let result = samples
        let count = result.count
        samples.removeAll()
        sampleLock.unlock()
        print("[AudioRecorder] stopRecording returning \(count) samples, tapFireCount=\(fireCount)")
        return result
    }

    deinit {
        stateLock.lock()
        let active = isRecording
        isRecording = false
        stateLock.unlock()
        if active {
            engine.inputNode.removeTap(onBus: 0)
        }
    }
}
