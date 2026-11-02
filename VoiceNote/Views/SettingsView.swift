import SwiftUI

// MARK: - 设置首页

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var showDone = true
    @AppStorage("appearance") private var appearance = 1
    @AppStorage(SettingsKey.asrEngine) private var engineRaw = ASREngine.apple.rawValue
    @AppStorage(SettingsKey.autoTranscribe) private var autoTranscribe = true
    @AppStorage(SettingsKey.autoOrganize) private var autoOrganize = true
    @AppStorage(SettingsKey.organizeStyle) private var styleRaw = OrganizeStyle.general.rawValue
    @State private var refresh = 0

    private var engine: ASREngine { ASREngine(rawValue: engineRaw) ?? .apple }
    private var keyCount: Int { LLMProvider.allCases.filter { AppConfig.hasKey($0) }.count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ASRSettingsView()
                    } label: {
                        SettingRow(icon: "waveform", tint: .orange, title: "语音转文字", value: engine.shortLabel)
                    }
                    Toggle(isOn: $autoTranscribe) {
                        SettingRow(icon: "bolt.fill", tint: .yellow, title: "录完自动转写")
                    }
                } header: {
                    Text("转写")
                }

                Section {
                    NavigationLink {
                        ProvidersView()
                    } label: {
                        SettingRow(icon: "key.fill", tint: .blue, title: "服务商与密钥",
                                   value: keyCount == 0 ? "还没填" : "已填 \(keyCount) 家")
                    }
                    NavigationLink {
                        ModelPickerView(title: "默认模型", selection: Binding(
                            get: { AppConfig.defaultModelRef.storage },
                            set: { v in
                                if let r = ModelRef(storage: v) {
                                    UserDefaults.standard.set(r.provider.rawValue, forKey: SettingsKey.llmProvider)
                                    UserDefaults.standard.set(r.model, forKey: SettingsKey.llmModel(r.provider))
                                    refresh += 1
                                }
                            }
                        ), allowFollowDefault: false)
                    } label: {
                        SettingRow(icon: "cpu", tint: Theme.ai, title: "默认模型", value: AppConfig.defaultModelRef.model)
                    }
                    NavigationLink {
                        StyleModelsView()
                    } label: {
                        SettingRow(icon: "square.stack.3d.up.fill", tint: .teal, title: "按整理方式指定模型",
                                   value: customizedCount == 0 ? "都用默认" : "\(customizedCount) 种单独指定")
                    }
                    Picker(selection: $styleRaw) {
                        ForEach(OrganizeStyle.allCases) { Text($0.label).tag($0.rawValue) }
                    } label: {
                        SettingRow(icon: "doc.text.fill", tint: .pink, title: "默认整理方式")
                    }
                    Toggle(isOn: $autoOrganize) {
                        SettingRow(icon: "sparkles", tint: Theme.ai, title: "转写后自动整理")
                    }
                } header: {
                    Text("AI 整理")
                } footer: {
                    Text("比如会议纪要用 DeepSeek V4 Pro、平时用免费的智谱 Flash，在「按整理方式指定模型」里设置。")
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
                    Text("API Key 只存在这台手机的钥匙串里，请求直接从手机发到各家服务商。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .id(refresh)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .onAppear { refresh += 1 }
        }
    }

    private var customizedCount: Int {
        OrganizeStyle.allCases.filter {
            UserDefaults.standard.string(forKey: SettingsKey.styleModel($0))?.isEmpty == false
        }.count
    }
}

