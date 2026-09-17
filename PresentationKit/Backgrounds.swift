import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Royalty-free background library
//
//  • NASA Image and Video Library (images-api.nasa.gov) — public domain, no key.
//  • Pixabay videos (pixabay.com/api/videos) — free to use under the Pixabay Content License; needs a free API key.
//  • Pexels videos (api.pexels.com/videos) — free to use under the Pexels License; needs a free API key.

public enum BackgroundProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case nasa = "NASA (public domain)"
    case pixabay = "Pixabay"
    case pexels = "Pexels"
    public var id: String { rawValue }
    public var needsKey: Bool { self != .nasa }
    public var keySignupURL: URL? {
        switch self {
        case .nasa: return nil
        case .pixabay: return URL(string: "https://pixabay.com/api/docs/")
        case .pexels: return URL(string: "https://www.pexels.com/api/")
        }
    }
    public var license: String {
        switch self {
        case .nasa: return "Public domain (NASA media guidelines)"
        case .pixabay: return "Pixabay Content License"
        case .pexels: return "Pexels License"
        }
    }
}

public enum MediaKind: String, Codable, Sendable { case image, video }

public struct BackgroundItem: Codable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var kind: MediaKind
    public var thumbnailURL: URL?
    public var downloadURL: URL?          // chosen file (≤ 1920 px wide when possible)
    public var assetManifestID: String?   // NASA: resolve download URL later
    public var width: Int
    public var height: Int
    public var duration: Double
    public var sizeBytes: Int64
    public var credit: String
    public var license: String
    public var provider: String
    public var pageURL: URL?

    public init(id: String, title: String, kind: MediaKind, thumbnailURL: URL?, downloadURL: URL?, assetManifestID: String? = nil,
                width: Int = 0, height: Int = 0, duration: Double = 0, sizeBytes: Int64 = 0, credit: String = "", license: String, provider: String,
                pageURL: URL? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.thumbnailURL = thumbnailURL; self.downloadURL = downloadURL
        self.assetManifestID = assetManifestID; self.width = width; self.height = height; self.duration = duration
        self.sizeBytes = sizeBytes; self.credit = credit; self.license = license; self.provider = provider; self.pageURL = pageURL
    }
}

public enum BackgroundSearch {
    static func q(_ s: String) -> String {
        s.trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
    }

    public static func searchURL(_ p: BackgroundProvider, query: String, videos: Bool = true, key: String = "", page: Int = 1) -> URL? {
        let text = query.trimmed
        guard !text.isEmpty else { return nil }
        switch p {
        case .nasa:
            return URL(string: "https://images-api.nasa.gov/search?q=\(q(text))&media_type=\(videos ? "video" : "image")&page=\(max(1, page))")
        case .pixabay:
            guard !key.trimmed.isEmpty else { return nil }
            return URL(string: "https://pixabay.com/api/\(videos ? "videos/" : "")?key=\(q(key))&q=\(q(text))&per_page=30&page=\(max(1, page))&safesearch=true"
                       + (videos ? "" : "&image_type=photo&orientation=horizontal"))
        case .pexels:
            return URL(string: videos ? "https://api.pexels.com/videos/search?query=\(q(text))&per_page=30&page=\(max(1, page))&orientation=landscape"
                                      : "https://api.pexels.com/v1/search?query=\(q(text))&per_page=30&page=\(max(1, page))&orientation=landscape")
        }
    }

    // MARK: parsers

    public static func parseNASASearch(_ data: Data) -> [BackgroundItem] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let coll = obj["collection"] as? [String: Any], let items = coll["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { it in
            guard let d = (it["data"] as? [[String: Any]])?.first, let nasaID = d["nasa_id"] as? String else { return nil }
            let kind: MediaKind = (d["media_type"] as? String) == "image" ? .image : .video
            let links = it["links"] as? [[String: Any]] ?? []
            let thumb = links.compactMap { $0["href"] as? String }.first { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.flatMap(URL.init(string:))
            return BackgroundItem(id: "nasa-" + nasaID, title: d["title"] as? String ?? nasaID, kind: kind, thumbnailURL: thumb,
                                  downloadURL: nil, assetManifestID: nasaID, credit: (d["center"] as? String).map { "NASA \($0)" } ?? "NASA",
                                  license: BackgroundProvider.nasa.license, provider: "NASA",
                                  pageURL: URL(string: "https://images.nasa.gov/details/\(nasaID)"))
        }
    }

