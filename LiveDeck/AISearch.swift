import SwiftUI
import AppKit
import Security
import PresentationKit

// MARK: - API keys in the macOS Keychain

enum KeychainStore {
    private static let service = "com.livedeck.studio.ai"

    static func get(_ account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Model

final class AIModel: ObservableObject {
    weak var engine: Engine?
    private let history = AIHistory(libraryRoot: PresentationLibrary.defaultRoot)

    @Published var provider: AIProvider { didSet { UserDefaults.standard.set(provider.rawValue, forKey: "ai.provider"); loadProviderSettings() } }
    @Published var model = "" { didSet { UserDefaults.standard.set(model, forKey: "ai.model.\(provider.shortName)") } }
    @Published var endpoint = "" { didSet { UserDefaults.standard.set(endpoint, forKey: "ai.endpoint.\(provider.shortName)") } }
    @Published var apiKey = "" { didSet { if !loading { KeychainStore.set(apiKey, for: provider.shortName) } } }
    @Published var style: AIPromptStyle { didSet { UserDefaults.standard.set(style.rawValue, forKey: "ai.style") } }
    @Published var extraInstructions: String { didSet { UserDefaults.standard.set(extraInstructions, forKey: "ai.extra") } }
    @Published var question = ""
    @Published var asking = false
    @Published var message = ""
    @Published var answers: [AIAnswer] = []
    @Published var selectedID: UUID?
    @Published var editing = false
    @Published var targetID: UUID?
    @Published var liveIndex: Int?
    @Published var showSettings = false
    private var loading = false

    init() {
        provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "ai.provider") ?? "") ?? .claude
        style = AIPromptStyle(rawValue: UserDefaults.standard.string(forKey: "ai.style") ?? "") ?? .answer
        extraInstructions = UserDefaults.standard.string(forKey: "ai.extra") ?? ""
        answers = history.items
        selectedID = answers.first?.id
        loadProviderSettings()
    }

    private func loadProviderSettings() {
        loading = true
        model = UserDefaults.standard.string(forKey: "ai.model.\(provider.shortName)") ?? provider.defaultModel
        endpoint = UserDefaults.standard.string(forKey: "ai.endpoint.\(provider.shortName)") ?? provider.defaultEndpoint
        apiKey = KeychainStore.get(provider.shortName)
        loading = false
        showSettings = provider.needsKey && apiKey.isEmpty
    }

