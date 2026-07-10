import Foundation

enum WhisperTranscriberError: LocalizedError {
    case binaryNotFound(String)
    case modelNotFound(String, tried: [String])
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return """
            找不到 whisper 可执行文件：\(path)
            请安装：brew install whisper-cpp
            然后在设置中填写 whisper-cli 路径（通常为 /opt/homebrew/bin/whisper-cli）
            """
        case .modelNotFound(let path, let tried):
            let paths = tried.joined(separator: "\n  - ")
            return """
            找不到模型文件：\(path)
            已尝试：
              - \(paths)
            请从 https://huggingface.co/ggerganov/whisper.cpp 下载 .bin 模型
            """
        case .failed(let message):
            return message
        }
    }
}

final class WhisperTranscriber {
    struct Config {
        var binary: String
        var modelPath: String
        var languageHint: String = "auto"
    }

    func transcribe(wavURL: URL, config: Config) async throws -> String {
        let binaryURL = try resolveBinary(config.binary)
        let modelURL = try resolveModel(config.modelPath)

        var args = [
            "-m", modelURL.path,
            "-f", wavURL.path,
            "-nt", "-np",
        ]
        if !config.languageHint.isEmpty, config.languageHint != "auto" {
            args.append(contentsOf: ["-l", config.languageHint])
        }

        NSLog("WhisperTranscriber: \(binaryURL.path) \(args.joined(separator: " "))")

        let output = try await runProcess(executable: binaryURL, arguments: args)
        let text = parseStdout(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw WhisperTranscriberError.failed("识别结果为空，请检查模型语言是否匹配（说中文需中文模型）")
        }
        NSLog("WhisperTranscriber result: \(text)")
        return text
    }

    private func resolveBinary(_ path: String) throws -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        var candidates: [String] = []

        if expanded.contains("/") {
            candidates.append(expanded)
        } else {
            candidates.append(contentsOf: [expanded, "whisper-cli", "whisper", "main"])
        }

        let brewPaths = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ]
        candidates.append(contentsOf: brewPaths)

        for candidate in candidates {
            let resolved = NSString(string: candidate).expandingTildeInPath
            if resolved.contains("/") {
                if FileManager.default.isExecutableFile(atPath: resolved) {
                    return URL(fileURLWithPath: resolved)
                }
                continue
            }
            if let url = findInPath(resolved) {
                return url
            }
        }

        throw WhisperTranscriberError.binaryNotFound(path)
    }

    private func resolveModel(_ path: String) throws -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        var candidates: [String] = [expanded]

        if !expanded.hasPrefix("/") {
            let repoModels = URL(fileURLWithPath: "/Users/aaronfang/Documents/github/open-dictate/models")
                .appendingPathComponent(expanded).path
            let homeModels = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(expanded).path
            let cwdModels = FileManager.default.currentDirectoryPath + "/" + expanded
            candidates.append(contentsOf: [repoModels, homeModels, cwdModels])
        }

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        throw WhisperTranscriberError.modelNotFound(path, tried: candidates)
    }

    private func findInPath(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    private func runProcessSync(executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = executable.deletingLastPathComponent()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = [err, out]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let detail = message.isEmpty ? "无输出（请检查 whisper-cli 与模型路径）" : message
            throw WhisperTranscriberError.failed("whisper 退出码 \(process.terminationStatus)：\(detail)")
        }
        return out
    }

    private func runProcess(executable: URL, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try self.runProcessSync(executable: executable, arguments: arguments)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func parseStdout(_ stdout: String) -> String {
        stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                !line.hasPrefix("whisper_") && !line.contains("load time") && !line.contains("fallbacks")
            }
            .map { line -> String in
                if line.hasPrefix("["), let idx = line.lastIndex(of: "]") {
                    return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                }
                return line
            }
            .joined(separator: " ")
    }
}
