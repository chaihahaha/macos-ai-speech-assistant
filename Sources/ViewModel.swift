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
    
    // MARK: - Private
    
    private var asrModel: Qwen3ASRModel?
    private var vadModel: SileroVADModel?
    private var recorder: AudioRecorder?
    private var conversationTask: Task<Void, Never>?
    private var llamaTask: Task<Void, Error>?
    private var asrTask: Task<String, Error>?
    
    // LLM config
    private let llamaServerURL = "http://127.0.0.1:8080"
    private let silenceTimeout: TimeInterval = 5.0
    
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
    
    override init() {
        super.init()
        speechSynthesizer.delegate = self
        setupConversationLogging()
    }
    
    // MARK: - Conversation Logging
    
    private func setupConversationLogging() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        let logDir = URL(fileURLWithPath: "conversation_history", isDirectory: true, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        
        let filename = "conversation_\(formatter.string(from: Date())).log"
        let fileURL = logDir.appendingPathComponent(filename)
        
        // Create file and open handle for appending
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        conversationLogFile = fileURL
        conversationLogHandle = try? FileHandle(forWritingTo: fileURL)
        conversationLogHandle?.seekToEndOfFile()
        
        logConversation("=== Conversation started at \(Date()) ===\n")
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
        loadingStatus = "Loading models from local path..."
        errorMessage = nil
        
        do {
            let possibleASRPaths = [
                "../../../../../Qwen3-ASR-0.6B-MLX-4bit",
                "/Users/hasee/source/personaplex-mlx-swift/Qwen3-ASR-0.6B-MLX-4bit"
            ]
            let asrPath = possibleASRPaths.first { FileManager.default.fileExists(atPath: $0) }
                ?? "/Users/hasee/source/personaplex-mlx-swift/Qwen3-ASR-0.6B-MLX-4bit"
            
            loadingStatus = "Loading ASR model..."
            let asr = try await Qwen3ASRModel.fromPretrained(localPath: asrPath) { progress, status in
                DispatchQueue.main.async {
                    self.loadingStatus = "ASR: \(status) (\(Int(progress * 100))%)"
                }
            }
            asrModel = asr
            
            let possibleVADPaths = [
                "../../../../../Silero-VAD-v5-MLX",
                "/Users/hasee/source/personaplex-mlx-swift/Silero-VAD-v5-MLX"
            ]
            let vadPath = possibleVADPaths.first { FileManager.default.fileExists(atPath: $0) }
                ?? "/Users/hasee/source/personaplex-mlx-swift/Silero-VAD-v5-MLX"
            
            loadingStatus = "Loading VAD model..."
            let vad = try await SileroVADModel.fromPretrained(localPath: vadPath) { progress, status in
                DispatchQueue.main.async {
                    self.loadingStatus = "VAD: \(status) (\(Int(progress * 100))%)"
                }
            }
            vadModel = vad
            
            let vadConfig = VADConfig(
                onset: 0.5, offset: 0.35,
                minSpeechDuration: 0.25, minSilenceDuration: 1.0,
                windowDuration: 0.032, stepRatio: 1.0
            )
            let processor = StreamingVADProcessor(model: vad, config: vadConfig)
            recorder = AudioRecorder(targetSampleRate: 16000, vadProcessor: processor)
            
            loadingStatus = "Ready"
            debugInfo = "Models loaded"
        } catch {
            errorMessage = "Failed to load models: \(error.localizedDescription)"
            loadingStatus = nil
        }
        isLoading = false
    }
    
    // MARK: - Conversation Control
    
    func startListening() {
        // Don't start recording while system TTS is speaking
        if speechSynthesizer.isSpeaking {
            print("[DEBUG] startListening deferred (TTS active)")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.startListening()
            }
            return
        }
        
        conversationState = .listening
        logStateChange(.listening)
        errorMessage = nil
        debugInfo = "Listening... (5s silence to send)"
        
        asrBuffer = []
        lastSpeechEndTime = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        silenceTimerValue = silenceTimeout
        pendingSentence = ""
        hasStartedSpeaking = false
        streamingComplete = false
        pendingUtteranceCount = 0
        pendingAudio = []
        pendingSendTask?.cancel()
        pendingSendTask = nil
        
        recorder?.onSpeechEnded = { [weak self] in
            Task { @MainActor [weak self] in
                self?.onSpeechEnded()
            }
        }
        
        recorder?.startRecording()
    }
    
    func stopConversation() {
        logStateChange(.inactive)
        pendingSendTask?.cancel()
        pendingSendTask = nil
        pendingAudio = []
        
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
    }
    
    // MARK: - Speech Events
    
    private func onSpeechEnded() {
        guard conversationState == .listening else { return }
        
        let now = Date()
        lastSpeechEndTime = now
        conversationState = .waitingSilence
        
        pendingAudio = recorder?.stopRecording() ?? []
        
        silenceTimer?.invalidate()
        silenceTimerValue = silenceTimeout
        
        pendingSendTask?.cancel()
        pendingSendTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self!.silenceTimeout * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.processAndSend()
        }
        
        debugInfo = "Waiting for silence... \(Int(silenceTimerValue))s"
    }
    
    private func processAndSend() async {
        guard !pendingAudio.isEmpty else {
            startListening()
            return
        }
        
        pendingSendTask?.cancel()
        pendingSendTask = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        debugInfo = "Sending after silence..."
        conversationState = .transcribing
        
        let audio = pendingAudio
        pendingAudio = []
        
        guard !audio.isEmpty, let asr = asrModel else {
            errorMessage = "No audio or ASR model."
            stopConversation()
            return
        }
        
        let asrText = await Task {
            let audio16k = Self.downsample(audio, from: 16000, to: 16000)
            return asr.transcribe(audio: audio16k, sampleRate: 16000, language: "en")
        }.value
        
        guard !asrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            startListening()
            return
        }
        
        messages.append(Message(role: .user, text: asrText))
        logMessage(messages.last!)
        debugInfo = "Transcribed: \(asrText)"
        
        await sendToLLM(asrText)
    }
    
    // MARK: - LLM Streaming
    
    private func sendToLLM(_ prompt: String) async {
        llamaTask = Task {
            try await handleLLMResponse(prompt: prompt)
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
        
        let systemPrompt = ["role": "system", "content": "You are a helpful assistant. After reasoning, provide a concise response. Output your reasoning in the reasoning block, then output the actual response content."]
        
        let history = messages.map { msg in
            ["role": msg.role == .user ? "user" : "assistant", "content": msg.text]
        }
        let userMessage = ["role": "user", "content": prompt]
        let allMessages = [systemPrompt] + history + [userMessage]
        
        let requestBody: [String: Any] = [
            "model": "",
            "messages": allMessages,
            "n_predict": 512,
            "stream": true
        ]
        
        let url = URL(string: "\(llamaServerURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = body
        
        var assistantText = ""
        let startTime = Date()
        
        print("[LLM] Starting streaming request to \(llamaServerURL)")
        
        let session = URLSession.shared
        let (bytes, response) = try await session.bytes(for: request)
        
        print("[LLM] Got response: \(response)")
        
        // Process SSE stream in real-time, line by line
        var lineBuffer = Data()
        var lineCount = 0
        for try await byte in bytes {
            lineBuffer.append(byte)
            // Check if we have a complete line (ending with \n)
            if byte == UInt8(ascii: "\n") {
                lineCount += 1
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
                                // Process token in real-time on main actor
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
        print("[LLM] Finished in \(totalTime)s, \(lineCount) lines, \(assistantText.count) chars")
        
        await MainActor.run {
            messages.append(Message(role: .assistant, text: assistantText))
            logMessage(messages.last!)
            isTyping = false
            
            // Speak any remaining pending text
            if !pendingSentence.isEmpty {
                speakSentence(pendingSentence)
                pendingSentence = ""
            }
            
            // Mark streaming complete - delegate will start listening when all utterances finish
            streamingComplete = true
            // Edge case: no sentences were spoken (empty response)
            if pendingUtteranceCount == 0 {
                streamingComplete = false
                startListening()
            }
        }
    }
    
    // MARK: - Built-in TTS
    
    private func streamTTSToken(_ token: String) {
        pendingSentence += token
        
        // Speak when we hit a sentence boundary
        let sentenceEnders = CharacterSet(charactersIn: ".!?。！？\n")
        if let lastChar = token.unicodeScalars.last, sentenceEnders.contains(lastChar) {
            // Also check comma for very long sentences (> ~80 chars without break)
            if !pendingSentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speakSentence(pendingSentence)
                pendingSentence = ""
            }
        } else if pendingSentence.count > 80 {
            // Force a break on long text without punctuation
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
        
        // Pick voice based on detected language
        let language = detectLanguage(from: trimmed)
        let voiceLanguage = language == "chinese" ? "zh-CN" : "en-US"
        
        let utterance = AVSpeechUtterance(string: trimmed)
        if let voice = AVSpeechSynthesisVoice(language: voiceLanguage) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
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
}
