import SwiftUI
import AppKit
import WebKit
import AVFoundation
import UniformTypeIdentifiers
import PresentationKit

// MARK: - Navigation used by Help "Show me"

enum AppNavigator {
    static func go(_ target: String?, engine: Engine, present: PresentModel) {
        guard let target else { return }
        switch target {
        case "deck.inputs": present.deck = DeckTab.inputs.rawValue
        case "deck.present": present.deck = DeckTab.present.rawValue
        case "deck.dictionary": present.deck = DeckTab.dictionary.rawValue
        case "deck.images": present.deck = DeckTab.images.rawValue; present.mediaSection = 0
        case "deck.ai": present.deck = DeckTab.ai.rawValue
        case "deck.backgrounds": present.deck = DeckTab.images.rawValue; present.mediaSection = 1
        case "deck.generator": present.deck = DeckTab.images.rawValue; present.mediaSection = 2
        case "deck.automation": present.deck = DeckTab.automation.rawValue
        case "deck.audio": present.deck = DeckTab.audio.rawValue
        case "right.input": engine.rightTab = 1
        case "right.audio": engine.rightTab = 0
        case "right.overlays": engine.rightTab = 2
        case "right.scenes": engine.rightTab = 3
        case "right.outputs": engine.rightTab = 4
        case "right.presets": engine.rightTab = 5
        case "right.network": engine.rightTab = 6
        default: break
        }
    }
}

// MARK: - Help center

struct HelpCenter: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String? = "tour"
    @State private var category = "Getting started"
    @FocusState private var searchFocused: Bool

    private var results: [HelpTopic] {
        engine.helpQuery.trimmingCharacters(in: .whitespaces).isEmpty
            ? HelpIndex.topics(in: category)
            : HelpIndex.search(engine.helpQuery)
    }
    private var selected: HelpTopic? { HelpIndex.topics.first { $0.id == selectedID } }

    var body: some View {
        HStack(spacing: 0) {
            // search + list
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle.fill").font(.system(size: 20)).foregroundColor(DS.accent)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("LiveDeck Help").font(.system(size: 15, weight: .bold)).foregroundColor(DS.text)
                        Text("Find a tool or learn how to use it").font(.system(size: 10)).foregroundColor(DS.text2)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(DS.text3)
                    TextField("Search tools — e.g. blend, projector, lyrics", text: $engine.helpQuery)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .focused($searchFocused)
                        .onSubmit { if let f = results.first { selectedID = f.id } }
                    if !engine.helpQuery.isEmpty {
                        Button { engine.helpQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(DS.text3) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.bg0))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searchFocused ? DS.accent : DS.line, lineWidth: 1))

                if engine.helpQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(HelpIndex.categories, id: \.self) { c in
                                Button(c) { category = c; selectedID = HelpIndex.topics(in: c).first?.id }
                                    .buttonStyle(.ds(.normal, .small, active: category == c))
                            }
                        }
                    }
                } else {
                    Text(results.isEmpty ? "No matching tools — try other words." : "\(results.count) result\(results.count == 1 ? "" : "s")")
                        .font(.system(size: 10)).foregroundColor(DS.text3)
                }

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(results) { t in
                            Button { selectedID = t.id } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).font(.system(size: 12, weight: .semibold)).foregroundColor(DS.text).lineLimit(1)
                                    Text(t.summary).font(.system(size: 10)).foregroundColor(DS.text2).lineLimit(2)
                                    Text(t.category).font(.system(size: 9, weight: .semibold)).foregroundColor(DS.accent)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(selectedID == t.id ? DS.accent.opacity(0.18) : DS.bg2))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selectedID == t.id ? DS.accent : Color.clear, lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 330)
            .background(DS.bg1)

            Rectangle().fill(DS.line).frame(width: 1)

            // article
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }.buttonStyle(.ds(.normal, .small)).keyboardShortcut(.cancelAction)
                }
                .padding(10)
                if let t = selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(t.category.uppercased()).font(.system(size: 10, weight: .bold)).kerning(1.2).foregroundColor(DS.accent)
                            Text(t.title).font(.system(size: 22, weight: .bold)).foregroundColor(DS.text)
                            Text(t.summary).font(.system(size: 13)).foregroundColor(DS.text2).fixedSize(horizontal: false, vertical: true)
                            if t.target != nil {
                                Button {
                                    AppNavigator.go(t.target, engine: engine, present: present)
                                    dismiss()
                                } label: { Label("Show me", systemImage: "arrow.right.circle.fill") }
                                .buttonStyle(.ds(.primary, .regular))
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(t.steps.enumerated()), id: \.offset) { i, step in
                                    HStack(alignment: .top, spacing: 10) {
                                        Text("\(i + 1)").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                                            .frame(width: 22, height: 22).background(Circle().fill(DS.accent))
                                        Text(step).font(.system(size: 13)).foregroundColor(DS.text).fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 10).fill(DS.bg2))
                            let related = HelpIndex.topics(in: t.category).filter { $0.id != t.id }
                            if !related.isEmpty {
                                Text("RELATED").font(.system(size: 10, weight: .bold)).kerning(1.2).foregroundColor(DS.text3)
                                ForEach(related) { r in
                                    Button { selectedID = r.id } label: {
                                        Label(r.title, systemImage: "doc.text").font(.system(size: 12)).foregroundColor(DS.accent)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 24).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("Choose a topic.").foregroundColor(DS.text2).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(DS.bg0)
        }
        .frame(width: 960, height: 640)
        .preferredColorScheme(.dark)
        .onAppear {
            searchFocused = true
            if !engine.helpQuery.isEmpty, let f = HelpIndex.search(engine.helpQuery).first { selectedID = f.id }
        }
        .onChange(of: engine.helpQuery) { q in
            if let f = HelpIndex.search(q).first, !q.trimmingCharacters(in: .whitespaces).isEmpty { selectedID = f.id }
        }
    }
}

