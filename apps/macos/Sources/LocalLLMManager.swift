import Foundation

/// Downloads llama-cli + Qwen2.5-3B GGUF and runs local polish via llama-cli.
final class LocalLLMManager: ObservableObject {
    static let shared = LocalLLMManager()

    enum Phase: Equatable {
        case idle
        case downloadingCLI
        case downloadingModel
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = LocalLLMAssets.isReady ? .ready : .idle
    /// 0...1 for the active download file.
    @Published private(set) var fileProgress: Double = 0
    /// Combined progress (CLI ~5%, model ~95%).
    @Published private(set) var overallProgress: Double = LocalLLMAssets.isReady ? 1 : 0
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var expectedBytes: Int64 = 0
    @Published private(set) var downloadSourceLabel: String = ""

    private var ensureTask: Task<Void, Error>?
    private let stateLock = NSLock()
    private let downloader = FileDownloader()
    private var activeEnsure: Task<Void, Error>?
    private var serverProcess: Process?
    private let serverLock = NSLock()

    var isDownloading: Bool {
        switch phase {
        case .downloadingCLI, .downloadingModel: return true
        default: return false
        }
    }

    var byteProgressText: String {
        guard expectedBytes > 0 || downloadedBytes > 0 else { return "" }
        let done = LocalLLMAssets.formatBytes(downloadedBytes)
        if expectedBytes > 0 {
            return "\(done) / \(LocalLLMAssets.formatBytes(expectedBytes))"
        }
        return done
    }

    var statusMenuTitle: String {
        switch phase {
        case .idle:
            return LocalLLMAssets.isReady ? "文字润色：就绪" : "文字润色：未下载"
        case .downloadingCLI:
            return "文字润色：下载运行时 \(percent(fileProgress))%"
        case .downloadingModel:
            let bytes = byteProgressText
            if bytes.isEmpty {
                return "文字润色：下载中 \(percent(overallProgress))%"
            }
            return "文字润色：\(bytes) (\(percent(overallProgress))%)"
        case .ready:
            return "文字润色：就绪"
        case .failed(let message):
            return "文字润色：失败 — \(message.prefix(40))"
        }
    }

    var statusToolTipSuffix: String? {
        switch phase {
        case .downloadingCLI, .downloadingModel:
            let bytes = byteProgressText
            if bytes.isEmpty {
                return "文字润色模型下载中 \(percent(overallProgress))%"
            }
            return "文字润色模型下载中 \(bytes)"
        case .failed(let message):
            return "文字润色模型下载失败：\(message)"
        case .ready:
            return "文字润色就绪"
        case .idle:
            return LocalLLMAssets.isReady ? "文字润色就绪" : nil
        }
    }

    /// Cancel in-flight ensure and start fresh (e.g. after switching mirror).
    func forceRestartDownload() {
        stateLock.lock()
        ensureTask?.cancel()
        activeEnsure?.cancel()
        ensureTask = nil
        activeEnsure = nil
        stateLock.unlock()
        downloader.cancel()
        updateState(phase: .idle, fileProgress: 0, overallProgress: 0, downloadedBytes: 0, expectedBytes: 0)
        prefetchIfNeeded()
    }

    /// Kick off background ensure when user selects local polish.
    func prefetchIfNeeded() {
        stateLock.lock()
        let running = ensureTask != nil
        stateLock.unlock()
        guard !running else { return }
        if LocalLLMAssets.isReady {
            updateState(phase: .ready, fileProgress: 1, overallProgress: 1)
            return
        }
        stateLock.lock()
        ensureTask = Task { [weak self] in
            defer {
                self?.stateLock.lock()
                self?.ensureTask = nil
                self?.stateLock.unlock()
            }
            do {
                try await self?.ensureReady()
            } catch is CancellationError {
                // ignore
            } catch {
                self?.updateState(phase: .failed(error.localizedDescription))
            }
        }
        stateLock.unlock()
    }

    func ensureReady() async throws {
        // Serialize concurrent ensure calls (settings prefetch + dictate path).
        let task: Task<Void, Error>
        stateLock.lock()
        if let activeEnsure {
            task = activeEnsure
            stateLock.unlock()
            try await task.value
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.activeEnsure = nil
                self.stateLock.unlock()
            }
            try await self.ensureReadyUnlocked()
        }
        activeEnsure = task
        stateLock.unlock()
        try await task.value
    }

