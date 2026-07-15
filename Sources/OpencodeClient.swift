import Foundation

final class OpencodeClient {
    var baseURL: String
    var directory: String
    var providerID: String
    var modelID: String
    var agent: String
    private var sessionID: String?
    private var onTextDelta: ((String) -> Void)?
    private var onComplete: (() -> Void)?
    private var completeCalled = false

    init(baseURL: String, directory: String, providerID: String, modelID: String, agent: String) {
        self.baseURL = baseURL
        self.directory = directory
        self.providerID = providerID
        self.modelID = modelID
        self.agent = agent
    }

    convenience init(config: AppConfig) {
        self.init(
            baseURL: config.opencode.serverURL,
            directory: config.opencode.directory,
            providerID: config.opencode.providerID,
            modelID: config.opencode.modelID,
            agent: config.opencode.agent
        )
    }

    func setSessionID(_ id: String) {
        sessionID = id
        print("[Opencode] Using existing session: \(id)")
    }

    func ensureSession() async throws {
        if sessionID != nil { return }
        let url = URL(string: "\(baseURL)/api/session")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !directory.isEmpty { req.setValue(directory, forHTTPHeaderField: "x-opencode-directory") }
        let body: [String: Any] = ["agent": agent, "model": ["id": modelID, "providerID": providerID]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req, delegate: nil)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let respData = json["data"] as? [String: Any],
           let id = respData["id"] as? String {
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

            let url = URL(string: "\(baseURL)/session/\(sid)/message")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !directory.isEmpty { req.setValue(directory, forHTTPHeaderField: "x-opencode-directory") }
            req.timeoutInterval = 600

            let body: [String: Any] = [
                "agent": self.agent,
                "model": ["providerID": self.providerID, "modelID": self.modelID],
                "parts": [["type": "text", "text": text]]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: req, delegate: nil)
            if let httpResponse = response as? HTTPURLResponse {
                print("[Opencode] v1 message HTTP \(httpResponse.statusCode)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = json["info"] as? [String: Any] else {
                print("[Opencode] Invalid v1 response")
                await callComplete()
                return
            }

            let finish = info["finish"] as? String
            var responseText = ""
            if let parts = json["parts"] as? [[String: Any]] {
                for part in parts {
                    if let pt = part["type"] as? String, pt == "text",
                       let txt = part["text"] as? String, !txt.isEmpty {
                        responseText += txt
                    }
                }
            }

            print("[Opencode] v1 response: \(responseText.count) chars, finish=\(finish ?? "nil")")
            if !responseText.isEmpty {
                await MainActor.run { self.onTextDelta?(responseText) }
            }
            await callComplete()
        } catch {
            print("[Opencode] Send error: \(error)")
            if !Task.isCancelled { await callComplete() }
        }
    }

    func interrupt() async {
        guard let sid = sessionID else { return }
        let url = URL(string: "\(baseURL)/api/session/\(sid)/interrupt")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !directory.isEmpty { req.setValue(directory, forHTTPHeaderField: "x-opencode-directory") }
        _ = try? await URLSession.shared.data(for: req, delegate: nil)
    }

    func reset() {
        sessionID = nil
        onTextDelta = nil
        onComplete = nil
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
            let (data, resp) = try await URLSession.shared.data(for: req, delegate: nil)
            guard let httpResp = resp as? HTTPURLResponse else { return false }
            if httpResp.statusCode == 401 { return true }
            if httpResp.statusCode == 200,
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let healthy = json["healthy"] as? Bool { return healthy }
        } catch {}
        return false
    }

    static func startServer(hostname: String = "0.0.0.0", port: Int = 9999) -> Process? {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["opencode", "serve", "--hostname", hostname, "--port", "\(port)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            print("[Opencode] Starting opencode serve on \(hostname):\(port)...")
            return task
        } catch {
            print("[Opencode] Failed to start serve: \(error)")
            return nil
        }
    }
}
