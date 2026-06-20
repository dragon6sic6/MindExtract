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
    case gemini = "Google Gemini"
    case grok = "xAI Grok"
    case mistral = "Mistral"
    case groq = "Groq"
    case openRouter = "OpenRouter"
    case custom = "Custom endpoint"

    var id: String { rawValue }

    /// Compact name for tight UI (e.g. the in-chat model switcher chip).
    var shortName: String {
        switch self {
        case .apple: return "Apple"
        case .ollama: return "Ollama"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .mistral: return "Mistral"
        case .groq: return "Groq"
        case .openRouter: return "OpenRouter"
        case .custom: return "Custom"
        }
    }

    var detail: String {
        switch self {
        case .apple: return "Built into macOS 26 — fully on-device, nothing leaves your Mac"
        case .ollama: return "Use models you've downloaded with Ollama (Gemma, Mistral, Llama…) — fully local"
        case .openAI: return "Cloud — transcript text is sent to OpenAI"
        case .anthropic: return "Cloud — transcript text is sent to Anthropic"
        case .gemini: return "Cloud — transcript text is sent to Google"
        case .grok: return "Cloud — transcript text is sent to xAI"
        case .mistral: return "Cloud — European provider (EU-hosted). Transcript text is sent to Mistral"
        case .groq: return "Cloud — fast open-model inference. Transcript text is sent to Groq"
        case .openRouter: return "Cloud — an aggregator: your transcript goes to OpenRouter and is then forwarded to whichever model you pick (two hops)"
        case .custom: return "Your own endpoint — the transcript is sent wherever you point it. You're in control; use a server you trust"
        }
    }

    /// Keychain account holding this provider's API key (nil for local providers).
    var keychainKey: String? {
        switch self {
        case .apple, .ollama: return nil
        case .openAI: return "openai-api-key"
        case .anthropic: return "anthropic-api-key"
        case .gemini: return "gemini-api-key"
        case .grok: return "grok-api-key"
        case .mistral: return "mistral-api-key"
        case .groq: return "groq-api-key"
        case .openRouter: return "openrouter-api-key"
        case .custom: return "custom-api-key"
        }
    }

    /// OpenAI-Chat-Completions-compatible config (everything except Apple, Ollama,
    /// Anthropic — which have their own wire formats).
    @MainActor
    func compatConfig(_ s: AppSettings) -> (baseURL: String, keychainKey: String, model: String, defaultModel: String)? {
        switch self {
        case .openAI:     return ("https://api.openai.com/v1", "openai-api-key", s.openAIModel, "gpt-4o-mini")
        case .gemini:     return ("https://generativelanguage.googleapis.com/v1beta/openai", "gemini-api-key", s.geminiModel, "gemini-2.5-flash")
        case .grok:       return ("https://api.x.ai/v1", "grok-api-key", s.grokModel, "grok-4.3")
        case .mistral:    return ("https://api.mistral.ai/v1", "mistral-api-key", s.mistralModel, "mistral-small-latest")
        case .groq:       return ("https://api.groq.com/openai/v1", "groq-api-key", s.groqModel, "openai/gpt-oss-120b")
        case .openRouter: return ("https://openrouter.ai/api/v1", "openrouter-api-key", s.openRouterModel, "google/gemini-2.5-flash")
        case .custom:     return (s.customBaseURL, "custom-api-key", s.customModel, "")
        case .apple, .ollama, .anthropic: return nil
        }
    }

    /// Rough prompt character budget (drives chunking) — smaller-context models
    /// get a smaller budget so a long transcript chunks instead of overflowing.
    var promptBudget: Int {
        switch self {
        case .groq: return 24_000      // hosted open models, modest context
        case .mistral: return 90_000   // ~32k tokens on the small tier
        default: return 200_000        // OpenAI/Gemini/Grok/OpenRouter/Custom — large
        }
    }

    /// Where to get an API key (shown in Settings).
    var keyURL: String? {
        switch self {
        case .openAI: return "https://platform.openai.com/api-keys"
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .gemini: return "https://aistudio.google.com/apikey"
        case .grok: return "https://console.x.ai"
        case .mistral: return "https://console.mistral.ai/api-keys"
        case .groq: return "https://console.groq.com/keys"
        case .openRouter: return "https://openrouter.ai/keys"
        case .apple, .ollama, .custom: return nil
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
        let s = AppSettings.shared
        switch s.aiBackend {
        case .apple: return AppleIntelligenceBackend()
        case .ollama: return OllamaBackend(model: s.ollamaModel)
        case .anthropic: return AnthropicBackend(model: s.anthropicModel)
        case .openAI, .gemini, .grok, .mistral, .groq, .openRouter, .custom:
            let cfg = s.aiBackend.compatConfig(s)!
            return OpenAICompatibleBackend(
                providerName: s.aiBackend.shortName,
                baseURL: cfg.baseURL,
                apiKey: KeychainHelper.get(cfg.keychainKey) ?? "",
                model: cfg.model,
                defaultModel: cfg.defaultModel,
                maxPromptChars: s.aiBackend.promptBudget
            )
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

// MARK: - OpenAI Chat-Completions-compatible providers (cloud, opt-in)
// One client serves OpenAI, Gemini's compat endpoint, Grok, Mistral, Groq,
// OpenRouter, and any custom endpoint — they all share the same wire format.

struct OpenAICompatibleBackend: AIBackend {
    let providerName: String
    let baseURL: String
    let apiKey: String
    let model: String
    let defaultModel: String

    var resolvedModel: String { model.isEmpty ? defaultModel : model }
    var badge: String { "Cloud · \(providerName) (\(resolvedModel))" }
    var maxPromptChars: Int = 200_000

    func respond(instructions: String, prompt: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIError(message: "Add your \(providerName) API key in Settings to use this provider.")
        }
        var trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            throw AIError(message: "Set the \(providerName) endpoint URL in Settings.")
        }
        // A custom URL without a scheme would parse but never connect — fix it up.
        if !trimmedBase.lowercased().hasPrefix("http") {
            trimmedBase = "https://" + trimmedBase
        }
        // Tolerate a pasted full endpoint (…/chat/completions) instead of just the base.
        while trimmedBase.hasSuffix("/") { trimmedBase = String(trimmedBase.dropLast()) }
        if trimmedBase.hasSuffix("/chat/completions") {
            trimmedBase = String(trimmedBase.dropLast("/chat/completions".count))
        }
        let endpoint = trimmedBase + "/chat/completions"
        guard let url = URL(string: endpoint), url.scheme != nil, url.host != nil else {
            throw AIError(message: "\(providerName): the endpoint URL isn't valid. It should look like https://host/v1")
        }
        guard !resolvedModel.isEmpty else {
            throw AIError(message: "Set a model name for \(providerName) in Settings.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        let body: [String: Any] = [
            "model": resolvedModel,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError(message: "Unexpected response from \(providerName).")
        }
        // Error can be an object {message} (OpenAI/Grok/Mistral) or a string.
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            throw AIError(message: "\(providerName): \(msg)")
        }
        if let err = json["error"] as? String {
            throw AIError(message: "\(providerName): \(err)")
        }
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            throw AIError(message: "\(providerName) rejected the API key — check it in Settings.")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError(message: "Unexpected response from \(providerName).")
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