    public static func nasaAssetURL(_ nasaID: String) -> URL? {
        let id = nasaID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nasaID
        return URL(string: "https://images-api.nasa.gov/asset/\(id)")
    }

    /// Picks the best playable file from a NASA asset manifest: medium/large mp4 for video, large/orig jpg for images.
    public static func parseNASAAsset(_ data: Data, kind: MediaKind) -> URL? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let coll = obj["collection"] as? [String: Any], let items = coll["items"] as? [[String: Any]] else { return nil }
        let hrefs = items.compactMap { $0["href"] as? String }.map { $0.replacingOccurrences(of: "http://", with: "https://") }
        let order: [String] = kind == .video
            ? ["~large.mp4", "~medium.mp4", "~orig.mp4", "~mobile.mp4", "~small.mp4", ".mp4", ".mov"]
            : ["~large.jpg", "~orig.jpg", "~medium.jpg", ".jpg", ".png"]
        for suffix in order {
            if let h = hrefs.first(where: { $0.lowercased().hasSuffix(suffix) }), let u = URL(string: h.replacingOccurrences(of: " ", with: "%20")) { return u }
        }
        return nil
    }

    public static func parsePixabay(_ data: Data, videos: Bool) -> [BackgroundItem] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = obj["hits"] as? [[String: Any]] else { return [] }
        return hits.compactMap { h in
            let id = h["id"].map { "\($0)" } ?? UUID().uuidString
            let tags = (h["tags"] as? String ?? "").capitalized
            let credit = h["user"] as? String ?? ""
            let page = (h["pageURL"] as? String).flatMap(URL.init(string:))
            if videos {
                guard let v = h["videos"] as? [String: Any] else { return nil }
                var pick: [String: Any]?
                for name in ["large", "medium", "small"] {
                    guard let f = v[name] as? [String: Any] else { continue }
                    let urlText: String = (f["url"] as? String) ?? ""
                    let w: Int = (f["width"] as? Int) ?? 0
                    if !urlText.isEmpty && w <= 1920 { pick = f; break }
                }
                guard let f = pick, let urlText = f["url"] as? String, let u = URL(string: urlText) else { return nil }
                let thumbText: String = (f["thumbnail"] as? String) ?? ""
                let w: Int = (f["width"] as? Int) ?? 0
                let hgt: Int = (f["height"] as? Int) ?? 0
                let dur: Int = (h["duration"] as? Int) ?? 0
                let size: Int = (f["size"] as? Int) ?? 0
                let title: String = tags.isEmpty ? "Pixabay video" : tags
                return BackgroundItem(id: "pixabay-v-" + id, title: title, kind: .video,
                                      thumbnailURL: URL(string: thumbText), downloadURL: u,
                                      width: w, height: hgt, duration: Double(dur), sizeBytes: Int64(size),
                                      credit: credit, license: BackgroundProvider.pixabay.license, provider: "Pixabay", pageURL: page)
            } else {
                let largeText: String = (h["largeImageURL"] as? String) ?? ((h["webformatURL"] as? String) ?? "")
                guard let u = URL(string: largeText) else { return nil }
                let thumbText: String = (h["webformatURL"] as? String) ?? ""
                let w: Int = (h["imageWidth"] as? Int) ?? 0
                let hgt: Int = (h["imageHeight"] as? Int) ?? 0
                let title: String = tags.isEmpty ? "Pixabay image" : tags
                return BackgroundItem(id: "pixabay-i-" + id, title: title, kind: .image,
                                      thumbnailURL: URL(string: thumbText), downloadURL: u, width: w, height: hgt,
                                      credit: credit, license: BackgroundProvider.pixabay.license, provider: "Pixabay", pageURL: page)
            }
        }
    }

    public static func parsePexels(_ data: Data, videos: Bool) -> [BackgroundItem] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if videos {
            let list = obj["videos"] as? [[String: Any]] ?? []
            return list.compactMap { v in
                let id = v["id"].map { "\($0)" } ?? UUID().uuidString
                let all: [[String: Any]] = (v["video_files"] as? [[String: Any]]) ?? []
                var files: [(w: Int, h: Int, link: String)] = []
                for f in all {
                    let type: String = (f["file_type"] as? String) ?? ""
                    let link: String = (f["link"] as? String) ?? ""
                    let w: Int = (f["width"] as? Int) ?? 0
                    let hh: Int = (f["height"] as? Int) ?? 0
                    if type == "video/mp4" && !link.isEmpty { files.append((w, hh, link)) }
                }
                files.sort { $0.w > $1.w }
                guard let f = files.first(where: { $0.w <= 1920 }) ?? files.last, let u = URL(string: f.link) else { return nil }
                let userObj: [String: Any] = (v["user"] as? [String: Any]) ?? [:]
                let user: String = (userObj["name"] as? String) ?? ""
                let imageText: String = (v["image"] as? String) ?? ""
                let pageText: String = (v["url"] as? String) ?? ""
                let dur: Int = (v["duration"] as? Int) ?? 0
                return BackgroundItem(id: "pexels-v-" + id, title: "Pexels video \(id)", kind: .video,
                                      thumbnailURL: URL(string: imageText), downloadURL: u, width: f.w, height: f.h,
                                      duration: Double(dur), credit: user,
                                      license: BackgroundProvider.pexels.license, provider: "Pexels", pageURL: URL(string: pageText))
            }
        } else {
            let list = obj["photos"] as? [[String: Any]] ?? []
            return list.compactMap { p in
                let id = p["id"].map { "\($0)" } ?? UUID().uuidString
                let src: [String: Any] = (p["src"] as? [String: Any]) ?? [:]
                let bigText: String = (src["large2x"] as? String) ?? ((src["original"] as? String) ?? "")
                guard let u = URL(string: bigText) else { return nil }
                let alt: String = (p["alt"] as? String) ?? ""
                let title: String = alt.isEmpty ? "Pexels photo \(id)" : alt
                let thumbText: String = (src["medium"] as? String) ?? ""
                let w: Int = (p["width"] as? Int) ?? 0
                let hh: Int = (p["height"] as? Int) ?? 0
                let credit: String = (p["photographer"] as? String) ?? ""
                let pageText: String = (p["url"] as? String) ?? ""
                return BackgroundItem(id: "pexels-i-" + id, title: title, kind: .image, thumbnailURL: URL(string: thumbText), downloadURL: u,
                                      width: w, height: hh, credit: credit, license: BackgroundProvider.pexels.license, provider: "Pexels",
                                      pageURL: URL(string: pageText))
            }
        }
    }

    // MARK: network

    static func get(_ url: URL, headers: [String: String] = [:], completion: @escaping (Result<Data, Error>) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue("LiveDeckStudio/4.4 (macOS)", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(PresentationKitError.network(err.localizedDescription))); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { completion(.failure(PresentationKitError.network("the API key was refused"))); return }
            if status == 429 { completion(.failure(PresentationKitError.network("too many requests — wait a minute"))); return }
            guard let data, status < 400 else { completion(.failure(PresentationKitError.network("server returned \(status)"))); return }
            completion(.success(data))
        }.resume()
    }

    public static func search(_ p: BackgroundProvider, query: String, videos: Bool, key: String, page: Int = 1,
                              completion: @escaping (Result<[BackgroundItem], Error>) -> Void) {
        if p.needsKey && key.trimmed.isEmpty {
            completion(.failure(PresentationKitError.badFormat("\(p.rawValue) needs a free API key — paste it in the key box"))); return
        }
        guard let u = searchURL(p, query: query, videos: videos, key: key, page: page) else { completion(.success([])); return }
        let headers = p == .pexels ? ["Authorization": key.trimmed] : [:]
        get(u, headers: headers) { r in
            switch r {
            case .failure(let e): completion(.failure(e))
            case .success(let data):
                switch p {
                case .nasa: completion(.success(parseNASASearch(data)))
                case .pixabay: completion(.success(parsePixabay(data, videos: videos)))
                case .pexels: completion(.success(parsePexels(data, videos: videos)))
                }
            }
        }
    }

    /// Resolves the file URL (NASA needs a second request) and downloads it into `folder`.
    public static func download(_ item: BackgroundItem, into folder: URL,
                                completion: @escaping (Result<URL, Error>) -> Void) {
        func fetch(_ u: URL) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var ext = u.pathExtension.lowercased()
            if ext.isEmpty { ext = item.kind == .video ? "mp4" : "jpg" }
            let safe = String(item.id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
            let dest = folder.appendingPathComponent(safe + "." + ext)
            if FileManager.default.fileExists(atPath: dest.path) { completion(.success(dest)); return }
            var req = URLRequest(url: u, timeoutInterval: 300)
            req.setValue("LiveDeckStudio/4.4 (macOS)", forHTTPHeaderField: "User-Agent")
            URLSession.shared.downloadTask(with: req) { tmp, resp, err in
                if let err { completion(.failure(PresentationKitError.network(err.localizedDescription))); return }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
                guard let tmp, status < 400 else { completion(.failure(PresentationKitError.network("download failed (\(status))"))); return }
                do { try? FileManager.default.removeItem(at: dest); try FileManager.default.moveItem(at: tmp, to: dest); completion(.success(dest)) }
                catch { completion(.failure(error)) }
            }.resume()
        }
        if let u = item.downloadURL { fetch(u); return }
        guard let nasaID = item.assetManifestID, let manifest = nasaAssetURL(nasaID) else {
            completion(.failure(PresentationKitError.badFormat("no downloadable file"))); return
        }
        get(manifest) { r in
            switch r {
            case .failure(let e): completion(.failure(e))
            case .success(let data):
                if let u = parseNASAAsset(data, kind: item.kind) { fetch(u) }
                else { completion(.failure(PresentationKitError.badFormat("NASA did not list a playable file for this item"))) }
            }
        }
    }

    /// First-install starter pack: searches that give calm, wide worship-friendly backgrounds.
    public static let starterQueries: [(provider: BackgroundProvider, query: String, videos: Bool, take: Int)] = [
        (.nasa, "earth from space", true, 2),
        (.nasa, "clouds", true, 1),
        (.nasa, "nebula", false, 2),
        (.nasa, "aurora", false, 2),
        (.nasa, "sunrise", false, 1)
    ]
}