    var selected: AIAnswer? { answers.first { $0.id == selectedID } }
    var keyMissing: Bool { provider.needsKey && apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: targets

    func currentTarget() -> AISource? {
        guard let engine else { return nil }
        if let id = targetID, let s = engine.sources.first(where: { $0.id == id }) as? AISource { return s }
        return engine.sources.compactMap { $0 as? AISource }.first
    }

    @discardableResult
    func ensureTarget() -> AISource? {
        if let t = currentTarget() { targetID = t.id; return t }
        guard let engine else { return nil }
        let s = engine.addAIInput()
        targetID = s.id
        return s
    }

    // MARK: asking

    func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        if keyMissing { message = "Paste your \(provider.shortName) API key first."; showSettings = true; return }
        asking = true; message = "Asking \(provider.shortName)…"
        let words = max(20, (currentTarget()?.look.maxCharsPerSlide ?? 260) / 6)
        let system = AIAssist.systemPrompt(style: style, wordsPerSlide: words, extra: extraInstructions)
        let cfg = AIRequestConfig(provider: provider, apiKey: apiKey, model: model, endpoint: provider.endpointEditable ? endpoint : nil)
        let providerName = provider.shortName, modelName = cfg.model, st = style
        AIAssist.ask(cfg, prompt: q, system: system) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.asking = false
                switch r {
                case .success(let text):
                    let a = AIAnswer(question: q, answer: AIAssist.cleanMarkdown(text), provider: providerName, model: modelName, style: st)
                    self.history.add(a)
                    self.answers = self.history.items
                    self.selectedID = a.id
                    self.liveIndex = nil
                    self.message = "Answer from \(providerName) — check it before putting it on screen."
                case .failure(let e):
                    self.message = "\(providerName): \(e.localizedDescription)"
                }
            }
        }
    }

    func updateSelected(text: String) {
        guard var a = selected else { return }
        a.answer = text
        history.update(a)
        answers = history.items
    }

    func delete(_ a: AIAnswer) {
        history.remove(a.id); answers = history.items
        if selectedID == a.id { selectedID = answers.first?.id }
    }
    func clearHistory() { history.clear(); answers = []; selectedID = nil }

    // MARK: slides

    func slides(for a: AIAnswer?, look: SlideLook) -> [SlideContent] {
        guard let a else { return [] }
        let parts = AIAssist.slides(from: a.answer, maxChars: look.maxCharsPerSlide)
        let credit = "\(a.provider) · AI-generated"
        return parts.enumerated().map { i, body in
            SlideContent(title: a.question, body: body, footer: i == 0 ? credit : "", label: "\(i + 1)/\(parts.count)")
        }
    }

    func show(_ index: Int) {
        guard let t = ensureTarget() else { return }
        let list = slides(for: selected, look: t.look)
        guard list.indices.contains(index) else { return }
        t.show(list[index])
        liveIndex = index
    }

    func step(_ d: Int) { show((liveIndex ?? -1) + d) }
    func clearText() { currentTarget()?.textCleared = true; liveIndex = nil }

    func preview() {
        if liveIndex == nil { show(0) }
        guard let t = currentTarget(), let engine else { return }
        engine.setPreview(t.id); engine.selectedSourceID = t.id
    }
    func program() {
        if liveIndex == nil { show(0) }
        guard let t = currentTarget(), let engine else { return }
        engine.keyedSources.remove(t.id); engine.setPreview(t.id); engine.cut()
    }
    func keyPreview() { if liveIndex == nil { show(0) }; if let t = currentTarget() { engine?.toggleKeyPreview(t.id) } }
    func keyProgram() { if liveIndex == nil { show(0) }; if let t = currentTarget() { engine?.toggleKey(t.id) } }
}

// MARK: - AI deck (same layout as the Dictionary: search · preview · format)

