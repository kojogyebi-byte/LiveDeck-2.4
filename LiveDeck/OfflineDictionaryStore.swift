import Foundation
import PresentationKit

// MARK: - Offline English dictionary on this Mac
//
// Ships compressed inside the app (Resources/Dictionary/english-wordnet.lddict.gz, ≈10 MB) and is unpacked once into
// ~/Library/Application Support/LiveDeck/Dictionaries (≈33 MB). If the app was built without it, “Download” fetches
// WordNet and the CMU pronouncing dictionary and builds the same file on this Mac.

final class OfflineDictionaryStore: ObservableObject {
    static let shared = OfflineDictionaryStore()

    enum Status: Equatable { case notInstalled, working(String), ready(Int), failed(String) }
    @Published private(set) var status: Status = .notInstalled
    private(set) var dictionary: OfflineDictionary?
    private let queue = DispatchQueue(label: "livedeck.dictionary", qos: .userInitiated)

    static let fileName = "english-wordnet.lddict"

    var installedURL: URL {
        PresentationLibrary.defaultRoot.deletingLastPathComponent().appendingPathComponent("Dictionaries").appendingPathComponent(Self.fileName)
    }

    var bundledArchive: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Dictionary/\(Self.fileName).gz"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Dictionary/\(Self.fileName).gz")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var isReady: Bool { if case .ready = status { return true }; return false }

    private init() {
        if FileManager.default.fileExists(atPath: installedURL.path) { open() }
    }

    private func open() {
        do {
            let d = try OfflineDictionary(url: installedURL)
            let n = d.wordCount
            guard n > 0 else { throw PresentationKitError.sqlite("empty dictionary") }
            dictionary = d
            DispatchQueue.main.async { self.status = .ready(n) }
        } catch {
            dictionary = nil
            try? FileManager.default.removeItem(at: installedURL)
            DispatchQueue.main.async { self.status = .notInstalled }
        }
    }

    /// Makes sure the dictionary is available; unpacks the bundled copy automatically.
    func prepare(_ done: (() -> Void)? = nil) {
        if dictionary != nil { done?(); return }
        if let archive = bundledArchive { install(from: archive, done) } else { DispatchQueue.main.async { self.status = .notInstalled; done?() } }
    }

    private func install(from archive: URL, _ done: (() -> Void)?) {
        status = .working("Unpacking the offline dictionary…")
        queue.async {
            do {
                let data = try Data(contentsOf: archive)
                let raw = try Self.gunzip(data)
                try FileManager.default.createDirectory(at: self.installedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try raw.write(to: self.installedURL, options: .atomic)
                self.open()
            } catch {
                DispatchQueue.main.async { self.status = .failed("Could not unpack the dictionary: \(error.localizedDescription)") }
            }
            DispatchQueue.main.async { done?() }
        }
    }

    /// Downloads WordNet 3.1, the WordNet 3.0 irregular forms and the CMU pronunciations (≈25 MB) and builds the dictionary.
    func download() {
        status = .working("Downloading the dictionary (about 25 MB)…")
        queue.async {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("livedeck-dict-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let packages = [
                    ("wordnet", "https://registry.npmjs.org/wordnet-db/-/wordnet-db-3.1.14.tgz"),
                    ("exceptions", "https://registry.npmjs.org/wndb-with-exceptions/-/wndb-with-exceptions-3.0.2.tgz"),
                    ("cmu", "https://registry.npmjs.org/cmu-pronouncing-dictionary/-/cmu-pronouncing-dictionary-3.0.0.tgz")
                ]
                for (name, url) in packages {
                    let data = try Self.fetch(URL(string: url)!)
                    let tgz = work.appendingPathComponent("\(name).tgz")
                    try data.write(to: tgz)
                    let dir = work.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    p.arguments = ["-xzf", tgz.path, "-C", dir.path, "--exclude", "*.tar.gz"]
                    try p.run(); p.waitUntilExit()
                    guard p.terminationStatus == 0 else { throw PresentationKitError.network("Could not unpack \(name)") }
                }
                let cmuText = (try? String(contentsOf: work.appendingPathComponent("cmu/package/index.js"), encoding: .utf8)) ?? ""
                let pronunciations = ARPAbet.parseCMUJavaScript(cmuText)
                try FileManager.default.createDirectory(at: self.installedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try OfflineDictionaryBuilder.build(wordNetDict: work.appendingPathComponent("wordnet/package/dict"),
                                                   exceptionsDir: work.appendingPathComponent("exceptions/package/data"),
                                                   pronunciations: pronunciations, output: self.installedURL) { step in
                    DispatchQueue.main.async { self.status = .working(step) }
                }
                self.open()
            } catch {
                DispatchQueue.main.async { self.status = .failed("Download failed: \(error.localizedDescription). Check the internet connection and try again.") }
            }
        }
    }

    func lookup(_ word: String) -> [WordEntry] { dictionary?.lookup(word) ?? [] }
    func suggestions(_ prefix: String) -> [String] { dictionary?.suggestions(prefix: prefix, limit: 10) ?? [] }

    private static func fetch(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(PresentationKitError.network("No response"))
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error { result = .failure(error) }
            else if let data, (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 { result = .success(data) }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }

    /// .gz → raw bytes (Apple's Compression framework inflates the DEFLATE stream inside the gzip wrapper).
    static func gunzip(_ data: Data) throws -> Data {
        let b = [UInt8](data.prefix(512))
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw PresentationKitError.sqlite("not a gzip file") }
        let flags = b[3]
        var pos = 10
        if flags & 0x04 != 0 { pos += 2 + (Int(b[pos]) | Int(b[pos + 1]) << 8) }
        if flags & 0x08 != 0 { while pos < b.count && b[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 0x10 != 0 { while pos < b.count && b[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 0x02 != 0 { pos += 2 }
        let deflated = data.subdata(in: (data.startIndex + pos)..<(data.endIndex - 8)) as NSData
        return try deflated.decompressed(using: .zlib) as Data
    }
}
