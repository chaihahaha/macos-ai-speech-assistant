import Foundation

final class OpencodeClient {
    private let baseURL: String
    private let directory: String
    private let providerID: String
    private let modelID: String
    private let agent: String
    private var sessionID: String?
    private var pollTask: Task<Void, Never>?
    private var onTextDelta: ((String) -> Void)?
    private var onComplete: (() -> Void)?
    private var completeCalled = false

    init(config: AppConfig) {
        self.baseURL = config.opencode.serverURL
        self.directory = config.opencode.directory
        self.providerID = config.opencode.providerID
        self.modelID = config.opencode.modelID
        self.agent = config.opencode.agent
    }

    func ensureSession() async throws {
        if sessionID != nil { return }

        let url = URL(string: "\(baseURL)/session")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !directory.isEmpty {
            req.setValue(directory, forHTTPHeaderField: "x-opencode-directory")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: [:])

        let (data, _) = try await URLSession.shared.data(for: req, delegate: nil)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String {
            sessionID = id
            print("[Opencode] Created session: \(id)")
        }
    }

    func sendMessage(_ text: String,
                     onDelta: @escaping (String) -> Void,
                     onComplete: @escaping () -> Void) async {
        self.onTextDelta = onDelta
        self.onComplete = onComplete
        completeCalled = false

        do {
            try await ensureSession()
            guard let sid = sessionID else { return }

            print("[Opencode] Sending prompt_async to \(sid) (agent: \(self.agent))")

            let url = URL(string: "\(baseURL)/session/\(sid)/prompt_async")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(directory, forHTTPHeaderField: "x-opencode-directory")
            req.timeoutInterval = 10

            let body: [String: Any] = [
                "parts": [["type": "text", "text": text]],
                "agent": self.agent,
                "model": [
                    "providerID": self.providerID,
                    "modelID": self.modelID
                ]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (_, response) = try await URLSession.shared.data(for: req, delegate: nil)
            if let httpResponse = response as? HTTPURLResponse {
                print("[Opencode] prompt_async HTTP \(httpResponse.statusCode)")
            }

            // Poll for the assistant response
            startPolling(sessionID: sid)
            print("[Opencode] Poll task started for session \(sid)")
        } catch {
            print("[Opencode] Send error: \(error)")
            if !Task.isCancelled { await callComplete() }
        }
    }

    private func startPolling(sessionID sid: String) {
        pollTask?.cancel()
        var seenMessageIDs = Set<String>()
        var lastText = ""

        pollTask = Task { [weak self] in
            guard let self else { return }

            let deadline = Date().addingTimeInterval(300)
            var lastMessageCount = 0

            while Date() < deadline {
                if Task.isCancelled { break }

                do {
                    let url = URL(string: "\(self.baseURL)/session/\(sid)/message?limit=10")!
                    var req = URLRequest(url: url)
                    req.setValue(self.directory, forHTTPHeaderField: "x-opencode-directory")
                    req.timeoutInterval = 5

                    let (data, _) = try await URLSession.shared.data(for: req, delegate: nil)
                    guard let rawMessages = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                        print("[Opencode] Poll: unexpected response format")
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        continue
                    }

                    if seenMessageIDs.isEmpty {
                        print("[Opencode] Poll: got \(rawMessages.count) messages")
                    }

                    // Process each message in the array
                    for raw in rawMessages {
                        guard let msg = raw as? [String: Any],
                              let info = msg["info"] as? [String: Any],
                              let msgID = info["id"] as? String,
                              let role = info["role"] as? String else {
                            continue
                        }

                        if role == "user" { continue }

                        // Collect text from parts array
                        var textParts: [String] = []
                        if let parts = msg["parts"] as? [[String: Any]] {
                            for part in parts {
                                if let pt = part["type"] as? String, pt == "text",
                                   let txt = part["text"] as? String, !txt.isEmpty {
                                    textParts.append(txt)
                                }
                            }
                        }
                        if textParts.isEmpty { continue }

                        let fullText = textParts.joined()

                        if !seenMessageIDs.contains(msgID) {
                            seenMessageIDs.insert(msgID)
                            print("[Opencode] Poll: new assistant msg \(msgID.prefix(12)) \(fullText.count) chars")
                            if !fullText.isEmpty {
                                await MainActor.run { self.onTextDelta?(fullText) }
                                lastText = fullText
                            }
                        } else if fullText.count > lastText.count {
                            let delta = String(fullText.dropFirst(lastText.count))
                            if !delta.isEmpty {
                                await MainActor.run { self.onTextDelta?(delta) }
                                lastText = fullText
                            }
                        }
                    }

                    let currentCount = seenMessageIDs.count
                    if currentCount > 0, currentCount == lastMessageCount {
                        // Check if the last assistant message is complete
                        for raw in rawMessages {
                            guard let msg = raw as? [String: Any],
                                  let info = msg["info"] as? [String: Any],
                                  let role = info["role"] as? String,
                                  role == "assistant",
                                  let msgID = info["id"] as? String,
                                  seenMessageIDs.contains(msgID) else { continue }

                            let finish = info["finish"] as? String
                            let completed = info["time"] as? [String: Any]
                            if finish == "stop" || finish == "error" || completed?["completed"] != nil {
                                print("[Opencode] Poll: response complete (\(lastText.count) chars)")
                                await callComplete()
                                return
                            }
                        }
                    }

                    lastMessageCount = currentCount
                } catch {
                    if !Task.isCancelled {
                        print("[Opencode] Poll error: \(error)")
                    }
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            // Timeout
            print("[Opencode] Poll timeout")
            await callComplete()
        }
    }

    func abort() async {
        pollTask?.cancel()
        pollTask = nil

        guard let sid = sessionID else { return }
        let url = URL(string: "\(baseURL)/session/\(sid)/abort")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(directory, forHTTPHeaderField: "x-opencode-directory")
        _ = try? await URLSession.shared.data(for: req, delegate: nil)
        print("[Opencode] Aborted session \(sid)")
    }

    func reset() {
        pollTask?.cancel()
        pollTask = nil
        sessionID = nil
        onTextDelta = nil
        onComplete = nil
        completeCalled = false
    }

    private func callComplete() async {
        guard !completeCalled else { return }
        completeCalled = true
        pollTask?.cancel()
        await MainActor.run { onComplete?() }
    }

    static func isServerRunning(_ url: String) async -> Bool {
        guard let healthURL = URL(string: "\(url)/global/health") else { return false }
        var req = URLRequest(url: healthURL)
        req.timeoutInterval = 2
        do {
            let (data, _) = try await URLSession.shared.data(for: req, delegate: nil)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let healthy = json["healthy"] as? Bool { return healthy }
        } catch {}
        return false
    }

    static func startServer() -> Process? {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["opencode", "serve", "--hostname", "0.0.0.0", "--port", "9999"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            print("[Opencode] Starting opencode serve...")
            return task
        } catch {
            print("[Opencode] Failed to start serve: \(error)")
            return nil
        }
    }
}