struct AIDeck: View {
    var body: some View {
        HSplitView {
            AISearchColumn().frame(minWidth: 280, idealWidth: 330, maxWidth: 460)
            AIAnswerColumn().frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AISearchColumn: View {
    @EnvironmentObject var ai: AIModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "AI search", icon: "sparkle.magnifyingglass") {
                Button { ai.showSettings.toggle() } label: {
                    Image(systemName: ai.keyMissing ? "key.fill" : "gearshape").foregroundColor(ai.keyMissing ? DS.amber : CP.text2)
                }
                .buttonStyle(.plain).help("Provider, model and API key")
            }
            CPInspector {
                CPCard(title: ai.provider.shortName, subtitle: ai.model + (ai.keyMissing ? " · key needed" : ""), icon: "cpu") {
                    CPRow(label: "Provider") {
                        Picker("", selection: $ai.provider) { ForEach(AIProvider.allCases) { p in Text(p.rawValue).tag(p) } }
                            .cpPickerChrome().frame(maxWidth: 190)
                    }
                    if ai.showSettings || ai.keyMissing {
                        CPRow(label: "Model") {
                            HStack(spacing: 4) {
                                TextField(ai.provider.defaultModel, text: $ai.model).dsField().frame(maxWidth: 150)
                                Menu("") { ForEach(ai.provider.models, id: \.self) { m in Button(m) { ai.model = m } } }
                                    .menuStyle(.borderlessButton).fixedSize().frame(width: 18)
                            }
                        }
                        if ai.provider.needsKey {
                            CPTextRow(label: "API key", text: $ai.apiKey, prompt: "paste key", secure: true)
                        }
                        if ai.provider.endpointEditable {
                            CPTextRow(label: "Address", text: $ai.endpoint, prompt: ai.provider.defaultEndpoint)
                        }
                        HStack {
                            if let page = ai.provider.keyPage {
                                Button(ai.provider == .ollama ? "Get Ollama" : "Get an API key") { NSWorkspace.shared.open(page) }
                                    .buttonStyle(.ds(.ghost, .small))
                            }
                            Spacer()
                            Button("Done") { ai.showSettings = false }.buttonStyle(.ds(.normal, .small)).disabled(ai.keyMissing)
                        }
                        .padding(.vertical, 4)
                        CPNote("Keys are kept in the macOS Keychain. Usage is billed by the provider to your own account.")
                    }
                }

                CPCard(title: "Ask", subtitle: ai.style.rawValue, icon: "questionmark.bubble") {
                    CPRow(label: "Write as") {
                        Picker("", selection: $ai.style) { ForEach(AIPromptStyle.allCases) { s in Text(s.rawValue).tag(s) } }
                            .cpPickerChrome().frame(maxWidth: 170)
                    }
                    TextField("Type a question — e.g. What does grace mean in Ephesians 2?", text: $ai.question, axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(CP.text)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(CP.field))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? CP.accentLine : CP.border, lineWidth: 1))
                        .focused($focused)
                        .onSubmit { ai.ask() }
                        .padding(.vertical, 6)
                    CPTextRow(label: "Extra rules", text: $ai.extraInstructions, prompt: "e.g. use NKJV, answer in Twi")
                    HStack {
                        if ai.asking { ProgressView().controlSize(.small) }
                        Text(ai.message).font(.system(size: 10)).foregroundColor(ai.message.contains(":") && !ai.message.hasPrefix("Answer") ? DS.amber : CP.text2)
                            .lineLimit(3)
                        Spacer()
                        CPButton(icon: "sparkles", title: "Ask", prominent: true) { ai.ask() }
                            .disabled(ai.asking || ai.question.trimmingCharacters(in: .whitespaces).isEmpty)
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                    .padding(.vertical, 6)
                }

                CPCard(title: "Answers", subtitle: "\(ai.answers.count) saved", icon: "clock.arrow.circlepath") {
                    if ai.answers.isEmpty {
                        CPNote("Your questions and answers are kept here so you can reuse them in the service.")
                    }
                    ForEach(ai.answers) { a in
                        let sel = ai.selectedID == a.id
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.question).font(.system(size: 11.5, weight: sel ? .semibold : .regular)).foregroundColor(CP.text).lineLimit(2)
                            Text("\(a.provider) · \(a.style.rawValue) · \(a.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 9)).foregroundColor(CP.text2)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(sel ? CP.blueSoft : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture { ai.selectedID = a.id; ai.liveIndex = nil }
                        .contextMenu {
                            Button("Show first slide") { ai.selectedID = a.id; ai.show(0) }
                            Button("Ask again") { ai.question = a.question; ai.style = a.style; ai.ask() }
                            Button("Copy answer") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a.answer, forType: .string) }
                            Divider()
                            Button("Delete", role: .destructive) { ai.delete(a) }
                        }
                    }
                    if !ai.answers.isEmpty {
                        HStack { Spacer(); Button("Clear all") { ai.clearHistory() }.buttonStyle(.ds(.ghost, .small)) }.padding(.vertical, 4)
                    }
                }
            }
        }
        .background(CP.bg)
    }
}

struct AIAnswerColumn: View {
    @EnvironmentObject var ai: AIModel
    @EnvironmentObject var engine: Engine
    @State private var draft = ""

