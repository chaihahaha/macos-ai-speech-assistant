import Foundation
import AppKit
import AVFoundation
@preconcurrency import Qwen3ASR
import SpeechVAD
import AudioCommon

/// `Qwen3ASRModel` is documented as not thread-safe and is not `Sendable`. All
/// of its use is serialised through `ViewModel.asrQueue`, so passing it into
/// that queue's `@Sendable` closure via this box is sound.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Drives the listen → transcribe → generate → speak loop.
///
/// Concurrency model
/// -----------------
/// Every "cycle" of the loop (one recording session) is tagged with a
/// monotonically increasing `generation` token. Any asynchronous continuation —
/// a delayed restart, a VAD callback, a TTS completion, an LLM completion, an
/// ASR result — captures the generation it belongs to and does nothing if the
/// generation is no longer current. This is what makes the media key able to
/// interrupt *at any time*: `stopConversation` / `interruptConversation` bump
/// the generation, so every in-flight continuation becomes a no-op instead of
/// resurrecting the conversation later.
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
    @Published var ttsRateLabel: String = ""
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
    /// Separate synthesizer used only for the short "快 / 慢" speed confirmation,
    /// so it never disturbs the conversation TTS bookkeeping.
    private let speedAnnouncer = AVSpeechSynthesizer()
    private var pendingSentence: String = ""
    private var hasStartedSpeaking = false
    /// Sentences waiting to be spoken. They are handed to
    /// `AVSpeechSynthesizer` one at a time so a speed change can restart the
    /// current sentence without losing the rest of the reply.
    private var ttsQueue: [String] = []
    private var currentlySpeakingText: String?
    private var streamingComplete = false
    /// Maps each utterance to the generation that queued it, so completions
    /// coming from a stopped/interrupted cycle can be ignored.
    private var utteranceGenerations: [ObjectIdentifier: UInt64] = [:]

    private var conversationLogFile: URL?
    private var conversationLogHandle: FileHandle?

    private var pendingAudio: [Float] = []
    private var pendingSendTask: Task<Void, Never>?
    private var maxRecordingTimer: Timer?
    private var beepTimer: Timer?
    private var beepCount = 0
    private var beepSound: NSSound? = NSSound(named: "Tink")

    /// Serialises ASR inference. `Qwen3ASRModel` is not thread-safe, and running
    /// it on the main actor used to freeze the whole UI (and therefore the media
    /// keys) for the entire transcription.
    private let asrQueue = DispatchQueue(label: "com.myllama.speech.asr", qos: .userInitiated)

    /// Invalidates every pending continuation. See the type documentation.
    private var generation: UInt64 = 0
    private var restartTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var ttsWaitAttempts = 0

    private var opencodeResponseText = ""

    /// The user message that belongs to the turn currently being generated.
    /// Used to undo *only* the in-flight exchange when interrupting, never the
    /// previous completed one.
    private var currentTurnUserMessageID: UUID?

    private let mediaKeys = MediaKeyController()

    override init() {
        appConfig = AppConfig.load()
        ttsRate = appConfig.tts.rate
        ttsRateLabel = String(format: "%.2fx", ttsRate)

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
        // Persist media-key diagnostics into the conversation log so problems
        // with a specific headset can be diagnosed after the fact.
        mediaKeys.logHandler = { [weak self] message in
            self?.logConversation(message)
        }
        mediaKeys.setHandlers(
            // EDIFIER X Fit: a double press on either earbud is the only
            // gesture that maps to play/pause (single presses send nothing at
            // all), so this is the primary talk control.
            playPause: { [weak self] in self?.handlePlayPause() },
            // EDIFIER X Fit: right-ear triple press reports as `nextTrack`.
            // Context-sensitive: undo the last turn when idle, TTS speed while
            // a turn is in progress.
            nextTrack: { [weak self] in self?.handleTriplePress() },
            // Not emitted by this headset; kept for other AVRCP devices.
            previousTrack: { [weak self] in self?.handleTriplePress() }
        )
        mediaKeys.becomeNowPlaying()
    }

    deinit {
        restartTask?.cancel()
        pipelineTask?.cancel()
        pendingSendTask?.cancel()
        maxRecordingTimer?.invalidate()
        beepTimer?.invalidate()
        speechSynthesizer.stopSpeaking(at: .immediate)
        llamaCppClient?.cancel()
        opencodeClient?.reset()
        opencodeServerProcess?.terminate()
        try? conversationLogHandle?.close()
    }

    // MARK: - Generation / cancellation helpers

    private func isCurrent(_ gen: UInt64) -> Bool { generation == gen }

    @discardableResult
    private func beginNewGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Cancels timers and the pending silence-send task. Optionally also cancels
    /// the in-flight transcription/generation pipeline.
    private func cancelPendingWork(cancelPipeline: Bool) {
        pendingSendTask?.cancel()
        pendingSendTask = nil
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil
        beepTimer?.invalidate()
        beepTimer = nil
        if cancelPipeline {
            pipelineTask?.cancel()
            pipelineTask = nil
        }
    }

    // MARK: - Media key entry points

    private func handlePlayPause() {
        print("[MediaKey] handlePlayPause, state=\(conversationState.rawValue)")
        switch conversationState {
        case .inactive:
            startListening()
        case .listening, .waitingSilence:
            stopConversation(caller: "playPause")
        case .transcribing, .generating, .speaking:
            interruptConversation()
        }
        if conversationState != .inactive {
            mediaKeys.setPlaying()
        }
    }

    /// Right-ear triple press.
    /// - Idle: undo the last exchange (the user wants to rephrase and retry).
    /// - Any active turn: toggle the TTS speaking rate.
    private func handleTriplePress() {
        print("[MediaKey] handleTriplePress, state=\(conversationState.rawValue)")
        if conversationState == .inactive {
            undoLastConversation()
        } else {
            toggleTTSSpeed()
        }
    }

    private func toggleTTSSpeed() {
        print("[MediaKey] toggleTTSSpeed, before=\(ttsRate) state=\(conversationState.rawValue)")
        if ttsRate <= appConfig.tts.slowRate + 0.05 {
            ttsRate = 1.5
            debugInfo = "TTS: fast (1.5x)"
        } else {
            ttsRate = appConfig.tts.slowRate
            debugInfo = "TTS: slow (\(String(format: "%.1f", ttsRate))x)"
        }
        ttsRateLabel = String(format: "%.2fx", ttsRate)
        print("[MediaKey] TTS rate: \(ttsRate)")

        if let current = currentlySpeakingText {
            // Restart the sentence that is playing so the change is audible
            // immediately. The rest of the queue is preserved and will also be
            // spoken at the new rate.
            utteranceGenerations.removeAll()
            currentlySpeakingText = nil
            speechSynthesizer.stopSpeaking(at: .immediate)
            ttsQueue.insert(current, at: 0)
            drainTTSQueue()
        } else {
            // Nothing to restart — announce so a triple-click while idle is
            // not silent.
            announceTTSSpeed()
        }
    }

    private func announceTTSSpeed() {
        let text = ttsRate >= 1.0 ? "快" : "慢"
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * ttsRate
        utterance.volume = 1.0
        speedAnnouncer.stopSpeaking(at: .immediate)
        speedAnnouncer.speak(utterance)
    }

    // MARK: - State transitions

    func startListening() {
        mediaKeys.setPlaying()

        guard asrModel != nil, recorder != nil else {
            debugInfo = "Models are still loading..."
            return
        }

        // TTS may still be draining. Retry shortly, but keep the retry
        // cancellable and bounded so a stuck synthesizer can never wedge the
        // state machine.
        if speechSynthesizer.isSpeaking {
            ttsWaitAttempts += 1
            if ttsWaitAttempts <= 40 {
                scheduleStartListening(after: 0.25, reason: "ttsBusy")
            } else {
                print("[VM] TTS did not stop in time; forcing stop")
                speechSynthesizer.stopSpeaking(at: .immediate)
                ttsWaitAttempts = 0
                scheduleStartListening(after: 0.1, reason: "ttsBusyTimeout")
            }
            return
        }
        ttsWaitAttempts = 0

        // A new cycle starts here: invalidate everything from the previous one.
        restartTask?.cancel()
        restartTask = nil
        let gen = beginNewGeneration()
        cancelPendingWork(cancelPipeline: true)

        ensureBackendClient()

        conversationState = .listening
        logStateChange(.listening)
        errorMessage = nil
        debugInfo = "Listening... (\(Int(appConfig.vad.silenceTimeout))s silence to send)"

        silenceTimerValue = appConfig.vad.silenceTimeout
        pendingSentence = ""
        beepCount = 0
        hasStartedSpeaking = false
        streamingComplete = false
        ttsQueue.removeAll()
        currentlySpeakingText = nil
        utteranceGenerations.removeAll()
        speedAnnouncer.stopSpeaking(at: .immediate)
        pendingAudio = []
        currentTurnUserMessageID = nil

        maxRecordingTimer?.invalidate()
        maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: appConfig.vad.maxRecordingDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(gen) else { return }
                guard self.conversationState == .listening || self.conversationState == .waitingSilence else { return }
                print("[VM] maxRecordingDuration reached")
                self.pendingAudio = self.recorder?.stopRecording() ?? []
                self.cancelPendingWork(cancelPipeline: false)
                self.launchPipeline(generation: gen)
            }
        }

        recorder?.onSpeechEnded = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(gen) else { return }
                self.onSpeechEnded(generation: gen)
            }
        }

        recorder?.startRecording()
    }

    func stopConversation(caller: String = "direct") {
        print("[VM] stopConversation, caller=\(caller), state=\(conversationState.rawValue)")

        // Invalidate every in-flight continuation *first*.
        beginNewGeneration()
        restartTask?.cancel()
        restartTask = nil
        cancelPendingWork(cancelPipeline: true)
        ttsWaitAttempts = 0

        pendingAudio = []
        opencodeResponseText = ""
        currentTurnUserMessageID = nil
        llamaCppClient?.cancel()
        opencodeClient?.cancelPending()
        Task { await opencodeClient?.interrupt() }

        stopSynthesis()
        isTyping = false

        recorder?.onSpeechEnded = nil
        _ = recorder?.stopRecording()

        conversationState = .inactive
        logStateChange(.inactive)
        // Keep reporting `.playing`: macOS only routes the hardware media keys
        // to the app that currently owns Now Playing. Reporting `.paused` made
        // single presses get swallowed by the system.
        mediaKeys.setPlaying()
        debugInfo = "Stopped"
    }

    /// Stops the current generation/speech and returns to Idle.
    /// Deliberately does **not** auto-resume listening: the user starts the next
    /// recording manually with a double press.
    private func interruptConversation() {
        print("[MediaKey] Interrupting conversation, state=\(conversationState.rawValue)")

        beginNewGeneration()
        restartTask?.cancel()
        restartTask = nil
        cancelPendingWork(cancelPipeline: true)
        ttsWaitAttempts = 0

        stopSynthesis()
        isTyping = false
        llamaCppClient?.cancel()
        opencodeClient?.cancelPending()
        Task { await opencodeClient?.interrupt() }
        opencodeResponseText = ""

        removePartialExchange()

        conversationState = .inactive
        logStateChange(.inactive)
        mediaKeys.setPlaying()
        debugInfo = "Interrupted (idle). Double-press to talk again."
    }

    /// Undo the last user+assistant exchange. Stays Idle — the user will
    /// rephrase and start the next recording manually.
    private func undoLastConversation() {
        print("[MediaKey] Undo last conversation, state=\(conversationState.rawValue)")
        stopConversation(caller: "undoLastConversation")

        guard let lastUser = messages.lastIndex(where: { $0.role == .user }) else {
            debugInfo = "Nothing to undo"
            return
        }
        messages.removeSubrange(lastUser...)
        // Clear the server-side opencode session too, otherwise the removed turn
        // would still be part of the model's context.
        opencodeClient?.reset()
        currentSessID = nil
        debugInfo = "Undid last turn (idle). Double-press to talk again."
    }

    private func removePartialExchange() {
        guard let turnID = currentTurnUserMessageID,
              let userMsg = messages.first(where: { $0.id == turnID }) else {
            // Nothing from the current turn was committed yet (e.g. we were
            // interrupted during transcription) — leave history untouched.
            currentTurnUserMessageID = nil
            return
        }
        messages.removeAll { msg in
            msg.id == userMsg.id || (msg.role == .assistant && msg.timestamp >= userMsg.timestamp)
        }
        currentTurnUserMessageID = nil
    }

    private func stopSynthesis() {
        // Invalidate bookkeeping *before* stopping so the asynchronous
        // didCancel callbacks are ignored.
        utteranceGenerations.removeAll()
        currentlySpeakingText = nil
        ttsQueue.removeAll()
        speechSynthesizer.stopSpeaking(at: .immediate)
        speedAnnouncer.stopSpeaking(at: .immediate)
        hasStartedSpeaking = false
        pendingSentence = ""
        streamingComplete = false
    }

    /// Schedules `startListening()` after `delay`, in a task that is cancelled by
    /// any later state transition and that refuses to run if the generation
    /// changed in the meantime.
    private func scheduleStartListening(after delay: TimeInterval, reason: String) {
        restartTask?.cancel()
        let gen = generation
        print("[VM] scheduling startListening in \(delay)s (reason=\(reason), gen=\(gen))")
        restartTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled, self.isCurrent(gen) else {
                print("[VM] scheduled startListening cancelled (reason=\(reason))")
                return
            }
            self.restartTask = nil
            self.startListening()
        }
    }

    /// The exchange is complete. Mark the cycle as inactive and **stay there**:
    /// the user starts the next recording manually (double press). This also
    /// makes "triple press while idle = undo last turn" reachable after a normal
    /// answer.
    private func finishTurn() {
        guard conversationState != .inactive else { return }
        print("[VM] cycle complete, going idle (state was \(conversationState.rawValue))")
        conversationState = .inactive
        logStateChange(.inactive)
        isTyping = false
        currentTurnUserMessageID = nil
        debugInfo = "Done (idle). Double-press to talk again."
        mediaKeys.setPlaying()
    }

    // MARK: - Logging

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

    // MARK: - TTS delegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let preview = utterance.speechString.prefix(24)
            print("[TTS] didStart: \(preview)")
            self.logConversation("[\(self.timestamp())] TTS-START: \(preview)")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.handleUtteranceFinished(utterance)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.handleUtteranceFinished(utterance)
        }
    }

    private func handleUtteranceFinished(_ utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        guard let gen = utteranceGenerations.removeValue(forKey: key) else { return }
        guard isCurrent(gen) else { return }

        // This was the sentence we fed to the synthesizer; move on to the next
        // queued sentence, if any.
        currentlySpeakingText = nil
        if !ttsQueue.isEmpty {
            drainTTSQueue()
            return
        }
        guard streamingComplete else { return }
        print("[TTS] All utterances finished, going idle")
        streamingComplete = false
        finishTurn()
    }

    // MARK: - Model loading

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
            // Dedicated capture engine (NOT the Now-Playing engine): stopping
            // it releases the microphone so Bluetooth can leave HFP mode.
            let recorder = AudioRecorder(targetSampleRate: 16000, vadProcessor: processor)
            recorder.onLog = { [weak self] message in
                self?.logConversation(message)
            }
            self.recorder = recorder

            loadingStatus = "Ready"
            debugInfo = "Models loaded (backend: \(selectedBackend))"
            logConversation("[\(timestamp())] MODELS: loaded, backend=\(selectedBackend)")
        } catch {
            errorMessage = "Failed to load models: \(error.localizedDescription)"
            loadingStatus = nil
        }
        isLoading = false
    }

    func applyBackendSettings() {
        llamacppURL = llamacppURL.trimmingCharacters(in: .whitespacesAndNewlines)
        opencodeURL = opencodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        opencodeDirectory = opencodeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)

        if conversationState != .inactive {
            stopConversation(caller: "applyBackendSettings")
        }
        opencodeClient?.reset()
        opencodeClient = nil
        llamaCppClient = nil
        currentSessID = nil
        mediaKeys.setPlaying()

        // Persist the switch: otherwise the next launch silently falls back to
        // the user config's backend (which may be a server that is not running).
        var updated = appConfig
        updated.backend = selectedBackend
        updated.llamacpp.serverURL = llamacppURL
        updated.opencode.serverURL = opencodeURL
        updated.opencode.providerID = opencodeProviderID
        updated.opencode.modelID = opencodeModelID
        updated.opencode.agent = opencodeAgent
        updated.opencode.directory = opencodeDirectory
        let saved = updated.save()

        errorMessage = nil
        debugInfo = saved
            ? "Backend: \(selectedBackend) (saved)"
            : "Backend: \(selectedBackend) (FAILED to save config)"
        logConversation("[\(timestamp())] BACKEND: \(selectedBackend) saved=\(saved)")
    }

    private func ensureBackendClient() {
        if selectedBackend == "opencode", opencodeClient == nil {
            let client = OpencodeClient(
                baseURL: opencodeURL,
                directory: opencodeDirectory,
                providerID: opencodeProviderID,
                modelID: opencodeModelID,
                agent: opencodeAgent
            )
            client.log = { [weak self] message in
                self?.logConversation("[Opencode] \(message)")
            }
            opencodeClient = client
        }
        if selectedBackend == "llamacpp", llamaCppClient == nil {
            let client = LlamaCppClient(
                baseURL: llamacppURL,
                systemPrompt: appConfig.llamacpp.systemPrompt,
                maxTokens: appConfig.llamacpp.maxTokens
            )
            client.log = { [weak self] message in
                self?.logConversation("[LlamaCpp] \(message)")
            }
            llamaCppClient = client
        }
    }

    /// Returns `false` when the opencode server could not be made available.
    @discardableResult
    private func ensureOpencodeServer() async -> Bool {
        if await OpencodeClient.isServerRunning(opencodeURL) { return true }
        loadingStatus = "Starting opencode serve..."
        debugInfo = "Starting opencode serve on \(opencodeURL)..."
        logConversation("[\(timestamp())] OPENCODE: starting serve on \(opencodeURL)")
        guard let url = URL(string: opencodeURL),
              let host = url.host,
              let port = url.port else {
            loadingStatus = "Invalid opencode URL"
            errorMessage = "Invalid opencode URL: \(opencodeURL)"
            return false
        }
        opencodeServerProcess = OpencodeClient.startServer(hostname: host, port: port)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if await !OpencodeClient.isServerRunning(opencodeURL) {
            loadingStatus = "Opencode server not available"
            debugInfo = "Failed to start opencode serve"
            logConversation("[\(timestamp())] OPENCODE: server NOT available at \(opencodeURL)")
            return false
        }
        loadingStatus = "Opencode serve started"
        debugInfo = "Opencode serve started on \(opencodeURL)"
        logConversation("[\(timestamp())] OPENCODE: server started")
        return true
    }

    // MARK: - Recording callbacks

    private func onSpeechEnded(generation gen: UInt64) {
        guard isCurrent(gen), conversationState == .listening else { return }
        print("[VM] onSpeechEnded, state=\(conversationState.rawValue)")

        conversationState = .waitingSilence
        pendingAudio = recorder?.stopRecording() ?? []

        silenceTimerValue = appConfig.vad.silenceTimeout
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        beepTimer?.invalidate()
        beepCount = 0
        beepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(gen) else { return }
                self.beepCount += 1
                self.silenceTimerValue = max(0, self.silenceTimerValue - 1)
                self.beepSound?.stop()
                self.beepSound?.play()
                if self.silenceTimerValue <= 0 {
                    self.beepTimer?.invalidate()
                    self.beepTimer = nil
                }
            }
        }

        scheduleSendAfterSilence(timeout: appConfig.vad.silenceTimeout, generation: gen)
        debugInfo = "Waiting for silence... \(Int(silenceTimerValue))s"
    }

    private func scheduleSendAfterSilence(timeout: TimeInterval, generation gen: UInt64) {
        pendingSendTask?.cancel()
        pendingSendTask = Task { @MainActor [weak self] in
            if timeout > 0 {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            guard let self, !Task.isCancelled, self.isCurrent(gen) else { return }
            guard self.conversationState == .waitingSilence else { return }
            self.pendingSendTask = nil
            self.launchPipeline(generation: gen)
        }
    }

    private func launchPipeline(generation gen: UInt64) {
        pipelineTask?.cancel()
        pipelineTask = Task { @MainActor [weak self] in
            await self?.processAndSend(generation: gen)
        }
    }

    // MARK: - Pipeline

    private func processAndSend(generation gen: UInt64) async {
        // Re-entrancy guard: while the first invocation is awaiting ASR the
        // state is `.transcribing`, so a second invocation bails out here.
        // The cancellation check must come first so a superseded task does not
        // consume `pendingAudio` before the surviving one runs.
        guard isCurrent(gen), !Task.isCancelled else {
            print("[VM] processAndSend skipped (stale or cancelled)")
            return
        }
        guard conversationState == .listening || conversationState == .waitingSilence else {
            print("[VM] processAndSend ignored, state=\(conversationState.rawValue)")
            return
        }

        print("[VM] processAndSend, pendingAudio=\(pendingAudio.count) samples")
        logConversation("[\(timestamp())] PIPELINE: audio=\(pendingAudio.count) samples (\(String(format: "%.2f", Double(pendingAudio.count) / 16000))s)")
        guard !pendingAudio.isEmpty else {
            stopConversation(caller: "processAndSend_noAudio")
            debugInfo = "Auto-stopped: no speech detected"
            logConversation("[\(timestamp())] PIPELINE: no audio captured")
            return
        }

        cancelPendingWork(cancelPipeline: false)
        debugInfo = "Sending after silence..."
        conversationState = .transcribing
        logStateChange(.transcribing)

        let audio = pendingAudio
        pendingAudio = []

        guard let asr = asrModel else {
            errorMessage = "ASR model not loaded."
            stopConversation(caller: "processAndSend_noModel")
            return
        }

        // Run inference off the main actor so media keys / UI stay responsive.
        let asrText = await transcribe(asr: asr, audio: audio)

        guard isCurrent(gen), !Task.isCancelled, conversationState == .transcribing else {
            print("[VM] dropping stale ASR result (gen changed or cancelled)")
            logConversation("[\(timestamp())] PIPELINE: stale ASR result dropped")
            return
        }

        _ = recorder?.stopRecording()

        let trimmed = asrText.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[VM] ASR result: '\(trimmed)' len=\(trimmed.count)")
        logConversation("[\(timestamp())] ASR: '\(trimmed)'")
        guard !trimmed.isEmpty else {
            stopConversation(caller: "processAndSend_emptyASR")
            debugInfo = "Auto-stopped: empty ASR"
            return
        }

        guard isValidSpeech(trimmed) else {
            stopConversation(caller: "processAndSend_noise")
            debugInfo = "Auto-stopped: noise filtered"
            logConversation("[\(timestamp())] PIPELINE: ASR text filtered as noise")
            return
        }

        messages.append(Message(role: .user, text: trimmed))
        currentTurnUserMessageID = messages.last?.id
        logMessage(messages.last!)
        debugInfo = "Transcribed: \(trimmed)"

        logConversation("[\(timestamp())] PIPELINE: sending to backend=\(selectedBackend)")
        if selectedBackend == "opencode" {
            await sendToOpencode(trimmed, generation: gen)
        } else {
            await sendToLlamaCpp(trimmed, generation: gen)
        }
    }

    private func transcribe(asr: Qwen3ASRModel, audio: [Float]) async -> String {
        let model = UncheckedSendableBox(value: asr)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            asrQueue.async {
                let text = model.value.transcribe(audio: audio, sampleRate: 16000, language: "en")
                continuation.resume(returning: text)
            }
        }
    }

    private func isValidSpeech(_ text: String) -> Bool {
        let chineseCount = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let minChars = chineseCount > 0 ? 2 : 3
        if text.count < minChars { return false }
        let noiseWords: Set<String> = ["the", "a", "an", "um", "umm", "emm", "ah", "oh", "uh", "er", "hmm", "huh", "eh", "ha", "mm", "mhm"]
        let words = text.lowercased().split(separator: " ")
        if words.count <= 1 {
            let contentWords = words.filter { !noiseWords.contains(String($0)) }
            if contentWords.isEmpty { return false }
        }
        return true
    }

    private func resetSpeechPipelineState() {
        hasStartedSpeaking = false
        pendingSentence = ""
        streamingComplete = false
        ttsQueue.removeAll()
        currentlySpeakingText = nil
        utteranceGenerations.removeAll()
    }

    /// Called when the assistant text has been fully received. Hands control
    /// back to TTS (if there is anything left to speak) or to listening.
    private func finishStreaming(generation gen: UInt64) {
        guard isCurrent(gen) else { return }
        streamingComplete = true
        if currentlySpeakingText == nil && ttsQueue.isEmpty {
            streamingComplete = false
            finishTurn()
        }
    }

    private func sendToLlamaCpp(_ prompt: String, generation gen: UInt64) async {
        print("[VM] sendToLlamaCpp, prompt=\(prompt.prefix(40))...")
        guard isCurrent(gen), !Task.isCancelled else { return }
        guard let client = llamaCppClient else {
            errorMessage = "LlamaCpp client not initialized"
            stopConversation(caller: "sendToLlamaCpp_noClient")
            return
        }

        conversationState = .generating
        logStateChange(.generating)
        isTyping = true
        debugInfo = "Generating (llama.cpp)..."
        resetSpeechPipelineState()

        let history = Array(messages.prefix(max(0, messages.count - 1)))
        let startTime = Date()

        client.sendMessage(prompt, history: history,
            onDelta: { [weak self] delta in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(gen) else { return }
                    self.streamTTSToken(delta)
                }
            },
            onComplete: { [weak self] assistantText in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(gen) else { return }
                    let totalTime = Date().timeIntervalSince(startTime)
                    print("[LlamaCpp] Total time: \(String(format: "%.2f", totalTime))s")
                    self.isTyping = false

                    if !assistantText.isEmpty {
                        self.messages.append(Message(role: .assistant, text: assistantText))
                        self.logMessage(self.messages.last!)
                    } else {
                        self.errorMessage = "llama.cpp returned no text. Check \(self.llamacppURL) and the server log."
                        self.logConversation("[\(self.timestamp())] ERROR: llama.cpp returned no text")
                    }

                    if !self.pendingSentence.isEmpty {
                        self.speakSentence(self.pendingSentence)
                        self.pendingSentence = ""
                    }

                    self.finishStreaming(generation: gen)
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

    private func sendToOpencode(_ text: String, generation gen: UInt64) async {
        guard await ensureOpencodeServer() else {
            guard isCurrent(gen) else { return }
            errorMessage = "opencode server unavailable at \(opencodeURL). Switch to llama.cpp or start 'opencode serve'."
            logConversation("[\(timestamp())] ERROR: opencode server unavailable")
            stopConversation(caller: "sendToOpencode_serverUnavailable")
            return
        }

        guard isCurrent(gen), !Task.isCancelled else {
            print("[VM] sendToOpencode aborted (generation changed)")
            return
        }
        guard let client = opencodeClient else {
            errorMessage = "Opencode client not initialized"
            stopConversation(caller: "sendToOpencode_noClient")
            return
        }

        conversationState = .generating
        logStateChange(.generating)
        isTyping = true
        debugInfo = "Generating (opencode)..."
        resetSpeechPipelineState()
        opencodeResponseText = ""

        let startTime = Date()

        await client.sendMessage(text,
            onDelta: { [weak self] delta in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(gen) else { return }
                    self.opencodeResponseText += delta
                    self.streamTTSToken(delta)
                }
            },
            onComplete: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(gen) else { return }
                    let totalTime = Date().timeIntervalSince(startTime)
                    print("[Opencode] Finished in \(totalTime)s")
                    self.isTyping = false

                    if !self.opencodeResponseText.isEmpty {
                        self.messages.append(Message(role: .assistant, text: self.opencodeResponseText))
                        self.logMessage(self.messages.last!)
                        self.opencodeResponseText = ""
                    } else {
                        self.errorMessage = "opencode returned no text. Check the server at \(self.opencodeURL)."
                        self.logConversation("[\(self.timestamp())] ERROR: opencode returned no text")
                    }

                    if !self.pendingSentence.isEmpty {
                        self.speakSentence(self.pendingSentence)
                        self.pendingSentence = ""
                    }

                    self.finishStreaming(generation: gen)
                }
            }
        )

        if !isCurrent(gen) {
            opencodeResponseText = ""
        }
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

        ttsQueue.append(trimmed)
        drainTTSQueue()
    }

    /// Feeds exactly one sentence to `AVSpeechSynthesizer` at a time. Keeping
    /// the queue ourselves lets `toggleTTSSpeed()` restart the current sentence
    /// at the new rate without losing the remaining sentences.
    private func drainTTSQueue() {
        guard currentlySpeakingText == nil, !ttsQueue.isEmpty else { return }
        let text = ttsQueue.removeFirst()
        currentlySpeakingText = text

        let language = detectLanguage(from: text)
        let voiceLanguage = language == "chinese" ? "zh-CN" : "en-US"

        let utterance = AVSpeechUtterance(string: text)
        if let voice = AVSpeechSynthesisVoice(language: voiceLanguage) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * ttsRate
        utterance.volume = 1.0

        utteranceGenerations[ObjectIdentifier(utterance)] = generation
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

    // MARK: - Conversation management

    func clearConversation() {
        messages = []
        debugInfo = ""
        isTyping = false
        currentTurnUserMessageID = nil
        opencodeClient?.reset()
        currentSessID = nil
    }

    func copyConversation() {
        guard !messages.isEmpty else { return }
        let text = messages.map { msg in
            let role = msg.role == .user ? "You" : "AI"
            let time = DateFormatter.localizedString(from: msg.timestamp, dateStyle: .none, timeStyle: .short)
            return "[\(time)] \(role): \(msg.text)"
        }.joined(separator: "\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        debugInfo = "Conversation copied to clipboard"
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
