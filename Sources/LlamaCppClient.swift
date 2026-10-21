import Foundation

final class LlamaCppClient: @unchecked Sendable {
    let baseURL: String
    let systemPrompt: String
    let maxTokens: Int
    var onTextDelta: ((String) -> Void)?
    var onComplete: ((String) -> Void)?
    /// Diagnostics sink (written into the conversation log by the ViewModel).
    var log: ((String) -> Void)?
    var completeCalled = false
    private var streamingTask: Task<Void, Never>?

    init(baseURL: String, systemPrompt: String, maxTokens: Int) {
        self.baseURL = baseURL
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
    }

    func sendMessage(_ text: String,
                     history: [Message],
                     onDelta: @escaping (String) -> Void,
                     onComplete: @escaping (String) -> Void) {
        self.onTextDelta = onDelta
        self.onComplete = onComplete
        completeCalled = false

        streamingTask = Task { [weak self] in
            guard let self else { return }
            var assistantText = ""
            let startTime = Date()

            let systemMsg: [String: String] = ["role": "system", "content": systemPrompt]
            let historyMsgs = history.map { msg in
                ["role": msg.role == .user ? "user" : "assistant", "content": msg.text]
            }
            let userMsg: [String: String] = ["role": "user", "content": text]
            let allMessages = [systemMsg] + historyMsgs + [userMsg]

            let requestBody: [String: Any] = [
                "model": "",
                "messages": allMessages,
                "n_predict": maxTokens,
                "stream": true
            ]

            guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
                await callComplete("")
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 300

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            } catch {
                print("[LlamaCpp] Failed to serialize request: \(error)")
                await callComplete("")
                return
            }

            print("[LlamaCpp] Starting streaming request to \(baseURL)")
            log?("POST \(url.absoluteString)")

            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[LlamaCpp] Got response: \(response)")
                log?("HTTP \(status)")

                if status != 200 {
                    var body = ""
                    for try await byte in bytes {
                        body.append(Character(UnicodeScalar(byte)))
                        if body.count > 500 { break }
                    }
                    log?("HTTP error body: \(body)")
                    await callComplete("")
                    return
                }

                var lineBuffer = Data()
                for try await byte in bytes {
                    if Task.isCancelled { break }
                    lineBuffer.append(byte)
                    if byte == UInt8(ascii: "\n") {
                        if let lineStr = String(data: lineBuffer, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           lineStr.hasPrefix("data: ") {
                            let jsonStr = String(lineStr.dropFirst(6))
                            if jsonStr != "[DONE]" {
                                if let jsonData = jsonStr.data(using: .utf8),
                                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                                   let choices = json["choices"] as? [[String: Any]],
                                   let firstChoice = choices.first,
                                   let delta = firstChoice["delta"] as? [String: Any],
                                   let content = delta["content"] as? String,
                                   !content.isEmpty {
                                    assistantText += content
                                    await MainActor.run { [weak self] in
                                        self?.onTextDelta?(content)
                                    }
                                }
                            }
                        }
                        lineBuffer = Data()
                    }
                }
            } catch {
                if !Task.isCancelled {
                    print("[LlamaCpp] Stream error: \(error)")
                    log?("stream error: \(error.localizedDescription)")
                }
            }

            let totalTime = Date().timeIntervalSince(startTime)
            print("[LlamaCpp] Finished in \(String(format: "%.2f", totalTime))s, \(assistantText.count) chars")
            log?("finished \(String(format: "%.2f", totalTime))s, \(assistantText.count) chars")
            await callComplete(assistantText)
        }
    }

    func cancel() {
        completeCalled = true
        onTextDelta = nil
        onComplete = nil
        streamingTask?.cancel()
        streamingTask = nil
    }

    private func callComplete(_ text: String) async {
        guard !completeCalled else { return }
        completeCalled = true
        await MainActor.run { [weak self] in self?.onComplete?(text) }
    }
}