    var body: some View {
        let target = ai.currentTarget()
        let keyed = target.map { engine.isKeyed($0.id) } ?? false
        let pvwKeyed = target.map { engine.isPreviewKeyed($0.id) } ?? false
        let onAir = target.map { engine.programID == $0.id } ?? false
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(engine.sources.compactMap { $0 as? AISource }, id: \.id) { s in Button(s.name) { ai.targetID = s.id } }
                    Divider()
                    Button("New AI Search input") { let s = engine.addAIInput(); ai.targetID = s.id }
                    if let t = target { Button("Rename “\(t.name)”…") { engine.renamingSourceID = t.id } }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(onAir ? DS.program : (keyed ? DS.amber : DS.text3)).frame(width: 7, height: 7)
                        Text(target?.name ?? "No AI input").font(.system(size: 11, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Divider().frame(height: 18)
                Button { ai.step(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.ds(.normal, .small))
                Button { ai.step(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.ds(.normal, .small))
                Button("Clear text") { ai.clearText() }.buttonStyle(.ds(.normal, .small))
                Spacer(minLength: 6)
                Button("Preview") { ai.preview() }.buttonStyle(.ds(.preview, .small, active: target.map { engine.previewID == $0.id } ?? false))
                Button("Program") { ai.program() }.buttonStyle(.ds(.program, .small, active: onAir))
                Button("Key PVW") { ai.keyPreview() }.buttonStyle(.ds(.amber, .small, active: pvwKeyed))
                Button("Key PGM") { ai.keyProgram() }.buttonStyle(.ds(.amber, .small, active: keyed))
            }
            .padding(.horizontal, 8).frame(height: 38).background(DS.bg2)
            .overlay(Rectangle().fill(DS.lineSoft).frame(height: 1), alignment: .bottom)
            .disabled(ai.selected == nil)

            if let a = ai.selected {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(a.question).font(.system(size: 12, weight: .semibold)).foregroundColor(DS.text).lineLimit(2)
                        Spacer()
                        Button(ai.editing ? "Done editing" : "Edit answer") {
                            if ai.editing { ai.updateSelected(text: draft) } else { draft = a.answer }
                            ai.editing.toggle()
                        }
                        .buttonStyle(.ds(ai.editing ? .primary : .normal, .small))
                    }
                    if ai.editing {
                        TextEditor(text: $draft)
                            .font(.system(size: 12)).frame(minHeight: 120, maxHeight: 220)
                            .scrollContentBackground(.hidden)
                            .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(CP.field))
                        Text("Blank lines start new slides. AI can make mistakes — check names, dates and scripture.")
                            .font(.system(size: 10)).foregroundColor(DS.text3)
                    }
                }
                .padding(8).background(DS.bg1)

                if let t = target {
                    AISlideGrid(answer: a, source: t)
                } else {
                    VStack(spacing: 8) {
                        Text("Add an AI Search input to put answers on screen.").font(DS.label).foregroundColor(DS.text2)
                        Button("Add AI Search input") { ai.ensureTarget() }.buttonStyle(.ds(.primary))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 34)).foregroundColor(DS.text3)
                    Text("Ask Claude, ChatGPT, Gemini and more — the answer becomes slides you can format and show.")
                        .font(DS.label).foregroundColor(DS.text2).multilineTextAlignment(.center)
                    Text("Always check AI answers before they go on screen.").font(.system(size: 10)).foregroundColor(DS.text3)
                }
                .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DS.bg1)
    }
}

struct AISlideGrid: View {
    @EnvironmentObject var ai: AIModel
    @EnvironmentObject var engine: Engine
    let answer: AIAnswer
    @ObservedObject var source: AISource

    var body: some View {
        let slides = ai.slides(for: answer, look: source.look)
        GeometryReader { geo in
            let cols = max(1, Int((geo.size.width - 8) / 210))
            let w = floor((geo.size.width - CGFloat(cols + 1) * 8) / CGFloat(cols))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(max(100, w)), spacing: 8), count: cols), spacing: 8) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { idx, c in
                        SlideCard(index: idx + 1, content: c, source: source, width: max(100, w), live: ai.liveIndex == idx)
                            .onTapGesture { ai.show(idx) }
                            .contextMenu {
                                Button("Show this slide") { ai.show(idx) }
                                Button("Show and put on Preview") { ai.show(idx); ai.preview() }
                                Button("Show and cut to Program") { ai.show(idx); ai.program() }
                                Divider()
                                Button(engine.isPreviewKeyed(source.id) ? "Remove key from Preview" : "Show and key on Preview") { ai.show(idx); engine.toggleKeyPreview(source.id) }
                                Button(engine.isKeyed(source.id) ? "Remove key from Program" : "Show and key on Program") {
                                    if engine.isKeyed(source.id) { engine.toggleKey(source.id) } else { ai.show(idx); engine.toggleKey(source.id) }
                                }
                                Divider()
                                Button("Clear text") { ai.clearText() }
                                Button("Copy slide text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.body, forType: .string) }
                            }
                    }
                }
                .padding(8)
            }
        }
    }
}
