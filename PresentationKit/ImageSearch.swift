import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Web image search (free, no API key)
//
//  • Openverse (api.openverse.org) — hundreds of millions of openly-licensed images (Flickr, Wikimedia,
//    museums…). Anonymous access; up to 20 results per page.
//  • Wikimedia Commons (commons.wikimedia.org) — free-licence photos and illustrations.
// Every result carries its creator and licence so the operator can credit it.

public enum ImageProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case openverse = "Openverse"
    case wikimedia = "Wikimedia Commons"
    public var id: String { rawValue }
    public var detail: String {
        switch self {
        case .openverse: return "Openly-licensed photos and illustrations from Flickr, Wikimedia, museums and more."
        case .wikimedia: return "Free-licence photos, maps and illustrations from Wikimedia Commons."
        }
    }
}

public struct WebImage: Codable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var thumbnailURL: URL
    public var imageURL: URL
    public var pageURL: URL?
    public var width: Int
    public var height: Int
    public var creator: String
    public var license: String
    public var provider: String

    public init(id: String, title: String, thumbnailURL: URL, imageURL: URL, pageURL: URL? = nil, width: Int = 0, height: Int = 0,
                creator: String = "", license: String = "", provider: String) {
        self.id = id; self.title = title; self.thumbnailURL = thumbnailURL; self.imageURL = imageURL; self.pageURL = pageURL
        self.width = width; self.height = height; self.creator = creator; self.license = license; self.provider = provider
    }

    /// "Title — creator (CC BY 4.0) via Openverse"
    public var attribution: String {
        var s = title.isEmpty ? "Image" : title
        if !creator.isEmpty { s += " — \(creator)" }
        if !license.isEmpty { s += " (\(license))" }
        return s + " via \(provider)"
    }
    public var sizeText: String { width > 0 && height > 0 ? "\(width)×\(height)" : "" }
    public var isLandscape: Bool { width >= height }
}

public enum ImageOrientation: String, Codable, Sendable, CaseIterable, Identifiable {
    case any = "Any shape"
    case wide = "Wide"
    case tall = "Tall"
    case square = "Square"
    public var id: String { rawValue }
}

public enum ImageSearch {
    public static let userAgent = "LiveDeckStudio/4.3 (macOS church production app)"

    static func q(_ s: String) -> String {
        s.trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
    }

    public static func url(_ provider: ImageProvider, query: String, page: Int = 1, orientation: ImageOrientation = .any) -> URL? {
        let text = query.trimmed
        guard !text.isEmpty else { return nil }
        switch provider {
        case .openverse:
            var s = "https://api.openverse.org/v1/images/?q=\(q(text))&page_size=20&page=\(max(1, page))"
            switch orientation {
            case .wide: s += "&aspect_ratio=wide"
            case .tall: s += "&aspect_ratio=tall"
            case .square: s += "&aspect_ratio=square"
            case .any: break
            }
            return URL(string: s)
        case .wikimedia:
            let offset = (max(1, page) - 1) * 30
            return URL(string: "https://commons.wikimedia.org/w/api.php?action=query&format=json&generator=search"
                       + "&gsrnamespace=6&gsrlimit=30&gsroffset=\(offset)&gsrsearch=\(q(text + " filetype:bitmap"))"
                       + "&prop=imageinfo&iiprop=url%7Csize%7Cmime%7Cextmetadata&iiurlwidth=480")
        }
    }

    // MARK: Parsers (pure — unit tested)

