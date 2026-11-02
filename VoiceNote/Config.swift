import Foundation
import Security

enum ASREngine: String, CaseIterable, Identifiable {
    case apple, siliconflow, aliyun
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple: return "苹果本机（免费）"
        case .siliconflow: return "硅基流动 SenseVoice（免费）"
        case .aliyun: return "阿里云百炼（约0.12元/小时）"
        }
    }
    var shortLabel: String {
        switch self {
        case .apple: return "苹果本机"
        case .siliconflow: return "SenseVoice"
        case .aliyun: return "阿里云"
        }
    }
    var title: String {
        switch self {
        case .apple: return "苹果自带转写"
        case .siliconflow: return "硅基流动"
        case .aliyun: return "阿里云百炼"
        }
    }
    var modelLabel: String {
        switch self {
        case .apple: return "系统语音识别，在手机上完成"
        case .siliconflow: return AppConfig.siliconModel
        case .aliyun: return AppConfig.aliyunModel
        }
    }
    var price: String {
        switch self {
        case .apple: return "免费 · 不用网络也能转"
        case .siliconflow: return "免费 · 云端 · 能听懂粤语"
        case .aliyun: return "约 0.12 元/小时 · 粤普混说最准"
        }
    }
    var tag: String {
        switch self {
        case .apple: return "免费"
        case .siliconflow: return "免费"
        case .aliyun: return "推荐"
        }
    }
    var keyName: KeyName? {
        switch self {
        case .apple: return nil
        case .siliconflow: return .siliconflow
        case .aliyun: return .aliyun
        }
    }
    var keyURL: String {
        switch self {
        case .apple: return ""
        case .siliconflow: return "https://cloud.siliconflow.cn/account/ak"
        case .aliyun: return "https://bailian.console.aliyun.com/?tab=model#/api-key"
        }
    }
}

enum LLMProvider: String, CaseIterable, Identifiable {
    case deepseek, zhipu, qwen, doubao, kimi, minimax, siliconflow, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .zhipu: return "智谱 GLM"
        case .qwen: return "通义千问"
        case .doubao: return "豆包"
        case .kimi: return "Kimi"
        case .minimax: return "MiniMax"
        case .siliconflow: return "硅基流动"
        case .custom: return "自定义"
        }
    }

    var company: String {
        switch self {
        case .deepseek: return "深度求索 · 便宜，中文总结强"
        case .zhipu: return "智谱 AI · Flash 系列免费"
        case .qwen: return "阿里云百炼 · 和阿里云转写共用 Key"
        case .doubao: return "字节火山方舟"
        case .kimi: return "月之暗面 · 长文本"
        case .minimax: return "稀宇科技"
        case .siliconflow: return "很多开源模型，部分免费"
        case .custom: return "任何 OpenAI 兼容接口"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .minimax: return "https://api.minimaxi.com/v1"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .custom: return ""
        }
    }

    /// 常用模型（可以在设置里从服务商拉取最新列表，或手动填）
    var suggestedModels: [String] {
        switch self {
        case .deepseek: return ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .zhipu: return ["glm-5.3-flash", "glm-5.3-flashx", "glm-5.3"]
        case .qwen: return ["qwen-flash", "qwen-plus", "qwen3-max"]
        case .doubao: return ["doubao-seed-2.0-mini", "doubao-seed-2.0-pro"]
        case .kimi: return ["kimi-k2.6", "kimi-k3"]
        case .minimax: return ["MiniMax-M3"]
        case .siliconflow: return ["deepseek-ai/DeepSeek-V4-Flash", "Qwen/Qwen3-32B"]
        case .custom: return []
        }
    }

    var defaultModel: String { suggestedModels.first ?? "" }

    var keyURL: String {
        switch self {
        case .deepseek: return "https://platform.deepseek.com/api_keys"
        case .zhipu: return "https://open.bigmodel.cn/usercenter/apikeys"
        case .qwen: return "https://bailian.console.aliyun.com/?tab=model#/api-key"
        case .doubao: return "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey"
        case .kimi: return "https://platform.moonshot.cn/console/api-keys"
        case .minimax: return "https://platform.minimaxi.com/user-center/basic-information/interface-key"
        case .siliconflow: return "https://cloud.siliconflow.cn/account/ak"
        case .custom: return ""
        }
    }

    var keyName: KeyName {
        switch self {
        case .deepseek: return .deepseek
        case .zhipu: return .zhipu
        case .qwen: return .aliyun
        case .doubao: return .doubao
        case .kimi: return .kimi
        case .minimax: return .minimax
        case .siliconflow: return .siliconflow
        case .custom: return .custom
        }
    }
}

