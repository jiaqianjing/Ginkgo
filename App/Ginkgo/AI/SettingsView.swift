import GinkgoAI
import SwiftUI

/// AI provider, key, model and answer language.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = AISettings.shared
    @State private var keyDraft = ""
    @State private var modelDraft = ""
    @State private var testState: TestState = .idle

    enum TestState: Equatable { case idle, running, ok(String), failed(String) }

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
                    TextField("模型（默认 \(settings.provider.defaultModel)）", text: $modelDraft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { settings.setModel(modelDraft, for: settings.provider) }
                } header: {
                    Text("AI 服务")
                } footer: {
                    VStack(alignment: .leading, spacing: Theme.Space.compact) {
                        Text("Key 只保存在这台设备的钥匙串里，App 直接调用服务商，不经过任何中间服务器。")
                        Link("去 \(settings.provider.displayName) 创建 key", destination: settings.provider.keyPage)
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
                            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.error)
                            }
                        }
                    }
                    .disabled(testState == .running)
                    switch testState {
                    case .ok(let text): Text(text).font(Theme.calloutFont).foregroundStyle(Theme.secondaryInk)
                    case .failed(let text): Text(text).font(Theme.calloutFont).foregroundStyle(Theme.error)
                    default: EmptyView()
                    }
                }

                Section("回答") {
                    Picker("回答语言", selection: $settings.readerLanguage) {
                        ForEach(AISettings.languages, id: \.self) { Text($0).tag($0) }
                    }
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
        }
    }

    private func loadDrafts() {
        keyDraft = AISettings.shared.key(for: settings.provider) ?? ""
        modelDraft = settings.model(for: settings.provider)
    }

    private func saveKey() { settings.setKey(keyDraft, for: settings.provider) }

    private func commit() {
        saveKey()
        settings.setModel(modelDraft, for: settings.provider)
    }

    private func test() async {
        commit()
        testState = .running
        do {
            let (client, label) = try settings.client()
            let context = PassageContext(bookTitle: "", passage: "The leaves of the ginkgo turn gold all at once.",
                                         readerLanguage: settings.readerLanguage)
            var text = ""
            for try await chunk in client.stream(PromptBuilder.request(for: .translate, context: context)) { text += chunk }
            testState = .ok("\(label)：\(text)")
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }
}