struct SettingRow: View {
    let icon: String
    let tint: Color
    let title: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
            if let value {
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - 服务商图标（自己画的字母徽章，不用官方 logo）

struct ProviderBadge: View {
    let provider: LLMProvider
    var size: CGFloat = 44

    private var glyph: String {
        switch provider {
        case .deepseek: return "DS"
        case .zhipu: return "智"
        case .qwen: return "千"
        case .doubao: return "豆"
        case .kimi: return "K"
        case .minimax: return "MM"
        case .siliconflow: return "硅"
        case .custom: return "⚙︎"
        }
    }

    private var colors: [Color] {
        switch provider {
        case .deepseek: return [Color(red: 0.30, green: 0.42, blue: 0.98), Color(red: 0.18, green: 0.26, blue: 0.78)]
        case .zhipu: return [Color(red: 0.36, green: 0.40, blue: 0.95), Color(red: 0.55, green: 0.30, blue: 0.90)]
        case .qwen: return [Color(red: 0.55, green: 0.38, blue: 0.98), Color(red: 0.38, green: 0.25, blue: 0.85)]
        case .doubao: return [Color(red: 0.20, green: 0.75, blue: 0.70), Color(red: 0.32, green: 0.40, blue: 0.95)]
        case .kimi: return [Color(white: 0.18), Color(white: 0.05)]
        case .minimax: return [Color(red: 0.98, green: 0.36, blue: 0.48), Color(red: 0.90, green: 0.45, blue: 0.20)]
        case .siliconflow: return [Color(red: 0.45, green: 0.30, blue: 0.95), Color(red: 0.20, green: 0.55, blue: 0.95)]
        case .custom: return [Color.gray, Color(white: 0.35)]
        }
    }

    var body: some View {
        Text(glyph)
            .font(.system(size: size * (glyph.count > 1 ? 0.34 : 0.44), weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct KeyStatus: View {
    let ok: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            Text(ok ? "已填密钥" : "没填密钥")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(ok ? Color.green : Color.secondary)
    }
}

// MARK: - 服务商列表

struct ProvidersView: View {
    @State private var tick = 0

    var body: some View {
        List {
            Section {
                ForEach(LLMProvider.allCases.filter { $0 != .custom }) { p in
                    row(p)
                }
            } header: {
                Text("国内大模型")
            }
            Section {
                row(.custom)
            } header: {
                Text("自定义")
            } footer: {
                Text("自己填接口地址，适合中转站或自建服务。密钥存在这台手机的钥匙串里。")
            }
        }
        .id(tick)
        .navigationTitle("服务商与密钥")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tick += 1 }
    }

    private func row(_ p: LLMProvider) -> some View {
        NavigationLink {
            ProviderDetailView(provider: p)
        } label: {
            HStack(spacing: 14) {
                ProviderBadge(provider: p, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(p.label).font(.body.weight(.semibold))
                        if AppConfig.defaultModelRef.provider == p {
                            Text("默认")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.ai)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.ai.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(p.company).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    KeyStatus(ok: AppConfig.hasKey(p))
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - 单个服务商：密钥、去官网、模型

struct ProviderDetailView: View {
    let provider: LLMProvider
    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var baseURL = ""
    @State private var models: [String] = []
    @State private var current = ""
    @State private var newModel = ""
    @State private var loading = false
    @State private var testing = false
    @State private var message: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ProviderBadge(provider: provider, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.label).font(.title3.weight(.bold))
                        Text(provider.company).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                SecureField("粘贴 API Key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: key) { _, v in if loaded { Keychain.set(v, for: provider.keyName) } }
                if !provider.keyURL.isEmpty {
                    Button {
                        if let u = URL(string: provider.keyURL) { openURL(u) }
                    } label: {
                        HStack {
                            Label(key.isEmpty ? "还没有？去官网注册并获取 Key" : "去官网管理 Key", systemImage: "safari")
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption.weight(.bold))
                        }
                    }
                }
            } header: {
                Text("密钥")
            } footer: {
                if !provider.keyURL.isEmpty {
                    Text("打开后登录（没账号会提示注册）→ 新建 API Key → 复制，回来粘贴到上面就行。")
                }
            }

            Section {
                ForEach(models, id: \.self) { m in
                    Button {
                        current = m
                        UserDefaults.standard.set(m, forKey: SettingsKey.llmModel(provider))
                    } label: {
                        HStack {
                            Text(m).foregroundStyle(.primary)
                            Spacer()
                            if m == current {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold)
                            }
                        }
                    }
                }
                HStack {
                    TextField("手动填模型名", text: $newModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("添加") {
                        let m = newModel.trimmingCharacters(in: .whitespaces)
                        guard !m.isEmpty else { return }
                        if !models.contains(m) { models.append(m) }
                        current = m
                        UserDefaults.standard.set(m, forKey: SettingsKey.llmModel(provider))
                        newModel = ""
                        hideKeyboard()
                    }
                    .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button {
                    fetchModels()
                } label: {
                    HStack {
                        Label("从服务商拉取最新模型列表", systemImage: "arrow.clockwise")
                        if loading { Spacer(); ProgressView() }
                    }
                }
                .disabled(key.isEmpty || loading)
            } header: {
                Text("模型")
            } footer: {
                Text("打勾的是这家服务商默认用的模型。模型名以官网为准，列表里没有的可以拉取或手动填。")
            }

            Section {
                Button {
                    UserDefaults.standard.set(provider.rawValue, forKey: SettingsKey.llmProvider)
                    UserDefaults.standard.set(current, forKey: SettingsKey.llmModel(provider))
                    message = "✅ 已设为默认整理模型：\(current)"
                } label: {
                    Label("设为默认整理模型", systemImage: "star")
                }
                .disabled(current.isEmpty || key.isEmpty)
                Button {
                    runTest()
                } label: {
                    HStack {
                        Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(key.isEmpty || current.isEmpty || testing)
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                TextField("接口地址", text: $baseURL)
                    .font(.footnote)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: baseURL) { _, v in
                        if loaded { UserDefaults.standard.set(v, forKey: SettingsKey.llmBaseURL(provider)) }
                    }
            } header: {
                Text("接口地址")
            } footer: {
                Text(provider == .custom ? "填 OpenAI 兼容的地址，到 /v1 为止。" : "一般不用改。")
            }
        }
        .keyboardDoneBar()
        .submitLabel(.done)
        .onSubmit { hideKeyboard() }
        .navigationTitle(provider.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loaded = false
            key = Keychain.get(provider.keyName) ?? ""
            baseURL = AppConfig.llmBaseURL(provider)
            models = AppConfig.models(for: provider)
            current = AppConfig.llmModel(provider)
            DispatchQueue.main.async { loaded = true }
        }
    }

    private func fetchModels() {
        loading = true
        message = nil
        Task {
            do {
                let list = try await OpenAIClient.listModels(baseURL: baseURL.isEmpty ? provider.defaultBaseURL : baseURL,
                                                             apiKey: key)
                // 只留文字模型，去掉明显的语音、向量、画图模型
                let filtered = list.filter { m in
                    let l = m.lowercased()
                    return !["embed", "tts", "asr", "whisper", "image", "rerank", "vision", "audio", "video", "cogview"]
                        .contains { l.contains($0) }
                }
                UserDefaults.standard.set(filtered, forKey: SettingsKey.fetchedModels(provider))
                models = AppConfig.models(for: provider)
                message = "✅ 拉到 \(filtered.count) 个模型"
            } catch {
                message = "❌ \(error.localizedDescription)"
            }
            loading = false
        }
    }

    private func runTest() {
        testing = true
        message = nil
        let base = baseURL.isEmpty ? provider.defaultBaseURL : baseURL
        Task {
            do {
                let r = try await Organizer.test(provider: provider, apiKey: key, baseURL: base, model: current)
                message = "✅ \(current)：\(r.prefix(40))"
            } catch {
                message = "❌ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}

// MARK: - 选模型（列出所有填了密钥的服务商的模型）

struct ModelPickerView: View {
    let title: String
    @Binding var selection: String          // "provider|model"，空字符串 = 跟随默认
    var allowFollowDefault = true
    @Environment(\.dismiss) private var dismiss

    private var providers: [LLMProvider] { LLMProvider.allCases.filter { AppConfig.hasKey($0) } }

    var body: some View {
        List {
            if allowFollowDefault {
                Section {
                    pickRow(title: "跟随默认模型", subtitle: AppConfig.defaultModelRef.label, value: "")
                }
            }
            if providers.isEmpty {
                Section {
                    NavigationLink {
                        ProvidersView()
                    } label: {
                        Label("还没有填任何服务商的密钥，先去填", systemImage: "key")
                    }
                }
            }
            ForEach(providers) { p in
                Section {
                    ForEach(AppConfig.models(for: p), id: \.self) { m in
                        pickRow(title: m, subtitle: nil, value: ModelRef(p, m).storage)
                    }
                } header: {
                    HStack(spacing: 8) {
                        ProviderBadge(provider: p, size: 22)
                        Text(p.label)
                    }
                    .textCase(nil)
                }
            }
            Section {
                NavigationLink("添加其他服务商") { ProvidersView() }
            } footer: {
                Text("只列出已经填了密钥的服务商。")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pickRow(title: String, subtitle: String?, value: String) -> some View {
        Button {
            selection = value
            UISelectionFeedbackGenerator().selectionChanged()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selection == value {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - 每种整理方式用哪个模型

struct StyleModelsView: View {
    @State private var tick = 0

    var body: some View {
        List {
            Section {
                ForEach(OrganizeStyle.allCases) { st in
                    NavigationLink {
                        ModelPickerView(title: st.label, selection: Binding(
                            get: { UserDefaults.standard.string(forKey: SettingsKey.styleModel(st)) ?? "" },
                            set: { v in
                                UserDefaults.standard.set(v, forKey: SettingsKey.styleModel(st))
                                tick += 1
                            }
                        ))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: st.icon)
                                .foregroundStyle(Theme.ai)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(st.label)
                                let custom = UserDefaults.standard.string(forKey: SettingsKey.styleModel(st)) ?? ""
                                Text(custom.isEmpty ? "跟随默认（\(AppConfig.defaultModelRef.model)）"
                                                    : AppConfig.modelFor(st).label)
                                    .font(.caption)
                                    .foregroundStyle(custom.isEmpty ? Color.secondary : Theme.ai)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } footer: {
                Text("例如：会议纪要 → DeepSeek V4 Pro（更强），通用整理 → 智谱 GLM Flash（免费）。在录音详情里点「AI 整理」时也可以临时换。")
            }
        }
        .id(tick)
        .navigationTitle("按整理方式指定模型")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tick += 1 }
    }
}

// MARK: - 语音转文字设置

struct ASRSettingsView: View {
    @AppStorage(SettingsKey.asrEngine) private var engineRaw = ASREngine.apple.rawValue
    @AppStorage(SettingsKey.appleLocale) private var appleLocale = "zh-CN"
    @AppStorage(SettingsKey.aliyunLanguage) private var aliyunLanguage = "auto"
    @State private var tick = 0

    private var engine: ASREngine { ASREngine(rawValue: engineRaw) ?? .apple }

    var body: some View {
        List {
            Section {
                if engine == .aliyun {
                    Picker("识别语言", selection: $aliyunLanguage) {
                        Text("自动识别（混说推荐）").tag("auto")
                        Text("普通话").tag("zh")
                        Text("粤语").tag("yue")
                        Text("英语").tag("en")
                    }
                } else if engine == .apple {
                    Picker("识别语言", selection: $appleLocale) {
                        Text("普通话").tag("zh-CN")
                        Text("粤语").tag("yue-CN")
                        Text("粤语（香港）").tag("zh-HK")
                        Text("英语").tag("en-US")
                    }
                } else {
                    LabeledContent("识别语言", value: "自动（中/粤/英/日/韩）")
                }
            }

            Section("正在用") {
                engineRow(engine, current: true)
            }

            Section {
                ForEach(ASREngine.allCases.filter { $0 != engine }) { e in
                    engineRow(e, current: false)
                }
            } header: {
                Text("换一家")
            } footer: {
                Text("白话、玉林话这类粤普混说，苹果本机基本转不准，建议用阿里云或硅基流动。每条录音在详情页也能单独选转写方式。")
            }
        }
        .id(tick)
        .navigationTitle("语音转文字")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tick += 1 }
    }

    @ViewBuilder private func engineRow(_ e: ASREngine, current: Bool) -> some View {
        let hasKey = e.keyName.map { Keychain.get($0) != nil } ?? true
        let content = HStack(spacing: 14) {
            Image(systemName: e == .apple ? "apple.logo" : (e == .aliyun ? "cloud.fill" : "waveform.badge.mic"))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background((e == .apple ? Color.black : (e == .aliyun ? Color.purple : Color.indigo)).gradient,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(e.title).font(.body.weight(.semibold))
                    Text(e.tag)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                Text(e.modelLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(e.price).font(.caption).foregroundStyle(.secondary)
                if e.keyName != nil { KeyStatus(ok: hasKey) }
            }
            Spacer()
            if !current && hasKey {
                Button("使用") {
                    engineRaw = e.rawValue
                    tick += 1
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(.vertical, 4)

        if e.keyName != nil {
            NavigationLink {
                ASRProviderDetailView(engine: e)
            } label: { content }
        } else {
            content
        }
    }
}

struct ASRProviderDetailView: View {
    let engine: ASREngine
    @Environment(\.openURL) private var openURL
    @AppStorage(SettingsKey.asrEngine) private var engineRaw = ASREngine.apple.rawValue
    @AppStorage(SettingsKey.aliyunModel) private var aliyunModel = AppConfig.defaultAliyunModel
    @AppStorage(SettingsKey.siliconModel) private var siliconModel = AppConfig.defaultSiliconModel
    @State private var key = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                SecureField("粘贴 API Key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: key) { _, v in
                        if loaded, let k = engine.keyName { Keychain.set(v, for: k) }
                    }
                Button {
                    if let u = URL(string: engine.keyURL) { openURL(u) }
                } label: {
                    HStack {
                        Label(key.isEmpty ? "还没有？去官网注册并获取 Key" : "去官网管理 Key", systemImage: "safari")
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption.weight(.bold))
                    }
                }
            } header: {
                Text("密钥")
            } footer: {
                Text(engine == .aliyun
                     ? "阿里云百炼的 Key 和「通义千问」整理共用，填一次两边都能用。"
                     : "硅基流动新用户注册就能用，SenseVoice 模型免费。")
            }

            Section("模型") {
                if engine == .aliyun {
                    TextField("qwen3-asr-flash", text: $aliyunModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    TextField("FunAudioLLM/SenseVoiceSmall", text: $siliconModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section {
                Button {
                    engineRaw = engine.rawValue
                } label: {
                    Label(engineRaw == engine.rawValue ? "正在用这家转写" : "用这家转写",
                          systemImage: engineRaw == engine.rawValue ? "checkmark.circle.fill" : "circle")
                }
                .disabled(key.isEmpty)
            }
        }
        .keyboardDoneBar()
        .submitLabel(.done)
        .onSubmit { hideKeyboard() }
        .navigationTitle(engine.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loaded = false
            key = engine.keyName.flatMap { Keychain.get($0) } ?? ""
            DispatchQueue.main.async { loaded = true }
        }
    }
}
