import Foundation

/// 火山引擎豆包语音 — 录音文件极速版 ASR（HTTP）。
/// 文档：https://www.volcengine.com/docs/6561/1631584
/// 出网类型：音频（整段 WAV/base64）。
enum VolcengineAsrClient {
    struct Config: Sendable {
        /// 旧版控制台 App ID（X-Api-App-Key）。
        var appKey: String
        /// 旧版 Access Token（X-Api-Access-Key）。
        var accessKey: String
        /// 新版控制台统一 API Key（X-Api-Key）；优先于 App/Access。
        var apiKey: String
        var endpoint: String
        var resourceId: String
        var timeoutSeconds: TimeInterval
        var uid: String
    }

    enum ProcessError: LocalizedError {
        case notConfigured
        case emptyAudio
        case httpStatus(Int, String)
        case apiStatus(String, String)
        case badResponse
        case emptyResult
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "未配置火山引擎鉴权（API Key，或 App Key + Access Key）"
            case .emptyAudio:
                return "录音为空"
            case .httpStatus(let code, let body):
                return "火山 ASR HTTP \(code): \(body.prefix(200))"
            case .apiStatus(let code, let message):
                return "火山 ASR \(code): \(message)"
            case .badResponse:
                return "火山 ASR 返回无法解析"
            case .emptyResult:
                return "火山 ASR 未识别到有效文本"
            case .transport(let message):
                return message
            }
        }
    }

    static func isConfigured(_ config: Config) -> Bool {
        let api = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !api.isEmpty { return true }
        let app = config.appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let access = config.accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !app.isEmpty && !access.isEmpty
    }

    static func transcribe(wavURL: URL, config: Config) async throws -> String {
        guard isConfigured(config) else { throw ProcessError.notConfigured }

        let audioData = try Data(contentsOf: wavURL)
        guard !audioData.isEmpty else { throw ProcessError.emptyAudio }

        let endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
            : config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint) else {
            throw ProcessError.transport("无效的 endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(5, config.timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestId = UUID().uuidString
        let resource = config.resourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "volc.bigasr.auc_turbo"
            : config.resourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue(resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestId, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        } else {
            request.setValue(
                config.appKey.trimmingCharacters(in: .whitespacesAndNewlines),
                forHTTPHeaderField: "X-Api-App-Key"
            )
            request.setValue(
                config.accessKey.trimmingCharacters(in: .whitespacesAndNewlines),
                forHTTPHeaderField: "X-Api-Access-Key"
            )
        }

        let uid = config.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (config.appKey.isEmpty ? "open-dictate" : config.appKey)
            : config.uid
        let body: [String: Any] = [
            "user": ["uid": uid],
            "audio": ["data": audioData.base64EncodedString()],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
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

        let statusCode = http.value(forHTTPHeaderField: "X-Api-Status-Code")
            ?? http.value(forHTTPHeaderField: "x-api-status-code")
            ?? ""
        let statusMessage = http.value(forHTTPHeaderField: "X-Api-Message")
            ?? http.value(forHTTPHeaderField: "x-api-message")
            ?? ""
        let logId = http.value(forHTTPHeaderField: "X-Tt-Logid")
            ?? http.value(forHTTPHeaderField: "x-tt-logid")
            ?? ""

        NSLog(
            "Volcengine ASR http=%d apiStatus=%@ message=%@ logid=%@ bytes=%d",
            http.statusCode,
            statusCode,
            statusMessage,
            logId,
            data.count
        )

        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ProcessError.httpStatus(http.statusCode, bodyText)
        }

        // 20000000 = finished OK. Some gateways omit the header on success — fall through to body.
        if !statusCode.isEmpty, statusCode != "20000000" {
            throw ProcessError.apiStatus(statusCode, statusMessage.isEmpty ? "识别失败" : statusMessage)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProcessError.badResponse
        }

        let text = extractText(from: json)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProcessError.emptyResult }
        return text
    }

    private static func extractText(from json: [String: Any]) -> String {
        if let result = json["result"] as? [String: Any],
           let text = result["text"] as? String,
           !text.isEmpty {
            return text
        }
        if let result = json["result"] as? String, !result.isEmpty {
            return result
        }
        if let text = json["text"] as? String, !text.isEmpty {
            return text
        }
        // Fallback: join utterance texts.
        if let result = json["result"] as? [String: Any],
           let utterances = result["utterances"] as? [[String: Any]] {
            let joined = utterances.compactMap { $0["text"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined()
            if !joined.isEmpty { return joined }
        }
        return ""
    }
}
