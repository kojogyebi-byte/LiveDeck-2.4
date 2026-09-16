import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - AI search (Claude, ChatGPT, Gemini, Grok, DeepSeek, Mistral, Perplexity, Groq, Ollama, custom)
//
// Every provider is called with the user's own API key (Ollama runs on the Mac and needs none).
// Answers are cleaned of Markdown and split into screen-sized slides that use the same looks as
// songs, scripture and the dictionary.

public enum AIWireFormat: String, Codable, Sendable { case anthropic, openAI, gemini }

public enum AIProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude = "Claude (Anthropic)"
    case chatgpt = "ChatGPT (OpenAI)"
    case gemini = "Gemini (Google)"
    case grok = "Grok (xAI)"
    case deepseek = "DeepSeek"
    case mistral = "Mistral"
    case perplexity = "Perplexity (web search)"
    case groq = "Groq"
    case ollama = "Ollama (on this Mac)"
    case custom = "Custom (OpenAI-compatible)"

    public var id: String { rawValue }
    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .deepseek: return "DeepSeek"
        case .mistral: return "Mistral"
        case .perplexity: return "Perplexity"
        case .groq: return "Groq"
        case .ollama: return "Ollama"
        case .custom: return "AI"
        }
    }

    public var wire: AIWireFormat {
        switch self {
        case .claude: return .anthropic
        case .gemini: return .gemini
        default: return .openAI
        }
    }

    public var needsKey: Bool { self != .ollama }

    /// Suggested model ids (the first is the default). Users can type any model id.
    public var models: [String] {
        switch self {
        case .claude: return ["claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5-20251001"]
        case .chatgpt: return ["gpt-5.5", "gpt-6-astra", "gpt-5.4-mini"]
        case .gemini: return ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.1-flash-lite"]
        case .grok: return ["grok-4", "grok-4-fast"]
        case .deepseek: return ["deepseek-chat", "deepseek-reasoner"]
        case .mistral: return ["mistral-large-latest", "mistral-small-latest"]
        case .perplexity: return ["sonar", "sonar-pro"]
        case .groq: return ["llama-3.3-70b-versatile", "openai/gpt-oss-120b"]
        case .ollama: return ["llama3.2", "gemma3", "qwen3"]
        case .custom: return ["model-name"]
        }
    }
    public var defaultModel: String { models[0] }

    /// Default endpoint (custom/Ollama can be changed by the user).
    public var defaultEndpoint: String {
        switch self {
        case .claude: return "https://api.anthropic.com/v1/messages"
        case .chatgpt: return "https://api.openai.com/v1/chat/completions"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
        case .grok: return "https://api.x.ai/v1/chat/completions"
        case .deepseek: return "https://api.deepseek.com/chat/completions"
        case .mistral: return "https://api.mistral.ai/v1/chat/completions"
        case .perplexity: return "https://api.perplexity.ai/chat/completions"
        case .groq: return "https://api.groq.com/openai/v1/chat/completions"
        case .ollama: return "http://localhost:11434/v1/chat/completions"
        case .custom: return "https://your-server/v1/chat/completions"
        }
    }
    public var endpointEditable: Bool { self == .ollama || self == .custom }

    public var keyPage: URL? {
        switch self {
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")
        case .chatgpt: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .grok: return URL(string: "https://console.x.ai")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")
        case .perplexity: return URL(string: "https://www.perplexity.ai/settings/api")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .ollama: return URL(string: "https://ollama.com/download")
        case .custom: return nil
        }
    }
}

/// What kind of screen text to ask for.
public enum AIPromptStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case answer = "Answer"
    case bibleStudy = "Bible study"
    case sermonPoints = "Sermon points"
    case explain = "Explain simply"
    case summary = "Summary"
    case prayer = "Prayer points"
    case announcement = "Announcement"
    case quotes = "Quotes & sayings"
    case translate = "Translate"

    public var id: String { rawValue }

    public var instruction: String {
        switch self {
        case .answer: return "Answer the question accurately and briefly."
        case .bibleStudy: return "Give a short Bible study: the key passage references, what they mean, and how to apply them. Quote scripture only when you are certain of the wording and always give the reference."
        case .sermonPoints: return "Write clear sermon points: a title line, then 3 to 6 numbered points, each with a supporting scripture reference."
        case .explain: return "Explain the topic simply, as to a mixed congregation, using everyday words."
        case .summary: return "Summarise the text or topic in a few short points."
        case .prayer: return "Write short prayer points, each on its own paragraph."
        case .announcement: return "Write a friendly church announcement with the key details (what, when, where, who to contact)."
        case .quotes: return "Give a few short, well-known quotes on the topic with the name of the person who said each one. Do not invent quotes."
        case .translate: return "Translate the text faithfully. Keep line breaks. Reply with the translation only."
        }
    }
}

