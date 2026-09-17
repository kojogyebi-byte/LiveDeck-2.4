import Foundation

public protocol LibraryDocument: Codable, Identifiable, Sendable where ID == UUID {
    var meta: LibraryMeta { get set }
    var searchText: String { get }
    static var folderName: String { get }
}

extension Song: LibraryDocument { public static var folderName: String { "Songs" } }
extension Presentation: LibraryDocument {
    public static var folderName: String { "Presentations" }
    public var searchText: String { ([meta.title] + meta.tags + slides.map { $0.plainText }).joined(separator: " ").searchFolded }
}
extension ServicePlan: LibraryDocument {
    public static var folderName: String { "Services" }
    public var searchText: String { ([meta.title] + items.map { $0.title }).joined(separator: " ").searchFolded }
}

/// One JSON file per document, atomic writes, automatic version snapshots, soft delete.
/// All documents are held in memory: a song is ~3 KB, so 5,000 songs ≈ 15 MB.
public final class DocumentStore<Doc: LibraryDocument> {
    public let directory: URL
    private let versionsDir: URL
    private let trashDir: URL
    private let damagedDir: URL
    public private(set) var items: [UUID: Doc] = [:]
    /// Files that could not be read at load (moved to Damaged/, never deleted).
    public private(set) var damaged: [String] = []

    public var versionInterval: TimeInterval = 300    // at most one snapshot per 5 minutes per document
    public var maxVersions = 30

    public init(libraryRoot: URL) {
        directory = libraryRoot.appendingPathComponent(Doc.folderName)
        versionsDir = libraryRoot.appendingPathComponent("Versions").appendingPathComponent(Doc.folderName)
        trashDir = libraryRoot.appendingPathComponent("Trash").appendingPathComponent(Doc.folderName)
        damagedDir = libraryRoot.appendingPathComponent("Damaged").appendingPathComponent(Doc.folderName)
        for d in [directory, versionsDir, trashDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        reload()
    }

    public func reload() {
        items = [:]; damaged = []
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            if let doc = try? JSONFile.read(Doc.self, from: f) { items[doc.id] = doc }
            else {
                damaged.append(f.lastPathComponent)
                try? FileManager.default.createDirectory(at: damagedDir, withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: f, to: damagedDir.appendingPathComponent(f.lastPathComponent + "-\(Int(Date().timeIntervalSince1970))"))
            }
        }
    }