// MARK: - Web image search

final class ImageSearchModel: ObservableObject {
    weak var engine: Engine?
    @Published var provider: ImageProvider { didSet { UserDefaults.standard.set(provider.rawValue, forKey: "images.provider") } }
    @Published var orientation: ImageOrientation = .wide
    @Published var query = ""
    @Published var results: [WebImage] = []
    @Published var selectedID: String?
    @Published var loading = false
    @Published var message = ""
    @Published var busy = false
    @Published var browserMode = false
    @Published var browserEngine = 0          // 0 DuckDuckGo · 1 Google · 2 Bing
    @Published var browserURL: URL?
    private var page = 1
    private var lastQuery = ""
    weak var webView: WKWebView?

    let folder = PresentationLibrary.defaultRoot.appendingPathComponent("Images")

    init() {
        provider = ImageProvider(rawValue: UserDefaults.standard.string(forKey: "images.provider") ?? "") ?? .openverse
    }

    var selected: WebImage? { results.first { $0.id == selectedID } }

    // MARK: videos (NASA without a key; Pixabay / Pexels with the keys saved in Backgrounds)

    /// 0 = images · 1 = videos
    @Published var mediaType = 0
    @Published var videoProvider: BackgroundProvider = BackgroundProvider(rawValue: UserDefaults.standard.string(forKey: "images.videoProvider") ?? "") ?? .nasa {
        didSet { UserDefaults.standard.set(videoProvider.rawValue, forKey: "images.videoProvider") }
    }
    @Published var videoResults: [BackgroundItem] = []
    @Published var selectedVideoID: String?
    var selectedVideo: BackgroundItem? { videoResults.first { $0.id == selectedVideoID } }

    func videoKey(_ p: BackgroundProvider) -> String {
        switch p {
        case .nasa: return ""
        case .pixabay: return UserDefaults.standard.string(forKey: "bg.pixabayKey") ?? ""
        case .pexels: return UserDefaults.standard.string(forKey: "bg.pexelsKey") ?? ""
        }
    }

    func searchVideos() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        loading = true; message = ""; videoResults = []; selectedVideoID = nil
        BackgroundSearch.search(videoProvider, query: q, videos: true, key: videoKey(videoProvider)) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                switch r {
                case .success(let list):
                    self.videoResults = list
                    self.selectedVideoID = list.first?.id
                    if list.isEmpty { self.message = "No videos found. Try other words (sky, clouds, light, ocean, city) or another source." }
                case .failure(let e): self.message = "Video search failed: \(e.localizedDescription)"
                }
            }
        }
    }

    func search(more: Bool = false) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if mediaType == 1 { searchVideos(); return }
        if browserMode { openBrowser(); return }
        if !more { page = 1; results = []; selectedID = nil; lastQuery = q } else { page += 1 }
        loading = true; message = ""
        let p = provider, o = orientation, pg = page
        ImageSearch.search(p, query: more ? lastQuery : q, page: pg, orientation: o) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                switch r {
                case .success(let list):
                    let existing = Set(self.results.map { $0.id })
                    self.results += list.filter { !existing.contains($0.id) }
                    if self.selectedID == nil { self.selectedID = self.results.first?.id }
                    if self.results.isEmpty { self.message = "No images found. Try other words, another shape, or the other source." }
                case .failure(let e):
                    self.message = "Search failed: \(e.localizedDescription)"
                }
            }
        }
    }

    func openBrowser() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch browserEngine {
        case 1: browserURL = URL(string: "https://www.google.com/search?tbm=isch&q=\(q)")
        case 2: browserURL = URL(string: "https://www.bing.com/images/search?q=\(q)")
        default: browserURL = URL(string: "https://duckduckgo.com/?q=\(q)&iax=images&ia=images")
        }
    }

    /// Downloads (or reuses) the full image, then runs `then` on the main thread.
    func localFile(_ image: WebImage, then: @escaping (URL) -> Void) {
        busy = true; message = "Downloading image…"
        ImageSearch.download(image, into: folder) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch r {
                case .success(let url): self.message = ""; then(url)
                case .failure(let e): self.message = "Could not download: \(e.localizedDescription)"
                }
            }
        }
    }

    enum Destination { case input, preview, program }

    func addAsInput(_ image: WebImage, _ dest: Destination) {
        localFile(image) { [weak self] url in self?.placeImage(url, name: image.title, dest) }
    }

    private func placeImage(_ url: URL, name: String, _ dest: Destination) {
        guard let engine else { return }
        let src = ImageSource(url: url)
        if !name.isEmpty { src.name = name }
        engine.placeInput(src)
        switch dest {
        case .input: break
        case .preview: engine.setPreview(src.id); engine.selectedSourceID = src.id
        case .program: engine.setPreview(src.id); engine.cut()
        }
        message = "Added “\(src.name)” as an input."
    }

    func useAsBackground(_ image: WebImage, on source: SlideSource?) {
        guard let source else { message = "Add a Songs & Bible or Dictionary input first."; return }
        localFile(image) { url in Self.setBackground(url, on: source) }
    }

    static func setBackground(_ url: URL, on source: SlideSource) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var look = source.look
        look.background.kind = .image
        look.background.media = MediaRef(path: url.path, bytes: size)
        source.look = look
    }

    /// Saves an image copied to the clipboard (e.g. right-click → Copy Image in the browser).
    func clipboardImageFile() -> URL? {
        guard let img = NSImage(pasteboard: NSPasteboard.general),
              let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            message = "No image on the clipboard. Right-click an image on the page → Copy Image, then try again."
            return nil
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("pasted-\(Int(Date().timeIntervalSince1970)).png")
        do { try png.write(to: url); return url } catch { message = "Could not save the image: \(error.localizedDescription)"; return nil }
    }

    func pasteAsInput(_ dest: Destination) {
        if let url = clipboardImageFile() { placeImage(url, name: query.isEmpty ? "Pasted image" : query, dest) }
    }
}

