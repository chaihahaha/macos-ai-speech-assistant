import AVFoundation
import CoreMedia
import Foundation
import SpeechVAD

/// Captures microphone audio through `AVCaptureSession` — the same audio path
/// used by video-conferencing apps. `AVAudioEngine` was fundamentally unable to
/// use this headset's HFP microphone: input-only delivered 16 kHz zeros, a
/// duplex engine delivered zero callbacks, and voice processing attenuated the
/// signal. `AVCaptureSession` activates the HFP/SCO link correctly.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0

    /// True when the capture session (or the file-based test feed) is running.
    var isEngineRunning: Bool {
        if !testAudioFiles.isEmpty { return true }
        return session?.isRunning == true
    }

    /// When non-empty, AudioRecorder replays these files instead of using the
    /// microphone. Used by the headless three-round test.
    var testAudioFiles: [URL] = []
    var onTestFinished: (() -> Void)?

    var onSpeechEnded: ((TimeInterval) -> Void)?
    var onSpeechStarted: (() -> Void)?
    /// Called once per capture when the first audio buffer arrives.
    var onFirstTap: (() -> Void)?
    var onCaptureFailed: (() -> Void)?
    var onLog: ((String) -> Void)?

    private let targetSampleRate: Double
    private let vadProcessor: StreamingVADProcessor

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private let sessionQueue = DispatchQueue(label: "AudioRecorder.session")
    private let audioQueue = DispatchQueue(label: "AudioRecorder.audio")

    private var samples: [Float] = []
    private var peak: Float = 0
    private let sampleLock = NSLock()
    private let vadLock = NSLock()
    private let stateLock = NSLock()

    private var bufferCount = 0
    private var didReportFirstBuffer = false
    private var captureToken = 0
    private var speechActive = false
    private var firstBufferWatchdog: DispatchWorkItem?
    private var testFileIndex = 0
    private var testPending: [Float] = []
    private var testFeedToken = 0

    init(targetSampleRate: Double = 16000, vadProcessor: StreamingVADProcessor) {
        self.targetSampleRate = targetSampleRate
        self.vadProcessor = vadProcessor
        super.init()
    }

    private func report(_ message: String) {
        print(message)
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(message)
        }
    }

    // MARK: - Public API

    func startRecording() {
        if !testAudioFiles.isEmpty {
            startTestCapture()
            return
        }
        stateLock.lock()
        if isRecording {
            stateLock.unlock()
            report("[AudioRecorder] startRecording ignored (already recording)")
            return
        }
        isRecording = true
        captureToken &+= 1
        let token = captureToken
        bufferCount = 0
        didReportFirstBuffer = false
        stateLock.unlock()

        sampleLock.lock()
        samples.removeAll()
        peak = 0
        sampleLock.unlock()

        speechActive = false
        vadLock.lock()
        vadProcessor.reset()
        vadLock.unlock()

        report("[AudioRecorder] startRecording (AVCaptureSession)")
        startSessionIfNeeded(token: token)
    }

    /// End the utterance but keep the capture session running so the headset
    /// stays in HFP and the next turn needs no profile switch.
    @discardableResult
    func finishCapture() -> [Float] {
        stateLock.lock()
        guard isRecording else {
            stateLock.unlock()
            return []
        }
        isRecording = false
        let count = bufferCount
        stateLock.unlock()
        firstBufferWatchdog?.cancel()
        firstBufferWatchdog = nil

        sampleLock.lock()
        let result = samples
        let peakValue = peak
        samples.removeAll()
        peak = 0
        sampleLock.unlock()
        report("[AudioRecorder] capture finished (session kept alive): \(result.count) samples, peak=\(String(format: "%.4f", peakValue)), buffers=\(count)")
        return result
    }

    func resumeCapture() {
        stateLock.lock()
        let canResume = !isRecording && session?.isRunning == true
        if canResume {
            isRecording = true
            captureToken &+= 1
            bufferCount = 0
            didReportFirstBuffer = false
        }
        let token = captureToken
        stateLock.unlock()

        guard canResume else {
            startRecording()
            return
        }

        sampleLock.lock()
        samples.removeAll()
        peak = 0
        sampleLock.unlock()
        speechActive = false
        vadLock.lock()
        vadProcessor.reset()
        vadLock.unlock()
        report("[AudioRecorder] capture resumed on existing session")
        startFirstBufferWatchdog(token: token)
    }

    @discardableResult
    func stopRecording() -> [Float] {
        stateLock.lock()
        isRecording = false
        captureToken &+= 1
        let count = bufferCount
        stateLock.unlock()
        firstBufferWatchdog?.cancel()
        firstBufferWatchdog = nil

        if let session, session.isRunning {
            sessionQueue.async { session.stopRunning() }
        }
        session = nil
        output = nil

        sampleLock.lock()
        let result = samples
        samples.removeAll()
        peak = 0
        sampleLock.unlock()
        report("[AudioRecorder] stopped (session torn down): \(result.count) samples, buffers=\(count)")
        return result
    }

    // MARK: - Session

    private func startSessionIfNeeded(token: Int) {
        if let session, session.isRunning {
            startFirstBufferWatchdog(token: token)
            report("[AudioRecorder] capture started (reused running session)")
            return
        }

        guard configureSessionIfNeeded() else {
            failCapture()
            return
        }
        guard let session else {
            failCapture()
            return
        }
        startFirstBufferWatchdog(token: token)
        report("[AudioRecorder] capture started (AVCaptureSession)")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            session.startRunning()
            let running = session.isRunning
            self.report("[AudioRecorder] session.startRunning done, running=\(running)")
            if !running {
                DispatchQueue.main.async { [weak self] in self?.failCapture() }
            }
        }
    }

    private func configureSessionIfNeeded() -> Bool {
        if session != nil { return true }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        let device = devices.first(where: { $0.localizedName.uppercased().contains("EDIFIER") }) ?? AVCaptureDevice.default(for: .audio)
        guard let device else {
            report("[AudioRecorder] no audio capture device")
            return false
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                report("[AudioRecorder] cannot add input \(device.localizedName)")
                return false
            }
            session.addInput(input)
        } catch {
            report("[AudioRecorder] device input failed: \(error)")
            return false
        }

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: audioQueue)
        guard session.canAddOutput(output) else {
            report("[AudioRecorder] cannot add audio output")
            return false
        }
        session.addOutput(output)
        session.commitConfiguration()
        self.session = session
        self.output = output
        report("[AudioRecorder] configured device=\(device.localizedName)")
        return true
    }

    private func startFirstBufferWatchdog(token: Int) {
        firstBufferWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let active = self.isRecording && token == self.captureToken
            let count = self.bufferCount
            self.stateLock.unlock()
            guard active, count == 0 else { return }
            self.report("[AudioRecorder] no audio buffers after 4s")
            self.failCapture()
        }
        firstBufferWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func failCapture() {
        stateLock.lock()
        guard isRecording else {
            stateLock.unlock()
            return
        }
        isRecording = false
        captureToken &+= 1
        stateLock.unlock()
        firstBufferWatchdog?.cancel()
        firstBufferWatchdog = nil
        DispatchQueue.main.async { [weak self] in
            self?.onCaptureFailed?()
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        stateLock.lock()
        let active = isRecording
        let isFirst = !didReportFirstBuffer && active
        stateLock.unlock()
        guard active else { return }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let floatCount = length / MemoryLayout<Float>.size
        guard floatCount > 0 else { return }
        let data = pointer.withMemoryRebound(to: Float.self, capacity: floatCount) {
            Array(UnsafeBufferPointer(start: $0, count: floatCount))
        }
        var description = "unknown"
        if let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            description = "\(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch"
        }
        processAudio(data, isFirst: isFirst, description: description)
    }

    /// Shared by AVCaptureSession and the file-based test feed.
    private func processAudio(_ data: [Float], isFirst: Bool, description: String = "file") {
        stateLock.lock()
        if isFirst { didReportFirstBuffer = true }
        bufferCount += 1
        stateLock.unlock()

        if isFirst {
            report("[AudioRecorder] TAP: first buffer (\(description))")
            DispatchQueue.main.async { [weak self] in self?.onFirstTap?() }
        }

        var sum: Float = 0
        var bufferPeak: Float = 0
        for sample in data {
            sum += sample * sample
            bufferPeak = max(bufferPeak, abs(sample))
        }
        let rms = sqrt(sum / max(Float(data.count), 1))

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
                speechActive = true
                DispatchQueue.main.async { [weak self] in self?.onSpeechStarted?() }
            case .speechEnded(let segment):
                report("[VAD] Speech ended at \(String(format: "%.2f", segment.endTime))s (duration: \(String(format: "%.2f", segment.duration))s)")
                speechActive = false
                let duration = Double(segment.duration)
                DispatchQueue.main.async { [weak self] in self?.onSpeechEnded?(duration) }
            }
        }
    }

    // MARK: - File-based test feed

    private func startTestCapture() {
        stateLock.lock()
        if isRecording {
            stateLock.unlock()
            return
        }
        isRecording = true
        captureToken &+= 1
        let token = captureToken
        bufferCount = 0
        didReportFirstBuffer = false
        stateLock.unlock()

        sampleLock.lock()
        samples.removeAll()
        peak = 0
        sampleLock.unlock()
        speechActive = false
        vadLock.lock()
        vadProcessor.reset()
        vadLock.unlock()

        guard testFileIndex < testAudioFiles.count else {
            stateLock.lock()
            isRecording = false
            stateLock.unlock()
            report("[TEST] all audio files processed")
            DispatchQueue.main.async { [weak self] in self?.onTestFinished?() }
            return
        }

        let url = testAudioFiles[testFileIndex]
        testFileIndex += 1
        report("[TEST] feeding \(url.lastPathComponent)")

        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let capacity = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "buffer alloc failed"])
            }
            try file.read(into: buffer)
            var data: [Float]
            if let channel = buffer.floatChannelData?[0] {
                data = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            } else {
                data = convertToTarget(buffer, from: format) ?? []
            }
            if abs(format.sampleRate - targetSampleRate) > 1 || format.channelCount != 1 {
                data = convertToTarget(buffer, from: format) ?? data
            }
            // Append trailing silence so the VAD emits speechEnded.
            data.append(contentsOf: [Float](repeating: 0, count: Int(targetSampleRate * 0.8)))
            testPending = data
            testFeedToken &+= 1
            let feedToken = testFeedToken
            feedTestChunk(token: token, feedToken: feedToken)
        } catch {
            report("[TEST] read failed: \(error)")
            stateLock.lock()
            isRecording = false
            stateLock.unlock()
            DispatchQueue.main.async { [weak self] in self?.onCaptureFailed?() }
        }
    }

    private func convertToTarget(_ source: AVAudioPCMBuffer, from format: AVAudioFormat) -> [Float]? {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { return nil }
        let ratio = targetSampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var provided = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if provided { status.pointee = .endOfStream; return nil }
            provided = true
            status.pointee = .haveData
            return source
        }
        guard let channel = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    private func feedTestChunk(token: Int, feedToken: Int) {
        stateLock.lock()
        let active = isRecording && token == captureToken && feedToken == testFeedToken
        stateLock.unlock()
        guard active, !testPending.isEmpty else { return }

        let count = min(1024, testPending.count)
        let chunk = Array(testPending.prefix(count))
        testPending.removeFirst(count)
        processAudio(chunk, isFirst: !didReportFirstBuffer, description: "file")

        if !testPending.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.064) { [weak self] in
                self?.feedTestChunk(token: token, feedToken: feedToken)
            }
        }
    }
}
