import AppKit
import AVFoundation
import SwiftUI

@main
struct OpenDictateMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let status = StatusController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.start()
    }
}

struct SettingsView: View {
    @StateObject private var settings = AppSettings()

    var body: some View {
        Form {
            Section("热键") {
                LabeledContent("默认热键") {
                    Text("右 Option（按住说话）")
                }
                Text("提示：全局热键与文本注入需要在“隐私与安全性 → 辅助功能(Accessibility)”中授权本 App。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("本地识别（whisper.cpp）") {
                TextField("whisper.cpp 可执行文件（例如 whisper-cli）", text: $settings.whisperBinary)
                TextField("模型路径（ggml *.bin）", text: $settings.whisperModelPath)
            }

            Section("数据存储") {
                TextField("SQLite 存储路径", text: $settings.storePath)
                Text("默认仅本地存储词典与画像，不做任何遥测。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("词典（MVP）") {
                Text("词典管理 UI 将在下一步接入 Rust Core Store 后完善。当前可通过 SQLite 表 `dictionary` 手动插入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

final class StatusController {
    private var item: NSStatusItem?
    private let hotkey = HotkeyMonitor(hotkey: .init(keyCode: 61, flags: [.maskAlternate]))
    private let recorder = AudioRecorder()
    private let hud = HudWindow()
    private let injector = TextInjector()

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "OpenDictate"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        self.item = item

        hotkey.onHotkeyDown = { [weak self] in
            guard let self else { return }
            do {
                _ = try self.recorder.startRecording()
                self.hud.show(text: "正在录音…")
            } catch {
                self.hud.show(text: "录音启动失败")
                NSLog("startRecording error: \(error)")
            }
        }
        hotkey.onHotkeyUp = { [weak self] in
            guard let self else { return }
            self.recorder.stopRecording()
            self.hud.hide()
            self.injector.insert(text: "（MVP）已完成一次录音。下一步接入本地识别并上屏。")
        }

        hotkey.start()
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        hotkey.stop()
        NSApp.terminate(nil)
    }
}