struct ImageSearchDeck: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var dict: DictionaryModel
    @EnvironmentObject var images: ImageSearchModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DSSegmented(selection: $images.mediaType, options: [(0, "Images"), (1, "Videos")])
                    .frame(width: 150)
                if images.mediaType == 1 {
                    Picker("", selection: $images.videoProvider) {
                        ForEach(BackgroundProvider.allCases) { p in Text(p.rawValue).tag(p) }
                    }
                    .labelsHidden().frame(width: 190)
                } else {
                DSSegmented(selection: $images.browserMode, options: [(false, "Free libraries"), (true, "Web browser")])
                    .frame(width: 210)
                if images.browserMode {
                    Picker("", selection: $images.browserEngine) {
                        Text("DuckDuckGo Images").tag(0); Text("Google Images").tag(1); Text("Bing Images").tag(2)
                    }
                    .labelsHidden().frame(width: 170)
                } else {
                    Picker("", selection: $images.provider) {
                        ForEach(ImageProvider.allCases) { p in Text(p.rawValue).tag(p) }
                    }
                    .labelsHidden().frame(width: 170)
                    Picker("", selection: $images.orientation) {
                        ForEach(ImageOrientation.allCases) { o in Text(o.rawValue).tag(o) }
                    }
                    .labelsHidden().frame(width: 110)
                }
                }
                TextField(images.mediaType == 1 ? "Type a word — e.g. clouds, worship, light, ocean" : "Type a word — e.g. cross, sunrise, worship, Accra", text: $images.query)
                    .dsField()
                    .onSubmit { images.search() }
                Button { images.search() } label: { Label("Search", systemImage: "magnifyingglass") }.buttonStyle(.ds(.primary))
                if images.loading || images.busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).frame(height: 44).background(DS.bg2)
            .overlay(Rectangle().fill(DS.lineSoft).frame(height: 1), alignment: .bottom)

            if !images.message.isEmpty {
                Text(images.message).font(.system(size: 11)).foregroundColor(DS.amber)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 4)
            }

            if images.mediaType == 1 { VideoSearchResults() }
            else if images.browserMode { browser } else { library }
        }
        .background(DS.bg1)
    }

    // MARK: libraries

    private var library: some View {
        HSplitView {
            Group {
                if images.results.isEmpty && !images.loading {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36)).foregroundColor(DS.text3)
                        Text("Type a word and press Search to see images.").font(DS.label).foregroundColor(DS.text2)
                        Text(images.provider.detail).font(.system(size: 10)).foregroundColor(DS.text3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 10)], spacing: 10) {
                            ForEach(images.results) { img in
                                ImageResultCard(image: img, selected: images.selectedID == img.id)
                                    .onTapGesture(count: 2) { images.addAsInput(img, .preview) }
                                    .onTapGesture { images.selectedID = img.id }
                                    .contextMenu {
                                        Button("Add as input") { images.addAsInput(img, .input) }
                                        Button("Add and put on Preview") { images.addAsInput(img, .preview) }
                                        Button("Add and cut to Program") { images.addAsInput(img, .program) }
                                        Divider()
                                        Button("Use as Songs & Bible background") { images.useAsBackground(img, on: present.currentTarget()) }
                                        Button("Use as Dictionary background") { images.useAsBackground(img, on: dict.currentTarget()) }
                                    }
                            }
                        }
                        .padding(10)
                        if !images.results.isEmpty {
                            Button(images.loading ? "Loading…" : "Load more") { images.search(more: true) }
                                .buttonStyle(.ds(.normal)).disabled(images.loading).padding(.bottom, 12)
                        }
                    }
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            ImageDetailPanel()
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
        }
    }

    // MARK: browser

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                DSIconButton(symbol: "chevron.left", help: "Back") { images.webView?.goBack() }
                DSIconButton(symbol: "chevron.right", help: "Forward") { images.webView?.goForward() }
                Text("Right-click an image → Copy Image, then:").font(.system(size: 11)).foregroundColor(DS.text2)
                Button("Paste as input") { images.pasteAsInput(.input) }.buttonStyle(.ds(.normal, .small))
                Button("Paste to Preview") { images.pasteAsInput(.preview) }.buttonStyle(.ds(.preview, .small))
                Button("Paste to Program") { images.pasteAsInput(.program) }.buttonStyle(.ds(.program, .small))
                Button("Paste as slide background") {
                    if let url = images.clipboardImageFile(), let t = present.currentTarget() { ImageSearchModel.setBackground(url, on: t) }
                }
                .buttonStyle(.ds(.normal, .small))
                Spacer()
            }
            .padding(.horizontal, 8).frame(height: 36)
            ZStack {
                if let u = images.browserURL {
                    ImageBrowserView(url: u, model: images)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "safari").font(.system(size: 32)).foregroundColor(DS.text3)
                        Text("Type a word and press Search to open image results here.").font(DS.label).foregroundColor(DS.text2)
                        Text("Check the image's licence on its website before using it publicly.").font(.system(size: 10)).foregroundColor(DS.text3)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct VideoSearchResults: View {
    @EnvironmentObject var images: ImageSearchModel
    @EnvironmentObject var bg: BackgroundsModel
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var dict: DictionaryModel

    var body: some View {
        HSplitView {
            Group {
                if images.videoResults.isEmpty && !images.loading {
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack").font(.system(size: 36)).foregroundColor(DS.text3)
                        Text("Type a word and press Search to find free videos.").font(DS.label).foregroundColor(DS.text2)
                        Text("NASA videos are public domain and need no key. Pixabay and Pexels need a free API key.")
                            .font(.system(size: 10)).foregroundColor(DS.text3)
                        if images.videoProvider != .nasa {
                            HStack(spacing: 6) {
                                SecureField("\(images.videoProvider.rawValue) API key", text: images.videoProvider == .pixabay ? $bg.pixabayKey : $bg.pexelsKey)
                                    .dsField().frame(width: 260)
                                if let u = images.videoProvider.keySignupURL {
                                    Button("Get free key") { NSWorkspace.shared.open(u) }.buttonStyle(.ds(.ghost, .small))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 10)], spacing: 10) {
                            ForEach(images.videoResults) { item in
                                VideoResultCard(item: item, selected: images.selectedVideoID == item.id, status: bg.downloads[item.id], saved: bg.catalog.contains(item.id))
                                    .onTapGesture(count: 2) { use(item, .preview) }
                                    .onTapGesture { images.selectedVideoID = item.id }
                                    .contextMenu {
                                        Button("Add as input") { use(item, .input) }
                                        Button("Add and put on Preview") { use(item, .preview) }
                                        Button("Add and cut to Program") { use(item, .program) }
                                        Divider()
                                        Button("Use as Songs & Bible background") { background(item, present.currentTarget()) }
                                        Button("Use as Dictionary background") { background(item, dict.currentTarget()) }
                                        Button("Save to library") { bg.download(item) }
                                        if let page = item.pageURL { Button("Open source page") { NSWorkspace.shared.open(page) } }
                                    }
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            CPInspector {
                if let item = images.selectedVideo {
                    CPCard(title: item.title, subtitle: [item.provider, item.duration > 0 ? "\(Int(item.duration)) s" : "", item.width > 0 ? "\(item.width)×\(item.height)" : ""].filter { !$0.isEmpty }.joined(separator: " · "), icon: "film") {
                        AsyncImage(url: item.thumbnailURL) { phase in
                            if let i = phase.image { i.resizable().aspectRatio(contentMode: .fit) } else { Color.black.aspectRatio(16.0 / 9.0, contentMode: .fit) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6)).padding(.vertical, 6)
                        CPNote([item.credit, item.license].filter { !$0.isEmpty }.joined(separator: " · "))
                        if let st = bg.downloads[item.id] {
                            Text(st).font(.system(size: 10)).foregroundColor(st.hasPrefix("Failed") ? DS.program : DS.ok)
                        }
                    }
                    CPCard(title: "Use it", icon: "play.rectangle") {
                        VStack(spacing: 6) {
                            CPButton(icon: "plus.rectangle.on.rectangle", title: "Add as input") { use(item, .input) }
                            HStack(spacing: 6) {
                                Button("Preview") { use(item, .preview) }.buttonStyle(.ds(.preview, .small, fullWidth: true))
                                Button("Program") { use(item, .program) }.buttonStyle(.ds(.program, .small, fullWidth: true))
                            }
                            CPButton(icon: "music.note.list", title: "Songs & Bible background") { background(item, present.currentTarget()) }
                            CPButton(icon: "character.book.closed", title: "Dictionary background") { background(item, dict.currentTarget()) }
                            CPButton(icon: "square.and.arrow.down", title: bg.catalog.contains(item.id) ? "Saved in library" : "Save to library") { bg.download(item) }
                                .disabled(bg.catalog.contains(item.id))
                        }
                        .padding(.vertical, 6)
                        CPNote("Videos are downloaded into your Media library first (they loop and start muted as inputs).")
                    }
                } else {
                    CPNote("Select a video to see its details.")
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
        }
    }

    private func use(_ item: BackgroundItem, _ dest: BackgroundsModel.Dest) {
        images.message = "Downloading “\(item.title)”…"
        bg.download(item) { saved in
            if let s = saved { bg.addAsInput(s, dest); images.message = "" }
            else { images.message = bg.downloads[item.id] ?? "Download failed." }
        }
    }

    private func background(_ item: BackgroundItem, _ target: SlideSource?) {
        guard let target else { images.message = "Add a Songs & Bible or Dictionary input first."; return }
        bg.download(item) { saved in if let s = saved { bg.useAsBackground(s, on: target) } }
    }
}

struct VideoResultCard: View {
    let item: BackgroundItem
    let selected: Bool
    let status: String?
    let saved: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Color.black
                AsyncImage(url: item.thumbnailURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                    case .failure: Image(systemName: "film").font(.system(size: 22)).foregroundColor(DS.text3)
                    default: ProgressView().controlSize(.small)
                    }
                }
                HStack(spacing: 3) {
                    if saved { Image(systemName: "checkmark.circle.fill").foregroundColor(DS.ok) }
                    Image(systemName: "play.fill")
                    if item.duration > 0 { Text("\(Int(item.duration))s") }
                }
                .font(.system(size: 9, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.6))).padding(5)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipped()
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 11, weight: .semibold)).foregroundColor(DS.text).lineLimit(1)
                Text(status ?? [item.provider, item.credit].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 9)).foregroundColor(status?.hasPrefix("Failed") == true ? DS.program : DS.text3).lineLimit(1)
            }
            .padding(6)
        }
        .background(DS.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? DS.accent : DS.lineSoft, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }
}

