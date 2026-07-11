import AppKit
import AVFoundation
import ApplicationServices

enum Permissions {
    static func requestOnLaunch() {
        requestMicrophone()
        requestAccessibility()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            showAlertIfNeeded()
        }
    }

    static var executablePath: String {
        Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments[0]
    }

    /// Path shown in Accessibility instructions (.app when bundled).
    static var accessibilityTargetPath: String {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.path
        }
        return executablePath
    }

    static var isMicrophoneGranted: Bool {
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func requestMicrophone() {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined:
                AVAudioApplication.requestRecordPermission { granted in
                    NSLog("Microphone permission: \(granted)")
                }
            default:
                break
            }
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                NSLog("Microphone permission: \(granted)")
            }
        default:
            break
        }
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openMicrophoneSettings() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func showAlertIfNeeded() {
        guard !isMicrophoneGranted || !isAccessibilityGranted else { return }

        let alert = NSAlert()
        alert.messageText = "OpenDictate 需要系统授权"
        alert.alertStyle = .informational

        var lines: [String] = []
        if !isMicrophoneGranted {
            lines.append("• 麦克风：用于录音与语音识别")
        }
        if !isAccessibilityGranted {
            lines.append("• 辅助功能：用于全局热键与文本上屏")
            lines.append("  请在列表中添加：")
            lines.append("  \(accessibilityTargetPath)")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if !isAccessibilityGranted {
            openAccessibilitySettings()
        } else if !isMicrophoneGranted {
            openMicrophoneSettings()
        }
    }

    private static func openSystemSettings(path: String) {
        guard let url = URL(string: path) else { return }
        NSWorkspace.shared.open(url)
    }
}