    func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }

    public var all: [Doc] {
        items.values.sorted { $0.meta.title.localizedCaseInsensitiveCompare($1.meta.title) == .orderedAscending }
    }

    public subscript(id: UUID) -> Doc? { items[id] }

    @discardableResult
    public func save(_ doc: Doc, touch: Bool = true, snapshot: Bool = true) throws -> Doc {
        var d = doc
        if touch { d.meta.modified = Date() }
        let file = url(d.id)
        if snapshot { snapshotIfDue(d.id, file) }
        try JSONFile.write(d, to: file)
        items[d.id] = d
        return d
    }

    private func snapshotIfDue(_ id: UUID, _ file: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return }
        let dir = versionsDir.appendingPathComponent(id.uuidString)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = versionFiles(dir)
        if let newest = existing.first, let date = Self.versionDate(newest), Date().timeIntervalSince(date) < versionInterval { return }
        let stamp = Self.stampFormatter.string(from: Date())
        var target = dir.appendingPathComponent(stamp + ".json"), n = 2
        while fm.fileExists(atPath: target.path) { target = dir.appendingPathComponent("\(stamp)-\(n).json"); n += 1 }
        try? fm.copyItem(at: file, to: target)
        for old in versionFiles(dir).dropFirst(maxVersions) { try? fm.removeItem(at: old) }
    }

    static var stampFormatter: DateFormatter { VersionStamp.formatter }
    static func versionDate(_ url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        return stampFormatter.date(from: String(name.split(separator: "-").first ?? Substring(name)))
    }

    private func versionFiles(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest first
    }

    /// Previous versions, newest first.
    public func versions(of id: UUID) -> [(date: Date, url: URL)] {
        versionFiles(versionsDir.appendingPathComponent(id.uuidString)).compactMap { u in Self.versionDate(u).map { ($0, u) } }
    }

    @discardableResult
    public func restoreVersion(_ versionURL: URL) throws -> Doc {
        let old = try JSONFile.read(Doc.self, from: versionURL)
        let previous = versionInterval
        versionInterval = 0; defer { versionInterval = previous }
        return try save(old)          // current state is snapshotted first, so restore is undoable
    }

    @discardableResult
    public func duplicate(_ id: UUID) throws -> Doc? {
        guard let d = items[id] else { return nil }
        var c = try Self.withNewID(d)
        c.meta.title = d.meta.title + " copy"
        c.meta.created = Date(); c.meta.favorite = false
        return try save(c)
    }

    /// Re-encode with a fresh id (ids are `let`-like in the JSON; rewrite the key).
    static func withNewID(_ d: Doc) throws -> Doc {
        var obj = try JSONSerialization.jsonObject(with: JSONFile.encoder.encode(d)) as? [String: Any] ?? [:]
        obj["id"] = UUID().uuidString
        return try JSONFile.decoder.decode(Doc.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    public func rename(_ id: UUID, to title: String) throws {
        guard var d = items[id] else { return }
        d.meta.title = title.trimmed.isEmpty ? d.meta.title : title.trimmed
        try save(d)
    }

    public func setFavorite(_ id: UUID, _ fav: Bool) throws {
        guard var d = items[id] else { return }
        d.meta.favorite = fav
        try save(d, touch: false, snapshot: false)
    }

    public func setFolder(_ id: UUID, _ folder: String) throws {
        guard var d = items[id] else { return }
        d.meta.folder = folder.trimmed
        try save(d, touch: false, snapshot: false)
    }

    public func setTags(_ id: UUID, _ tags: [String]) throws {
        guard var d = items[id] else { return }
        d.meta.tags = Array(Set(tags.map { $0.trimmed }.filter { !$0.isEmpty })).sorted()
        try save(d, touch: false, snapshot: false)
    }

    public func markOpened(_ id: UUID) {
        guard var d = items[id] else { return }
        d.meta.lastOpened = Date()
        _ = try? save(d, touch: false, snapshot: false)
    }

    /// Soft delete → Trash/ (restorable).
    public func delete(_ id: UUID) throws {
        let fm = FileManager.default
        let src = url(id)
        let dst = trashDir.appendingPathComponent(id.uuidString + ".json")
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        if fm.fileExists(atPath: src.path) { try fm.moveItem(at: src, to: dst) }
        items[id] = nil
    }

    public var trashed: [Doc] {
        ((try? FileManager.default.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? JSONFile.read(Doc.self, from: $0) }
    }

    public func restoreFromTrash(_ id: UUID) throws {
        let src = trashDir.appendingPathComponent(id.uuidString + ".json")
        let doc = try JSONFile.read(Doc.self, from: src)
        try save(doc, touch: false)
        try FileManager.default.removeItem(at: src)
    }

    public var folders: [String] { Array(Set(items.values.map { $0.meta.folder }.filter { !$0.isEmpty })).sorted() }

    public func recent(_ limit: Int = 10) -> [Doc] {
        items.values.filter { $0.meta.lastOpened != nil }
            .sorted { ($0.meta.lastOpened ?? .distantPast) > ($1.meta.lastOpened ?? .distantPast) }
            .prefix(limit).map { $0 }
    }

    /// Every word must match (title, author, tags, lyrics…). Title matches rank first.
    public func search(_ query: String, folder: String? = nil, favoritesOnly: Bool = false, tag: String? = nil) -> [Doc] {
        let words = query.searchFolded.split(separator: " ").map(String.init)
        return all.filter { d in
            if favoritesOnly && !d.meta.favorite { return false }
            if let f = folder, !f.isEmpty, d.meta.folder != f && !d.meta.folder.hasPrefix(f + "/") { return false }
            if let t = tag, !d.meta.tags.contains(t) { return false }
            if words.isEmpty { return true }
            let hay = d.searchText
            return words.allSatisfy { hay.contains($0) }
        }.sorted { a, b in
            let at = words.allSatisfy { a.meta.title.searchFolded.contains($0) }
            let bt = words.allSatisfy { b.meta.title.searchFolded.contains($0) }
            if at != bt { return at }
            return a.meta.title.localizedCaseInsensitiveCompare(b.meta.title) == .orderedAscending
        }
    }
}

enum VersionStamp {
    static let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss.SSS"; return f
    }()
}

/// The whole presentation library on disk.
public final class PresentationLibrary {
    public let root: URL
    public let songs: DocumentStore<Song>
    public let presentations: DocumentStore<Presentation>
    public let services: DocumentStore<ServicePlan>
    public let bibles: BibleLibrary

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        songs = DocumentStore(libraryRoot: root)
        presentations = DocumentStore(libraryRoot: root)
        services = DocumentStore(libraryRoot: root)
        bibles = BibleLibrary(directory: root.appendingPathComponent("Bibles"))
    }

    /// ~/Library/Application Support/LiveDeck/Library
    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LiveDeck").appendingPathComponent("Library")
    }
}