struct ImageResultCard: View {
    let image: WebImage
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black
                AsyncImage(url: image.thumbnailURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fit)
                    case .failure: Image(systemName: "photo").font(.system(size: 22)).foregroundColor(DS.text3)
                    default: ProgressView().controlSize(.small)
                    }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            VStack(alignment: .leading, spacing: 1) {
                Text(image.title.isEmpty ? "Untitled" : image.title).font(.system(size: 11, weight: .semibold)).foregroundColor(DS.text).lineLimit(1)
                Text([image.sizeText, image.license].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 9)).foregroundColor(DS.text3).lineLimit(1)
            }
            .padding(6)
        }
        .background(DS.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? DS.accent : DS.lineSoft, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }
}

struct ImageDetailPanel: View {
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var dict: DictionaryModel
    @EnvironmentObject var images: ImageSearchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Selected image", icon: "photo")
            if let img = images.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        AsyncImage(url: img.thumbnailURL) { phase in
                            if let i = phase.image { i.resizable().aspectRatio(contentMode: .fit) } else { Color.black.aspectRatio(16.0 / 9.0, contentMode: .fit) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(img.title.isEmpty ? "Untitled" : img.title).font(.system(size: 13, weight: .bold)).foregroundColor(DS.text)
                        Text(img.attribution).font(.system(size: 10)).foregroundColor(DS.text2).fixedSize(horizontal: false, vertical: true)
                        if !img.sizeText.isEmpty { Text(img.sizeText + " px").font(DS.mono(10)).foregroundColor(DS.text3) }

                        SectionLabel("Use it")
                        Button { images.addAsInput(img, .input) } label: { Label("Add as input", systemImage: "plus.rectangle.on.rectangle") }
                            .buttonStyle(.ds(.normal, .regular, fullWidth: true)).disabled(images.busy)
                        HStack(spacing: 6) {
                            Button("Preview") { images.addAsInput(img, .preview) }.buttonStyle(.ds(.preview, .regular, fullWidth: true))
                            Button("Program") { images.addAsInput(img, .program) }.buttonStyle(.ds(.program, .regular, fullWidth: true))
                        }
                        .disabled(images.busy)
                        SectionLabel("Slide background")
                        Button("Songs & Bible background") { images.useAsBackground(img, on: present.currentTarget()) }
                            .buttonStyle(.ds(.normal, .regular, fullWidth: true)).disabled(images.busy)
                        Button("Dictionary background") { images.useAsBackground(img, on: dict.currentTarget()) }
                            .buttonStyle(.ds(.normal, .regular, fullWidth: true)).disabled(images.busy)
                        if let page = img.pageURL {
                            Button { NSWorkspace.shared.open(page) } label: { Label("Open image page (licence)", systemImage: "safari") }
                                .buttonStyle(.ds(.ghost, .small))
                        }
                        Text("Credit the creator where the licence asks for it. Images are saved in Library/Images.")
                            .font(.system(size: 9.5)).foregroundColor(DS.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 10).padding(.bottom, 10)
                }
            } else {
                Text("Select an image to see its details.").font(DS.small).foregroundColor(DS.text2).padding(10)
                Spacer()
            }
        }
        .background(CP.bg)
    }
}

