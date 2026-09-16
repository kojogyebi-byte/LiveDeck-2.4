import XCTest
@testable import PresentationKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AIAssistTests: XCTestCase {
    func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }

    func testAnthropicRequestAndParse() throws {
        let r = try AIAssist.makeRequest(AIRequestConfig(provider: .claude, apiKey: "sk-ant"), prompt: "Who wrote Psalm 23?", system: "SYS")
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let b = body(r)
        XCTAssertEqual(b["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(b["system"] as? String, "SYS")
        let json = #"{"content":[{"type":"text","text":"David wrote it."}],"stop_reason":"end_turn"}"#
        XCTAssertEqual(try AIAssist.parseResponse(.anthropic, data: Data(json.utf8)), "David wrote it.")
    }

    func testOpenAICompatibleRequestAndParse() throws {
        let r = try AIAssist.makeRequest(AIRequestConfig(provider: .chatgpt, apiKey: "sk-1", model: "gpt-5.5"), prompt: "Hi", system: "S")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer sk-1")
        let msgs = body(r)["messages"] as? [[String: Any]]
        XCTAssertEqual(msgs?.first?["role"] as? String, "system")
        XCTAssertNil(body(r)["temperature"], "newer reasoning models reject custom temperature")
        let json = #"{"choices":[{"message":{"role":"assistant","content":"Hello there"}}]}"#
        XCTAssertEqual(try AIAssist.parseResponse(.openAI, data: Data(json.utf8)), "Hello there")
        // Ollama: no key, custom endpoint
        let o = try AIAssist.makeRequest(AIRequestConfig(provider: .ollama, endpoint: "http://localhost:11434/v1/chat/completions"), prompt: "x", system: "y")
        XCTAssertNil(o.value(forHTTPHeaderField: "Authorization"))
        XCTAssertThrowsError(try AIAssist.makeRequest(AIRequestConfig(provider: .perplexity), prompt: "x", system: "y"))
    }

    func testGeminiRequestAndParse() throws {
        let r = try AIAssist.makeRequest(AIRequestConfig(provider: .gemini, apiKey: "g"), prompt: "Q", system: "S")
        XCTAssertEqual(r.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-goog-api-key"), "g")
        let json = #"{"candidates":[{"content":{"parts":[{"text":"thinking","thought":true},{"text":"Part one. "},{"text":"Part two."}]}}]}"#
        XCTAssertEqual(try AIAssist.parseResponse(.gemini, data: Data(json.utf8)), "Part one. Part two.")
        XCTAssertThrowsError(try AIAssist.parseResponse(.gemini, data: Data(#"{"error":{"message":"API key not valid"}}"#.utf8))) { e in
            XCTAssertTrue("\(e)".contains("API key not valid"))
        }
    }

    func testMarkdownCleanup() {
        let md = "## The Good Shepherd\n\n**Psalm 23** says *the Lord* is my shepherd [1].\n\n- Rest\n- Guidance\n\n```\ncode\n```\nSee [Bible Gateway](https://example.com)."
        let c = AIAssist.cleanMarkdown(md)
        XCTAssertFalse(c.contains("#")); XCTAssertFalse(c.contains("*")); XCTAssertFalse(c.contains("[1]"))
        XCTAssertTrue(c.hasPrefix("The Good Shepherd"))
        XCTAssertTrue(c.contains("• Rest"))
        XCTAssertTrue(c.contains("See Bible Gateway."))
        XCTAssertFalse(c.contains("```")); XCTAssertTrue(c.contains("code"), "code-block text is kept, fences removed")
    }

    func testSlideSplitting() {
        let long = (1...12).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let text = "Title\n\n" + long + "\n\n1. One\n2. Two\n3. Three"
        let slides = AIAssist.slides(from: text, maxChars: 120)
        XCTAssertTrue(slides.allSatisfy { $0.count <= 120 }, "\(slides.map { $0.count })")
        XCTAssertEqual(slides.first, "Title")
        XCTAssertTrue(slides.last?.contains("1. One\n2. Two\n3. Three") == true)
        XCTAssertTrue(AIAssist.slides(from: "").isEmpty)
        XCTAssertTrue(AIAssist.systemPrompt(style: .sermonPoints).contains("sermon points"))
    }

    func testHistoryPersistence() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let h = AIHistory(libraryRoot: root)
        h.add(AIAnswer(question: "Q", answer: "A", provider: "Claude", model: "m", style: .answer))
        XCTAssertEqual(AIHistory(libraryRoot: root).items.first?.answer, "A")
    }
}
