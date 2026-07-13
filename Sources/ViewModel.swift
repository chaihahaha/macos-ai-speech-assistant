import Foundation
import AVFoundation
import Qwen3ASR
import SpeechVAD
import AudioCommon

@MainActor
final class ViewModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    // MARK: - State

    enum ConversationState: String {
        case inactive
        case listening
        case waitingSilence
        case transcribing
        case generating
        case speaking
    }

    @Published var conversationState: ConversationState = .inactive
    @Published var isLoading = false
    @Published var loadingStatus: String?
    @Published var errorMessage: String?
    @Published var messages: [Message] = []
    @Published var debugInfo: String = ""
    @Published var isTyping = false
    @Published var silenceTimerValue: Double = 5.0
    @Published var currentSessID: String? = nil

    // MARK: - Private

    private var asrModel: Qwen3ASRModel?
    private var vadModel: SileroVADModel?
    private var recorder: AudioRecorder?
    private var conversationTask: Task<Void, Never>?
    private var llamaTask: Task<Void, Error>?
    private var asrTask: Task<String, Error>?
    private var opencodeClient: OpencodeClient?
    private var opencodeServerProcess: Process?

    // Config
    private let appConfig: AppConfig
    private var ttsRate: Float

    // Built-in macOS TTS
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var pendingSentence: String = ""
    private var hasStartedSpeaking = false

    // TTS utterance tracking
    private var pendingUtteranceCount = 0
    private var streamingComplete = false

    // Conversation logging
    private var conversationLogFile: URL?
    private var conversationLogHandle: FileHandle?

    // ASR buffer for silence-based sending
    private var asrBuffer: [Float] = []
    private var pendingAudio: [Float] = []
    private var lastSpeechEndTime: Date?
    private var silenceTimer: Timer?
    private var pendingSendTask: Task<Void, Never>?
    private var maxRecordingTimer: Timer?

    // Opencode response tracking
    private var opencodeResponseText = ""

    // Media key controller
    private let mediaKeys = MediaKeyController()

    override init() {
        appConfig = AppConfig.load()
        ttsRate = appConfig.tts.rate
        super.init()
        speechSynthesizer.delegate = self
        setupConversationLogging()
        setupMediaKeys()
        print("[ViewModel] Backend: \(appConfig.backend), opencode URL: \(appConfig.opencode.serverURL)")
    }

    // MARK: - Media Key Setup

    private func setupMediaKeys() {
        mediaKeys.setHandlers(
            playPause: { [weak self] in self?.toggleTTSSpeed() },
            nextTrack: { [weak self] in self?.handleNextTrack() },
            previousTrack: { [weak self] in self?.handlePreviousTrack() }
        )
        mediaKeys.becomeNowPlaying()
    }

    deinit {
        speechSynthesizer.stopSpeaking(at: .immediate)
        llamaTask?.cancel()
        pendingSendTask?.cancel()
        maxRecordingTimer?.invalidate()
        silenceTimer?.invalidate()
        opencodeClient?.reset()
        opencodeServerProcess?.terminate()
        try? conversationLogHandle?.close()
    }

    private func toggleTTSSpeed() {
        let oldRate = ttsRate
        if ttsRate <= appConfig.tts.slowRate + 0.05 {
            ttsRate = appConfig.tts.fastRate
            debugInfo = "TTS: fast (\(String(format: "%.1f", ttsRate))x)"
        } else {
            ttsRate = appConfig.tts.slowRate
            debugInfo = "TTS: slow (\(String(format: "%.1f", ttsRate))x)"
        }
        print("[MediaKey] TTS rate: \(oldRate) -> \(ttsRate)")

        // Re-speak current sentence at new rate if TTS is active
        if speechSynthesizer.isSpeaking || hasStartedSpeaking {
            let current = pendingSentence
            speechSynthesizer.stopSpeaking(at: .immediate)
            pendingUtteranceCount = 0
            hasStartedSpeaking = false
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speakSentence(current)
            }
        }
    }

    private func handleNextTrack() {
        print("[MediaKey] handleNextTrack called, state=\(conversationState)")
        if conversationState == .inactive {
            undoLastConversation()
        } else {
            interruptConversation()
        }
    }

    private func handlePreviousTrack() {
        print("[MediaKey] handlePreviousTrack called, state=\(conversationState), msgs=\(messages.count)")
        guard let lastResponse = messages.last(where: { $0.role == .assistant }) else {
            print("[MediaKey] No assistant message to repeat")
            return
        }

        stopConversation()
        speechSynthesizer.stopSpeaking(at: .immediate)

        // Ensure TTS finishes speaking before setting up resume
        // Use a small delay to let AVFoundation settle
        debugInfo = "Repeating last response..."
        hasStartedSpeaking = false
        pendingUtteranceCount = 0
        streamingComplete = true
        pendingSentence = ""

        print("[MediaKey] Speaking: \"\(lastResponse.text.prefix(40))...\"")
        speakSentence(lastResponse.text)
    }

    private func undoLastConversation() {
        print("[MediaKey] Undoing last conversation")
        guard let lastUser = messages.lastIndex(where: { $0.role == .user }) else { return }
        messages.removeSubrange(lastUser...)
        opencodeClient?.reset()
        debugInfo = "Undone. Restarting listening..."
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.startListening()
        }
    }

    private func interruptConversation() {
        print("[MediaKey] Interrupting conversation")
        speechSynthesizer.stopSpeaking(at: .immediate)
        pendingUtteranceCount = 0
        streamingComplete = false
        pendingSentence = ""

        llamaTask?.cancel()
        llamaTask = nil
        Task { await opencodeClient?.abort() }

        if let lastUserMsg = messages.last(where: { $0.role == .user }) {
            messages.removeAll { msg in
                msg.id == lastUserMsg.id || (msg.role == .assistant && msg.timestamp >= lastUserMsg.timestamp)
            }
        }
        stopConversation()
        debugInfo = "Interrupted. Restarting listening..."
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.startListening()
        }
    }

    // MARK: - Conversation Logging

    private func setupConversationLogging() {
        let logDir = URL(fileURLWithPath: appConfig.conversationHistoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let filename = "conversation_\(formatter.string(from: Date())).log"
        let fileURL = logDir.appendingPathComponent(filename)

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        conversationLogFile = fileURL
        conversationLogHandle = try? FileHandle(forWritingTo: fileURL)
        conversationLogHandle?.seekToEndOfFile()

        logConversation("=== Conversation started at \(Date()) ===")
        print("[LOG] Writing to: \(fileURL.path)")
    }

    private func logConversation(_ text: String) {
        guard let handle = conversationLogHandle else { return }
        if let data = (text + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private func logStateChange(_ newState: ConversationState) {
        logConversation("[\(timestamp())] STATE: \(newState.rawValue)")
    }

    private func logMessage(_ msg: Message) {
        let roleStr = msg.role == .user ? "USER" : "ASSISTANT"
        logConversation("[\(timestamp())] \(roleStr): \(msg.text)")
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            pendingUtteranceCount = max(0, pendingUtteranceCount - 1)
            if streamingComplete && pendingUtteranceCount == 0 {
                print("[TTS] All utterances finished, resuming listening")
                streamingComplete = false
                try? await Task.sleep(nanoseconds: 500_000_000)
                startListening()
            }
        }
    }

    // MARK: - Model Loading

    func loadModels() async {
        isLoading = true
        loadingStatus = "Loading models..."
        errorMessage = nil

        if appConfig.backend == "opencode" {
            await setupOpencodeBackend()
        }

        do {
            let asrPath = appConfig.resolvedASRPath()
            loadingStatus = "Loading ASR model..."
            let asr = try await Qwen3ASRModel.fromPretrained(localPath: asrPath) { progress, status in
                DispatchQueue.main.async {
                    self.loadingStatus = "ASR: \(status) (\(Int(progress * 100))%)"
                }
            }
            asrModel = asr

            let vadPath = appConfig.resolvedVADPath()
            loadingStatus = "Loading VAD model..."
            let vad = try await SileroVADModel.fromPretrained(localPath: vadPath) { progress, status in
                DispatchQueue.main.async {
                    self.loadingStatus = "VAD: \(status) (\(Int(progress * 100))%)"
                }
            }
            vadModel = vad

            let vadConfig = VADConfig(
                onset: appConfig.vad.onset,
                offset: appConfig.vad.offset,
                minSpeechDuration: appConfig.vad.minSpeechDuration,
                minSilenceDuration: appConfig.vad.minSilenceDuration,
                windowDuration: 0.032,
                stepRatio: 1.0
            )
            let processor = StreamingVADProcessor(model: vad, config: vadConfig)
            recorder = AudioRecorder(targetSampleRate: 16000, vadProcessor: processor)

            loadingStatus = "Ready"
            debugInfo = "Models loaded (backend: \(appConfig.backend))"
        } catch {
            errorMessage = "Failed to load models: \(error.localizedDescription)"
            loadingStatus = nil
        }
        isLoading = false
    }

    private func setupOpencodeBackend() async {
        let serverURL = appConfig.opencode.serverURL
        if await !OpencodeClient.isServerRunning(serverURL) {
            loadingStatus = "Starting opencode serve..."
            opencodeServerProcess = OpencodeClient.startServer()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if await !OpencodeClient.isServerRunning(serverURL) {
                loadingStatus = "Opencode server not available, will retry on first message"
            }
        }
        opencodeClient = OpencodeClient(config: appConfig)
    }

    // MARK: - Conversation Control

    func startListening() {
        print("[ViewModel] startListening: state=\(conversationState.rawValue), recorder=\(recorder != nil ? "present" : "NIL"), hasClient=\(opencodeClient != nil)")
        if speechSynthesizer.isSpeaking {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.startListening()
            }
            return
        }

        conversationState = .listening
        logStateChange(.listening)
        errorMessage = nil
        debugInfo = "Listening... (\(Int(appConfig.vad.silenceTimeout))s silence to send)"

        asrBuffer = []
        lastSpeechEndTime = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        silenceTimerValue = appConfig.vad.silenceTimeout
        pendingSentence = ""
        hasStartedSpeaking = false
        streamingComplete = false
        pendingUtteranceCount = 0
        pendingAudio = []
        pendingSendTask?.cancel()
        pendingSendTask = nil

        maxRecordingTimer?.invalidate()
        maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: appConfig.vad.maxRecordingDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.conversationState == .listening || self.conversationState == .waitingSilence else { return }
                print("[Recorder] Max recording duration reached, forcing send (recorder=\(self.recorder != nil ? "present" : "NIL"))")
                self.pendingAudio = self.recorder?.stopRecording() ?? []
                print("[Recorder] stopRecording returned \(self.pendingAudio.count) samples")
                self.silenceTimer?.invalidate()
                self.maxRecordingTimer?.invalidate()
                await self.processAndSend()
            }
        }

        recorder?.onSpeechEnded = { [weak self] in
            Task { @MainActor [weak self] in self?.onSpeechEnded() }
        }

        recorder?.startRecording()
    }

    func stopConversation() {
        print("[ViewModel] stopConversation called, state=\(conversationState.rawValue)")
        logStateChange(.inactive)
        pendingSendTask?.cancel()
        pendingSendTask = nil
        pendingAudio = []
        llamaTask?.cancel()
        llamaTask = nil
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        speechSynthesizer.stopSpeaking(at: .immediate)
        streamingComplete = false
        pendingUtteranceCount = 0

        recorder?.onSpeechEnded = nil
        _ = recorder?.stopRecording()

        conversationState = .inactive
        debugInfo = "Stopped"
    }

    func clearConversation() {
        messages = []
        debugInfo = ""
        isTyping = false
        opencodeClient?.reset()
        currentSessID = nil
    }

    // MARK: - Speech Events

    private func onSpeechEnded() {
        guard conversationState == .listening else { return }

        let now = Date()
        lastSpeechEndTime = now
        conversationState = .waitingSilence

        pendingAudio = recorder?.stopRecording() ?? []

        silenceTimer?.invalidate()
        silenceTimerValue = appConfig.vad.silenceTimeout

        let timeout = appConfig.vad.silenceTimeout
        pendingSendTask?.cancel()
        pendingSendTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.processAndSend()
        }

        debugInfo = "Waiting for silence... \(Int(silenceTimerValue))s"
    }

    private func processAndSend() async {
        print("[ViewModel] processAndSend: pendingAudio.count=\(pendingAudio.count), recorder=\(recorder != nil ? "present" : "NIL")")
        guard !pendingAudio.isEmpty else {
            print("[ViewModel] processAndSend: pendingAudio empty, restarting listening")
            startListening()
            return
        }

        pendingSendTask = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        debugInfo = "Sending after silence..."
        conversationState = .transcribing
        print("[ViewModel] processAndSend: transcribing \(pendingAudio.count) samples")

        let audio = pendingAudio
        pendingAudio = []
        asrBuffer = []

        guard !audio.isEmpty, let asr = asrModel else {
            errorMessage = "No audio or ASR model."
            print("[ViewModel] processAndSend: audio empty=\(audio.isEmpty), asrModel=\(asrModel != nil ? "present" : "NIL")")
            stopConversation()
            return
        }

        let asrText = await Task {
            let audio16k = Self.downsample(audio, from: 16000, to: 16000)
            return asr.transcribe(audio: audio16k, sampleRate: 16000, language: "en")
        }.value

        // Clear recorder's internal buffer after ASR
        _ = recorder?.stopRecording()

        guard !asrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            startListening()
            return
        }

        messages.append(Message(role: .user, text: asrText))
        logMessage(messages.last!)
        debugInfo = "Transcribed: \(asrText)"

        if appConfig.backend == "opencode" {
            await sendToOpencode(asrText)
        } else {
            await sendToLLM(asrText)
        }
    }

    // MARK: - LLM Streaming (llamacpp)

    private func sendToLLM(_ prompt: String) async {
        llamaTask?.cancel()
        llamaTask = Task { [weak self] in
            try await self?.handleLLMResponse(prompt: prompt)
        }
    }

    private func handleLLMResponse(prompt: String) async throws {
        conversationState = .generating
        logStateChange(.generating)
        isTyping = true
        debugInfo = "Generating..."
        hasStartedSpeaking = false
        pendingSentence = ""
        streamingComplete = false
        pendingUtteranceCount = 0

        let systemPrompt = ["role": "system", "content": appConfig.llamacpp.systemPrompt]

        let history = messages.prefix(max(0, messages.count - 1)).map { msg in
            ["role": msg.role == .user ? "user" : "assistant", "content": msg.text]
        }
        let userMessage = ["role": "user", "content": prompt]
        let allMessages = [systemPrompt] + history + [userMessage]

        let requestBody: [String: Any] = [
            "model": "",
            "messages": allMessages,
            "n_predict": appConfig.llamacpp.maxTokens,
            "stream": true
        ]

        let url = URL(string: "\(appConfig.llamacpp.serverURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        var assistantText = ""
        let startTime = Date()

        print("[LLM] Starting streaming request to \(appConfig.llamacpp.serverURL)")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        print("[LLM] Got response: \(response)")

        var lineBuffer = Data()
        for try await byte in bytes {
            if Task.isCancelled { break }
            lineBuffer.append(byte)
            if byte == UInt8(ascii: "\n") {
                if let lineStr = String(data: lineBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   lineStr.hasPrefix("data: ") {
                    let jsonStr = String(lineStr.dropFirst(6))
                    if jsonStr != "[DONE]" {
                        if let jsonData = jsonStr.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                            var content: String?
                            if let choices = json["choices"] as? [[String: Any]],
                               let firstChoice = choices.first,
                               let delta = firstChoice["delta"] as? [String: Any] {
                                content = delta["content"] as? String
                            }
                            if let content = content, !content.isEmpty {
                                assistantText += content
                                await MainActor.run { [weak self] in
                                    self?.streamTTSToken(content)
                                }
                            }
                        }
                    }
                }
                lineBuffer = Data()
            }
        }

        let totalTime = Date().timeIntervalSince(startTime)
        print("[LLM] Finished in \(totalTime)s, \(assistantText.count) chars")

        await MainActor.run {
            messages.append(Message(role: .assistant, text: assistantText))
            logMessage(messages.last!)
            isTyping = false

            if !pendingSentence.isEmpty {
                speakSentence(pendingSentence)
                pendingSentence = ""
            }

            streamingComplete = true
            if pendingUtteranceCount == 0 {
                streamingComplete = false
                startListening()
            }
        }
    }

    // MARK: - Opencode Backend

    func setSessID(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client = opencodeClient else {
            print("[ViewModel] setSessID: opencodeClient is nil, creating new client")
            opencodeClient = OpencodeClient(config: appConfig)
            opencodeClient?.setSessionID(trimmed)
            currentSessID = trimmed
            debugInfo = "Session ID set: \(trimmed.prefix(12))..."
            return
        }
        client.setSessionID(trimmed)
        currentSessID = trimmed
        debugInfo = "Session ID set: \(trimmed.prefix(12))..."
    }

    private func sendToOpencode(_ text: String) async {
        guard let client = opencodeClient else {
            errorMessage = "Opencode client not initialized"
            stopConversation()
            return
        }

        conversationState = .generating
        logStateChange(.generating)
        isTyping = true
        debugInfo = "Generating (opencode)..."
        hasStartedSpeaking = false
        pendingSentence = ""
        streamingComplete = false
        pendingUtteranceCount = 0
        opencodeResponseText = ""

        let startTime = Date()

        await client.sendMessage(text,
            onDelta: { [weak self] delta in
                Task { @MainActor [weak self] in
                    self?.opencodeResponseText += delta
                    self?.streamTTSToken(delta)
                }
            },
            onComplete: { [weak self] in
                let totalTime = Date().timeIntervalSince(startTime)
                print("[Opencode] Finished in \(totalTime)s")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isTyping = false

                    if !self.opencodeResponseText.isEmpty {
                        self.messages.append(Message(role: .assistant, text: self.opencodeResponseText))
                        self.logMessage(self.messages.last!)
                        self.opencodeResponseText = ""
                    }

                    if !self.pendingSentence.isEmpty {
                        self.speakSentence(self.pendingSentence)
                        self.pendingSentence = ""
                    }

                    self.streamingComplete = true
                    if self.pendingUtteranceCount == 0 {
                        self.streamingComplete = false
                        self.startListening()
                    }
                }
            }
        )
    }

    // MARK: - Built-in TTS

    private func streamTTSToken(_ token: String) {
        pendingSentence += token

        let sentenceEnders = CharacterSet(charactersIn: ".!?。！？\n")
        if let lastChar = token.unicodeScalars.last, sentenceEnders.contains(lastChar) {
            if !pendingSentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speakSentence(pendingSentence)
                pendingSentence = ""
            }
        } else if pendingSentence.count > 80 {
            if let lastSpace = pendingSentence.lastIndex(of: " ") {
                let sentence = String(pendingSentence[pendingSentence.startIndex..<lastSpace])
                pendingSentence = String(pendingSentence[pendingSentence.index(after: lastSpace)...])
                speakSentence(sentence)
            }
        }
    }

    private func speakSentence(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !hasStartedSpeaking {
            hasStartedSpeaking = true
            conversationState = .speaking
            logStateChange(.speaking)
            debugInfo = "Speaking..."
        }

        print("[TTS] Speaking: \"\(trimmed.prefix(60))\"")
        pendingUtteranceCount += 1

        let language = detectLanguage(from: trimmed)
        let voiceLanguage = language == "chinese" ? "zh-CN" : "en-US"

        let utterance = AVSpeechUtterance(string: trimmed)
        if let voice = AVSpeechSynthesisVoice(language: voiceLanguage) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * ttsRate
        utterance.volume = 1.0

        speechSynthesizer.speak(utterance)
    }

    private func detectLanguage(from text: String) -> String {
        let chineseChars = text.unicodeScalars.filter { $0.value >= 0x4e00 && $0.value <= 0x9fff }
        return chineseChars.isEmpty ? "english" : "chinese"
    }

    // MARK: - Test

    func testTTS() {
        print("[TTS] Test: macOS built-in TTS")
        let utterance = AVSpeechUtterance(string: "Hello world, this is a test of the built-in speech synthesizer.")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * ttsRate
        speechSynthesizer.speak(utterance)
    }

    // MARK: - Audio Processing

    private static func downsample(_ samples: [Float], from srcRate: Int, to dstRate: Int) -> [Float] {
        guard srcRate != dstRate, !samples.isEmpty else { return samples }
        let ratio = Double(srcRate) / Double(dstRate)
        let outCount = Int(Double(samples.count) / ratio)
        var result = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcIdx = Double(i) * ratio
            let idx0 = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx0))
            let s0 = samples[min(idx0, samples.count - 1)]
            let s1 = samples[min(idx0 + 1, samples.count - 1)]
            result[i] = s0 + frac * (s1 - s0)
        }
        return result
    }

    // MARK: - Model Info

    var backendDescription: String {
        switch appConfig.backend {
        case "opencode":
            return "LLM: opencode (\(appConfig.opencode.providerID)/\(appConfig.opencode.modelID))"
        default:
            return "LLM: llama.cpp @ \(appConfig.llamacpp.serverURL)"
        }
    }
}
