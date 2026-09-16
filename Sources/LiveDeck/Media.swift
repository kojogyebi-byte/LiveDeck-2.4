import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import PresentationKit

// MARK: - Backgrounds model

final class BackgroundsModel: ObservableObject {
    weak var engine: Engine?
    let catalog = BackgroundCatalog(libraryRoot: PresentationLibrary.defaultRoot)

    @Published var items: [LocalBackground] = []
    @Published var filter = 0                 // 0 all · 1 videos · 2 images · 3 generated · 4 favourites
    @Published var provider: BackgroundProvider { didSet { UserDefaults.standard.set(provider.rawValue, forKey: "bg.provider") } }
    @Published var pixabayKey: String { didSet { UserDefaults.standard.set(pixabayKey, forKey: "bg.pixabayKey") } }
    @Published var pexelsKey: String { didSet { UserDefaults.standard.set(pexelsKey, forKey: "bg.pexelsKey") } }
    @Published var query = ""
    @Published var searchVideos = true
    @Published var results: [BackgroundItem] = []
    @Published var searching = false
    @Published var message = ""
    @Published var downloads: [String: String] = [:]      // result id → status
    @Published var thumbs: [String: NSImage] = [:]
    @Published var showFirstRun = false
    @Published var starterRunning = false
    @Published var starterStatus = ""
    @Published var selectedLocalID: String?

    init() {
        provider = BackgroundProvider(rawValue: UserDefaults.standard.string(forKey: "bg.provider") ?? "") ?? .nasa
        pixabayKey = UserDefaults.standard.string(forKey: "bg.pixabayKey") ?? ""
        pexelsKey = UserDefaults.standard.string(forKey: "bg.pexelsKey") ?? ""
        items = catalog.items
        if !UserDefaults.standard.bool(forKey: "bg.firstRunOffered") { showFirstRun = true }
    }

    func refresh() { items = catalog.items }

    var filtered: [LocalBackground] {
        switch filter {
        case 1: return items.filter { $0.kind == .video }
        case 2: return items.filter { $0.kind == .image }
        case 3: return items.filter { $0.category == "Generated" }
        case 4: return items.filter { $0.favorite }
        default: return items
        }
    }

    var selectedLocal: LocalBackground? { items.first { $0.id == selectedLocalID } }

    private var key: String { provider == .pixabay ? pixabayKey : (provider == .pexels ? pexelsKey : "") }

    // MARK: online