// MARK: - Local background library

public struct LocalBackground: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var kind: MediaKind
    public var fileName: String          // inside the library folder
    public var category: String          // "Downloaded", "Generated", "Imported"
    public var credit: String
    public var license: String
    public var provider: String
    public var added: Date
    public var favorite: Bool

    public init(id: String, title: String, kind: MediaKind, fileName: String, category: String, credit: String = "",
                license: String = "", provider: String = "", added: Date = Date(), favorite: Bool = false) {
        self.id = id; self.title = title; self.kind = kind; self.fileName = fileName; self.category = category
        self.credit = credit; self.license = license; self.provider = provider; self.added = added; self.favorite = favorite
    }
}


public final class BackgroundCatalog {
    public let folder: URL
    public private(set) var items: [LocalBackground] = []
    private var indexURL: URL { folder.appendingPathComponent("catalog.json") }

    public init(libraryRoot: URL) {
        folder = libraryRoot.appendingPathComponent("Backgrounds")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        items = (try? JSONFile.read([LocalBackground].self, from: indexURL)) ?? []
        items.removeAll { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
    }

    public func url(_ item: LocalBackground) -> URL { folder.appendingPathComponent(item.fileName) }
    public func contains(_ id: String) -> Bool { items.contains { $0.id == id } }

    @discardableResult
    public func add(file: URL, id: String, title: String, kind: MediaKind, category: String,
                    credit: String = "", license: String = "", provider: String = "") throws -> LocalBackground {
        var name = file.lastPathComponent
        if file.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
            let dest = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) {
                name = UUID().uuidString.prefix(8) + "-" + name
            }
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(name))
        }
        let item = LocalBackground(id: id, title: title, kind: kind, fileName: name, category: category,
                                   credit: credit, license: license, provider: provider)
        items.removeAll { $0.id == id }
        items.insert(item, at: 0)
        try save()
        return item
    }

    public func remove(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: url(items[i]))
        items.remove(at: i)
        try? save()
    }

    public func setFavorite(_ id: String, _ on: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].favorite = on
        try? save()
    }

    public func save() throws { try JSONFile.write(items, to: indexURL) }
}