    public static func parseOpenverse(_ data: Data) -> [WebImage] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let id = r["id"] as? String, let urlS = r["url"] as? String, let url = URL(string: urlS) else { return nil }
            let thumb = (r["thumbnail"] as? String).flatMap(URL.init(string:)) ?? url
            var lic = (r["license"] as? String ?? "").uppercased()
            if lic == "CC0" || lic == "PDM" { lic = lic == "PDM" ? "Public domain" : "CC0" }
            else if !lic.isEmpty { lic = "CC " + lic + ((r["license_version"] as? String).map { " " + $0 } ?? "") }
            return WebImage(id: "ov-" + id, title: WordLookup.stripHTML(r["title"] as? String ?? ""), thumbnailURL: thumb, imageURL: url,
                            pageURL: (r["foreign_landing_url"] as? String).flatMap(URL.init(string:)),
                            width: r["width"] as? Int ?? 0, height: r["height"] as? Int ?? 0,
                            creator: r["creator"] as? String ?? "", license: lic, provider: "Openverse")
        }
    }

    public static func parseWikimedia(_ data: Data) -> [WebImage] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = obj["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any] else { return [] }
        let items: [(Int, WebImage)] = pages.values.compactMap { v in
            guard let p = v as? [String: Any], let infos = p["imageinfo"] as? [[String: Any]], let info = infos.first,
                  let urlS = info["url"] as? String, let url = URL(string: urlS) else { return nil }
            let mime = info["mime"] as? String ?? ""
            guard ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mime) else { return nil }
            let thumb = (info["thumburl"] as? String).flatMap(URL.init(string:)) ?? url
            let meta = info["extmetadata"] as? [String: Any] ?? [:]
            func m(_ k: String) -> String { WordLookup.stripHTML(((meta[k] as? [String: Any])?["value"] as? String) ?? "") }
            var title = (p["title"] as? String ?? "").replacingOccurrences(of: "File:", with: "")
            if let dot = title.lastIndex(of: ".") { title = String(title[..<dot]) }
            let index = p["index"] as? Int ?? 0
            let pageID = p["pageid"].map { "\($0)" } ?? UUID().uuidString
            return (index, WebImage(id: "wm-" + pageID, title: title, thumbnailURL: thumb, imageURL: url,
                                    pageURL: (info["descriptionurl"] as? String).flatMap(URL.init(string:)),
                                    width: info["width"] as? Int ?? 0, height: info["height"] as? Int ?? 0,
                                    creator: m("Artist"), license: m("LicenseShortName"), provider: "Wikimedia Commons"))
        }
        return items.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// Client-side shape filter (Wikimedia has no orientation filter).
    public static func filter(_ images: [WebImage], _ o: ImageOrientation) -> [WebImage] {
        switch o {
        case .any: return images
        case .wide: return images.filter { $0.width == 0 || Double($0.width) >= Double($0.height) * 1.2 }
        case .tall: return images.filter { $0.width == 0 || Double($0.height) >= Double($0.width) * 1.2 }
        case .square: return images.filter { $0.width == 0 || abs(Double($0.width - $0.height)) <= Double(max($0.width, $0.height)) * 0.15 }
        }
    }

    public static func search(_ provider: ImageProvider, query: String, page: Int = 1, orientation: ImageOrientation = .any,
                              completion: @escaping (Result<[WebImage], Error>) -> Void) {
        guard let u = url(provider, query: query, page: page, orientation: orientation) else { completion(.success([])); return }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(PresentationKitError.network(err.localizedDescription))); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 { completion(.failure(PresentationKitError.network("too many searches — wait a minute and try again"))); return }
            guard let data, status < 400 else { completion(.failure(PresentationKitError.network("server returned \(status)"))); return }
            let list = provider == .openverse ? parseOpenverse(data) : filter(parseWikimedia(data), orientation)
            completion(.success(list))
        }.resume()
    }

    /// Downloads an image into `folder` (reusing an earlier download of the same image).
    public static func download(_ image: WebImage, into folder: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var ext = image.imageURL.pathExtension.lowercased()
        if !["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tif", "tiff"].contains(ext) { ext = "jpg" }
        let safe = image.id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        let dest = folder.appendingPathComponent(String(safe) + "." + ext)
        if FileManager.default.fileExists(atPath: dest.path) { completion(.success(dest)); return }
        var req = URLRequest(url: image.imageURL, timeoutInterval: 60)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.downloadTask(with: req) { tmp, resp, err in
            if let err { completion(.failure(PresentationKitError.network(err.localizedDescription))); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
            guard let tmp, status < 400 else { completion(.failure(PresentationKitError.network("download failed (\(status))"))); return }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                completion(.success(dest))
            } catch { completion(.failure(error)) }
        }.resume()
    }
}
