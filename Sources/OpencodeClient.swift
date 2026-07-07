import Foundation

final class OpencodeClient {
    private let baseURL: String
    private let directory: String
    private var sessionID: String?
    private var eventTask: Task<Void, Never>?
    private var onTextDelta: ((String) -> Void)?
    private var onComplete: (() -> Void)?
    private var currentAssistantMessageID: String?
    private var completeCalled = false

    init(config: AppConfig) {
        self.baseURL = config.opencode.serverURL
        self.directory = config.opencode.directory
    }

    var isSessionActive: Bool { sessionID != nil }

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
                     providerID: String,
                     modelID: String,
                     agent: String,
                     onDelta: @escaping (String) -> Void,
                     onComplete: @escaping () -> Void) async {
        self.onTextDelta = onDelta
        self.onComplete = onComplete
        currentAssistantMessageID = nil
        completeCalled = false

        do {
            try await ensureSession()
            guard let sid = sessionID else { return }

            // Start SSE stream first, then send message
            startEventStream(sessionID: sid)

            try await Task.sleep(nanoseconds: 100_000_000)

            let url = URL(string: "\(baseURL)/session/\(sid)/message")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 300

            let body: [String: Any] = [
                "parts": [["type": "text", "text": text]],
                "agent": agent,
                "model": [
                    "providerID": providerID,
                    "modelID": modelID
                ]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            print("[Opencode] Sending message to session \(sid)")

            _ = try await URLSession.shared.data(for: req, delegate: nil)
        } catch {
            print("[Opencode] Send error: \(error)")
            await callComplete()
        }
    }

    private func startEventStream(sessionID sid: String) {
        eventTask?.cancel()

        eventTask = Task { [weak self] in
            guard let self else { return }

            var urlStr = "\(self.baseURL)/event"
            if !self.directory.isEmpty {
                var comps = URLComponents(string: urlStr)
                comps?.queryItems = [URLQueryItem(name: "directory", value: self.directory)]
                if let u = comps?.url { urlStr = u.absoluteString }
            }

            do {
                var req = URLRequest(url: URL(string: urlStr)!)
                req.timeoutInterval = 600

                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                print("[Opencode] SSE stream connected")

                var buffer = ""
                for try await byte in bytes {
                    if Task.isCancelled { break }

                    buffer.append(Character(UnicodeScalar(byte)))
                    if byte == UInt8(ascii: "\n") {
                        let line = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        buffer = ""

                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard let jsonData = jsonStr.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let props = event["properties"] as? [String: Any] else { continue }

                        let eventSid = props["sessionID"] as? String ?? ""
                        guard eventSid == sid else { continue }

                        let eventType = event["type"] as? String ?? ""

                        switch eventType {
                        case "session.next.text.delta":
                            if let delta = props["delta"] as? String {
                                await MainActor.run { self.onTextDelta?(delta) }
                            }

                        case "session.next.step.ended":
                            print("[Opencode] Step ended")
                            await callComplete()
                            return

                        case "session.next.step.failed":
                            print("[Opencode] Step failed: \(props["error"] ?? "unknown")")
                            await callComplete()
                            return

                        default:
                            break
                        }
                    }
                }

                // Stream ended naturally without step.ended
                if !Task.isCancelled {
                    print("[Opencode] SSE stream closed")
                    await callComplete()
                }
            } catch {
                if !Task.isCancelled {
                    print("[Opencode] SSE stream error: \(error)")
                    await callComplete()
                }
            }
        }
    }

    func abort() async {
        eventTask?.cancel()
        eventTask = nil

        guard let sid = sessionID else { return }
        let url = URL(string: "\(baseURL)/session/\(sid)/abort")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req, delegate: nil)
        print("[Opencode] Aborted session \(sid)")
    }

    func reset() {
        eventTask?.cancel()
        eventTask = nil
        sessionID = nil
        onTextDelta = nil
        onComplete = nil
        currentAssistantMessageID = nil
        completeCalled = false
    }

    private func callComplete() async {
        guard !completeCalled else { return }
        completeCalled = true
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