struct ImageBrowserView: NSViewRepresentable {
    let url: URL
    let model: ImageSearchModel
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        wv.load(URLRequest(url: url))
        context.coordinator.lastURL = url
        model.webView = wv
        return wv
    }
    func updateNSView(_ wv: WKWebView, context: Context) {
        model.webView = wv
        if context.coordinator.lastURL != url { context.coordinator.lastURL = url; wv.load(URLRequest(url: url)) }
    }
    final class Coordinator { var lastURL: URL? }
}

// MARK: - Presets

struct PresetIncludes: Codable, Equatable {
    var inputs = true
    var audio = true
    var overlays = true
    var output = true
    var transitions = true
}

struct PresetAudio: Codable {
    var gain: Double, trimDB: Double, pan: Double
    var muted: Bool, solo: Bool, sendToMain: Bool, audioFollowsVideo: Bool, fxEnabled: Bool
    var audioDeviceID: String?
    var fx: [Double]          // eq ×10, gate ×5, comp ×5 (order in `fxKeys`)

    static let fxCount = 20

    init(_ s: Source) {
        gain = s.gain; trimDB = s.trimDB; pan = s.pan
        muted = s.muted; solo = s.solo; sendToMain = s.sendToMain; audioFollowsVideo = s.audioFollowsVideo; fxEnabled = s.fxEnabled
        audioDeviceID = s.audioDeviceID
        fx = [s.eqHPF, s.eqLowGain, s.eqP1Freq, s.eqP1Gain, s.eqP1Q, s.eqP2Freq, s.eqP2Gain, s.eqP2Q, s.eqHighGain, s.eqLPF,
              s.gateThreshold, s.gateRange, s.gateAttack, s.gateHold, s.gateRelease,
              s.compThreshold, s.compRatio, s.compAttack, s.compRelease, s.compMakeup]
    }

    func apply(to s: Source, includeDevice: Bool = true) {
        s.gain = gain; s.trimDB = trimDB; s.pan = pan
        s.muted = muted; s.solo = solo; s.sendToMain = sendToMain; s.audioFollowsVideo = audioFollowsVideo; s.fxEnabled = fxEnabled
        if includeDevice { s.audioDeviceID = audioDeviceID }
        guard fx.count >= PresetAudio.fxCount else { return }
        s.eqHPF = fx[0]; s.eqLowGain = fx[1]; s.eqP1Freq = fx[2]; s.eqP1Gain = fx[3]; s.eqP1Q = fx[4]
        s.eqP2Freq = fx[5]; s.eqP2Gain = fx[6]; s.eqP2Q = fx[7]; s.eqHighGain = fx[8]; s.eqLPF = fx[9]
        s.gateThreshold = fx[10]; s.gateRange = fx[11]; s.gateAttack = fx[12]; s.gateHold = fx[13]; s.gateRelease = fx[14]
        s.compThreshold = fx[15]; s.compRatio = fx[16]; s.compAttack = fx[17]; s.compRelease = fx[18]; s.compMakeup = fx[19]
    }
}

