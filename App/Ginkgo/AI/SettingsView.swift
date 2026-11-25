import GinkgoAI
import SwiftUI

/// AI provider, key, model and answer language.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = AISettings.shared
    private var sync = SyncMonitor.shared
    @State private var keyDraft = ""
    @State private var listed: [AIProviderKind: [String]] = [:]
    @State private var listError: String?
    @State private var customModel = ""
    @State private var askingCustom = false
    @State private var testState: TestState = .idle
    @AppStorage("gesture.twoFingerUndo") private var twoFingerUndo = true
    @AppStorage(FingerInput.key) private var fingerInput = FingerInput.system

    enum TestState: Equatable { case idle, running, ok(String, latency: String), failed(String) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("服务商", selection: $settings.provider) {
                        ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    SecureField("API key", text: $keyDraft)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(saveKey)
                    modelMenu
                    Toggle("允许把文字发给 \(settings.provider.displayName)", isOn: consent)
                } header: {
                    Text("AI 服务")
                } footer: {
                    VStack(alignment: .leading, spacing: Theme.Space.compact) {
                        Text("Key 只保存在这台设备的钥匙串里。用 AI 时，选中的原文、前后几段文字、书名和你的问题会直接发给服务商，"
                             + "不经过任何中间服务器；第一次发送前会先问你，关掉后下次用 AI 时会再问。")
                        Link("去 \(settings.provider.displayName) 创建 key", destination: settings.provider.keyPage)
                        Link("\(settings.provider.displayName) 的隐私政策", destination: settings.provider.privacyPolicy)
                    }
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("测试连接")
                            Spacer()
                            switch testState {
                            case .idle: EmptyView()
                            case .running: ProgressView()
                            case .ok(_, let latency):
                                Text(latency).font(Theme.calloutFont).monospacedDigit().foregroundStyle(Theme.secondaryInk)
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.error)
                            }
                        }
                    }
                    .disabled(testState == .running)
                    switch testState {
                    case .ok(let text, _): Text(text).font(Theme.calloutFont).foregroundStyle(Theme.secondaryInk)
                    case .failed(let text): Text(text).font(Theme.calloutFont).foregroundStyle(Theme.error)
                    default: EmptyView()
                    }
                }

                Section {
                    Picker("回答语言", selection: $settings.readerLanguage) {
                        ForEach(AISettings.languages, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("我的外语水平", selection: $settings.learnerLevel) {
                        ForEach(LearnerLevel.allCases) { level in
                            VStack(alignment: .leading) {
                                Text(level.displayName)
                                Text(level.detail).font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
                            }
                            .tag(level)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("回答")
                } footer: {
                    Text("翻译外语时，选一个词出词卡，选一句话出译文和重点表达，难句可以再要语法分析。挑哪些表达、讲多深，按你的外语水平来。")
                }

                Section {
                    LabeledContent("iCloud 同步", value: sync.summary)
                    if case .failed(let message) = sync.state {
                        Text(message).font(Theme.calloutFont).foregroundStyle(Theme.error)
                    }
                } header: {
                    Text("同步")
                } footer: {
                    Text(sync.state == .unavailable
                         ? "没有登录 iCloud，或在系统设置里关掉了 Ginkgo 的 iCloud。书和批注只保存在这台设备上；打开 iCloud 后会自动同步。"
                         : "书、划线、批注、笔迹、草稿和阅读位置保存在你自己的 iCloud 里，登录同一个 Apple 账户的设备都能看到。PDF 文件放在 iCloud 云盘里，不会出现在「文件」App 中。")
                }

                Section {
                    Picker("用手指画", selection: $fingerInput) {
                        ForEach(FingerInput.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("双指轻点撤销", isOn: $twoFingerUndo)
                } header: {
                    Text("手势")
                } footer: {
                    Text("用手指画：跟随系统时，用过 Apple Pencil 就只有笔能画，手指滚动和选字；没有笔的 iPad 用手指画，双指滚动。拿起工具时，双指轻点页面撤销上一步。系统手势始终可用：三指左滑撤销，三指右滑重做，三指轻点弹出编辑栏；接键盘时用 ⌘Z 和 ⇧⌘Z。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { commit(); dismiss() }
                }
            }
            .onAppear(perform: loadDrafts)
            .onChange(of: settings.provider) { _, _ in loadDrafts(); testState = .idle }
            .task(id: listingKey) { await loadModels() }
            .alert("自定义模型", isPresented: $askingCustom) {
                TextField("模型名称", text: $customModel)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("取消", role: .cancel) {}
                Button("使用") { if !customModel.trimmingCharacters(in: .whitespaces).isEmpty { pick(customModel) } }
            } message: {
                Text("填写 \(settings.provider.displayName) 的模型 ID。")
            }
        }
    }

    // MARK: Model menu

    private var consent: Binding<Bool> {
        Binding(get: { settings.hasConsent(for: settings.provider) },
                set: { settings.setConsent($0, for: settings.provider) })
    }

    private var current: String { settings.effectiveModel(for: settings.provider) }

    private var modelMenu: some View {
        let kind = settings.provider
        let more = listed[kind] ?? []
        return Menu {
            Section("推荐") {
                ForEach(kind.curatedModels, id: \.id) { choice in
                    Button { pick(choice.id) } label: {
                        if choice.id == current { Label(choice.id, systemImage: "checkmark") } else { Text(choice.id) }
                        Text(choice.note)
                    }
                }
            }
            Section {
                if !more.isEmpty {
                    Menu("更多模型（\(more.count)）") {
                        ForEach(more, id: \.self) { id in
                            Button { pick(id) } label: {
                                if id == current { Label(id, systemImage: "checkmark") } else { Text(id) }
                            }
                        }
                    }
                } else if let listError {
                    Text(listError)
                }
                Button("自定义模型名…") { customModel = isCurated(current) ? "" : current; askingCustom = true }
            }
        } label: {
            HStack {
                Text("模型").foregroundStyle(Theme.ink)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(current).foregroundStyle(Theme.secondaryInk)
                    if current == kind.recommendedModel {
                        Text("推荐 · 速度快、费用低").font(.caption).foregroundStyle(Theme.accent)
                    }
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    private func isCurated(_ id: String) -> Bool { settings.provider.curatedModels.contains { $0.id == id } }

    private func pick(_ id: String) {
        settings.setModel(id, for: settings.provider)
        testState = .idle
    }

    /// Re-fetch when the provider or its key changes.
    private var listingKey: String { "\(settings.provider.rawValue)|\(settings.keyRevision)" }

    private func loadModels() async {
        let kind = settings.provider
        listError = nil
        guard let key = AISettings.shared.key(for: kind), listed[kind] == nil else { return }
        do {
            let models = try await kind.listModels(apiKey: key)
            listed[kind] = ModelCatalog.moreModels(models, kind: kind)
        } catch is CancellationError {
        } catch {
            listError = "无法获取模型列表"
        }
    }

    private func loadDrafts() {
        keyDraft = AISettings.shared.key(for: settings.provider) ?? ""
    }

    private func saveKey() {
        let kind = settings.provider
        guard keyDraft != (AISettings.shared.key(for: kind) ?? "") else { return }
        settings.setKey(keyDraft, for: kind)
        listed[kind] = nil
    }

    private func commit() {
        saveKey()
    }

    private func test() async {
        commit()
        testState = .running
        do {
            let (client, label) = try settings.client()
            let context = PassageContext(bookTitle: "", passage: "The leaves of the ginkgo turn gold all at once.",
                                         readerLanguage: settings.readerLanguage)
            let (text, latency) = try await AnswerLatency.measure(client, PromptBuilder.request(for: .translate, context: context))
            testState = .ok("\(label)：\(text)", latency: latency.summary)
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }
}