// MARK: - Generated backgrounds & effects (settings only; drawing lives in the app)

public enum GeneratorStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    // backgrounds
    case gradientFlow = "Gradient flow"
    case aurora = "Aurora"
    case bokeh = "Bokeh lights"
    case lightRays = "Light rays"
    case starfield = "Starfield"
    case waves = "Waves"
    case rings = "Pulse rings"
    case grid = "Neon grid"
    // effects (transparent, for keying)
    case particles = "Rising particles"
    case snow = "Snow"
    case confetti = "Confetti"
    case sparkles = "Sparkles"
    case lightLeak = "Light leak"
    case vignette = "Vignette"
    public var id: String { rawValue }
    public var isEffect: Bool { [.particles, .snow, .confetti, .sparkles, .lightLeak, .vignette].contains(self) }
}

public struct GeneratorSettings: Codable, Hashable, Sendable {
    public var style: GeneratorStyle
    public var colors: [RGBAColor]        // 3 colours
    public var background: RGBAColor      // backgrounds only
    public var transparent: Bool          // effects draw over nothing (key them over Program)
    public var speed: Double              // 0.1 … 3
    public var density: Double            // 0 … 1
    public var size: Double               // 0.2 … 3
    public var softness: Double           // 0 … 1
    public var loopSeconds: Double        // motion repeats exactly after this long
    public var seed: Int

