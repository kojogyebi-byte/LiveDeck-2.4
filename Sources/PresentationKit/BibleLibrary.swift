import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Free Use Bible API (bible.helloao.org) — 1000+ translations, no key, no usage restrictions

public struct CatalogTranslation: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var englishName: String?
    public var shortName: String?
    public var language: String?
    public var languageName: String?
    public var languageEnglishName: String?
    public var licenseUrl: String?
    public var website: String?
    public var textDirection: String?
    public var numberOfBooks: Int?
    public var totalNumberOfVerses: Int?

    public var displayName: String { englishName.flatMap { $0 != name ? "\(name) — \($0)" : nil } ?? name }
    public var languageLabel: String { languageEnglishName ?? languageName ?? language ?? "" }
    public var isComplete: Bool { (numberOfBooks ?? 0) >= 66 }
    public var searchText: String { [id, name, englishName ?? "", shortName ?? "", languageLabel, languageName ?? "", language ?? ""].joined(separator: " ").searchFolded }
}

public enum FreeUseBibleAPI {
    public static let base = URL(string: "https://bible.helloao.org/api/")!
    public static let sourceName = "Free Use Bible API (bible.helloao.org)"

    struct Catalog: Decodable { let translations: [CatalogTranslation] }

    public static func fetchCatalog(completion: @escaping (Result<[CatalogTranslation], Error>) -> Void) {
        let url = base.appendingPathComponent("available_translations.json")
        URLSession.shared.dataTask(with: url) { data, resp, err in
            if let err { completion(.failure(PresentationKitError.network(err.localizedDescription))); return }
            guard let data, (resp as? HTTPURLResponse)?.statusCode ?? 200 == 200 else {
                completion(.failure(PresentationKitError.network("no catalogue data"))); return
            }
            do {
                let list = try JSONDecoder().decode(Catalog.self, from: data).translations
                completion(.success(list.sorted { ($0.languageLabel, $0.name) < ($1.languageLabel, $1.name) }))
            } catch { completion(.failure(PresentationKitError.badFormat("catalogue: \(error.localizedDescription)"))) }
        }.resume()
    }

    /// Downloads `complete.simple.json` to disk (not memory) and converts it to a `.ldbible`.
    public static func install(_ t: CatalogTranslation, into directory: URL, phase: @escaping (String) -> Void,
                               completion: @escaping (Result<BibleVersionInfo, Error>) -> Void) -> URLSessionDownloadTask {
        let url = base.appendingPathComponent(t.id).appendingPathComponent("complete.simple.json")
        phase("Downloading \(t.shortName ?? t.id)…")
        let task = URLSession.shared.downloadTask(with: url) { tmp, resp, err in
            if let err { completion(.failure(PresentationKitError.network(err.localizedDescription))); return }
            guard let tmp, (resp as? HTTPURLResponse)?.statusCode ?? 200 == 200 else {
                completion(.failure(PresentationKitError.network("download failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))"))); return
            }
            // The temp file is deleted when this handler returns — move it first.
            let kept = directory.appendingPathComponent(".dl-\(UUID().uuidString).json")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: tmp, to: kept)
            } catch { completion(.failure(error)); return }
            DispatchQueue.global(qos: .utility).async {
                defer { try? FileManager.default.removeItem(at: kept) }
                phase("Installing \(t.shortName ?? t.id)…")
                do {
                    let info = BibleVersionInfo(
                        id: BibleLibrary.sanitize(t.id), name: t.displayName, abbreviation: t.shortName ?? t.id,
                        language: t.language ?? "", languageName: t.languageLabel,
                        license: t.licenseUrl ?? "", source: sourceName, rightToLeft: t.textDirection == "rtl")
                    completion(.success(try convertComplete(fileURL: kept, into: directory, overrideInfo: info)))
                } catch { completion(.failure(error)) }
            }
        }
        task.resume()
        return task
    }

    struct Complete: Decodable {
        let translation: CatalogTranslation?
        let books: [Book]
        struct Book: Decodable { let id: String; let name: String?; let commonName: String?; let chapters: [ChapterWrap] }
        struct ChapterWrap: Decodable { let chapter: Chapter }
        struct Chapter: Decodable { let number: Int; let content: [Item] }
        struct Item: Decodable { let type: String; let number: Int?; let text: String? }
    }

    public static func convertComplete(fileURL: URL, into directory: URL, overrideInfo: BibleVersionInfo? = nil) throws -> BibleVersionInfo {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let complete: Complete
        do { complete = try JSONDecoder().decode(Complete.self, from: data) }
        catch { throw PresentationKitError.badFormat("Bible JSON: \(error.localizedDescription)") }
        var info = overrideInfo ?? BibleVersionInfo(id: "user-bible", name: "Bible", abbreviation: "BIBLE")
        if overrideInfo?.source.hasSuffix("file") == true, let t = complete.translation {
            info.name = t.displayName; info.abbreviation = t.shortName ?? t.id
            info.language = t.language ?? ""; info.languageName = t.languageLabel; info.license = t.licenseUrl ?? info.license
        }
        let w = try BibleWriter(info: info, destination: BibleLibrary.fileURL(info.id, in: directory))
        for b in complete.books {
            guard let book = BibleBookInfo.byCode(b.id)?.number else { continue }   // apocrypha skipped
            w.setBookName(book, b.name ?? b.commonName ?? "")
            for ch in b.chapters {
                for item in ch.chapter.content where item.type == "verse" {
                    if let n = item.number, let text = item.text { w.add(book: book, chapter: ch.chapter.number, verse: n, text: text) }
                }
            }
        }
        return try w.finish()
    }
}

