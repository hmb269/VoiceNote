import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var showDone = true
    @AppStorage("appearance") private var appearance = 1

    @AppStorage(SettingsKey.asrEngine) private var engine = ASREngine.apple.rawValue
    @AppStorage(SettingsKey.appleLocale) private var appleLocale = "zh-CN"
    @AppStorage(SettingsKey.autoTranscribe) private var autoTranscribe = true
    @AppStorage(SettingsKey.autoOrganize) private var autoOrganize = true
    @AppStorage(SettingsKey.aliyunModel) private var aliyunModel = AppConfig.defaultAliyunModel
    @AppStorage(SettingsKey.aliyunBaseURL) private var aliyunBaseURL = AppConfig.defaultAliyunBaseURL
    @AppStorage(SettingsKey.aliyunLanguage) private var aliyunLanguage = "auto"
    @AppStorage(SettingsKey.llmProvider) private var providerRaw = LLMProvider.zhipu.rawValue

    @State private var aliyunKey = ""
    @State private var llmKey = ""
    @State private var llmModel = ""
    @State private var llmBaseURL = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var loaded = false

    private var provider: LLMProvider { LLMProvider(rawValue: providerRaw) ?? .zhipu }

    private let appleLocales: [(String, String)] = [
        ("zh-CN", "普通话"),
        ("yue-CN", "粤语"),
        ("zh-HK", "粤语（香港）"),
        ("en-US", "英语"),
    ]

    private let aliyunLanguages: [(String, String)] = [
        ("auto", "自动识别（混说推荐）"),
        ("zh", "普通话"),
        ("yue", "粤语"),
        ("en", "英语"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("默认转写方式", selection: $engine) {
                        ForEach(ASREngine.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle("录完自动转写", isOn: $autoTranscribe)
                    Toggle("转写后自动 AI 整理", isOn: $autoOrganize)
                } header: {
                    Text("转写")
                } footer: {
                    Text("苹果本机免费，普通话效果好；夹杂白话、方言多的录音用阿里云更准。详情页里每条录音都能单独选。")
                }

                Section {
                    Picker("识别语言", selection: $appleLocale) {
                        ForEach(appleLocales, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } header: {
                    Text("苹果本机转写")
                } footer: {
                    Text("第一次用可能会用到网络下载识别模型。如果转写一直失败，去 设置 → 通用 → 键盘 打开「启用听写」。")
                }

                Section {
                    SecureField("API Key（sk-开头）", text: $aliyunKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: aliyunKey) { _, v in if loaded { Keychain.set(v, for: .aliyun) } }
                    Picker("识别语言", selection: $aliyunLanguage) {
                        ForEach(aliyunLanguages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    LabeledContent("模型") {
                        TextField("qwen3-asr-flash", text: $aliyunModel)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField("接口地址", text: $aliyunBaseURL)
                        .font(.footnote)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("阿里云百炼转写")
                } footer: {
                    Text("在 bailian.console.aliyun.com 开通并创建 API Key。按音频时长计费，约 0.12 元/小时。")
                }

                Section {
                    Picker("服务商", selection: $providerRaw) {
                        ForEach(LLMProvider.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    SecureField("API Key", text: $llmKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: llmKey) { _, v in if loaded { Keychain.set(v, for: provider.keyName) } }
                    LabeledContent("模型") {
                        TextField(provider.defaultModel.isEmpty ? "模型名" : provider.defaultModel, text: $llmModel)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: llmModel) { _, v in
                                if loaded { UserDefaults.standard.set(v, forKey: SettingsKey.llmModel(provider)) }
                            }
                    }
                    TextField("接口地址", text: $llmBaseURL)
                        .font(.footnote)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onChange(of: llmBaseURL) { _, v in
                            if loaded { UserDefaults.standard.set(v, forKey: SettingsKey.llmBaseURL(provider)) }
                        }
                    Button {
                        runTest()
                    } label: {
                        HStack {
                            Text("测试连接")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing || llmKey.isEmpty)
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("AI 整理")
                } footer: {
                    Text("智谱在 open.bigmodel.cn → API Keys 创建，glm-5.3-flash 用新用户送的资源包；DeepSeek 在 platform.deepseek.com 创建。")
                }

                Section("外观") {
                    Picker("主题", selection: $appearance) {
                        Text("深色").tag(1)
                        Text("浅色").tag(2)
                        Text("跟随系统").tag(0)
                    }
                    .pickerStyle(.segmented)
                }

                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    Text("API Key 只存在这台手机的钥匙串里，请求直接从手机发到你填的地址。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .keyboardDoneBar()
            .submitLabel(.done)
            .onSubmit { hideKeyboard() }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .onAppear(perform: loadAll)
            .onChange(of: providerRaw) { _, _ in loadProvider() }
        }
    }

    private func loadAll() {
        loaded = false
        aliyunKey = Keychain.get(.aliyun) ?? ""
        loadProvider()
    }

    private func loadProvider() {
        loaded = false
        llmKey = Keychain.get(provider.keyName) ?? ""
        llmModel = AppConfig.llmModel(provider)
        llmBaseURL = AppConfig.llmBaseURL(provider)
        testResult = nil
        DispatchQueue.main.async { loaded = true }
    }

    private func runTest() {
        testing = true
        testResult = nil
        let p = provider
        let key = llmKey
        let base = llmBaseURL.isEmpty ? p.defaultBaseURL : llmBaseURL
        let model = llmModel.isEmpty ? p.defaultModel : llmModel
        Task {
            do {
                let r = try await Organizer.test(provider: p, apiKey: key, baseURL: base, model: model)
                testResult = "✅ \(r.prefix(50))"
            } catch {
                testResult = "❌ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
