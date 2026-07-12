import Foundation

/// DeepSeek chat completions (OpenAI-compatible). Sends text only — never audio.
enum DeepSeekPostProcessor {
    struct Config: Sendable {
        var apiKey: String
        var baseURL: String
        var model: String
        var timeoutSeconds: TimeInterval
        var conservative: Bool
    }

    enum ProcessError: LocalizedError {
        case notConfigured
        case emptyInput
        case httpStatus(Int, String)
        case badResponse
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "未配置 DeepSeek API Key"
            case .emptyInput: return "输入为空"
            case .httpStatus(let code, let body):
                let snippet = body.prefix(200)
                return "DeepSeek HTTP \(code): \(snippet)"
            case .badResponse: return "DeepSeek 返回无法解析"
            case .transport(let message): return message
            }
        }
    }

    static func process(
        _ input: String,
        tone: String?,
        config: Config,
        previousText: String? = nil,
        script: ChineseScriptPreference = .simplified
    ) async throws -> String {
        try await chat(
            system: LLMPolishPrompt.system,
            user: LLMPolishPrompt.user(
                text: input,
                tone: tone,
                conservative: config.conservative,
                previousText: previousText,
                script: script
            ),
            config: config,
            maxTokens: 1024
        )
    }

    static func ask(
        selected: String,
        instruction: String,
        config: Config
    ) async throws -> String {
        try await chat(
            system: LLMPolishPrompt.askSystem,
            user: LLMPolishPrompt.askUser(selected: selected, instruction: instruction),
            config: config,
            maxTokens: 2048
        )
    }

    private static func chat(
        system: String,
        user: String,
        config: Config,
        maxTokens: Int
    ) async throws -> String {
        let trimmedKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ProcessError.notConfigured }

        let text = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProcessError.emptyInput }

        let url = chatCompletionsURL(baseURL: config.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(2, config.timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        // Keep V4 default thinking mode (enabled). Cap output so runaway reasoning
        // cannot bill unbounded tokens; reasoning counts toward max_tokens.
        let body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "deepseek-v4-flash"
                : config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "temperature": 0.2,
            "stream": false,
            "max_tokens": maxTokens,
            "thinking": ["type": "enabled"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProcessError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProcessError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ProcessError.httpStatus(http.statusCode, bodyText)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw ProcessError.badResponse
        }

        if let usage = json["usage"] as? [String: Any] {
            let prompt = usage["prompt_tokens"] as? Int ?? -1
            let completion = usage["completion_tokens"] as? Int ?? -1
            let reasoning = usage["reasoning_tokens"] as? Int
                ?? (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
                ?? -1
            let total = usage["total_tokens"] as? Int ?? -1
            NSLog(
                "DeepSeek usage prompt=%d completion=%d reasoning=%d total=%d",
                prompt,
                completion,
                reasoning,
                total
            )
        }

        let out = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { throw ProcessError.badResponse }
        return out
    }

    /// Accepts `https://api.deepseek.com` or `.../v1` and builds chat completions URL.
    static func chatCompletionsURL(baseURL: String) -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            base = "https://api.deepseek.com"
        }
        while base.hasSuffix("/") {
            base.removeLast()
        }
        if base.hasSuffix("/v1") {
            return URL(string: "\(base)/chat/completions")!
        }
        return URL(string: "\(base)/chat/completions")!
    }
}
