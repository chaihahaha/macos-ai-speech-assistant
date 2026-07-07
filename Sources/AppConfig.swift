import Foundation

struct AppConfig: Codable, Sendable {
    var backend: String
    var llamacpp: LlamaCppConfig
    var opencode: OpencodeConfig
    var models: ModelsConfig
    var vad: VADSettings
    var tts: TTSSettings
    var conversationHistoryPath: String

    struct LlamaCppConfig: Codable, Sendable {
        var serverURL: String
        var maxTokens: Int
        var systemPrompt: String
    }

    struct OpencodeConfig: Codable, Sendable {
        var serverURL: String
        var providerID: String
        var modelID: String
        var agent: String
        var directory: String
    }

    struct ModelsConfig: Codable, Sendable {
        var asrPath: String
        var asrFallbackPaths: [String]
        var vadPath: String
        var vadFallbackPaths: [String]
    }

    struct VADSettings: Codable, Sendable {
        var onset: Float
        var offset: Float
        var minSpeechDuration: Float
        var minSilenceDuration: Float
        var silenceTimeout: Double
        var maxRecordingDuration: Double
    }

    struct TTSSettings: Codable, Sendable {
        var rate: Float
        var slowRate: Float
        var fastRate: Float
    }

    static func load() -> AppConfig {
        let configPaths: [String] = [
            // 1. Config next to executable or in cwd
            FileManager.default.currentDirectoryPath + "/config.json",
            // 2. Config in source directory
            NSString(string: "~/.config/my-llama-speech-assistant/config.json").expandingTildeInPath,
            // 3. Config in project source (build context)
            NSString(string: "~/source/my-llama-speech-assistant/config.json").expandingTildeInPath,
        ]

        var loadedConfig: AppConfig?
        for path in configPaths {
            if FileManager.default.fileExists(atPath: path) {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    let decoder = JSONDecoder()
                    loadedConfig = try decoder.decode(AppConfig.self, from: data)
                    print("[Config] Loaded from \(path)")
                    break
                } catch {
                    print("[Config] Failed to load \(path): \(error)")
                }
            }
        }

        let config: AppConfig
        if let loaded = loadedConfig {
            config = loaded
        } else {
            print("[Config] No config found, using defaults")
            config = AppConfig.defaultConfig
        }

        var resolved = config
        resolved.conversationHistoryPath = (resolved.conversationHistoryPath as NSString).expandingTildeInPath
        return resolved
    }

    static let defaultConfig = AppConfig(
        backend: "llamacpp",
        llamacpp: LlamaCppConfig(
            serverURL: "http://127.0.0.1:8080",
            maxTokens: 4096,
            systemPrompt: "You are a helpful assistant. Provide concise responses."
        ),
        opencode: OpencodeConfig(
            serverURL: "http://127.0.0.1:9999",
            providerID: "llama.cpp",
            modelID: "qwen3.6",
            agent: "general",
            directory: NSString(string: "~/source").expandingTildeInPath
        ),
        models: ModelsConfig(
            asrPath: "/Users/hasee/source/personaplex-mlx-swift/Qwen3-ASR-0.6B-MLX-4bit",
            asrFallbackPaths: ["../../../../../Qwen3-ASR-0.6B-MLX-4bit"],
            vadPath: "/Users/hasee/source/personaplex-mlx-swift/Silero-VAD-v5-MLX",
            vadFallbackPaths: ["../../../../../Silero-VAD-v5-MLX"]
        ),
        vad: VADSettings(
            onset: 0.5, offset: 0.35,
            minSpeechDuration: 0.25, minSilenceDuration: 1.0,
            silenceTimeout: 5.0, maxRecordingDuration: 60.0
        ),
        tts: TTSSettings(rate: 0.95, slowRate: 0.5, fastRate: 1.3),
        conversationHistoryPath: NSString(string: "~/source/ai_talk_ideas").expandingTildeInPath
    )

    func resolvedASRPath() -> String {
        let paths = [models.asrPath] + models.asrFallbackPaths
        for p in paths {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return models.asrPath
    }

    func resolvedVADPath() -> String {
        let paths = [models.vadPath] + models.vadFallbackPaths
        for p in paths {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return models.vadPath
    }
}