public struct AIRequestConfig: Sendable {
    public var provider: AIProvider
    public var apiKey: String
    public var model: String
    public var endpoint: String
    public var maxTokens: Int
    public init(provider: AIProvider, apiKey: String = "", model: String? = nil, endpoint: String? = nil, maxTokens: Int = 1200) {
        self.provider = provider; self.apiKey = apiKey
        self.model = (model ?? "").trimmed.isEmpty ? provider.defaultModel : model!.trimmed
        self.endpoint = (endpoint ?? "").trimmed.isEmpty ? provider.defaultEndpoint : endpoint!.trimmed
        self.maxTokens = maxTokens
    }
}

public struct AIAnswer: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var question: String
    public var answer: String
    public var provider: String
    public var model: String
    public var style: AIPromptStyle
    public var date: Date
    public init(id: UUID = UUID(), question: String, answer: String, provider: String, model: String, style: AIPromptStyle, date: Date = Date()) {
        self.id = id; self.question = question; self.answer = answer; self.provider = provider; self.model = model; self.style = style; self.date = date
    }
}

public enum AIAssist {
    public static func systemPrompt(style: AIPromptStyle, wordsPerSlide: Int = 45, extra: String = "") -> String {
        var s = """
        You write text that will be shown on a big projection screen during a live church service or event.
        \(style.instruction)
        Rules: plain text only — no Markdown, no asterisks, no headings with #, no tables, no emoji.
        Use short sentences. Separate screen-sized paragraphs with one blank line; keep each paragraph under \(wordsPerSlide) words.
        If a list helps, put each item on its own line starting with a number and a full stop (1. 2. 3.).
        If you are not sure about a fact, date or quotation, say so instead of guessing.
        """
        if !extra.trimmed.isEmpty { s += "\nAlso: " + extra.trimmed }
        return s
    }

    // MARK: request building