    private func ensureReadyUnlocked() async throws {
        if LocalLLMAssets.isReady {
            updateState(phase: .ready, fileProgress: 1, overallProgress: 1)
            return
        }

        try LocalLLMAssets.ensureDirectories()

        if !LocalLLMAssets.isCLIPresent {
            updateState(phase: .downloadingCLI, fileProgress: 0, overallProgress: 0)
            try await downloadAndInstallCLI()
            updateState(overallProgress: 0.05)
        }

        if !LocalLLMAssets.isModelPresent {
            updateState(phase: .downloadingModel, fileProgress: 0, overallProgress: max(overallProgress, 0.05))
            try await downloadModel()
        }

        guard LocalLLMAssets.isReady else {
            throw LocalLLMError.notReady
        }
        updateState(phase: .ready, fileProgress: 1, overallProgress: 1)
    }

    struct ReadyPaths {
        let cliURL: URL
        let modelURL: URL
    }

    func readyPaths() throws -> ReadyPaths {
        guard LocalLLMAssets.isReady else { throw LocalLLMError.notReady }
        return ReadyPaths(cliURL: LocalLLMAssets.cliURL, modelURL: LocalLLMAssets.modelURL)
    }

    func process(
        _ input: String,
        tone: String?,
        conservative: Bool,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        try await ensureReady()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalLLMError.emptyInput }

