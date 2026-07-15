import Foundation

@main
struct OpenCodeTest {
    static func main() async {
        FileHandle.standardError.write(Data("Starting OpenCodeTest...\n".utf8))
        let baseURL = "http://127.0.0.1:9999"
        let directory = "/Users/hasee"

        print("\n=== 1. Create session @ \(baseURL) ===")
        fflush(stdout)
        var req = URLRequest(url: URL(string: "\(baseURL)/api/session")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(directory, forHTTPHeaderField: "x-opencode-directory")
        req.httpBody = try! JSONSerialization.data(withJSONObject: [:])
        let (data, _) = try! await URLSession.shared.data(for: req)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let respData = json["data"] as? [String: Any] ?? json
        guard let sid = respData["id"] as? String else { print("FAIL: \(json)"); return }
        print("Session: \(sid)")

        // Round 1
        print("\n=== 2. Prompt 1: 潘姆巴斯星球的国王叫尼斯洛尔姆,记住这个名字 ===")
        await sendPrompt(baseURL: baseURL, sid: sid, directory: directory,
                         text: "潘姆巴斯星球的国王叫尼斯洛尔姆，记住这个名字。",
                         round: 1)

        // Round 2
        print("\n=== 3. Prompt 2: 潘姆巴斯星球的国王叫什么? ===")
        await sendPrompt(baseURL: baseURL, sid: sid, directory: directory,
                         text: "潘姆巴斯星球的国王叫什么？",
                         round: 2)

        print("\n=== Done ===")
    }

    static func sendPrompt(baseURL: String, sid: String, directory: String, text: String, round: Int) async {
        do {
            var req = URLRequest(url: URL(string: "\(baseURL)/api/session/\(sid)/prompt")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(directory, forHTTPHeaderField: "x-opencode-directory")
            let body: [String: Any] = [
                "parts": [["type": "text", "text": text]],
                "agent": "build",
                "model": ["providerID": "llama.cpp", "modelID": "qwen3.6"]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.timeoutInterval = 10
            let (respData, resp) = try await URLSession.shared.data(for: req)
            let httpResp = resp as! HTTPURLResponse
            print("[Prompt \(round)] HTTP \(httpResp.statusCode)")
            let bodyStr = String(data: respData, encoding: .utf8) ?? ""
            print("[Prompt \(round)] body: \(bodyStr.prefix(500))")
            fflush(stdout)
        } catch {
            print("[Prompt \(round)] FAIL: \(error)")
            fflush(stdout)
            return
        }

        do {
            var eventReq = URLRequest(url: URL(string: "\(baseURL)/api/session/\(sid)/event")!)
            eventReq.setValue(directory, forHTTPHeaderField: "x-opencode-directory")
            eventReq.timeoutInterval = 120
            let (bytes, _) = try await URLSession.shared.bytes(for: eventReq)
            print("[SSE \(round)] Connected")
            fflush(stdout)

            var allText = ""
            var lineBuffer = Data()
            var eventCount = 0

            let startTime = Date()
            for try await byte in bytes {
                if Date().timeIntervalSince(startTime) > 120 { break }
                lineBuffer.append(byte)
                if byte == UInt8(ascii: "\n") {
                    let rawLine = String(data: lineBuffer, encoding: .utf8) ?? ""
                    lineBuffer = Data()
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Print ALL lines for debugging
                    if !line.isEmpty {
                        print("[SSE \(round)] LINE: \(line.prefix(200))")
                        fflush(stdout)
                    }

                    if line.hasPrefix("data: ") {
                        let dataStr = String(line.dropFirst(6))
                        if let data = dataStr.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            eventCount += 1

                            let info = json["info"] as? [String: Any]
                            let infoType = (info?["type"] as? String) ?? ""

                            if infoType.contains("delta") {
                                let props = json["properties"] as? [String: Any]
                                let delta = props?["delta"] as? String ?? ""
                                allText += delta
                                print("[SSE \(round)] Δ: \(delta.prefix(30))")
                                fflush(stdout)
                            }
                            if infoType.contains("ended") || infoType.contains("finish") {
                                print("[SSE \(round)] DONE: '\(allText)'")
                                fflush(stdout)
                                return
                            }
                        }
                    }
                }
            }
            print("[SSE \(round)] End: '\(allText)' (\(eventCount) events)")
            fflush(stdout)
        } catch {
            print("[SSE \(round)] Error: \(error)")
            fflush(stdout)
        }
    }
}