    func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true; message = ""; results = []
        BackgroundSearch.search(provider, query: q, videos: searchVideos, key: key) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.searching = false
                switch r {
                case .success(let list):
                    self.results = list
                    if list.isEmpty { self.message = "Nothing found — try other words (e.g. sky, clouds, abstract, light, ocean)." }
                case .failure(let e): self.message = "Search failed: \(e.localizedDescription)"
                }
            }
        }
    }

    /// `then` is always called once: with the saved item, or nil on failure.
    func download(_ item: BackgroundItem, then: ((LocalBackground?) -> Void)? = nil) {
        if let existing = items.first(where: { $0.id == item.id }) { then?(existing); return }
        guard downloads[item.id] == nil || downloads[item.id]?.hasPrefix("Failed") == true else { then?(nil); return }
        downloads[item.id] = "Downloading…"
        let tmpFolder = catalog.folder.appendingPathComponent("incoming")
        BackgroundSearch.download(item, into: tmpFolder) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                switch r {
                case .success(let url):
                    do {
                        let saved = try self.catalog.add(file: url, id: item.id, title: item.title, kind: item.kind, category: "Downloaded",
                                                         credit: item.credit, license: item.license, provider: item.provider)
                        try? FileManager.default.removeItem(at: url)
                        self.downloads[item.id] = "Saved"
                        self.refresh()
                        then?(saved)
                    } catch { self.downloads[item.id] = "Failed: \(error.localizedDescription)"; then?(nil) }
                case .failure(let e):
                    self.downloads[item.id] = "Failed: \(e.localizedDescription)"
                    then?(nil)
                }
            }
        }
    }

    // MARK: first install

    func dismissFirstRun() {
        UserDefaults.standard.set(true, forKey: "bg.firstRunOffered")
        showFirstRun = false
    }

    func installStarter(nasa: Bool, generated: Bool) {
        dismissFirstRun()
        starterRunning = true
        let group = DispatchGroup()
        var done = 0
        if generated {
            group.enter()
            starterStatus = "Creating generated backgrounds…"
            installGenerated { group.leave() }
        }
        if nasa {
            for q in BackgroundSearch.starterQueries {
                group.enter()
                BackgroundSearch.search(q.provider, query: q.query, videos: q.videos, key: "") { [weak self] r in
                    DispatchQueue.main.async {
                        guard let self else { group.leave(); return }
                        if case .success(let list) = r {
                            for item in list.prefix(q.take) {
                                group.enter()
                                self.download(item) { saved in
                                    if saved != nil { done += 1; self.starterStatus = "Downloaded \(done) background\(done == 1 ? "" : "s")…" }
                                    group.leave()
                                }
                            }
                        }
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.starterRunning = false
            self?.starterStatus = "Starter backgrounds are ready."
            self?.refresh()
        }
    }

    private func installGenerated(completion: @escaping () -> Void) {
        let stills = GeneratorSettings.presets.filter { !$0.settings.style.isEffect }
        for p in stills {
            let url = catalog.folder.appendingPathComponent("starter-\(p.name.replacingOccurrences(of: " ", with: "-")).png")
            if GeneratorExporter.still(p.settings, to: url) {
                try? catalog.add(file: url, id: "starter-still-\(p.name)", title: p.name, kind: .image, category: "Generated", provider: "LiveDeck generator")
            }
        }
        refresh()
        // three short seamless loops (720p keeps first-run quick)
        let loops = stills.prefix(3)
        var remaining = loops.count
        guard remaining > 0 else { completion(); return }
        for p in loops {
            var s = p.settings; s.loopSeconds = 12
            let url = catalog.folder.appendingPathComponent("starter-\(p.name.replacingOccurrences(of: " ", with: "-"))-loop.mp4")
            GeneratorExporter.loop(s, to: url, size: CGSize(width: 1280, height: 720), progress: { _ in }, completion: { ok in
                DispatchQueue.main.async {
                    if ok { try? self.catalog.add(file: url, id: "starter-loop-\(p.name)", title: p.name + " (loop)", kind: .video,
                                                  category: "Generated", provider: "LiveDeck generator") }
                    self.refresh()
                    remaining -= 1
                    if remaining == 0 { completion() }
                }
            })
        }
    }

    // MARK: use

    enum Dest { case input, preview, program }

    func addAsInput(_ item: LocalBackground, _ dest: Dest) {
        guard let engine else { return }
        let url = catalog.url(item)
        let src: Source = item.kind == .video
            ? FileSource(url: url, displayName: item.title, startLooping: true, autoplay: true)
            : ImageSource(url: url)
        src.name = item.title
        if item.kind == .video { src.muted = true }
        engine.placeInput(src)
        switch dest {
        case .input: break
        case .preview: engine.setPreview(src.id); engine.selectedSourceID = src.id
        case .program: engine.setPreview(src.id); engine.cut()
        }
        message = "Added “\(item.title)” as an input."
    }

    func useAsBackground(_ item: LocalBackground, on source: SlideSource?) {
        guard let source else { message = "Add a Songs & Bible or Dictionary input first."; return }
        let url = catalog.url(item)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var look = source.look
        look.background.kind = item.kind == .video ? .video : .image
        look.background.media = MediaRef(path: url.path, bytes: size)
        source.look = look
        message = "“\(item.title)” is now the background of \(source.name)."
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie, .mpeg4Movie, .quickTimeMovie]
        panel.begin { [weak self] resp in
            guard resp == .OK, let self else { return }
            for u in panel.urls {
                let isVideo = ["mp4", "mov", "m4v"].contains(u.pathExtension.lowercased())
                try? self.catalog.add(file: u, id: "import-" + UUID().uuidString, title: u.deletingPathExtension().lastPathComponent,
                                      kind: isVideo ? .video : .image, category: "Imported")
            }
            self.refresh()
        }
    }

    func thumbnail(_ item: LocalBackground) {
        guard thumbs[item.id] == nil else { return }
        let url = catalog.url(item)
        DispatchQueue.global(qos: .utility).async {
            var image: NSImage?
            if item.kind == .image {
                if let src = NSImage(contentsOf: url) {
                    let target = NSSize(width: 320, height: 180)
                    let small = NSImage(size: target)
                    small.lockFocus()
                    src.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
                    small.unlockFocus()
                    image = small
                }
            } else {
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 320, height: 180)
                if let cg = try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil) {
                    image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
            DispatchQueue.main.async { if let image { self.thumbs[item.id] = image } }
        }
    }
}

// MARK: - Media deck (web images · backgrounds · generator)

struct MediaDeck: View {
    @EnvironmentObject var present: PresentModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DSSegmented(selection: $present.mediaSection, options: [(0, "Web images"), (1, "Backgrounds library"), (2, "Generator")])
                    .frame(width: 420)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6).background(DS.bg2)
            if present.mediaSection == 1 { BackgroundsView() }
            else if present.mediaSection == 2 { GeneratorView() }
            else { ImageSearchDeck() }
        }
    }
}

