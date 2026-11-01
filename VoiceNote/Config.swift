import Foundation
import Security

enum ASREngine: String, CaseIterable, Identifiable {
    case apple, aliyun
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple: return "苹果本机（免费）"
        case .aliyun: return "阿里云百炼（约0.12元/小时）"
        }
    }
    var shortLabel: String {
        switch self {
        case .apple: return "苹果本机"
        case .aliyun: return "阿里云"
        }
    }
}

enum LLMProvider: String, CaseIterable, Identifiable {
    case zhipu, deepseek, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .zhipu: return "智谱 GLM"
        case .deepseek: return "DeepSeek"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }
    var defaultBaseURL: String {
        switch self {
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .deepseek: return "https://api.deepseek.com"
        case .custom: return ""
        }
    }
    var defaultModel: String {
        switch self {
        case .zhipu: return "glm-5.3-flash"
        case .deepseek: return "deepseek-v4-flash"
        case .custom: return ""
        }
    }
    var keyName: KeyName {
        switch self {
        case .zhipu: return .zhipu
        case .deepseek: return .deepseek
        case .custom: return .custom
        }
    }
}

enum SettingsKey {
    static let asrEngine = "asrEngine"
    static let appleLocale = "appleLocale"
    static let autoTranscribe = "autoTranscribe"
    static let autoOrganize = "autoOrganize"
    static let aliyunBaseURL = "aliyunBaseURL"
    static let aliyunModel = "aliyunModel"
    static let aliyunLanguage = "aliyunLanguage"
    static let llmProvider = "llmProvider"
    static func llmModel(_ p: LLMProvider) -> String { "llmModel.\(p.rawValue)" }
    static func llmBaseURL(_ p: LLMProvider) -> String { "llmBaseURL.\(p.rawValue)" }
}

enum AppConfig {
    static let defaultAliyunBaseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    static let defaultAliyunModel = "qwen3-asr-flash"

    static func registerDefaults() {
        var d: [String: Any] = [
            SettingsKey.asrEngine: ASREngine.apple.rawValue,
            SettingsKey.appleLocale: "zh-CN",
            SettingsKey.autoTranscribe: true,
            SettingsKey.autoOrganize: true,
            SettingsKey.aliyunBaseURL: defaultAliyunBaseURL,
            SettingsKey.aliyunModel: defaultAliyunModel,
            SettingsKey.aliyunLanguage: "auto",
            SettingsKey.llmProvider: LLMProvider.zhipu.rawValue,
        ]
        for p in LLMProvider.allCases {
            d[SettingsKey.llmModel(p)] = p.defaultModel
            d[SettingsKey.llmBaseURL(p)] = p.defaultBaseURL
        }
        UserDefaults.standard.register(defaults: d)
    }

    private static var ud: UserDefaults { .standard }

    static var asrEngine: ASREngine {
        ASREngine(rawValue: ud.string(forKey: SettingsKey.asrEngine) ?? "") ?? .apple
    }
    static var appleLocale: String { ud.string(forKey: SettingsKey.appleLocale) ?? "zh-CN" }
    static var autoTranscribe: Bool { ud.bool(forKey: SettingsKey.autoTranscribe) }
    static var autoOrganize: Bool { ud.bool(forKey: SettingsKey.autoOrganize) }
    static var aliyunBaseURL: String { nonEmpty(ud.string(forKey: SettingsKey.aliyunBaseURL), defaultAliyunBaseURL) }
    static var aliyunModel: String { nonEmpty(ud.string(forKey: SettingsKey.aliyunModel), defaultAliyunModel) }
    static var aliyunLanguage: String { ud.string(forKey: SettingsKey.aliyunLanguage) ?? "auto" }
    static var llmProvider: LLMProvider {
        LLMProvider(rawValue: ud.string(forKey: SettingsKey.llmProvider) ?? "") ?? .zhipu
    }
    static func llmModel(_ p: LLMProvider) -> String {
        nonEmpty(ud.string(forKey: SettingsKey.llmModel(p)), p.defaultModel)
    }
    static func llmBaseURL(_ p: LLMProvider) -> String {
        nonEmpty(ud.string(forKey: SettingsKey.llmBaseURL(p)), p.defaultBaseURL)
    }

    private static func nonEmpty(_ s: String?, _ fallback: String) -> String {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }
}

enum KeyName: String {
    case aliyun, zhipu, deepseek, custom
}

enum Keychain {
    private static func baseQuery(_ key: KeyName) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VoiceNote",
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    static func set(_ value: String, for key: KeyName) {
        let q = baseQuery(key)
        SecItemDelete(q as CFDictionary)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: KeyName) -> String? {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }
}
