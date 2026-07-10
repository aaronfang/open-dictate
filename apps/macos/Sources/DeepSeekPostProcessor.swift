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
        config: Config
    ) async throws -> String {
        let trimmedKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ProcessError.notConfigured }

        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProcessError.emptyInput }

        let url = chatCompletionsURL(baseURL: config.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(2, config.timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let toneHint = (tone?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "中性书面，清晰自然"
        let conservativeHint = config.conservative ? "尽量少改动，只做必要清理" : "可以适度润色，使表达更顺畅"
        let system = "你是听写文本整理助手。只输出整理后的最终文本，不要解释、不要加引号、不要加前后缀。"
        let user = """
        请把下面的口语转写整理成更自然、清晰的文字。
        要求：删除口头禅与无意义重复，保留原意不新增事实，补全基础标点；风格参考：\(toneHint)；\(conservativeHint)。

        文本：
        \(text)
        """

        let body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "deepseek-v4-flash"
                : config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "temperature": 0.2,
            "stream": false,
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
