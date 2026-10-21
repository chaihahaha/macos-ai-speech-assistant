import AVFoundation
import Foundation
import SpeechVAD

/// Captures microphone audio through an `AVAudioEngine` tap, converts it to
/// 16 kHz mono float samples and feeds it to the streaming VAD.
///
/// The recorder owns a **dedicated** engine. It must not share the engine that
/// keeps the app registered as "Now Playing": as soon as an input tap is
/// installed on an engine, macOS opens the microphone and Bluetooth headsets
/// switch from A2DP to HFP (hands-free / call mode). If that engine keeps
/// running after recording, the microphone stays open — output then goes
/// through the headset's call path (often silent) and the headset's button
/// changes from media keys to call controls.
///
/// The lifecycle is also idempotent: `startRecording()` on an already running
/// recorder is a no-op (installing a second tap on the same bus raises an
/// Objective-C exception), and `stopRecording()` on a stopped recorder returns
/// no samples instead of removing a tap that was never installed.
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0

    var onSpeechEnded: (() -> Void)?
    /// Diagnostics sink (the ViewModel writes these into the conversation log).
    var onLog: ((String) -> Void)?

    /// Dedicated engine — only ever used for microphone capture.
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    /// Peak absolute sample seen since `startRecording()` (guarded by `sampleLock`).
    private var peak: Float = 0
    /// Protects `samples` / `peak`.
    private let sampleLock = NSLock()
    /// Protects `vadProcessor` (touched from the audio thread and from main).
    private let vadLock = NSLock()
    /// Protects `isRecording` / `tapFireCount`.
    private let stateLock = NSLock()
    private let targetSampleRate: Double

    private let vadProcessor: StreamingVADProcessor
    private var speechActive = false
    private var tapFireCount: Int = 0

    /// Silent looping player attached to the SAME engine as the input tap.
    /// While recording this is the only AVAudioEngine in the process, so the
    /// app stays "Now Playing" (media keys keep working) without a second
    /// output engine that would starve the input tap (see PITFALL.md #11).
    private var keepAlivePlayer: AVAudioPlayerNode?

    init(targetSampleRate: Double = 16000, vadProcessor: StreamingVADProcessor) {
        self.targetSampleRate = targetSampleRate
        self.vadProcessor = vadProcessor
    }

    private func report(_ message: String) {
        print(message)
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(message)
        }
    }

    func startRecording() {
        stateLock.lock()
        if isRecording {
            stateLock.unlock()
            report("[AudioRecorder] startRecording ignored (already recording)")
            return
        }
        isRecording = true
        tapFireCount = 0
        stateLock.unlock()

        report("[AudioRecorder] startRecording called, engine.running=\(engine.isRunning)")

        sampleLock.lock()
        samples.removeAll()
        peak = 0
        sampleLock.unlock()

        speechActive = false
        vadLock.lock()
        vadProcessor.reset()
        vadLock.unlock()
        report("[AudioRecorder] VAD reset")

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        report("[AudioRecorder] input format=\(inputFormat), sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            report("[AudioRecorder] no usable microphone format; aborting recording")
            stateLock.lock()
            isRecording = false
            stateLock.unlock()
            return
        }

        guard let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: targetSampleRate,
                                                  channels: 1,
                                                  interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            report("[AudioRecorder] failed to create converter \(inputFormat) -> \(targetSampleRate)Hz mono")
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

        // Attach the silent player BEFORE starting: mutating the graph while the
        // engine runs can hang/crash, and connecting before start is what the
        // successful probe used.
        prepareKeepAlivePlayer()

        if !engine.isRunning {
            do {
                try engine.start()
                report("[AudioRecorder] engine started")
            } catch {
                report("[AudioRecorder] engine start failed: \(error)")
                inputNode.removeTap(onBus: 0)
                keepAlivePlayer = nil
                stateLock.lock()
                isRecording = false
                stateLock.unlock()
                return
            }
        }

        keepAlivePlayer?.play()
        report("[AudioRecorder] capture started (AVAudioEngine tap)")
    }

    /// Runs on the audio render thread.
    private func handleTap(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, recordingFormat: AVAudioFormat) {
        stateLock.lock()
        tapFireCount += 1
        let fireCount = tapFireCount
        stateLock.unlock()

        if fireCount == 1 {
            report("[AudioRecorder] TAP: first callback, sampleRate=\(buffer.format.sampleRate), channels=\(buffer.format.channelCount)")
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

        var bufferPeak: Float = 0
        for s in data { bufferPeak = max(bufferPeak, abs(s)) }

        sampleLock.lock()
        samples.append(contentsOf: data)
        peak = max(peak, bufferPeak)
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
                report("[VAD] Speech started at \(String(format: "%.2f", time))s")
                self.speechActive = true
            case .speechEnded(let segment):
                report("[VAD] Speech ended at \(String(format: "%.2f", segment.endTime))s (duration: \(String(format: "%.2f", segment.duration))s)")
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

        // Remove the tap and stop the engine completely: this is what releases
        // the microphone and lets a Bluetooth headset return to A2DP.
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        audioLevel = 0

        sampleLock.lock()
        let result = samples
        let count = result.count
        let peakValue = peak
        samples.removeAll()
        peak = 0
        sampleLock.unlock()
        report("[AudioRecorder] stopped: \(count) samples (\(String(format: "%.2f", Double(count) / targetSampleRate))s), peak=\(String(format: "%.4f", peakValue)), tapFireCount=\(fireCount)")
        return result
    }

    deinit {
        stateLock.lock()
        let active = isRecording
        isRecording = false
        stateLock.unlock()
        if active {
            keepAlivePlayer?.stop()
            keepAlivePlayer = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// Attach a zero-volume looping player to the recording engine so macOS
    /// keeps treating this process as the Now Playing app while the mic is open.
    /// Must be called BEFORE `engine.start()` (graph mutation after start can
    /// hang), and the player is started after the engine is running.
    private func prepareKeepAlivePlayer() {
        let format = engine.outputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            report("[AudioRecorder] keep-alive player skipped: bad output format \(format)")
            return
        }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024),
              let channels = silence.floatChannelData else {
            report("[AudioRecorder] keep-alive player skipped: buffer allocation failed")
            return
        }
        silence.frameLength = 1024
        let bytes = Int(1024 * format.streamDescription.pointee.mBytesPerFrame)
        for channel in 0..<Int(format.channelCount) {
            memset(channels[channel], 0, bytes)
        }
        player.scheduleBuffer(silence, at: nil, options: .loops)
        player.volume = 0
        keepAlivePlayer = player
        report("[AudioRecorder] keep-alive player prepared, output format=\(format)")
    }
}