struct BackgroundsView: View {
    @EnvironmentObject var bg: BackgroundsModel
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var dict: DictionaryModel

    var body: some View {
        HSplitView {
            // local library
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    DSSegmented(selection: $bg.filter, options: [(0, "All"), (1, "Videos"), (2, "Images"), (3, "Generated"), (4, "★")])
                        .frame(width: 330)
                    Spacer()
                    if bg.starterRunning { ProgressView().controlSize(.small); Text(bg.starterStatus).font(.system(size: 10)).foregroundColor(DS.text2) }
                    Button("Starter pack…") { bg.showFirstRun = true }.buttonStyle(.ds(.normal, .small))
                    Button { bg.importFiles() } label: { Label("Import", systemImage: "square.and.arrow.down") }.buttonStyle(.ds(.normal, .small))
                }
                .padding(8)
                if bg.filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.stack").font(.system(size: 32)).foregroundColor(DS.text3)
                        Text("No backgrounds yet. Install the free starter pack, search online on the right, or make one in Generator.")
                            .font(DS.label).foregroundColor(DS.text2).multilineTextAlignment(.center)
                        Button("Install starter pack…") { bg.showFirstRun = true }.buttonStyle(.ds(.primary))
                    }
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 8)], spacing: 8) {
                            ForEach(bg.filtered) { item in
                                LocalBackgroundCard(item: item, selected: bg.selectedLocalID == item.id)
                                    .onTapGesture(count: 2) { bg.addAsInput(item, .preview) }
                                    .onTapGesture { bg.selectedLocalID = item.id }
                                    .contextMenu {
                                        Button("Add as input") { bg.addAsInput(item, .input) }
                                        Button("Add and put on Preview") { bg.addAsInput(item, .preview) }
                                        Button("Add and cut to Program") { bg.addAsInput(item, .program) }
                                        Divider()
                                        Button("Use as Songs & Bible background") { bg.useAsBackground(item, on: present.currentTarget()) }
                                        Button("Use as Dictionary background") { bg.useAsBackground(item, on: dict.currentTarget()) }
                                        Divider()
                                        Button(item.favorite ? "Remove from favourites" : "Add to favourites") { bg.catalog.setFavorite(item.id, !item.favorite); bg.refresh() }
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([bg.catalog.url(item)]) }
                                        Button("Delete", role: .destructive) { bg.catalog.remove(item.id); bg.refresh() }
                                    }
                            }
                        }
                        .padding(8)
                    }
                }
                if let sel = bg.selectedLocal {
                    HStack(spacing: 6) {
                        Text(sel.title).font(.system(size: 11, weight: .semibold)).foregroundColor(DS.text).lineLimit(1)
                        Text([sel.credit, sel.license].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 9)).foregroundColor(DS.text3).lineLimit(1)
                        Spacer()
                        Button("Input") { bg.addAsInput(sel, .input) }.buttonStyle(.ds(.normal, .small))
                        Button("Preview") { bg.addAsInput(sel, .preview) }.buttonStyle(.ds(.preview, .small))
                        Button("Program") { bg.addAsInput(sel, .program) }.buttonStyle(.ds(.program, .small))
                        Button("Songs & Bible BG") { bg.useAsBackground(sel, on: present.currentTarget()) }.buttonStyle(.ds(.normal, .small))
                        Button("Dictionary BG") { bg.useAsBackground(sel, on: dict.currentTarget()) }.buttonStyle(.ds(.normal, .small))
                    }
                    .padding(8).background(DS.bg2)
                }
                if !bg.message.isEmpty {
                    Text(bg.message).font(.system(size: 10)).foregroundColor(DS.amber).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.bottom, 4)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            // online search
            VStack(alignment: .leading, spacing: 8) {
                PanelHeader(title: "Free online backgrounds", icon: "globe")
                VStack(alignment: .leading, spacing: 8) {
                    FieldRow(label: "Source", labelWidth: 56) {
                        Picker("", selection: $bg.provider) { ForEach(BackgroundProvider.allCases) { p in Text(p.rawValue).tag(p) } }.labelsHidden()
                    }
                    if bg.provider == .pixabay {
                        keyField("Pixabay API key", $bg.pixabayKey, bg.provider.keySignupURL)
                    } else if bg.provider == .pexels {
                        keyField("Pexels API key", $bg.pexelsKey, bg.provider.keySignupURL)
                    }
                    DSSegmented(selection: $bg.searchVideos, options: [(true, "Videos"), (false, "Images")])
                    HStack(spacing: 6) {
                        TextField("e.g. clouds, sky, light, abstract, ocean", text: $bg.query).dsField().onSubmit { bg.search() }
                        Button("Search") { bg.search() }.buttonStyle(.ds(.primary))
                    }
                    Text(bg.provider.license).font(.system(size: 9.5)).foregroundColor(DS.text3)
                    if bg.searching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 10)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(bg.results) { item in
                            HStack(spacing: 8) {
                                AsyncImage(url: item.thumbnailURL) { phase in
                                    if let i = phase.image { i.resizable().aspectRatio(contentMode: .fill) } else { Color.black }
                                }
                                .frame(width: 96, height: 54).clipped().cornerRadius(4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.system(size: 11, weight: .semibold)).foregroundColor(DS.text).lineLimit(2)
                                    Text([item.kind == .video ? "Video" : "Image",
                                          item.width > 0 ? "\(item.width)×\(item.height)" : "",
                                          item.duration > 0 ? "\(Int(item.duration)) s" : "", item.credit].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.system(size: 9)).foregroundColor(DS.text3).lineLimit(1)
                                    if let st = bg.downloads[item.id] {
                                        Text(st).font(.system(size: 9)).foregroundColor(st.hasPrefix("Failed") ? DS.program : DS.ok).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Button(bg.catalog.contains(item.id) ? "Saved" : "Get") { bg.download(item) }
                                    .buttonStyle(.ds(.normal, .small)).disabled(bg.catalog.contains(item.id) || bg.downloads[item.id] == "Downloading…")
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(DS.bg2))
                        }
                    }
                    .padding(.horizontal, 10)
                }
                if !bg.message.isEmpty {
                    Text(bg.message).font(.system(size: 10)).foregroundColor(DS.amber).padding(.horizontal, 10).padding(.bottom, 6)
                }
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 440, maxHeight: .infinity)
            .background(DS.bg1)
        }
    }

    private func keyField(_ title: String, _ binding: Binding<String>, _ signup: URL?) -> some View {
        HStack(spacing: 6) {
            SecureField(title, text: binding).dsField()
            if let signup {
                Button("Get free key") { NSWorkspace.shared.open(signup) }.buttonStyle(.ds(.ghost, .small))
            }
        }
    }
}