/// 「服务商 + 模型名」，存成 "provider|model"
struct ModelRef: Hashable, Identifiable {
    let provider: LLMProvider
    let model: String
    var id: String { storage }
    var storage: String { "\(provider.rawValue)|\(model)" }
    var label: String { "\(provider.label) · \(model)" }

    init(_ provider: LLMProvider, _ model: String) {
        self.provider = provider
        self.model = model
    }

    init?(storage: String) {
        let parts = storage.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let p = LLMProvider(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        provider = p
        model = parts[1]
    }
}

enum OrganizeStyle: String, CaseIterable, Identifiable {
    case general, meeting, conversation, lecture
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "通用整理"
        case .meeting: return "会议纪要"
        case .conversation: return "谈话/通话"
        case .lecture: return "课堂/讲座"
        }
    }
    var icon: String {
        switch self {
        case .general: return "sparkles"
        case .meeting: return "person.3"
        case .conversation: return "bubble.left.and.bubble.right"
        case .lecture: return "graduationcap"
        }
    }
}

enum SettingsKey {
    static let organizeStyle = "organizeStyle"
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
    static func fetchedModels(_ p: LLMProvider) -> String { "fetchedModels.\(p.rawValue)" }
    static func styleModel(_ s: OrganizeStyle) -> String { "styleModel.\(s.rawValue)" }
    static let siliconModel = "siliconASRModel"
    static let siliconLanguage = "siliconLanguage"
}

enum AppConfig {
    static let defaultAliyunBaseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    static let defaultAliyunModel = "qwen3-asr-flash"
    static let defaultSiliconModel = "FunAudioLLM/SenseVoiceSmall"

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
            SettingsKey.siliconModel: defaultSiliconModel,
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
    static var organizeStyle: OrganizeStyle {
        OrganizeStyle(rawValue: ud.string(forKey: SettingsKey.organizeStyle) ?? "") ?? .general
    }
    static var llmProvider: LLMProvider {
        LLMProvider(rawValue: ud.string(forKey: SettingsKey.llmProvider) ?? "") ?? .zhipu
    }
    static func llmModel(_ p: LLMProvider) -> String {
        nonEmpty(ud.string(forKey: SettingsKey.llmModel(p)), p.defaultModel)
    }
    static func llmBaseURL(_ p: LLMProvider) -> String {
        nonEmpty(ud.string(forKey: SettingsKey.llmBaseURL(p)), p.defaultBaseURL)
    }

    static var siliconModel: String { nonEmpty(ud.string(forKey: SettingsKey.siliconModel), defaultSiliconModel) }

    static func hasKey(_ p: LLMProvider) -> Bool { Keychain.get(p.keyName) != nil }

    /// 默认整理模型
    static var defaultModelRef: ModelRef { ModelRef(llmProvider, llmModel(llmProvider)) }

    /// 某种整理方式要用的模型：单独指定了就用指定的，否则用默认
    static func modelFor(_ style: OrganizeStyle) -> ModelRef {
        if let s = ud.string(forKey: SettingsKey.styleModel(style)), let r = ModelRef(storage: s) { return r }
        return defaultModelRef
    }

    /// 某个服务商可选的模型：常用 + 拉取到的 + 当前在用的
    static func models(for p: LLMProvider) -> [String] {
        var list = p.suggestedModels
        for m in (ud.stringArray(forKey: SettingsKey.fetchedModels(p)) ?? []) + [llmModel(p)]
            where !m.isEmpty && !list.contains(m) {
            list.append(m)
        }
        return list
    }

    /// 已经填了密钥、能用来整理的模型（给详情页菜单用）
    static var quickModels: [ModelRef] {
        var out: [ModelRef] = [defaultModelRef]
        for st in OrganizeStyle.allCases {
            let r = modelFor(st)
            if !out.contains(r) { out.append(r) }
        }
        for p in LLMProvider.allCases where p != .custom && hasKey(p) {
            for m in p.suggestedModels {
                let r = ModelRef(p, m)
                if !out.contains(r) { out.append(r) }
            }
        }
        return out.filter { hasKey($0.provider) || $0.provider == .custom }
    }

    private static func nonEmpty(_ s: String?, _ fallback: String) -> String {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }
}

enum KeyName: String {
    case aliyun, zhipu, deepseek, custom, doubao, kimi, minimax, siliconflow
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