    public init(style: GeneratorStyle = .gradientFlow,
                colors: [RGBAColor] = [RGBAColor(0.10, 0.25, 0.75), RGBAColor(0.45, 0.10, 0.65), RGBAColor(0.05, 0.55, 0.75)],
                background: RGBAColor = RGBAColor(0.02, 0.03, 0.08), transparent: Bool = false,
                speed: Double = 1, density: Double = 0.5, size: Double = 1, softness: Double = 0.6, loopSeconds: Double = 20, seed: Int = 7) {
        self.style = style; self.colors = colors; self.background = background; self.transparent = transparent
        self.speed = speed; self.density = density; self.size = size; self.softness = softness; self.loopSeconds = loopSeconds; self.seed = seed
    }

    enum CodingKeys: String, CodingKey { case style, colors, background, transparent, speed, density, size, softness, loopSeconds, seed }
    public init(from decoder: Decoder) throws {
        let d = GeneratorSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = c.value(.style, d.style); colors = c.value(.colors, d.colors); background = c.value(.background, d.background)
        transparent = c.value(.transparent, d.transparent); speed = c.value(.speed, d.speed); density = c.value(.density, d.density)
        size = c.value(.size, d.size); softness = c.value(.softness, d.softness); loopSeconds = c.value(.loopSeconds, d.loopSeconds)
        seed = c.value(.seed, d.seed)
        while colors.count < 3 { colors.append(d.colors[colors.count]) }
    }

    /// Colour i (wrapping).
    public func color(_ i: Int) -> RGBAColor { colors.isEmpty ? .white : colors[((i % colors.count) + colors.count) % colors.count] }

