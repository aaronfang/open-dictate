import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("whisperBinary") var whisperBinary: String = "whisper-cli"
    @AppStorage("whisperModelPath") var whisperModelPath: String = "models/ggml-base.en.bin"
    @AppStorage("storePath") var storePath: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("OpenDictate", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("open_dictate.sqlite3").path
    }()
}