struct PresetInput: Codable {
    var kind: String
    var name: String
    var location: String?
    var color: [Double]?
    var look: SlideLook?
    var adjust: [Double]       // zoom panX panY rotation cropL cropR cropT cropB brightness contrast saturation
    var audio: PresetAudio
    var generator: GeneratorSettings?
}

struct PresetOutput: Codable {
    var width: Int, height: Int, fps: Int
    var recCodec: String, recContainer: String, recBitrateMbps: Int
    var mixInputsIntoRecording: Bool
}

struct AppPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var created = Date()
    var modified = Date()
    var includes = PresetIncludes()
    var inputs: [PresetInput]?
    var master: PresetAudio?
    var show: ShowFile?
    var output: PresetOutput?
    var transition: String?
    var transitionDuration: Double?

    var summary: String {
        var parts: [String] = []
        if includes.inputs, let n = inputs?.filter({ $0.kind != "empty" }).count { parts.append("\(n) input\(n == 1 ? "" : "s")") }
        if includes.audio { parts.append("audio") }
        if includes.overlays { parts.append("overlays & scenes") }
        if includes.output, let o = output { parts.append("\(o.height)p\(o.fps)") }
        if includes.transitions { parts.append("transitions") }
        return parts.joined(separator: " · ")
    }
}

final class PresetStore: ObservableObject {
    @Published private(set) var presets: [AppPreset] = []
    @Published var message = ""
    let folder = PresentationLibrary.defaultRoot.appendingPathComponent("Presets")

    init() { reload() }