// MARK: - Installed Bibles

public final class BibleLibrary {
    public let directory: URL
    private var cache: [String: BibleStore] = [:]

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static let fileExtension = "ldbible"

    public static func fileURL(_ id: String, in dir: URL) -> URL {
        dir.appendingPathComponent(sanitize(id)).appendingPathExtension(fileExtension)
    }

    public static func sanitize(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let s = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return s.isEmpty ? "bible" : String(s.prefix(60))
    }

    public static func uniqueID(for base: String, in dir: URL) -> String {
        var id = sanitize(base), n = 2
        while FileManager.default.fileExists(atPath: fileURL(id, in: dir).path) { id = sanitize(base) + "-\(n)"; n += 1 }
        return id
    }

    /// Copies a ready-made .ldbible file into the library (keeping its id unless it is taken).
    public static func installPackage(_ url: URL, into directory: URL) throws -> BibleVersionInfo {
        var info = try BibleStore(url: url).info
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let installed = BibleLibrary(directory: directory).installed()
        if installed.contains(where: { $0.name == info.name && $0.abbreviation == info.abbreviation && $0.verseCount == info.verseCount }) {
            throw PresentationKitError.badFormat("\(info.abbreviation) is already installed")
        }
        let newID = fm.fileExists(atPath: fileURL(info.id, in: directory).path) ? uniqueID(for: info.id, in: directory) : sanitize(info.id)
        let dest = fileURL(newID, in: directory)
        try fm.copyItem(at: url, to: dest)
        if newID != info.id {
            let db = try SQLiteDB(path: dest.path)
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('id', ?)", [.text(newID)])
            db.close()
            info.id = newID
        }
        return info
    }

    /// Installed versions (reads only the small meta table of each file).
    public func installed() -> [BibleVersionInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == BibleLibrary.fileExtension }
            .compactMap { try? BibleStore(url: $0).info }
            .sorted { $0.abbreviation.localizedCaseInsensitiveCompare($1.abbreviation) == .orderedAscending }
    }

    public func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: BibleLibrary.fileURL(id, in: directory).path)
    }

    public func store(_ id: String) -> BibleStore? {
        if let s = cache[id] { return s }
        guard let s = try? BibleStore(url: BibleLibrary.fileURL(id, in: directory)) else { return nil }
        if cache.count >= 4 { cache.removeAll() }      // keep memory low: only a few open at once
        cache[id] = s
        return s
    }

    public func remove(_ id: String) throws {
        cache[id] = nil
        try FileManager.default.removeItem(at: BibleLibrary.fileURL(id, in: directory))
    }

    /// Rename a version's display name / abbreviation.
    public func rename(_ id: String, name: String, abbreviation: String) throws {
        cache[id] = nil
        let db = try SQLiteDB(path: BibleLibrary.fileURL(id, in: directory).path)
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('name', ?)", [.text(name)])
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('abbreviation', ?)", [.text(abbreviation)])
    }
}
