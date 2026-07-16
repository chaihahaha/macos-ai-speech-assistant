import Foundation
import AVFoundation
import Qwen3ASR
import SpeechVAD
import AudioCommon

@MainActor
final class ViewModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
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

    @Published var selectedBackend: String = "opencode"
    @Published var llamacppURL: String = "http://127.0.0.1:8080"
    @Published var opencodeURL: String = "http://127.0.0.1:9999"
    @Published var opencodeProviderID: String = "llama.cpp"
    @Published var opencodeModelID: String = "qwen3.6"
    @Published var opencodeAgent: String = "build"
    @Published var opencodeDirectory: String = "~/source"

    private var asrModel: Qwen3ASRModel?
    private var vadModel: SileroVADModel?
    private var recorder: AudioRecorder?
    private var llamaCppClient: LlamaCppClient?
    private var opencodeClient: OpencodeClient?
    private var opencodeServerProcess: Process?

    private let appConfig: AppConfig
    private var ttsRate: Float

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var pendingSentence: String = ""
    private var hasStartedSpeaking = false
    private var pendingUtteranceCount = 0
    private var streamingComplete = false

    private var conversationLogFile: URL?
    private var conversationLogHandle: FileHandle?

    private var asrBuffer: [Float] = []
    private var pendingAudio: [Float] = []
    private var lastSpeechEndTime: Date?
    private var silenceTimer: Timer?
    private var pendingSendTask: Task<Void, Never>?
    private var maxRecordingTimer: Timer?

    private var opencodeResponseText = ""

    private let mediaKeys = MediaKeyController()

    override init() {
        appConfig = AppConfig.load()
        ttsRate = appConfig.tts.rate

        selectedBackend = appConfig.backend
        llamacppURL = appConfig.llamacpp.serverURL
        opencodeURL = appConfig.opencode.serverURL
        opencodeProviderID = appConfig.opencode.providerID
        opencodeModelID = appConfig.opencode.modelID
        opencodeAgent = appConfig.opencode.agent
        opencodeDirectory = appConfig.opencode.directory

        super.init()
        speechSynthesizer.delegate = self
        setupConversationLogging()
        setupMediaKeys()
        print("[ViewModel] Backend: \(appConfig.backend)")
    }

    private func setupMediaKeys() {
        mediaKeys.setHandlers(
            playPause: { [weak self] in self?.toggleTTSSpeed() },
            nextTrack: { [weak self] in self?.handleNextTrack() },
            previousTrack: { }
        )
        mediaKeys.becomeNowPlaying()
    }

    deinit {
        speechSynthesizer.stopSpeaking(at: .immediate)
        llamaCppClient?.cancel()
        pendingSendTask?.cancel()
        maxRecordingTimer?.invalidate()
        silenceTimer?.invalidate()
        opencodeClient?.reset()
        opencodeServerProcess?.terminate()
        try? conversationLogHandle?.close()
    }

    func applyBackendSettings() {
        llamacppURL = llamacppURL.trimmingCharacters(in: .whitespacesAndNewlines)
        opencodeURL = opencodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        opencodeDirectory = opencodeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        opencodeClient?.reset()
        opencodeClient = nil
        llamaCppClient = nil
        currentSessID = nil
        debugInfo = "Backend settings applied"
    }

    private func toggleTTSSpeed() {
        if ttsRate <= appConfig.tts.slowRate + 0.05 {
            ttsRate = 2.0
            debugInfo = "TTS: fast (2.0x)"
        } else {
            ttsRate = appConfig.tts.slowRate
            debugInfo = "TTS: slow (\(String(format: "%.1f", ttsRate))x)"
        }
        print("[MediaKey] TTS rate: \(ttsRate)")

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
        print("[MediaKey] handleNextTrack, state=\(conversationState.rawValue), msgCount=\(messages.count)")
        switch conversationState {
        case .generating, .speaking:
            interruptConversation()
        case .listening, .waitingSilence:
            undoLastConversation()
        case .inactive, .transcribing:
            startListening()
        }
    }

    private func undoLastConversation() {
        print("[MediaKey] Undoing last conversation")
        if conversationState != .inactive {
            stopConversation()
        }
        guard let lastUser = messages.lastIndex(where: { $0.role == .user }) else {
            startListening()
            return
        }
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

        llamaCppClient?.cancel()
        Task { await opencodeClient?.interrupt() }

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

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            pendingUtteranceCount = max(0, pendingUtteranceCount - 1)
            if streamingComplete && pendingUtteranceCount == 0 {
                print("[TTS] All utterances finished, waiting before resuming listening")
                streamingComplete = false
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                while speechSynthesizer.isSpeaking {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                startListening()
            }
        }
    }

    func loadModels() async {
        isLoading = true
        loadingStatus = "Loading models..."
        errorMessage = nil

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
            debugInfo = "Models loaded (backend: \(selectedBackend))"
        } catch {
            errorMessage = "Failed to load models: \(error.localizedDescription)"
            loadingStatus = nil
        }
        isLoading = false
    }

    private func ensureBackendClient() {
        if selectedBackend == "opencode", opencodeClient == nil {
            opencodeClient = OpencodeClient(
                baseURL: opencodeURL,
                directory: opencodeDirectory,
                providerID: opencodeProviderID,
                modelID: opencodeModelID,
                agent: opencodeAgent
            )
        }
        if selectedBackend == "llamacpp", llamaCppClient == nil {
            llamaCppClient = LlamaCppClient(
                baseURL: llamacppURL,
                systemPrompt: appConfig.llamacpp.systemPrompt,
                maxTokens: appConfig.llamacpp.maxTokens
            )
        }
    }

    private func ensureOpencodeServer() async {
        if await OpencodeClient.isServerRunning(opencodeURL) { return }
        loadingStatus = "Starting opencode serve..."
        debugInfo = "Starting opencode serve on \(opencodeURL)..."
        guard let url = URL(string: opencodeURL),
              let host = url.host,
              let port = url.port else {
            loadingStatus = "Invalid opencode URL"
            return
        }
        opencodeServerProcess = OpencodeClient.startServer(hostname: host, port: port)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if await !OpencodeClient.isServerRunning(opencodeURL) {
            loadingStatus = "Opencode server not available"
            debugInfo = "Failed to start opencode serve"
        } else {
            loadingStatus = "Opencode serve started"
            debugInfo = "Opencode serve started on \(opencodeURL)"
        }
    }

    func startListening() {
        if speechSynthesizer.isSpeaking {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.startListening()
            }
            return
        }

        ensureBackendClient()

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
                self.pendingAudio = self.recorder?.stopRecording() ?? []
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
        logStateChange(.inactive)
        pendingSendTask?.cancel()
        pendingSendTask = nil
        pendingAudio = []
        llamaCppClient?.cancel()
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

    private func onSpeechEnded() {
        guard conversationState == .listening else { return }

        lastSpeechEndTime = Date()
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
        guard !pendingAudio.isEmpty else {
            stopConversation()
            debugInfo = "Auto-stopped: no speech detected"
            return
        }

        pendingSendTask = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        debugInfo = "Sending after silence..."
        conversationState = .transcribing

        let audio = pendingAudio
        pendingAudio = []
        asrBuffer = []

        guard !audio.isEmpty, let asr = asrModel else {
            errorMessage = "No audio or ASR model."
            stopConversation()
            return
        }

        let asrText = await Task {
            let audio16k = Self.downsample(audio, from: 16000, to: 16000)
            return asr.transcribe(audio: audio16k, sampleRate: 16000, language: "en")
        }.value

        _ = recorder?.stopRecording()

        let trimmed = asrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            stopConversation()
            debugInfo = "Auto-stopped: empty ASR"
            return
        }

        guard isValidSpeech(trimmed) else {
            stopConversation()
            debugInfo = "Auto-stopped: noise filtered"
            return
        }

        messages.append(Message(role: .user, text: trimmed))
        logMessage(messages.last!)
        debugInfo = "Transcribed: \(trimmed)"

        if selectedBackend == "opencode" {
            await sendToOpencode(trimmed)
        } else {
            await sendToLlamaCpp(trimmed)
        }
    }

    private func isValidSpeech(_ text: String) -> Bool {
        if text.count < 5 { return false }
        let noiseWords: Set<String> = ["the", "a", "an", "um", "umm", "emm", "ah", "oh", "uh", "er", "hmm", "huh", "eh", "ha", "mm", "mhm"]
        let words = text.lowercased().split(separator: " ")
        if words.count <= 2 {
            let contentWords = words.filter { !noiseWords.contains(String($0)) }
            if contentWords.isEmpty { return false }
        }
        return true
    }

    private func sendToLlamaCpp(_ prompt: String) async {
        guard let client = llamaCppClient else {
            errorMessage = "LlamaCpp client not initialized"
            stopConversation()
            return
        }

        conversationState = .generating
        logStateChange(.generating)
        isTyping = true
        debugInfo = "Generating (llama.cpp)..."
        hasStartedSpeaking = false
        pendingSentence = ""
        streamingComplete = false
        pendingUtteranceCount = 0

        let history = Array(messages.prefix(max(0, messages.count - 1)))
        let startTime = Date()

        client.sendMessage(prompt, history: history,
            onDelta: { [weak self] delta in
                Task { @MainActor [weak self] in
                    self?.streamTTSToken(delta)
                }
            },
            onComplete: { [weak self] in
                let totalTime = Date().timeIntervalSince(startTime)
                print("[LlamaCpp] Total time: \(String(format: "%.2f", totalTime))s")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isTyping = false

                    if !self.pendingSentence.isEmpty {
                        self.speakSentence(self.pendingSentence)
                        self.pendingSentence = ""
                    }

                    self.streamingComplete = true
                    if self.pendingUtteranceCount == 0 {
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            while self.speechSynthesizer.isSpeaking {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                            }
                            self.streamingComplete = false
                            self.startListening()
                        }
                    }
                }
            }
        )
    }

    func setSessID(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ensureBackendClient()
        opencodeClient?.setSessionID(trimmed)
        currentSessID = trimmed
        debugInfo = "Session ID set: \(trimmed.prefix(12))..."
    }

    private func sendToOpencode(_ text: String) async {
        await ensureOpencodeServer()

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
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            while self.speechSynthesizer.isSpeaking {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                            }
                            self.streamingComplete = false
                            self.startListening()
                        }
                    }
                }
            }
        )
    }

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
        if !chineseChars.isEmpty { return "chinese" }
        let hasLetters = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        if !hasLetters {
            if let lastUser = messages.last(where: { $0.role == .user }) {
                let userChinese = lastUser.text.unicodeScalars.filter { $0.value >= 0x4e00 && $0.value <= 0x9fff }
                if !userChinese.isEmpty { return "chinese" }
            }
        }
        return "english"
    }

    func testTTS() {
        let utterance = AVSpeechUtterance(string: "Hello world, this is a test of the built-in speech synthesizer.")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * ttsRate
        speechSynthesizer.speak(utterance)
    }

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

    var backendDescription: String {
        switch selectedBackend {
        case "opencode":
            return "LLM: opencode (\(opencodeProviderID)/\(opencodeModelID))"
        default:
            return "LLM: llama.cpp @ \(llamacppURL)"
        }
    }
}