    /// Seeded pseudo-random in 0..<1 — the same inputs always give the same value, so loops are exact.
    public static func hash(_ i: Int, _ salt: Int, _ seed: Int) -> Double {
        var x = UInt64(bitPattern: Int64(i &* 73856093 ^ salt &* 19349663 ^ seed &* 83492791))
        x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33; x = x &* 0xc4ceb9fe1a85ec53; x ^= x >> 33
        return Double(x % 1_000_000) / 1_000_000
    }

    public static let presets: [(name: String, settings: GeneratorSettings)] = [
        ("Worship blue", GeneratorSettings(style: .gradientFlow)),
        ("Royal aurora", GeneratorSettings(style: .aurora, colors: [RGBAColor(0.35, 0.10, 0.70), RGBAColor(0.10, 0.60, 0.80), RGBAColor(0.80, 0.20, 0.60)])),
        ("Golden bokeh", GeneratorSettings(style: .bokeh, colors: [RGBAColor(1, 0.75, 0.30), RGBAColor(1, 0.55, 0.20), RGBAColor(1, 0.90, 0.60)],
                                           background: RGBAColor(0.08, 0.04, 0.02))),
        ("Heaven rays", GeneratorSettings(style: .lightRays, colors: [RGBAColor(1, 0.95, 0.80), RGBAColor(0.70, 0.80, 1), RGBAColor(1, 1, 1)],
                                          background: RGBAColor(0.05, 0.08, 0.18), speed: 0.6)),
        ("Night sky", GeneratorSettings(style: .starfield, colors: [RGBAColor(1, 1, 1), RGBAColor(0.70, 0.80, 1), RGBAColor(1, 0.90, 0.80)],
                                        background: RGBAColor(0.01, 0.01, 0.04))),
        ("Ocean waves", GeneratorSettings(style: .waves, colors: [RGBAColor(0.05, 0.35, 0.65), RGBAColor(0.10, 0.55, 0.75), RGBAColor(0.20, 0.75, 0.85)],
                                          background: RGBAColor(0.01, 0.06, 0.14))),
        ("Pulse", GeneratorSettings(style: .rings, colors: [RGBAColor(0.90, 0.20, 0.35), RGBAColor(0.40, 0.20, 0.80), RGBAColor(0.10, 0.50, 0.90)])),
        ("Neon grid", GeneratorSettings(style: .grid, colors: [RGBAColor(0.95, 0.20, 0.70), RGBAColor(0.20, 0.80, 1), RGBAColor(0.60, 0.30, 1)],
                                        background: RGBAColor(0.03, 0.01, 0.08))),
        ("Rising embers (effect)", GeneratorSettings(style: .particles, colors: [RGBAColor(1, 0.60, 0.20), RGBAColor(1, 0.85, 0.40), RGBAColor(1, 0.35, 0.10)], transparent: true)),
        ("Snowfall (effect)", GeneratorSettings(style: .snow, colors: [RGBAColor(1, 1, 1), RGBAColor(0.90, 0.95, 1), RGBAColor(1, 1, 1)], transparent: true)),
        ("Celebration confetti (effect)", GeneratorSettings(style: .confetti, colors: [RGBAColor(1, 0.30, 0.40), RGBAColor(0.20, 0.70, 1), RGBAColor(1, 0.85, 0.20)], transparent: true)),
        ("Sparkles (effect)", GeneratorSettings(style: .sparkles, colors: [RGBAColor(1, 0.95, 0.70), RGBAColor(1, 1, 1), RGBAColor(0.80, 0.90, 1)], transparent: true)),
        ("Warm light leak (effect)", GeneratorSettings(style: .lightLeak, colors: [RGBAColor(1, 0.55, 0.20), RGBAColor(1, 0.25, 0.30), RGBAColor(1, 0.85, 0.50)], transparent: true, speed: 0.5)),
        ("Vignette (effect)", GeneratorSettings(style: .vignette, colors: [RGBAColor(0, 0, 0), RGBAColor(0, 0, 0), RGBAColor(0, 0, 0)], transparent: true))
    ]
}