    public static func makeRequest(_ c: AIRequestConfig, prompt: String, system: String) throws -> URLRequest {
        if c.provider.needsKey && c.apiKey.trimmed.isEmpty {
            throw PresentationKitError.badFormat("\(c.provider.shortName) needs an API key — paste it in the key box")
        }
        let endpoint = c.endpoint.replacingOccurrences(of: "{model}", with: c.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? c.model)
        guard let url = URL(string: endpoint), url.scheme != nil else { throw PresentationKitError.badFormat("the endpoint address is not valid") }
        var req = URLRequest(url: url, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        switch c.provider.wire {
        case .anthropic:
            req.setValue(c.apiKey.trimmed, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": c.model, "max_tokens": c.maxTokens, "system": system,
                    "messages": [["role": "user", "content": prompt]]]
        case .gemini:
            req.setValue(c.apiKey.trimmed, forHTTPHeaderField: "x-goog-api-key")
            body = ["systemInstruction": ["parts": [["text": system]]],
                    "contents": [["role": "user", "parts": [["text": prompt]]]]]
        case .openAI:
            if !c.apiKey.trimmed.isEmpty { req.setValue("Bearer " + c.apiKey.trimmed, forHTTPHeaderField: "Authorization") }
            body = ["model": c.model,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    // MARK: response parsing

    public static func parseResponse(_ wire: AIWireFormat, data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw PresentationKitError.badFormat(text.isEmpty ? "empty reply" : String(text.prefix(200)))
        }
        if let err = errorMessage(obj) { throw PresentationKitError.network(err) }
        var text = ""
        switch wire {
        case .anthropic:
            let blocks = obj["content"] as? [[String: Any]] ?? []
            text = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .gemini:
            let cands = obj["candidates"] as? [[String: Any]] ?? []
            let content = cands.first?["content"] as? [String: Any] ?? [:]
            let parts = content["parts"] as? [[String: Any]] ?? []
            text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        case .openAI:
            let choices = obj["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any] ?? [:]
            if let s = message["content"] as? String { text = s }
            else if let parts = message["content"] as? [[String: Any]] { text = parts.compactMap { $0["text"] as? String }.joined() }
        }
        text = text.trimmed
        if text.isEmpty { throw PresentationKitError.badFormat("the AI returned no text") }
        return text
    }

    static func errorMessage(_ obj: [String: Any]) -> String? {
        if let e = obj["error"] as? [String: Any] {
            return (e["message"] as? String) ?? (e["type"] as? String) ?? "request failed"
        }
        if let e = obj["error"] as? String { return e }
        if (obj["type"] as? String) == "error" { return "request failed" }
        return nil
    }

    // MARK: text → screen

    /// Removes Markdown so answers look clean on screen.
    public static func cleanMarkdown(_ text: String) -> String {
        var lines: [String] = []
        var inCode = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var l = raw
            if l.trimmed.hasPrefix("```") { inCode.toggle(); continue }
            if !inCode {
                let t = l.trimmed
                if t.hasPrefix("#") { l = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
                if t == "---" || t == "***" || t == "___" { l = "" }
                if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { l = "• " + String(t.dropFirst(2)) }
                if t.hasPrefix(">") { l = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
                for mark in ["**", "__", "`"] { l = l.replacingOccurrences(of: mark, with: "") }
                // single *emphasis*
                l = l.replacingOccurrences(of: #"(?<![\w*])\*(\S[^*]*?\S|\S)\*(?![\w*])"#, with: "$1", options: .regularExpression)
                // [link](url) → link
                l = l.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)]+)\)"#, with: "$1", options: .regularExpression)
                // citation markers [1]
                l = l.replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
            }
            lines.append(l.trimmingCharacters(in: .whitespaces))
        }
        var out = lines.joined(separator: "\n")
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmed
    }

    /// Splits text into slides: blank-line paragraphs, keeping each slide under `maxChars`.
    /// Consecutive short list lines are kept together; long paragraphs split at sentence ends.
    public static func slides(from text: String, maxChars: Int = 280) -> [String] {
        let limit = max(60, maxChars)
        let paragraphs = cleanMarkdown(text).components(separatedBy: "\n\n").map { $0.trimmed }.filter { !$0.isEmpty }
        var out: [String] = []
        var buf = ""
        func flush() { if !buf.trimmed.isEmpty { out.append(buf.trimmed) }; buf = "" }
        for p in paragraphs {
            if p.count > limit {
                flush()
                // list lines first, then sentences
                let pieces = p.contains("\n") ? p.components(separatedBy: "\n") : sentences(p)
                for piece in pieces {
                    let sep = p.contains("\n") ? "\n" : " "
                    if piece.count > limit {
                        flush()
                        var chunk = ""
                        for word in piece.split(separator: " ") {
                            if chunk.count + word.count + 1 > limit { out.append(chunk.trimmed); chunk = "" }
                            chunk += (chunk.isEmpty ? "" : " ") + word
                        }
                        buf = chunk
                        continue
                    }
                    if !buf.isEmpty && buf.count + sep.count + piece.count > limit { flush() }
                    buf += (buf.isEmpty ? "" : sep) + piece
                }
                flush()
            } else {
                if !buf.isEmpty && buf.count + 2 + p.count > limit { flush() }
                // short paragraphs are joined only when both are very short (e.g. a title line)
                if !buf.isEmpty && (buf.count > limit / 3 || p.count > limit / 3) { flush() }
                buf += (buf.isEmpty ? "" : "\n") + p
            }
        }
        flush()
        return out
    }

    static func sentences(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            if ".!?".contains(ch) && (i + 1 == chars.count || chars[i + 1] == " ") {
                out.append(cur.trimmed); cur = ""
            }
        }
        if !cur.trimmed.isEmpty { out.append(cur.trimmed) }
        return out
    }

    // MARK: network

    public static func ask(_ c: AIRequestConfig, prompt: String, system: String,
                           completion: @escaping (Result<String, Error>) -> Void) {
        let req: URLRequest
        do { req = try makeRequest(c, prompt: prompt, system: system) } catch { completion(.failure(error)); return }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                let msg = c.provider == .ollama ? "Ollama is not running on this Mac (\(err.localizedDescription))" : err.localizedDescription
                completion(.failure(PresentationKitError.network(msg))); return
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else { completion(.failure(PresentationKitError.network("no reply (\(status))"))); return }
            do {
                let text = try parseResponse(c.provider.wire, data: data)
                completion(.success(text))
            } catch {
                if status == 401 || status == 403 { completion(.failure(PresentationKitError.network("the API key was refused — check it"))) }
                else if status == 429 { completion(.failure(PresentationKitError.network("rate limit or credit reached — wait or check your plan"))) }
                else { completion(.failure(error)) }
            }
        }.resume()
    }
}

/// Saved questions and answers (Library/ai-history.json).
public final class AIHistory {
    public let url: URL
    public private(set) var items: [AIAnswer]
    public init(libraryRoot: URL) {
        url = libraryRoot.appendingPathComponent("ai-history.json")
        items = (try? JSONFile.read([AIAnswer].self, from: url)) ?? []
    }
    public func add(_ a: AIAnswer) { items.insert(a, at: 0); if items.count > 200 { items.removeLast(items.count - 200) }; save() }
    public func update(_ a: AIAnswer) { if let i = items.firstIndex(where: { $0.id == a.id }) { items[i] = a; save() } }
    public func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }
    public func clear() { items.removeAll(); save() }
    func save() { try? JSONFile.write(items, to: url) }
}
