import Foundation

/// Preset tones stored in `app_profiles.tone` (also used later as LLM style hints).
enum AppTonePreset: String, CaseIterable, Identifiable {
    case casual
    case neutral
    case formal
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .casual: return "口语"
        case .neutral: return "中性"
        case .formal: return "正式"
        case .custom: return "自定义"
        }
    }

    /// Default prompt-oriented tone text for non-custom presets.
    var defaultToneText: String {
        switch self {
        case .casual: return "简洁口语，适合即时通讯"
        case .neutral: return "中性书面，清晰自然"
        case .formal: return "正式商务中文，礼貌完整"
        case .custom: return ""
        }
    }

    static func resolve(fromToneText text: String) -> AppTonePreset {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for preset in [AppTonePreset.casual, .neutral, .formal] where preset.defaultToneText == trimmed {
            return preset
        }
        if trimmed.isEmpty { return .neutral }
        return .custom
    }
}

/// Format flags stored in `app_profiles.settings_json`.
struct AppProfileFormatSettings: Codable, Equatable {
    var displayName: String = ""
    /// Chat-style: drop a lone trailing full stop.
    var stripTrailingPeriod: Bool = false
    /// Dev tools: keep fillers / skip aggressive rule cleanup.
    var skipFillerRemoval: Bool = false

    static let empty = AppProfileFormatSettings()
}

struct AppProfile: Identifiable, Equatable {
    var id: String { appId }
    let appId: String
    var tone: String
    var format: AppProfileFormatSettings
    let updatedAtMillis: Int64

    var tonePreset: AppTonePreset { AppTonePreset.resolve(fromToneText: tone) }

    var resolvedDisplayName: String {
        let name = format.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? appId : name
    }
}