    func reload() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        presets = files.filter { $0.pathExtension == "ldpreset" }
            .compactMap { try? dec.decode(AppPreset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.modified > $1.modified }
    }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".ldpreset") }

    private func write(_ p: AppPreset) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(p).write(to: url(p.id), options: .atomic)
    }

    // MARK: capture

    static func kind(of s: Source) -> String {
        switch s {
        case is EmptySource: return "empty"
        case is CameraSource: return "camera"
        case is ScreenSource: return "screen"
        case is FileSource: return s.sourceURLString != nil ? "stream" : "file"
        case is ImageSource: return "image"
        case is AudioFileSource: return "audio"
        case is WebSource: return "web"
        case is FFmpegStreamSource: return "ffmpeg"
        case is ColorSource: return "color"
        case is BarsSource: return "bars"
        case is DictionarySource: return "dictionary"
        case is PresentationSource: return "presentation"
        case is GeneratorSource: return "generator"
        case is AISource: return "ai"
        default: return "empty"
        }
    }

    static func capture(_ engine: Engine, name: String, includes: PresetIncludes, id: UUID = UUID(), created: Date = Date()) -> AppPreset {
        var p = AppPreset(id: id, name: name, created: created, modified: Date(), includes: includes)
        if includes.inputs || includes.audio {
            p.inputs = engine.sources.map { s in
                var color: [Double]? = nil
                if let c = s as? ColorSource, let rgb = c.color.usingColorSpace(.sRGB) {
                    color = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent), Double(rgb.alphaComponent)]
                }
                return PresetInput(kind: kind(of: s), name: s.name,
                                   location: s.sourceURLString ?? s.originLocation,
                                   color: color, look: (s as? SlideSource)?.look,
                                   adjust: [s.zoom, s.panX, s.panY, s.rotation, s.cropL, s.cropR, s.cropT, s.cropB, s.brightness, s.contrast, s.saturation],
                                   audio: PresetAudio(s), generator: (s as? GeneratorSource)?.settings)
            }
            p.master = PresetAudio(engine.masterBus)
        }
        if includes.overlays {
            func idx(_ slots: [UUID?]) -> [Int] { slots.map { id in id.flatMap { uid in engine.sources.firstIndex { $0.id == uid } } ?? -1 } }
            p.show = ShowFile(width: engine.width, height: engine.height, layers: engine.layers.map { $0.toShowLayer() },
                              layout: engine.programLayout.rawValue, slots: idx(engine.layoutSlots), gridCount: engine.gridCount,
                              scenes: engine.scenes.map { ShowScene(name: $0.name, layout: $0.layout.rawValue, slots: idx($0.slots), gridCount: $0.gridCount) })
        }
        if includes.output {
            p.output = PresetOutput(width: engine.width, height: engine.height, fps: engine.fpsTarget,
                                    recCodec: engine.recCodec.rawValue, recContainer: engine.recContainer,
                                    recBitrateMbps: engine.recBitrateMbps, mixInputsIntoRecording: engine.mixInputsIntoRecording)
        }
        if includes.transitions {
            p.transition = engine.transition.rawValue
            p.transitionDuration = engine.transitionDuration
        }
        return p
    }

    func save(_ engine: Engine, name: String, includes: PresetIncludes) {
        let n = name.trimmingCharacters(in: .whitespaces)
        let p = PresetStore.capture(engine, name: n.isEmpty ? "Preset \(presets.count + 1)" : n, includes: includes)
        do { try write(p); reload(); message = "Saved preset “\(p.name)”." }
        catch { message = "Could not save preset: \(error.localizedDescription)" }
    }

    /// Adds a preset received from another computer.
    func importPreset(_ p: AppPreset) {
        var copy = p
        if presets.contains(where: { $0.id == p.id }) { copy.id = UUID() }
        copy.modified = Date()
        do { try write(copy); reload(); message = "Received preset “\(copy.name)”." }
        catch { message = "Could not save the received preset: \(error.localizedDescription)" }
    }

    func update(_ preset: AppPreset, from engine: Engine) {
        let p = PresetStore.capture(engine, name: preset.name, includes: preset.includes, id: preset.id, created: preset.created)
        do { try write(p); reload(); message = "Updated “\(p.name)” with the current setup." }
        catch { message = "Could not update preset: \(error.localizedDescription)" }
    }

    func rename(_ preset: AppPreset, to name: String) {
        var p = preset; p.name = name; p.modified = Date()
        try? write(p); reload()
    }

    func delete(_ preset: AppPreset) {
        try? FileManager.default.removeItem(at: url(preset.id)); reload()
        message = "Deleted “\(preset.name)”."
    }

    // MARK: recall

    func recall(_ p: AppPreset, into engine: Engine) {
        var missing: [String] = []

        if p.includes.output, let o = p.output {
            if engine.isRecording || engine.isStreaming {
                missing.append("format not changed while recording/streaming")
            } else {
                engine.setResolution(width: o.width, height: o.height)
                engine.setFrameRate(o.fps)
            }
            if let c = RecCodec(rawValue: o.recCodec) { engine.recCodec = c }
            engine.recContainer = o.recContainer
            engine.recBitrateMbps = o.recBitrateMbps
            engine.mixInputsIntoRecording = o.mixInputsIntoRecording
        }
        if p.includes.transitions {
            if let t = p.transition.flatMap(TransitionType.init(rawValue:)) { engine.transition = t }
            if let d = p.transitionDuration { engine.transitionDuration = d }
        }

        if p.includes.inputs, let list = p.inputs {
            var made: [Source] = []
            for spec in list {
                let s = PresetStore.make(spec, missing: &missing)
                applyCommon(spec, to: s, audio: p.includes.audio)
                made.append(s)
            }
            engine.replaceAllSources(made)
        } else if p.includes.audio, let list = p.inputs {
            // audio only: match channels by name, then by position
            for (i, spec) in list.enumerated() {
                let target = engine.sources.first { $0.name == spec.name && !$0.isPlaceholder }
                    ?? (engine.sources.indices.contains(i) ? engine.sources[i] : nil)
                if let t = target, !t.isPlaceholder { spec.audio.apply(to: t) }
            }
        }
        if p.includes.audio, let m = p.master { m.apply(to: engine.masterBus, includeDevice: false) }

        if p.includes.overlays, let show = p.show {
            engine.layers = show.layers.compactMap { Layer.from($0) }
            engine.selectedLayerID = engine.layers.first?.id
            func slots(_ idx: [Int]) -> [UUID?] {
                var r = idx.map { $0 >= 0 && $0 < engine.sources.count ? engine.sources[$0].id : nil }
                while r.count < 10 { r.append(nil) }
                return Array(r.prefix(10))
            }
            engine.programLayout = ProgramLayout(rawValue: show.layout) ?? .single
            engine.gridCount = max(2, min(10, show.gridCount))
            engine.layoutSlots = slots(show.slots)
            engine.scenes = show.scenes.map { ProgramScene(name: $0.name, layout: ProgramLayout(rawValue: $0.layout) ?? .single,
                                                           slots: slots($0.slots), gridCount: max(2, min(10, $0.gridCount))) }
        }
        message = "Recalled “\(p.name)”." + (missing.isEmpty ? "" : " Not available on this Mac: " + missing.joined(separator: ", ") + ".")
    }

    private func applyCommon(_ spec: PresetInput, to s: Source, audio: Bool) {
        if !(s is EmptySource) || spec.kind == "empty" { s.name = s is EmptySource && spec.kind != "empty" ? "Empty" : spec.name }
        if spec.adjust.count >= 11 {
            s.zoom = spec.adjust[0]; s.panX = spec.adjust[1]; s.panY = spec.adjust[2]; s.rotation = spec.adjust[3]
            s.cropL = spec.adjust[4]; s.cropR = spec.adjust[5]; s.cropT = spec.adjust[6]; s.cropB = spec.adjust[7]
            s.brightness = spec.adjust[8]; s.contrast = spec.adjust[9]; s.saturation = spec.adjust[10]
        }
        if audio && !(s is EmptySource) { spec.audio.apply(to: s) }
    }

    static func make(_ spec: PresetInput, missing: inout [String]) -> Source {
        let loc = spec.location ?? ""
        func fileExists(_ p: String) -> Bool { !p.isEmpty && FileManager.default.fileExists(atPath: p) }
        switch spec.kind {
        case "camera":
            if let d = AVCaptureDevice(uniqueID: loc) { return CameraSource(device: d) }
            missing.append(spec.name)
        case "screen": return ScreenSource()
        case "file":
            if fileExists(loc) { return FileSource(url: URL(fileURLWithPath: loc)) }
            missing.append(spec.name)
        case "stream":
            if let u = URL(string: loc) { return FileSource(url: u, displayName: spec.name, label: "STREAM", startLooping: false, autoplay: true) }
        case "image":
            if fileExists(loc) { return ImageSource(url: URL(fileURLWithPath: loc)) }
            missing.append(spec.name)
        case "audio":
            if fileExists(loc) { return AudioFileSource(url: URL(fileURLWithPath: loc)) }
            missing.append(spec.name)
        case "web": if !loc.isEmpty { return WebSource(url: loc) }
        case "ffmpeg": if !loc.isEmpty { return FFmpegStreamSource(url: loc) }
        case "color":
            let c = spec.color ?? [0.1, 0.43, 0.85, 1]
            if c.count >= 4 { return ColorSource(color: NSColor(srgbRed: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: CGFloat(c[3]))) }
        case "bars": return BarsSource()
        case "presentation": return PresentationSource(name: spec.name, look: spec.look ?? .fullScreen)
        case "dictionary": return DictionarySource(name: spec.name, look: spec.look ?? .dictionaryPanel)
        case "generator": return GeneratorSource(settings: spec.generator ?? GeneratorSettings(), name: spec.name)
        case "ai": return AISource(name: spec.name, look: spec.look ?? AISource.defaultLook)
        default: break
        }
        return EmptySource()
    }

    // MARK: export / import

    func export(_ preset: AppPreset) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = preset.name + ".ldpreset"
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: self.url(preset.id), to: dest)
        }
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.message = "Choose LiveDeck preset files (.ldpreset)"
        panel.begin { resp in
            guard resp == .OK else { return }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            var n = 0
            for u in panel.urls {
                guard let data = try? Data(contentsOf: u), var p = try? dec.decode(AppPreset.self, from: data) else { continue }
                if self.presets.contains(where: { $0.id == p.id }) { p.id = UUID() }
                if (try? self.write(p)) != nil { n += 1 }
            }
            self.reload()
            self.message = "Imported \(n) preset\(n == 1 ? "" : "s")."
        }
    }
}

