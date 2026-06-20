import Foundation
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Pluggable AI backends for summaries & transcript chat
// Same pattern as the transcription engine: one protocol, several providers.
// Local (Apple, Ollama) by default; cloud (OpenAI, Anthropic) as clearly
// labeled opt-in. The UI always shows where text is processed.

enum AIBackendChoice: String, CaseIterable, Codable, Identifiable {
    case apple = "Apple Intelligence"
    case ollama = "Ollama (local)"
    case openAI = "OpenAI"
    case anthropic = "Anthropic"

    var id: String { rawValue }

    /// Compact name for tight UI (e.g. the in-chat model switcher chip).
    var shortName: String {
        switch self {
        case .apple: return "Apple"
        case .ollama: return "Ollama"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    var detail: String {
        switch self {
        case .apple: return "Built into macOS 26 — fully on-device, nothing leaves your Mac"
        case .ollama: return "Use models you've downloaded with Ollama (Gemma, Mistral, Llama…) — fully local"
        case .openAI: return "Cloud — transcript text is sent to OpenAI"
        case .anthropic: return "Cloud — transcript text is sent to Anthropic"
        }
    }
}

struct AIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol AIBackend: Sendable {
    /// Shown next to results so users always know where text was processed.
    var badge: String { get }
    /// Rough prompt budget in characters (drives chunking / retrieval size).
    var maxPromptChars: Int { get }
    func respond(instructions: String, prompt: String) async throws -> String
}

enum AIBackends {
    @MainActor
    static func current() -> AIBackend {
        switch AppSettings.shared.aiBackend {
        case .apple: return AppleIntelligenceBackend()
        case .ollama: return OllamaBackend(model: AppSettings.shared.ollamaModel)
        case .openAI: return OpenAIBackend(model: AppSettings.shared.openAIModel)
        case .anthropic: return AnthropicBackend(model: AppSettings.shared.anthropicModel)
        }
    }
}

// MARK: - Apple Intelligence (on-device, macOS 26)

struct AppleIntelligenceBackend: AIBackend {
    let badge = "On-device · Apple Intelligence"
    let maxPromptChars = 8_000

    func respond(instructions: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                let session = LanguageModelSession(instructions: instructions)
                do {
                    return try await session.respond(to: prompt).content
                } catch {
                    // Apple's on-device model runs every prompt and response
                    // through a safety guardrail that false-positives on ordinary
                    // transcripts (news, debates, legal testimony). It can't be
                    // disabled from the app — translate the cryptic system error
                    // into something actionable instead of dumping it in chat.
                    let desc = (String(describing: error) + " " + error.localizedDescription).lowercased()
                    if desc.contains("guardrail") || desc.contains("unsafe") || desc.contains("safety") {
                        throw AIError(message: "Apple Intelligence blocked this as possibly sensitive — a known limitation of Apple's on-device safety filter, which often flags ordinary transcripts. Switch to a local model (Ollama) or a cloud provider under Settings → AI Summaries & Chat to avoid it.")
                    }
                    if desc.contains("context") || desc.contains("exceeded") || desc.contains("window") {
                        throw AIError(message: "This transcript is too long for the on-device model. Switch to another AI provider under Settings → AI Summaries & Chat, which can handle longer text.")
                    }
                    throw AIError(message: "Apple Intelligence couldn't complete this request. Try again, or switch AI provider under Settings → AI Summaries & Chat.")
                }
            case .unavailable(.appleIntelligenceNotEnabled):
                throw AIError(message: "Turn on Apple Intelligence in System Settings, or pick another AI provider in Settings.")
            case .unavailable(.modelNotReady):
                throw AIError(message: "The on-device model is still downloading — try again in a few minutes.")
            case .unavailable:
                throw AIError(message: "Apple Intelligence isn't available on this Mac. Pick another AI provider in Settings.")
            }
        }
        #endif
        throw AIError(message: "Apple Intelligence requires macOS 26. Pick another AI provider in Settings.")
    }
}

// MARK: - Ollama (local server, any model the user has pulled)

struct OllamaBackend: AIBackend {
    let model: String
    var badge: String { "Local · Ollama (\(model))" }
    let maxPromptChars = 24_000

    func respond(instructions: String, prompt: String) async throws -> String {
        guard !model.isEmpty else {
            throw AIError(message: "Choose an Ollama model in Settings.")
        }
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    return content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let err = json["error"] as? String {
                    throw AIError(message: "Ollama: \(err)")
                }
            }
            throw AIError(message: "Unexpected response from Ollama.")
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError(message: "Couldn't reach Ollama — make sure the Ollama app is running, then try again.")
        }
    }

    /// Lists locally pulled models (for the Settings picker).
    static func installedModels() async -> [String] {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }
}

// MARK: - OpenAI (cloud, opt-in)

struct OpenAIBackend: AIBackend {
    let model: String
    var badge: String { "Cloud · OpenAI (\(model))" }
    let maxPromptChars = 200_000

    func respond(instructions: String, prompt: String) async throws -> String {
        guard let key = KeychainHelper.get("openai-api-key"), !key.isEmpty else {
            throw AIError(message: "Add your OpenAI API key in Settings to use this provider.")
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        let body: [String: Any] = [
            "model": model.isEmpty ? "gpt-4o-mini" : model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError(message: "Unexpected response from OpenAI.")
        }
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            throw AIError(message: "OpenAI: \(msg)")
        }
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            throw AIError(message: "OpenAI rejected the API key — check it in Settings.")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError(message: "Unexpected response from OpenAI.")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Anthropic (cloud, opt-in)

struct AnthropicBackend: AIBackend {
    let model: String
    var badge: String { "Cloud · Anthropic (\(model))" }
    let maxPromptChars = 200_000

    func respond(instructions: String, prompt: String) async throws -> String {
        guard let key = KeychainHelper.get("anthropic-api-key"), !key.isEmpty else {
            throw AIError(message: "Add your Anthropic API key in Settings to use this provider.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120
        let body: [String: Any] = [
            "model": model.isEmpty ? "claude-haiku-4-5-20251001" : model,
            "max_tokens": 2048,
            "system": instructions,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError(message: "Unexpected response from Anthropic.")
        }
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            throw AIError(message: "Anthropic: \(msg)")
        }
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            throw AIError(message: "Anthropic rejected the API key — check it in Settings.")
        }
        guard let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw AIError(message: "Unexpected response from Anthropic.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Keychain (API keys never touch UserDefaults)

enum KeychainHelper {
    private static let service = "com.mindact.mindextract"

    static func set(_ value: String, key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