        try await ensureServerRunning()
        return try await chatCompletions(
            system: LLMPolishPrompt.system,
            user: LLMPolishPrompt.user(text: text, tone: tone, conservative: conservative),
            timeoutSeconds: timeoutSeconds
        )
    }

    // MARK: - Download

    private func downloadAndInstallCLI() async throws {
        let zipURL = LocalLLMAssets.rootDirectory.appendingPathComponent("llama-cli.zip")
        try? FileManager.default.removeItem(at: zipURL)

        try await downloader.download(
            from: LocalLLMAssets.cliZipURL,
            to: zipURL,
            expectedBytesHint: 40_000_000
        ) { [weak self] written, expected in
            let exp = max(expected, 1)
            let file = min(1, Double(written) / Double(exp))
            self?.updateState(
                fileProgress: file,
                overallProgress: file * 0.05,
                downloadedBytes: written,
                expectedBytes: exp
            )
        }

        // Extract into a temp dir, then copy build/bin/* into binDirectory.
        let extractDir = LocalLLMAssets.rootDirectory.appendingPathComponent("cli-extract", isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        _ = try await runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-o", zipURL.path, "-d", extractDir.path]
        )

        let binSource = extractDir.appendingPathComponent("build/bin", isDirectory: true)
        guard FileManager.default.fileExists(atPath: binSource.path) else {
            throw LocalLLMError.installFailed("llama.cpp zip 缺少 build/bin")
        }

        // Replace bin directory contents.
        try? FileManager.default.removeItem(at: LocalLLMAssets.binDirectory)
        try FileManager.default.createDirectory(at: LocalLLMAssets.binDirectory, withIntermediateDirectories: true)

        let contents = try FileManager.default.contentsOfDirectory(atPath: binSource.path)
        for name in contents {
            let src = binSource.appendingPathComponent(name)
            let dst = LocalLLMAssets.binDirectory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: src, to: dst)
        }

        try clearQuarantine(at: LocalLLMAssets.binDirectory)
        try makeExecutable(at: LocalLLMAssets.cliURL)
        if FileManager.default.fileExists(atPath: LocalLLMAssets.serverURL.path) {
            try makeExecutable(at: LocalLLMAssets.serverURL)
        }

        try? FileManager.default.removeItem(at: zipURL)
        try? FileManager.default.removeItem(at: extractDir)

        guard LocalLLMAssets.isServerPresent else {
            throw LocalLLMError.installFailed("llama-server 安装失败")
        }
    }

    private func downloadModel() async throws {
        let partial = LocalLLMAssets.modelURL.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: LocalLLMAssets.modelURL)

        var lastError: Error?
        for (index, remote) in LocalLLMAssets.modelDownloadURLs.enumerated() {
            let label = remote.host ?? "mirror-\(index)"
            NSLog("LocalLLM: downloading model from %@", remote.absoluteString)
            updateState(
                phase: .downloadingModel,
                fileProgress: 0,
                overallProgress: 0.05,
                downloadedBytes: 0,
                expectedBytes: LocalLLMAssets.modelExpectedBytes,
                downloadSourceLabel: label
            )
            do {
                try await downloader.download(
                    from: remote,
                    to: partial,
                    expectedBytesHint: LocalLLMAssets.modelExpectedBytes
                ) { [weak self] written, expected in
                    let exp = expected > 0 ? expected : LocalLLMAssets.modelExpectedBytes
                    let file = exp > 0 ? min(1, Double(written) / Double(exp)) : 0
                    self?.updateState(
                        fileProgress: file,
                        overallProgress: 0.05 + file * 0.95,
                        downloadedBytes: written,
                        expectedBytes: exp
                    )
                }
                lastError = nil
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                NSLog("LocalLLM: model source failed (%@): %@", label, error.localizedDescription)
                try? FileManager.default.removeItem(at: partial)
            }
        }
        if let lastError {
            throw lastError
        }

        try FileManager.default.moveItem(at: partial, to: LocalLLMAssets.modelURL)
        guard LocalLLMAssets.isModelPresent else {
            throw LocalLLMError.installFailed("模型文件不完整")
        }
    }

    // MARK: - Inference (llama-server OpenAI-compatible API)

    private func ensureServerRunning() async throws {
        if await isServerHealthy() { return }

        serverLock.lock()
        if serverProcess?.isRunning != true {
            stopServerLocked()
            do {
                guard LocalLLMAssets.isServerPresent else {
                    serverLock.unlock()
                    throw LocalLLMError.installFailed("缺少 llama-server")
                }
                let process = Process()
                process.executableURL = LocalLLMAssets.serverURL
                process.arguments = [
                    "-m", LocalLLMAssets.modelURL.path,
                    "--host", "127.0.0.1",
                    "--port", "\(LocalLLMAssets.serverPort)",
                    "-ngl", "99",
                    "-c", "2048",
                    "--log-disable",
                ]
                process.currentDirectoryURL = LocalLLMAssets.binDirectory
                var env = ProcessInfo.processInfo.environment
                env["DYLD_LIBRARY_PATH"] = LocalLLMAssets.binDirectory.path
                process.environment = env
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                serverProcess = process
                NSLog("LocalLLM: started llama-server pid=%d port=%d", process.processIdentifier, LocalLLMAssets.serverPort)
            } catch {
                serverLock.unlock()
                throw error
            }
        }
        serverLock.unlock()

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if await isServerHealthy() { return }
            serverLock.lock()
            let dead = serverProcess?.isRunning != true
            serverLock.unlock()
            if dead {
                throw LocalLLMError.cliFailed("llama-server 已退出")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw LocalLLMError.timeout
    }

    private func stopServerLocked() {
        if let serverProcess, serverProcess.isRunning {
            serverProcess.terminate()
            serverProcess.waitUntilExit()
        }
        serverProcess = nil
    }

    private func isServerHealthy() async -> Bool {
        var request = URLRequest(url: LocalLLMAssets.serverBaseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 500) < 400
        } catch {
            return false
        }
    }

    private func chatCompletions(
        system: String,
        user: String,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        let url = LocalLLMAssets.serverBaseURL.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(5, timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": LocalLLMAssets.modelFileName,
            "temperature": 0.2,
            "max_tokens": 256,
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
            throw LocalLLMError.cliFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw LocalLLMError.cliFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(bodyText.prefix(200))")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw LocalLLMError.emptyOutput
        }
        let out = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { throw LocalLLMError.emptyOutput }
        // Reject obvious CLI banner leakage if any proxy misroutes.
        if out.contains("Loading model") || out.contains("available commands") {
            throw LocalLLMError.cliFailed("本地模型输出异常，已丢弃")
        }
        return out
    }

    // MARK: - Helpers

    private func updateState(
        phase: Phase? = nil,
        fileProgress: Double? = nil,
        overallProgress: Double? = nil,
        downloadedBytes: Int64? = nil,
        expectedBytes: Int64? = nil,
        downloadSourceLabel: String? = nil
    ) {
        let apply = { [weak self] in
            guard let self else { return }
            if let phase { self.phase = phase }
            if let fileProgress { self.fileProgress = fileProgress }
            if let overallProgress { self.overallProgress = overallProgress }
            if let downloadedBytes { self.downloadedBytes = downloadedBytes }
            if let expectedBytes { self.expectedBytes = expectedBytes }
            if let downloadSourceLabel { self.downloadSourceLabel = downloadSourceLabel }
            NotificationCenter.default.post(name: .localLLMStatusChanged, object: nil)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func percent(_ value: Double) -> Int {
        Int((value * 100).rounded(.down).clamped(to: 0...100))
    }

    private func clearQuarantine(at directory: URL) throws {
        _ = try? runProcessSync(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-cr", directory.path]
        )
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeoutSeconds: TimeInterval = 120
    ) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let out = try self.runProcessSync(
                        executable: executable,
                        arguments: arguments,
                        workingDirectory: workingDirectory,
                        timeoutSeconds: timeoutSeconds
                    )
                    cont.resume(returning: out)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private func runProcessSync(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeoutSeconds: TimeInterval = 120
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        // Prefer bundled dylibs next to llama-cli.
        var env = ProcessInfo.processInfo.environment
        if let workingDirectory {
            let bin = workingDirectory.path
            if let existing = env["DYLD_LIBRARY_PATH"], !existing.isEmpty {
                env["DYLD_LIBRARY_PATH"] = bin + ":" + existing
            } else {
                env["DYLD_LIBRARY_PATH"] = bin
            }
        }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw LocalLLMError.timeout
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let combined = (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalLLMError.cliFailed(combined.isEmpty ? "exit \(process.terminationStatus)" : String(combined.prefix(400)))
        }
        return out.isEmpty ? err : out
    }
}

enum LocalLLMError: LocalizedError {
    case notReady
    case emptyInput
    case emptyOutput
    case timeout
    case installFailed(String)
    case cliFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady: return "本地模型尚未就绪"
        case .emptyInput: return "输入为空"
        case .emptyOutput: return "本地模型输出为空"
        case .timeout: return "本地润色超时"
        case .installFailed(let message): return "本地模型安装失败：\(message)"
        case .cliFailed(let message): return "llama-cli 失败：\(message)"
        case .downloadFailed(let message): return "下载失败：\(message)"
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - FileDownloader

final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private var progressHandler: ((Int64, Int64) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destinationURL: URL?
    private var expectedBytesHint: Int64 = 0
    private var session: URLSession!
    private var currentTask: URLSessionDownloadTask?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 2
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        if let continuation {
            continuation.resume(throwing: CancellationError())
            self.continuation = nil
        }
    }

    func download(
        from remote: URL,
        to local: URL,
        expectedBytesHint: Int64 = 0,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws {
        _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            self.continuation = cont
            self.destinationURL = local
            self.expectedBytesHint = expectedBytesHint
            self.progressHandler = progress
            var request = URLRequest(url: remote)
            request.setValue("open-dictate", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 60
            let task = session.downloadTask(with: request)
            self.currentTask = task
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytesHint
        progressHandler?(totalBytesWritten, expected)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destinationURL else {
            continuation?.resume(throwing: LocalLLMError.downloadFailed("内部错误：无目标路径"))
            continuation = nil
            currentTask = nil
            return
        }
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw LocalLLMError.downloadFailed("HTTP \(http.statusCode)")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            // Reject tiny HTML/error bodies pretending to be the model.
            if size < 1_000_000, expectedBytesHint > 100_000_000 {
                throw LocalLLMError.downloadFailed("下载内容过小（\(size) bytes），可能不是模型文件")
            }
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)
            progressHandler?(size, max(expectedBytesHint, size))
            continuation?.resume(returning: destinationURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        currentTask = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(throwing: LocalLLMError.downloadFailed(error.localizedDescription))
        }
        continuation = nil
        currentTask = nil
    }
}
