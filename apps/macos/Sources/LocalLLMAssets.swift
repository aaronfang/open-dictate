import Foundation

extension Notification.Name {
    static let localLLMStatusChanged = Notification.Name("LocalLLMStatusChanged")
}

enum LocalLLMAssets {
    static let releaseTag = "b7375"
    /// Canonical on-disk name (ModelScope / Qwen official naming).
    static let modelFileName = "qwen2.5-3b-instruct-q4_k_m.gguf"
    static let modelDisplayName = "Qwen2.5-3B-Instruct (Q4_K_M)"
    static let modelSizeHint = "约 2 GB"
    /// ModelScope Q4_K_M size; used when server omits Content-Length.
    static let modelExpectedBytes: Int64 = 2_104_932_768

    /// Prefer ModelScope (fast in CN); Hugging Face as fallback.
    static let modelDownloadURLs: [URL] = [
        URL(string: "https://www.modelscope.cn/models/qwen/Qwen2.5-3B-Instruct-GGUF/resolve/master/qwen2.5-3b-instruct-q4_k_m.gguf")!,
        URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!,
        URL(string: "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf")!,
    ]

    static var rootDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("OpenDictate/llm", isDirectory: true)
    }

    static var modelURL: URL {
        rootDirectory.appendingPathComponent(modelFileName)
    }

    static var binDirectory: URL {
        rootDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    static var cliURL: URL {
        binDirectory.appendingPathComponent("llama-cli")
    }

    static var serverURL: URL {
        binDirectory.appendingPathComponent("llama-server")
    }

    /// Local OpenAI-compatible server port (app-managed llama-server).
    static let serverPort = 18_765

    static var serverBaseURL: URL {
        URL(string: "http://127.0.0.1:\(serverPort)")!
    }

    static var cliZipURL: URL {
        let arch = isArm64 ? "arm64" : "x64"
        return URL(
            string: "https://github.com/ggml-org/llama.cpp/releases/download/\(releaseTag)/llama-\(releaseTag)-bin-macos-\(arch).zip"
        )!
    }

    static var isArm64: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    }

    static var isModelPresent: Bool {
        let path = modelURL.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        // Q4_K_M is ~2.0GB; reject truncated downloads.
        return size > 1_800_000_000
    }

    static var isCLIPresent: Bool {
        FileManager.default.isExecutableFile(atPath: serverURL.path)
            || FileManager.default.isExecutableFile(atPath: cliURL.path)
    }

    static var isServerPresent: Bool {
        FileManager.default.isExecutableFile(atPath: serverURL.path)
    }

    static var isReady: Bool {
        isModelPresent && isCLIPresent
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024.0)
        }
        return String(format: "%.0f MB", mb)
    }
}
