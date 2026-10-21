import AVFoundation
import Foundation
import CoreAudio
import SpeechVAD

/// Captures microphone audio through an `AVAudioEngine` tap, converts it to
/// 16 kHz mono float samples and feeds it to the streaming VAD.
///
/// Hard-won lessons (see PITFALL.md #11/#12):
/// * only **one** `AVAudioEngine` may run in the process (a silent Now-Playing
///   output engine started first starves the input tap entirely);
/// * after the Bluetooth profile switches A2DP ↔ HFP, the first capture attempt
///   can bind to the wrong input endpoint (e.g. 44.1 kHz instead of the
///   headset's 16 kHz HFP) and then the tap never fires. We therefore watch for
///   a silent tap and retry with a **fresh engine** after a short settle delay;
/// * graph mutations (attach/connect) must happen before `engine.start()`.
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0

    var onSpeechEnded: (() -> Void)?
    /// Called when every capture attempt failed (no input callbacks at all).
    var onCaptureFailed: (() -> Void)?
    /// Diagnostics sink (the ViewModel writes these into the conversation log).
    var onLog: ((String) -> Void)?

    /// Recreated for every capture attempt.
    private var engine = AVAudioEngine()
    private var samples: [Float] = []
    /// Peak absolute sample seen since `startRecording()` (guarded by `sampleLock`).
    private var peak: Float = 0
    /// Protects `samples` / `peak`.
    private let sampleLock = NSLock()
    /// Protects `vadProcessor` (touched from the audio thread and from main).
    private let vadLock = NSLock()
    /// Protects `isRecording` / `tapFireCount` / `captureToken`.
    private let stateLock = NSLock()
    private let targetSampleRate: Double

    private let vadProcessor: StreamingVADProcessor
    private var speechActive = false
    private var tapFireCount: Int = 0
    private var tapInstalled = false
    /// Incremented on every start/stop so stale retries and stale taps are ignored.
    private var captureToken = 0

    private static let maxCaptureAttempts = 3
    /// How long to wait for the first tap callback before declaring the attempt dead.
    private static let tapWatchdogDelay: TimeInterval = 0.9
    /// Settle time between a failed attempt and the next one.
    private static let retryDelay: TimeInterval = 0.5

    /// Silent looping player attached to the SAME engine as the input tap.
    /// While recording this is the only AVAudioEngine in the process, so the
    /// app stays "Now Playing" (media keys keep working) without a second
    /// output engine that would starve the input tap.
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

    // MARK: - Public API

    func startRecording() {
        stateLock.lock()
        if isRecording {
            stateLock.unlock()
            report("[AudioRecorder] startRecording ignored (already recording)")
            return
        }
        isRecording = true
        tapFireCount = 0
        captureToken &+= 1
        let token = captureToken
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

        beginCapture(token: token, attempt: 1)
    }

    @discardableResult
    func stopRecording() -> [Float] {
        stateLock.lock()
        guard isRecording else {
            stateLock.unlock()
            return []
        }
        isRecording = false
        captureToken &+= 1 // invalidate any pending retry / watchdog
        let fireCount = tapFireCount
        stateLock.unlock()

        teardownEngine()

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

    // MARK: - Capture lifecycle

    private func beginCapture(token: Int, attempt: Int) {
        guard isCurrentCapture(token) else { return }

        // Fresh engine for every attempt: a reused engine can keep the previous
        // (wrong) input format/endpoint after a Bluetooth profile switch.
        engine = AVAudioEngine()
        tapInstalled = false
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        report("[AudioRecorder] attempt \(attempt)/\(Self.maxCaptureAttempts) input=\(inputFormat) defaultInput=\(defaultInputInfo())")

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            report("[AudioRecorder] no usable microphone format")
            scheduleRetry(token: token, attempt: attempt, reason: "invalid input format")
            return
        }

        guard let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: targetSampleRate,
                                                  channels: 1,
                                                  interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            report("[AudioRecorder] failed to create converter \(inputFormat) -> \(targetSampleRate)Hz mono")
            scheduleRetry(token: token, attempt: attempt, reason: "converter creation failed")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.stateLock.lock()
            let active = self.isRecording && token == self.captureToken
            self.stateLock.unlock()
            guard active else { return }
            self.handleTap(buffer: buffer, converter: converter, recordingFormat: recordingFormat)
        }
        tapInstalled = true

        prepareKeepAlivePlayer()

        do {
            try engine.start()
            report("[AudioRecorder] engine started")
        } catch {
            report("[AudioRecorder] engine start failed: \(error)")
            scheduleRetry(token: token, attempt: attempt, reason: "engine start failed")
            return
        }

        keepAlivePlayer?.play()
        report("[AudioRecorder] capture started (AVAudioEngine tap)")

        // If the tap never fires, we bound to a dead endpoint. Recreate the
        // engine and try again after the device settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapWatchdogDelay) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let active = self.isRecording && token == self.captureToken
            let fires = self.tapFireCount
            self.stateLock.unlock()
            guard active, fires == 0 else { return }
            self.report("[AudioRecorder] no input callbacks after \(Self.tapWatchdogDelay)s")
            self.scheduleRetry(token: token, attempt: attempt, reason: "tap watchdog")
        }
    }

    private func scheduleRetry(token: Int, attempt: Int, reason: String) {
        guard isCurrentCapture(token) else { return }
        teardownEngine()

        guard attempt < Self.maxCaptureAttempts else {
            report("[AudioRecorder] capture failed after \(attempt) attempts (\(reason))")
            stateLock.lock()
            isRecording = false
            captureToken &+= 1
            stateLock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.onCaptureFailed?()
            }
            return
        }

        report("[AudioRecorder] retrying capture in \(Self.retryDelay)s (attempt \(attempt) failed: \(reason))")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self, self.isCurrentCapture(token) else { return }
            self.beginCapture(token: token, attempt: attempt + 1)
        }
    }

    private func teardownEngine() {
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        engine.reset()
    }

    private func isCurrentCapture(_ token: Int) -> Bool {
        stateLock.lock()
        let ok = isRecording && token == captureToken
        stateLock.unlock()
        return ok
    }

    // MARK: - Audio

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

    deinit {
        stateLock.lock()
        isRecording = false
        captureToken &+= 1
        stateLock.unlock()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    /// Attach a zero-volume looping player to the recording engine so macOS
    /// keeps treating this process as the Now Playing app while the mic is open.
    /// Must be called BEFORE `engine.start()`.
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

    /// Diagnostics: which device does AVAudioEngine actually use as input?
    private func defaultInputInfo() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != 0 else { return "none" }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let nameStatus = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, pointer)
        }
        let deviceName = (nameStatus == noErr ? name?.takeUnretainedValue() as String? : nil) ?? "?"

        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        let rateStatus = AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &rate)
        let rateText = rateStatus == noErr ? String(format: "%.0f", rate) : "?"
        return "\(deviceName) id=\(device) sr=\(rateText)"
    }
}