struct PresetsPanel: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var link: LinkManager
    @EnvironmentObject var presets: PresetStore
    @State private var name = ""
    @State private var includes = PresetIncludes()
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var confirmRecall: AppPreset?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                CPCard(title: "Save current setup", subtitle: "Store settings to recall later", icon: "square.and.arrow.down.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Preset name — e.g. Sunday service", text: $name)
                            .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(CP.text)
                            .padding(.horizontal, 8).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(CP.field))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(CP.border, lineWidth: 1))
                            .onSubmit { save() }
                        includeRow("rectangle.stack", "Inputs (cameras, files, slides, looks)", $includes.inputs)
                        includeRow("slider.vertical.3", "Audio mixer & effects", $includes.audio)
                        includeRow("square.stack.3d.up", "Overlays, layouts & scenes", $includes.overlays)
                        includeRow("film", "Output format & recording", $includes.output)
                        includeRow("arrow.left.arrow.right", "Transitions", $includes.transitions)
                        HStack {
                            Spacer()
                            CPButton(icon: "square.and.arrow.down", title: "Save preset", prominent: true) { save() }
                        }
                    }
                    .padding(.vertical, 8)
                }

                CPCard(title: "Saved presets", subtitle: "\(presets.presets.count) saved", icon: "tray.full.fill") {
                    VStack(spacing: 0) {
                        HStack {
                            CPButton(icon: "square.and.arrow.down.on.square", title: "Import…") { presets.importFiles() }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        if presets.presets.isEmpty {
                            Text("No presets yet. Set everything up, name it above and press Save preset.")
                                .font(.system(size: 11)).foregroundColor(CP.text2).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(presets.presets) { p in
                            CPDivider()
                            VStack(alignment: .leading, spacing: 6) {
                                if renaming == p.id {
                                    HStack {
                                        TextField("Name", text: $renameText).textFieldStyle(.roundedBorder)
                                            .onSubmit { presets.rename(p, to: renameText); renaming = nil }
                                        Button("OK") { presets.rename(p, to: renameText); renaming = nil }
                                    }
                                } else {
                                    Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundColor(CP.text)
                                }
                                Text(p.summary).font(.system(size: 10)).foregroundColor(CP.text2)
                                Text(p.modified.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9)).foregroundColor(CP.text2.opacity(0.7))
                                HStack(spacing: 6) {
                                    CPButton(icon: "play.fill", title: "Recall", prominent: true) {
                                        if p.includes.inputs { confirmRecall = p } else { presets.recall(p, into: engine) }
                                    }
                                    Menu {
                                        Button("Update with current setup") { presets.update(p, from: engine) }
                                        Button("Rename…") { renameText = p.name; renaming = p.id }
                                        Button("Export…") { presets.export(p) }
                                        Divider()
                                        Button("Delete", role: .destructive) { presets.delete(p) }
                                    } label: { Image(systemName: "ellipsis.circle").foregroundColor(CP.text) }
                                    .menuStyle(.borderlessButton).fixedSize()
                                    Spacer()
                                }
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("Recall") { if p.includes.inputs { confirmRecall = p } else { presets.recall(p, into: engine) } }
                                Button("Update with current setup") { presets.update(p, from: engine) }
                                Button("Rename…") { renameText = p.name; renaming = p.id }
                                Button("Export…") { presets.export(p) }
                                LinkSendMenu(title: "Send to computer") { pid in link.sharePreset(p, to: pid) }
                                Divider()
                                Button("Delete", role: .destructive) { presets.delete(p) }
                            }
                        }
                    }
                }

                if !presets.message.isEmpty {
                    Text(presets.message).font(.system(size: 11)).foregroundColor(DS.amber)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                }
            }
            .padding(10)
        }
        .background(CP.bg)
        .alert("Recall “\(confirmRecall?.name ?? "")”?", isPresented: Binding(get: { confirmRecall != nil }, set: { if !$0 { confirmRecall = nil } })) {
            Button("Recall") { if let p = confirmRecall { presets.recall(p, into: engine) }; confirmRecall = nil }
            Button("Cancel", role: .cancel) { confirmRecall = nil }
        } message: {
            Text("This preset includes inputs: the current inputs will be replaced (Program and Preview are cleared).")
        }
    }

    private func save() {
        presets.save(engine, name: name, includes: includes)
        name = ""
    }

    private func includeRow(_ icon: String, _ label: String, _ on: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(CP.text2).frame(width: 18)
            Text(label).font(.system(size: 12)).foregroundColor(CP.text)
            Spacer()
            Toggle("", isOn: on).toggleStyle(.switch).tint(CP.blue).labelsHidden().controlSize(.small)
        }
    }
}

/// Top-bar menu: quick recall + save.
struct PresetsMenu: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var presets: PresetStore
    var body: some View {
        Menu {
            Button("Save current as preset…") { engine.rightTab = 5 }
            Button("Manage presets…") { engine.rightTab = 5 }
            if !presets.presets.isEmpty {
                Divider()
                ForEach(presets.presets) { p in
                    Button("Recall “\(p.name)”") {
                        if p.includes.inputs { engine.rightTab = 5 } else { presets.recall(p, into: engine) }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "tray.full")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.text)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Save and recall setups")
    }
}