struct LocalBackgroundCard: View {
    @EnvironmentObject var bg: BackgroundsModel
    let item: LocalBackground
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Color.black
                if let img = bg.thumbs[item.id] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.kind == .video ? "film" : "photo").font(.system(size: 20)).foregroundColor(DS.text3)
                }
                HStack(spacing: 3) {
                    if item.favorite { Image(systemName: "star.fill").foregroundColor(DS.amber) }
                    if item.kind == .video { Image(systemName: "play.fill") }
                }
                .font(.system(size: 9)).foregroundColor(.white).padding(4)
                .background(Capsule().fill(Color.black.opacity(0.55))).padding(4)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipped()
            Text(item.title).font(.system(size: 10.5, weight: .semibold)).foregroundColor(DS.text).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 4)
        }
        .background(DS.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? DS.accent : DS.lineSoft, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .onAppear { bg.thumbnail(item) }
    }
}

struct StarterPackSheet: View {
    @EnvironmentObject var bg: BackgroundsModel
    @Environment(\.dismiss) private var dismiss
    @State private var nasa = true
    @State private var generated = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "photo.stack.fill").font(.system(size: 28)).foregroundColor(DS.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free backgrounds for your services").font(.system(size: 17, weight: .bold))
                    Text("Download a starter set now — you can always add more from the Backgrounds library.").font(.system(size: 11)).foregroundColor(DS.text2)
                }
            }
            Toggle(isOn: $generated) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generated backgrounds").font(.system(size: 12, weight: .semibold))
                    Text("Worship blue, aurora, golden bokeh, heaven rays, night sky, waves… as HD stills plus 3 seamless loop videos. Made on this Mac — no internet, no licence limits.")
                        .font(.system(size: 10)).foregroundColor(DS.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: $nasa) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NASA space & sky media (public domain)").font(.system(size: 12, weight: .semibold))
                    Text("Earth from space and cloud videos, nebula, aurora and sunrise images from the NASA Image and Video Library. Needs internet; downloads run in the background.")
                        .font(.system(size: 10)).foregroundColor(DS.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("More free videos: choose Pixabay or Pexels in the Backgrounds library and paste a free API key from their websites.")
                .font(.system(size: 10)).foregroundColor(DS.text3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not now") { bg.dismissFirstRun(); dismiss() }.buttonStyle(.ds(.ghost))
                Spacer()
                Button("Install") { bg.installStarter(nasa: nasa, generated: generated); dismiss() }
                    .buttonStyle(.ds(.primary)).disabled(!nasa && !generated)
            }
        }
        .padding(20)
        .frame(width: 520)
        .preferredColorScheme(.dark)
        .onDisappear { UserDefaults.standard.set(true, forKey: "bg.firstRunOffered") }
    }
}
