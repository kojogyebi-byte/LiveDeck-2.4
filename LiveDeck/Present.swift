import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WebKit
import PresentationKit

// MARK: - Lower deck tabs (same page as the switcher)

enum DeckTab: Int { case inputs = 0, present = 1, dictionary = 2, images = 3, audio = 4, automation = 5, ai = 6, atem = 7 }

enum PresentLibraryTab: String, CaseIterable, Identifiable {
    case songs = "Songs"
    case bibles = "Bibles"
    var id: String { rawValue }
}

private let pPanel = DS.bg1
private let pBar = DS.bg2
private let pBG = DS.bg0
private let pAccent = DS.amber
private let pGreen = DS.ok

extension RGBAColor {
    var swiftUI: Color { Color(red: r, green: g, blue: b, opacity: a) }
}

// MARK: - Model

/// Songs & Bible operator state. Slides are sent to a Presentation input (a normal input on the
/// switcher), so lyrics and scripture can go to Preview, Program, or be keyed over Program.
final class PresentModel: ObservableObject {
    @Published var deck: Int = DeckTab.inputs.rawValue {
        didSet { if deck != oldValue { let d = deck; DispatchQueue.main.async { [weak self] in self?.engine?.deckChanged(to: d) } } }
    }
    /// The slide deck whose Format the control panel shows while another deck (Inputs, Media…) is open.
    var lastFormatDeck: Int = DeckTab.present.rawValue
    /// Media tab section: 0 web images · 1 backgrounds library · 2 generator
    @Published var mediaSection = 0
    @Published var tab: PresentLibraryTab = .songs
    @Published var editingSong = false
    @Published var findingLyrics = false
    let finder = LyricsFinder()

    let library: PresentationLibrary
    let looks: LookLibrary
    @Published var looksRevision = 0
    weak var engine: Engine?

    // Live control
    @Published var targetID: UUID?
    @Published var liveKey: String?
    /// Slides currently being stepped through, and the position (for the stage display).
    var liveSlides: [SlideContent] { liveList }
    var liveSlideIndex: Int { liveIndex }
    private var liveList: [SlideContent] = []
    private var livePrefix = ""
    private var liveIndex = -1
    let thumbs = NSCache<NSString, CGImageBox>()

    // Songs
    @Published var songs: [Song] = []
    @Published var songQuery = "" { didSet { refreshSongs() } }
    @Published var songFolder = "" { didSet { refreshSongs() } }
    @Published var favoritesOnly = false { didSet { refreshSongs() } }
    @Published var recentOnly = false { didSet { refreshSongs() } }
    @Published var selectedSongID: UUID? { didSet { if oldValue != selectedSongID { flushPendingSave(); if let id = selectedSongID { library.songs.markOpened(id) } } } }
    @Published var folders: [String] = []
    @Published var status = ""
    private var pendingSong: Song?
    private var saveWork: DispatchWorkItem?

    // Bibles
    @Published var bibles: [BibleVersionInfo] = []
    @Published var selectedBibleID: String? { didSet { UserDefaults.standard.set(selectedBibleID, forKey: "present.bible"); lookUp() } }
    @Published var catalog: [CatalogTranslation] = []
    @Published var catalogLoading = false
    @Published var catalogError = ""
    @Published var installPhase: [String: String] = [:]      // catalog id → phase text
    @Published var installErrors: [String: String] = [:]
    @Published var showCatalog = false
    @Published var reference = "John 3:16"
    @Published var passage: [BibleVerse] = []
    @Published var passageTitle = ""
    @Published var passageError = ""
    @Published var searchText = ""
    /// Extra Bible versions shown with the selected one (max 3).
    @Published var parallelBibleIDs: [String] = UserDefaults.standard.stringArray(forKey: "present.parallel") ?? [] {
        didSet { UserDefaults.standard.set(parallelBibleIDs, forKey: "present.parallel") }
    }
    @Published var searchResults: [BibleVerse] = []
    @Published var maxCharsPerSlide = 280
    private var installTasks: [String: URLSessionDownloadTask] = [:]

    init() {
        library = PresentationLibrary(root: PresentationLibrary.defaultRoot)
        looks = LookLibrary(libraryRoot: PresentationLibrary.defaultRoot)
        thumbs.countLimit = 400
        selectedBibleID = UserDefaults.standard.string(forKey: "present.bible")
        refreshSongs()
        refreshBibles()
        installBundledBibles()
        if !library.songs.damaged.isEmpty {
            status = "\(library.songs.damaged.count) unreadable song file(s) moved to Library/Damaged."
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.flushPendingSave()
        }
    }

    // MARK: Songs

    func refreshSongs() {
        var list = library.songs.search(songQuery, folder: songFolder.isEmpty ? nil : songFolder, favoritesOnly: favoritesOnly)
        if recentOnly {
            let recent = Set(library.songs.recent(25).map { $0.id })
            list = list.filter { recent.contains($0.id) }
                .sorted { ($0.meta.lastOpened ?? .distantPast) > ($1.meta.lastOpened ?? .distantPast) }
        }
        songs = list
        folders = library.songs.folders
    }

    func song(_ id: UUID?) -> Song? {
        guard let id else { return nil }
        if let p = pendingSong, p.id == id { return p }
        return library.songs[id]
    }

    func newSong() {
        flushPendingSave()
        let s = Song(title: "New Song")
        do {
            try library.songs.save(s)
            refreshSongs()
            selectedSongID = s.id
        } catch { status = "Could not create song: \(error.localizedDescription)" }
    }

    /// Autosave: edits are written 1.5 s after typing stops (and immediately on switch / quit).
    func scheduleSave(_ s: Song) {
        pendingSong = s
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flushPendingSave() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func flushPendingSave() {
        saveWork?.cancel(); saveWork = nil
        guard let s = pendingSong else { return }
        pendingSong = nil
        do {
            try library.songs.save(s)
            if let i = songs.firstIndex(where: { $0.id == s.id }) { songs[i] = s }
            folders = library.songs.folders
        } catch { status = "Save failed: \(error.localizedDescription)" }
    }

    func duplicateSong(_ id: UUID) {
        flushPendingSave()
        do { if let d = try library.songs.duplicate(id) { refreshSongs(); selectedSongID = d.id } }
        catch { status = error.localizedDescription }
    }

    func toggleFavorite(_ id: UUID) {
        flushPendingSave()
        guard let s = library.songs[id] else { return }
        try? library.songs.setFavorite(id, !s.meta.favorite)
        refreshSongs()
    }

    func deleteSong(_ id: UUID) {
        if pendingSong?.id == id { pendingSong = nil; saveWork?.cancel() }
        do {
            try library.songs.delete(id)
            if selectedSongID == id { selectedSongID = nil }
            refreshSongs()
            status = "Song moved to Trash (restore from the Library menu)."
        } catch { status = error.localizedDescription }
    }

    var trashedSongs: [Song] { library.songs.trashed }

    func restoreSong(_ id: UUID) {
        do { try library.songs.restoreFromTrash(id); refreshSongs(); selectedSongID = id }
        catch { status = error.localizedDescription }
    }

    func versions(_ id: UUID) -> [(date: Date, url: URL)] { library.songs.versions(of: id) }

    func restoreVersion(_ url: URL, of id: UUID) {
        pendingSong = nil; saveWork?.cancel()
        do {
            _ = try library.songs.restoreVersion(url)
            refreshSongs()
            selectedSongID = nil
            DispatchQueue.main.async { self.selectedSongID = id }
            status = "Previous version restored."
        } catch { status = error.localizedDescription }
    }

    func importSongs() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose song files: plain text, SongSelect (.txt/.usr), ChordPro, OpenLyrics or OpenSong"
        panel.begin { [weak self] resp in
            guard resp == .OK, let self else { return }
            let urls = panel.urls
            DispatchQueue.global(qos: .userInitiated).async {
                var imported: [Song] = []
                var failures = 0
                for u in urls {
                    if let list = try? SongImporter.importFile(u), !list.isEmpty { imported += list } else { failures += 1 }
                }
                DispatchQueue.main.async {
                    for s in imported { _ = try? self.library.songs.save(s) }
                    self.refreshSongs()
                    if let first = imported.first { self.selectedSongID = first.id }
                    self.status = "Imported \(imported.count) song(s)" + (failures > 0 ? ", \(failures) file(s) not recognised." : ".")
                }
            }
        }
    }

    // MARK: Bibles

    /// Copies the Bibles that ship inside the app (Contents/Resources/Bibles) into the library once.
    /// A Bible the user deletes later is not added again.
    func installBundledBibles() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Bibles"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let packages = files.filter { $0.pathExtension == BibleLibrary.fileExtension }
        var done = Set(UserDefaults.standard.stringArray(forKey: "bundledBibles.installed") ?? [])
        let todo = packages.filter { !done.contains($0.lastPathComponent) }
        guard !todo.isEmpty else { return }
        let dir = library.bibles.directory
        DispatchQueue.global(qos: .utility).async {
            var added: [String] = []
            for f in todo {
                if (try? BibleLibrary.installPackage(f, into: dir)) != nil { added.append(f.lastPathComponent) }
                done.insert(f.lastPathComponent)      // installed now, or already present
            }
            DispatchQueue.main.async {
                UserDefaults.standard.set(Array(done), forKey: "bundledBibles.installed")
                let hadNone = self.bibles.isEmpty
                self.refreshBibles()
                if hadNone, let kjv = self.bibles.first(where: { $0.abbreviation == "KJV" }) { self.selectedBibleID = kjv.id }
                if !added.isEmpty { self.status = "Added \(added.count) English Bible\(added.count == 1 ? "" : "s") to the library." }
            }
        }
    }

    func refreshBibles() {
        bibles = library.bibles.installed()
        if selectedBibleID == nil || !bibles.contains(where: { $0.id == selectedBibleID }) {
            selectedBibleID = bibles.first?.id
        }
    }

    var currentStore: BibleStore? { selectedBibleID.flatMap { library.bibles.store($0) } }

    func lookUp() {
        passageError = ""
        guard let store = currentStore else { passage = []; passageTitle = ""; return }
        guard let ref = store.parseReference(reference) else {
            passage = []; passageTitle = ""
            if !reference.trimmingCharacters(in: .whitespaces).isEmpty { passageError = "Couldn't read that reference. Try e.g. John 3:16-18 or Ps 23." }
            return
        }
        passage = store.verses(ref)
        passageTitle = ref.display(bookName: store.bookName(ref.book)) + " (\(store.info.abbreviation))"
        if passage.isEmpty { passageError = "Not found in \(store.info.abbreviation)." }
    }

    func runSearch() {
        searchResults = currentStore?.search(searchText, limit: 200) ?? []
    }

    // MARK: Bible search assistant

    @Published var suggestions: [BibleSuggestion] = []
    @Published var liveResults: [BibleVerse] = []
    @Published var liveBookFilter: Int?
    @Published var assistQuery = ""
    @Published var assistSelection = -1
    private var assistWork: DispatchWorkItem?
    private var suppressText: String?

    /// Called as the operator types in the Bible box: instant book/reference completions, then (debounced)
    /// matching verses and phrase completions.
    func updateAssist(_ text: String) {
        assistWork?.cancel()
        if let s = suppressText, s == text { suppressText = nil; return }
        suppressText = nil
        let q = text.trimmingCharacters(in: .whitespaces)
        assistQuery = q
        guard !q.isEmpty else { suggestions = []; liveResults = []; liveBookFilter = nil; return }
        let extra = currentStore?.bookNameMap ?? [:]
        let isRef = BibleAssist.looksLikeReference(q, extraNames: extra)
        var base = BibleAssist.referenceSuggestions(q, extraNames: extra)
        if !isRef { base += BibleAssist.themeSuggestions(q) }
        suggestions = base
        let hasDigits = q.contains { $0.isNumber }
        let wantsWords = q.count >= 3 && (!isRef || (!hasDigits && q.split(separator: " ").count >= 2))
        guard wantsWords else { liveResults = []; liveBookFilter = nil; return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.assistQuery == q else { return }
            let res = self.currentStore?.liveSearch(q, limit: 120) ?? []
            let phrases = BibleAssist.phraseCompletions(query: q, in: res)
            self.liveResults = res
            if let f = self.liveBookFilter, !res.contains(where: { $0.book == f }) { self.liveBookFilter = nil }
            var seen = Set(base.map { $0.text.lowercased() })
            self.suggestions = base + phrases.filter { seen.insert($0.text.lowercased()).inserted }
        }
        assistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    func applySuggestion(_ s: BibleSuggestion) {
        switch s.kind {
        case .book, .phrase:
            reference = s.text
            updateAssist(s.text)
        case .reference, .popular:
            reference = s.text
            lookUp()
            clearAssist()
        }
    }

    func openVerse(_ v: BibleVerse, following: Int = 0, wholeChapter: Bool = false) {
        let name = currentStore?.bookName(v.book) ?? BibleBookInfo.byNumber(v.book)?.name ?? ""
        reference = wholeChapter ? "\(name) \(v.chapter)" : (following > 0 ? "\(name) \(v.chapter):\(v.verse)-\(v.verse + following)" : "\(name) \(v.chapter):\(v.verse)")
        lookUp()
        clearAssist()
    }

    func clearAssist() {
        assistWork?.cancel(); suggestions = []; liveResults = []; liveBookFilter = nil; assistQuery = ""; assistSelection = -1
        suppressText = reference
    }

    func loadCatalog() {
        guard !catalogLoading else { return }
        catalogLoading = true; catalogError = ""
        FreeUseBibleAPI.fetchCatalog { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.catalogLoading = false
                switch result {
                case .success(let list): self.catalog = list
                case .failure(let e): self.catalogError = e.localizedDescription
                }
            }
        }
    }

    func isInstalled(_ t: CatalogTranslation) -> Bool { library.bibles.isInstalled(t.id) }

    func install(_ t: CatalogTranslation) {
        guard installPhase[t.id] == nil else { return }
        installErrors[t.id] = nil
        installPhase[t.id] = "Starting…"
        let task = FreeUseBibleAPI.install(t, into: library.bibles.directory, phase: { [weak self] p in
            DispatchQueue.main.async { if self?.installPhase[t.id] != nil { self?.installPhase[t.id] = p } }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.installPhase[t.id] = nil
                self.installTasks[t.id] = nil
                switch result {
                case .success(let info):
                    self.refreshBibles()
                    if self.selectedBibleID == nil { self.selectedBibleID = info.id }
                    self.status = "Installed \(info.abbreviation) — \(info.verseCount) verses."
                case .failure(let e):
                    self.installErrors[t.id] = e.localizedDescription
                }
            }
        })
        installTasks[t.id] = task
    }

    func cancelInstall(_ id: String) {
        installTasks[id]?.cancel()
        installTasks[id] = nil
        installPhase[id] = nil
    }

    func removeBible(_ id: String) {
        do { try library.bibles.remove(id); refreshBibles() } catch { status = error.localizedDescription }
    }

    func renameBible(_ id: String, name: String, abbreviation: String) {
        do { try library.bibles.rename(id, name: name, abbreviation: abbreviation); refreshBibles(); lookUp() }
        catch { status = error.localizedDescription }
    }

    func importBibleFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose Bible files (JSON, Zefania/OSIS XML, USFM, CSV, .ldbible), a folder of them, or a .zip"
        panel.begin { [weak self] resp in
            guard resp == .OK, let self else { return }
            self.importBibles(panel.urls)
        }
    }

    /// Imports any mix of Bible files, folders and zip archives (each translation becomes its own Bible).
    func importBibles(_ urls: [URL]) {
        let dir = library.bibles.directory
        status = "Importing Bibles…"
        DispatchQueue.global(qos: .userInitiated).async {
            var sources: [URL] = []
            var temps: [URL] = []
            for u in urls {
                if u.pathExtension.lowercased() == "zip" {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bibles-\(UUID().uuidString)")
                    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    p.arguments = ["-x", "-k", u.path, tmp.path]
                    try? p.run(); p.waitUntilExit()
                    sources.append(tmp); temps.append(tmp)
                } else { sources.append(u) }
            }
            let result = BibleImporter.importBatch(sources, into: dir) { msg in
                DispatchQueue.main.async { self.status = msg }
            }
            for t in temps { try? FileManager.default.removeItem(at: t) }
            DispatchQueue.main.async {
                self.refreshBibles()
                if let last = result.imported.last { self.selectedBibleID = last.id }
                var parts: [String] = []
                if !result.imported.isEmpty { parts.append("Imported \(result.imported.count): " + result.imported.map { $0.abbreviation }.joined(separator: ", ")) }
                if !result.skipped.isEmpty { parts.append("already installed: \(result.skipped.count)") }
                if !result.failed.isEmpty { parts.append("failed: " + result.failed.joined(separator: "; ")) }
                self.status = parts.isEmpty ? "No Bible files found." : parts.joined(separator: " · ") + "."
            }
        }
    }

    // MARK: Live control

    /// The Presentation input slides are sent to (no side effects — safe inside views).
    func currentTarget() -> PresentationSource? {
        guard let engine else { return nil }
        if let id = targetID, let s = engine.sources.first(where: { $0.id == id }) as? PresentationSource { return s }
        return engine.sources.compactMap { $0 as? PresentationSource }.first
    }

    @discardableResult
    func ensureTarget() -> PresentationSource? {
        if let t = currentTarget() { targetID = t.id; return t }
        guard let engine else { return nil }
        let s = engine.addPresentationInput()
        targetID = s.id
        return s
    }

    func goLive(_ list: [SlideContent], index: Int, prefix: String) {
        guard list.indices.contains(index), let t = ensureTarget() else { return }
        liveList = list; livePrefix = prefix; liveIndex = index
        t.show(list[index])
        liveKey = "\(prefix)#\(index)"
    }

    func step(_ delta: Int) {
        guard !liveList.isEmpty else { return }
        let i = liveIndex + delta
        guard liveList.indices.contains(i) else { return }
        goLive(liveList, index: i, prefix: livePrefix)
    }

    func clearText() { currentTarget()?.textCleared = true; liveKey = nil }
    func toggleBackground() { if let t = currentTarget() { t.backgroundCleared.toggle() } }

    func sendToPreview() {
        guard let t = ensureTarget(), let engine else { return }
        engine.setPreview(t.id); engine.selectedSourceID = t.id
    }
    func cutToProgram() {
        guard let t = ensureTarget(), let engine else { return }
        engine.keyedSources.remove(t.id)
        engine.setPreview(t.id); engine.cut()
    }
    func toggleKey() {
        guard let t = ensureTarget(), let engine else { return }
        engine.toggleKey(t.id)
    }

    func songSlides(_ song: Song, look: SlideLook) -> [SlideContent] {
        let credit = [song.author, song.copyright, song.ccliNumber.isEmpty ? "" : "CCLI Song #\(song.ccliNumber)"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let gen = song.generatedSlides(linesPerSlide: look.linesPerSlide > 0 ? look.linesPerSlide : nil)
        return gen.enumerated().map { i, g in
            SlideContent(title: song.title, body: g.lines.joined(separator: "\n"),
                         footer: i == 0 ? credit : "", label: g.label)
        }
    }

    func toggleParallel(_ id: String) {
        if let i = parallelBibleIDs.firstIndex(of: id) { parallelBibleIDs.remove(at: i) }
        else if parallelBibleIDs.count < 3 { parallelBibleIDs.append(id) }
        else { status = "Up to 4 versions can be shown together." }
    }

    var activeParallelStores: [BibleStore] {
        parallelBibleIDs.filter { $0 != selectedBibleID }.compactMap { library.bibles.store($0) }
    }

    func scriptureSlides(look: SlideLook) -> [SlideContent] {
        guard let store = currentStore, !passage.isEmpty else { return [] }
        let abbr = store.info.abbreviation
        let extras = activeParallelStores
        if !extras.isEmpty, let ref = store.parseReference(reference) {
            let others = extras.map { (label: $0.info.abbreviation, verses: $0.verses(ref)) }
            let slides = ParallelScripture.slides(primaryLabel: abbr, primary: passage, others: others,
                                                  maxChars: look.maxCharsPerSlide, verseNumbers: look.showVerseNumbers)
            let labels = ([abbr] + others.map { $0.label }).joined(separator: " · ")
            return slides.map { p in
                let r = ScriptureReference(book: p.first.book, startChapter: p.first.chapter, startVerse: p.first.verse,
                                           endChapter: p.last.chapter, endVerse: p.last.verse)
                let refText = r.display(bookName: store.bookName(p.first.book))
                return SlideContent(title: "", body: p.columns.first?.text ?? "", footer: refText + "  (" + labels + ")",
                                    label: refText, columns: p.columns.map { SlideColumn(label: $0.label, text: $0.text) })
            }
        }
        return BibleStore.slideTexts(passage, maxChars: look.maxCharsPerSlide, verseNumbers: look.showVerseNumbers).map { p in
            let r = ScriptureReference(book: p.first.book, startChapter: p.first.chapter, startVerse: p.first.verse,
                                       endChapter: p.last.chapter, endVerse: p.last.verse)
            let ref = r.display(bookName: store.bookName(p.first.book)) + (abbr.isEmpty ? "" : " (\(abbr))")
            return SlideContent(title: "", body: p.text, footer: ref, label: ref)
        }
    }

    /// Cached slide thumbnail rendered with the target's look.
    func thumbnail(_ c: SlideContent, source: SlideSource, width: Int = 384) -> CGImage? {
        let key = "\(source.look.hashValue)|\(c.hashValue)|\(width)" as NSString
        if let b = thumbs.object(forKey: key) { return b.image }
        guard let img = source.still(c, size: CGSize(width: width, height: width * 9 / 16)) else { return nil }
        thumbs.setObject(CGImageBox(img), forKey: key)
        return img
    }

    /// Saves lyrics found online (after editing) as a new song in the library and opens it.
    func saveFoundLyrics(title: String, artist: String, text: String, source: String) {
        let body = LyricsSearch.clean(text)
        guard !body.isEmpty else { status = "Nothing to save — the lyrics are empty."; return }
        flushPendingSave()
        let song = LyricsSearch.song(title: title, artist: artist, lyrics: body, source: source)
        do {
            try library.songs.save(song)
            songQuery = ""; songFolder = ""; favoritesOnly = false; recentOnly = false
            refreshSongs()
            tab = .songs
            selectedSongID = song.id
            findingLyrics = false
            editingSong = true
            status = "Saved “\(song.title)” to the song library — check the verse and chorus labels, then click slides to go live."
        } catch { status = "Could not save song: \(error.localizedDescription)" }
    }

    func saveLook(_ look: SlideLook, as name: String) {
        do { try looks.save(look, as: name); looksRevision += 1; status = "Saved look “\(name)”." }
        catch { status = "Could not save look: \(error.localizedDescription)" }
    }
    func deleteLook(_ id: UUID) { try? looks.delete(id); looksRevision += 1 }
}

final class CGImageBox {
    let image: CGImage
    init(_ i: CGImage) { image = i }
}

// MARK: - Library lists & song editor

struct SongListPane: View {
    @EnvironmentObject var present: PresentModel
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search title, author, lyrics", text: $present.songQuery)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 6) {
                Toggle("★ Favourites", isOn: $present.favoritesOnly).toggleStyle(.button)
                Toggle("Recent", isOn: $present.recentOnly).toggleStyle(.button)
                Menu(present.songFolder.isEmpty ? "All folders" : present.songFolder) {
                    Button("All folders") { present.songFolder = "" }
                    if !present.folders.isEmpty { Divider() }
                    ForEach(present.folders, id: \.self) { f in Button(f) { present.songFolder = f } }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }
            .font(.system(size: 10))
            HStack(spacing: 6) {
                Button { present.newSong() } label: { Label("New", systemImage: "plus") }
                Button { present.importSongs() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Button { present.findingLyrics = true } label: { Label("Find online", systemImage: "globe") }
                    .help("Search free lyrics sources on the internet, edit and save")
                Spacer()
                Menu {
                    let trashed = present.trashedSongs
                    if trashed.isEmpty { Text("Trash is empty") }
                    ForEach(trashed) { s in Button("Restore “\(s.title)”") { present.restoreSong(s.id) } }
                } label: { Image(systemName: "trash") }
                .menuStyle(.borderlessButton).fixedSize().help("Restore deleted songs")
            }
            .font(.system(size: 11))
            List(selection: $present.selectedSongID) {
                ForEach(present.songs) { s in
                    SongRow(song: s).tag(s.id)
                        .contextMenu {
                            Button(s.meta.favorite ? "Remove from favourites" : "Add to favourites") { present.toggleFavorite(s.id) }
                            Button("Duplicate") { present.duplicateSong(s.id) }
                            LinkSendMenu(title: "Send to computer") { pid, link in link.shareSong(s, to: pid) }
                            Divider()
                            Button("Delete", role: .destructive) { present.deleteSong(s.id) }
                        }
                }
            }
            .listStyle(.sidebar)
            Text("\(present.songs.count) song(s)").font(.system(size: 9)).foregroundColor(.secondary)
        }
        .padding(8)
    }
}

struct SongRow: View {
    let song: Song
    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(song.author.isEmpty ? " " : song.author).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if song.meta.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundColor(pAccent) }
        }
    }
}

struct SongEditor: View {
    @EnvironmentObject var present: PresentModel
    let initial: Song
    @State private var draft: Song
    @State private var lyrics: String
    @State private var tagsText: String

    init(initial: Song) {
        self.initial = initial
        _draft = State(initialValue: initial)
        _lyrics = State(initialValue: initial.sections.isEmpty ? "" : initial.lyricText)
        _tagsText = State(initialValue: initial.meta.tags.joined(separator: ", "))
    }

    var body: some View {
        HSplitView {
            editorColumn.frame(minWidth: 340, idealWidth: 460)
            SlidePreviewGrid(song: draft).frame(minWidth: 260)
        }
        .onChange(of: draft) { newValue in present.scheduleSave(newValue) }
        .onChange(of: lyrics) { newValue in draft.sections = SongText.parse(newValue) }
        .onChange(of: tagsText) { newValue in
            draft.meta.tags = newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Title", text: $draft.meta.title).font(.system(size: 16, weight: .semibold))
                Button { draft.meta.favorite.toggle() } label: {
                    Image(systemName: draft.meta.favorite ? "star.fill" : "star").foregroundColor(draft.meta.favorite ? pAccent : .secondary)
                }.buttonStyle(.plain).help("Favourite")
                historyMenu
            }
            HStack {
                TextField("Author", text: $draft.author)
                TextField("CCLI #", text: $draft.ccliNumber).frame(width: 90)
            }
            TextField("Copyright", text: $draft.copyright)
            HStack {
                TextField("Folder (e.g. Hymns)", text: $draft.meta.folder)
                TextField("Tags, comma separated", text: $tagsText)
            }
            Text("LYRICS — put section names on their own line (Verse 1, Chorus, Bridge, Tag…). A blank line starts a new slide.")
                .font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
            TextEditor(text: $lyrics)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .background(Color.black.opacity(0.35))
                .cornerRadius(4)
                .frame(minHeight: 200)
            HStack(spacing: 8) {
                Text("Order").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                TextField(draft.defaultArrangement.isEmpty ? "V1 C V2 C B C" : draft.defaultArrangement, text: $draft.arrangement)
                    .font(.system(size: 12).monospacedDigit())
                Button("As written") { draft.arrangement = "" }.font(.system(size: 10))
            }
            HStack(spacing: 8) {
                Text("Lines per slide").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                Stepper(draft.linesPerSlide == 0 ? "Use blank-line breaks" : "\(draft.linesPerSlide)",
                        value: $draft.linesPerSlide, in: 0...8)
                    .font(.system(size: 11))
                Spacer()
                Text("Sections: " + (draft.sections.isEmpty ? "—" : draft.sections.map { $0.code }.joined(separator: " ")))
                    .font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
    }

    private var historyMenu: some View {
        Menu {
            let versions = present.versions(draft.id)
            if versions.isEmpty { Text("No earlier versions yet") }
            ForEach(versions, id: \.url) { v in
                Button("Restore " + v.date.formatted(date: .abbreviated, time: .shortened)) {
                    present.restoreVersion(v.url, of: draft.id)
                }
            }
        } label: { Image(systemName: "clock.arrow.circlepath") }
        .menuStyle(.borderlessButton).fixedSize().help("Version history")
    }
}

struct SlideTextCard: View {
    let index: Int
    let label: String
    let color: Color
    let text: String
    let width: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                Text(text)
                    .font(.system(size: max(8, width / 20), weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.4)
                    .padding(width * 0.05)
            }
            .frame(width: width, height: width * 9 / 16)
            HStack(spacing: 4) {
                Text("\(index)").font(.system(size: 9, weight: .heavy))
                Text(label).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 5).frame(width: width, height: 16).background(color)
        }
        .overlay(Rectangle().stroke(Color(white: 0.25), lineWidth: 1))
    }
}

struct BibleListPane: View {
    @EnvironmentObject var present: PresentModel
    @State private var renaming: BibleVersionInfo?
    @State private var newName = ""
    @State private var newAbbr = ""
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button { present.showCatalog = true; present.loadCatalog() } label: { Label("Get Bibles…", systemImage: "icloud.and.arrow.down") }
                Button { present.importBibleFiles() } label: { Label("Import file…", systemImage: "square.and.arrow.down") }
                Spacer()
            }
            .font(.system(size: 11))
            if present.bibles.isEmpty {
                VStack(spacing: 6) {
                    Text("No Bibles installed yet.").font(.system(size: 11, weight: .semibold))
                    Text("Use Get Bibles… to download free translations (1000+ in many languages), or Import file… for a translation you are licensed to use.")
                        .font(.system(size: 10)).foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .padding(.vertical, 20)
            }
            List(selection: $present.selectedBibleID) {
                ForEach(present.bibles) { b in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(b.abbreviation).font(.system(size: 12, weight: .heavy))
                            Text(b.languageName.isEmpty ? b.language : b.languageName).font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        Text(b.name).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    }
                    .tag(b.id)
                    .contextMenu {
                        Button("Rename…") { renaming = b; newName = b.name; newAbbr = b.abbreviation }
                        Divider()
                        Button("Remove", role: .destructive) { present.removeBible(b.id) }
                    }
                }
            }
            .listStyle(.sidebar)
            Spacer(minLength: 0)
        }
        .padding(8)
        .sheet(item: $renaming) { b in
            VStack(alignment: .leading, spacing: 10) {
                Text("RENAME BIBLE").font(.system(size: 12, weight: .heavy))
                TextField("Name", text: $newName)
                TextField("Abbreviation", text: $newAbbr)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }
                    Button("Save") { present.renameBible(b.id, name: newName, abbreviation: newAbbr); renaming = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .textFieldStyle(.roundedBorder).padding(16).frame(width: 360)
        }
    }
}

// MARK: - Bible catalogue (Free Use Bible API)

struct BibleCatalogView: View {
    @EnvironmentObject var present: PresentModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var language = ""
    @State private var completeOnly = true

    private var languages: [String] {
        Array(Set(present.catalog.map { $0.languageLabel }.filter { !$0.isEmpty })).sorted()
    }

    private var filtered: [CatalogTranslation] {
        let words = query.searchFolded.split(separator: " ").map(String.init)
        return present.catalog.filter { t in
            if completeOnly && !t.isComplete { return false }
            if !language.isEmpty && t.languageLabel != language { return false }
            if words.isEmpty { return true }
            let hay = t.searchText
            return words.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("GET BIBLES").font(.system(size: 13, weight: .heavy)).kerning(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Free translations from the Free Use Bible API (bible.helloao.org): no key, no usage restrictions. Each download is stored on this Mac and works offline. Licensed translations (e.g. NKJV, NIV, AMP) are not offered here — import them from a file you are licensed to use.")
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Search name, abbreviation or language", text: $query).textFieldStyle(.roundedBorder)
                Picker("Language", selection: $language) {
                    Text("All languages").tag("")
                    ForEach(languages, id: \.self) { l in Text(l).tag(l) }
                }
                .frame(width: 220)
                Toggle("Complete Bibles only", isOn: $completeOnly)
            }
            .font(.system(size: 11))
            if present.catalogLoading {
                HStack { ProgressView().controlSize(.small); Text("Loading catalogue…").font(.system(size: 11)) }
            }
            if !present.catalogError.isEmpty {
                HStack {
                    Text(present.catalogError).font(.system(size: 11)).foregroundColor(.orange)
                    Button("Retry") { present.loadCatalog() }
                }
            }
            List(filtered) { t in CatalogRow(t: t) }
            Text("\(filtered.count) of \(present.catalog.count) translations").font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(16)
        .frame(width: 760, height: 620)
        .preferredColorScheme(.dark)
    }
}

struct CatalogRow: View {
    @EnvironmentObject var present: PresentModel
    let t: CatalogTranslation
    var body: some View {
        HStack(spacing: 10) {
            Text(t.shortName ?? t.id).font(.system(size: 11, weight: .heavy).monospacedDigit()).frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.displayName).font(.system(size: 12)).lineLimit(1)
                Text("\(t.languageLabel) · \(t.totalNumberOfVerses ?? 0) verses · \(t.numberOfBooks ?? 0) books")
                    .font(.system(size: 9)).foregroundColor(.secondary)
                if let err = present.installErrors[t.id] {
                    Text(err).font(.system(size: 9)).foregroundColor(.orange).lineLimit(2)
                }
            }
            Spacer()
            if let phase = present.installPhase[t.id] {
                ProgressView().controlSize(.small)
                Text(phase).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                Button("Cancel") { present.cancelInstall(t.id) }.font(.system(size: 10))
            } else if present.isInstalled(t) {
                Label("Installed", systemImage: "checkmark.circle.fill").font(.system(size: 10)).foregroundColor(pGreen)
            } else {
                Button("Install") { present.install(t) }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Dictionary model

final class DictionaryModel: ObservableObject {
    weak var engine: Engine?
    let custom: CustomDictionaryStore

    @Published var kind: DictionaryKind { didSet { UserDefaults.standard.set(kind.rawValue, forKey: "dict.kind") } }
    @Published var language: String { didSet { UserDefaults.standard.set(language, forKey: "dict.lang") } }
    @Published var query = ""
    @Published var results: [WordEntry] = []
    @Published var selectedID: UUID?
    @Published var loading = false
    @Published var message = ""
    @Published var targetID: UUID?
    @Published var customList: [CustomDictionary] = []

    init() {
        custom = CustomDictionaryStore(libraryRoot: PresentationLibrary.defaultRoot)
        kind = DictionaryKind(rawValue: UserDefaults.standard.string(forKey: "dict.kind") ?? "") ?? .offline
        language = UserDefaults.standard.string(forKey: "dict.lang") ?? "en"
        customList = custom.dictionaries
    }

    var selected: WordEntry? { results.first { $0.id == selectedID } ?? results.first }

    func search() {
        let word = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        message = ""; results = []; selectedID = nil
        switch kind {
        case .offline:
            let store = OfflineDictionaryStore.shared
            guard store.isReady else {
                store.prepare { [weak self] in if OfflineDictionaryStore.shared.isReady { self?.search() } else { self?.message = "Install the offline dictionary first (button above)." } }
                return
            }
            results = store.lookup(word)
            if results.isEmpty { message = "Not found in the offline dictionary. Check the spelling, or try English Dictionary or Wiktionary (internet)." }
            selectedID = results.first?.id
        case .macOS:
            if let text = engine?.defineWord(word) {
                results = [WordLookup.entryFromPlainDefinition(word: word, text: text, source: "macOS Dictionary")]
            } else { message = "No definition in the dictionaries enabled in the macOS Dictionary app." }
            selectedID = results.first?.id
        case .custom:
            results = custom.lookup(word)
            if results.isEmpty { message = customList.isEmpty ? "No dictionaries imported yet — use Import." : "Not found in your dictionaries." }
            selectedID = results.first?.id
        default:
            loading = true
            let k = kind
            WordLookup.fetch(k, word: word, language: language) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.kind == k else { return }
                    self.loading = false
                    switch result {
                    case .success(let list):
                        self.results = list
                        self.selectedID = list.first?.id
                        if list.isEmpty { self.message = "No results for “\(word)” in \(k.rawValue)." }
                    case .failure(let e):
                        self.message = "Lookup failed: \(e.localizedDescription) (check the internet connection)"
                    }
                }
            }
        }
    }

    func currentTarget() -> DictionarySource? {
        guard let engine else { return nil }
        if let id = targetID, let s = engine.sources.first(where: { $0.id == id }) as? DictionarySource { return s }
        return engine.sources.compactMap { $0 as? DictionarySource }.first
    }

    @discardableResult
    func ensureTarget() -> DictionarySource? {
        if let t = currentTarget() { targetID = t.id; return t }
        guard let engine else { return nil }
        let s = engine.addDictionaryInput()
        targetID = s.id
        return s
    }

    func loadIntoInput() {
        guard let e = selected, let t = ensureTarget() else { return }
        t.showEntry(e)
    }
    func preview() { loadIntoInput(); if let t = currentTarget(), let engine { engine.setPreview(t.id); engine.selectedSourceID = t.id } }
    func program() { loadIntoInput(); if let t = currentTarget(), let engine { engine.keyedSources.remove(t.id); engine.setPreview(t.id); engine.cut() } }
    func key() { loadIntoInput(); if let t = currentTarget(), let engine { engine.toggleKey(t.id) } }
    func overlayLayer() {
        guard let e = selected, let engine else { return }
        engine.showDefinition(word: e.word, definition: e.bodyText(maxSenses: currentTarget()?.look.maxSenses ?? 2, examples: false))
    }
    func clear() { currentTarget()?.showEntry(nil) }

    func importCustom() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.message = "Choose dictionary files: CSV or TSV (word, definition) or JSON"
        panel.begin { [weak self] resp in
            guard resp == .OK, let self else { return }
            var n = 0
            var failed: [String] = []
            for u in panel.urls {
                if (try? self.custom.importFile(u)) != nil { n += 1 } else { failed.append(u.lastPathComponent) }
            }
            self.customList = self.custom.dictionaries
            self.message = "Imported \(n) dictionar\(n == 1 ? "y" : "ies")" + (failed.isEmpty ? "." : ". Not recognised: " + failed.joined(separator: ", "))
        }
    }
    func toggleCustom(_ id: UUID, _ on: Bool) { custom.setEnabled(id, on); customList = custom.dictionaries }
    func removeCustom(_ id: UUID) { custom.remove(id); customList = custom.dictionaries }
}

// MARK: - Helpers

func colorBinding(_ b: Binding<RGBAColor>) -> Binding<Color> {
    Binding(get: { b.wrappedValue.swiftUI }, set: { c in
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? NSColor.white
        b.wrappedValue = RGBAColor(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    })
}

func intBinding(_ b: Binding<Int>) -> Binding<Double> {
    Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = Int($0.rounded()) })
}

// MARK: - Songs & Bible deck

struct PresentDeck: View {
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var engine: Engine
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    DSSegmented(selection: $present.tab, options: [(PresentLibraryTab.songs, "Songs"), (PresentLibraryTab.bibles, "Bible")])
                }
                .padding(8).background(DS.bg2)
                if present.tab == .songs { SongListPane() } else { BibleListPane() }
            }
            .background(DS.bg1)
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 380)

            PresentCenter()
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $present.showCatalog) { BibleCatalogView().environmentObject(present) }
    }
}

struct PresentOperatorBar: View {
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var engine: Engine
    var body: some View {
        let target = present.currentTarget()
        let keyed = target.map { engine.isKeyed($0.id) } ?? false
        let onAir = target.map { engine.programID == $0.id } ?? false
        HStack(spacing: 6) {
            Menu {
                ForEach(engine.sources.compactMap { $0 as? PresentationSource }, id: \.id) { s in
                    Button(s.name) { present.targetID = s.id }
                }
                Divider()
                Button("New Presentation input") { let s = engine.addPresentationInput(); present.targetID = s.id }
                if let t = target { Button("Rename “\(t.name)”…") { engine.renamingSourceID = t.id } }
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(onAir ? DS.program : (keyed ? DS.amber : DS.text3)).frame(width: 7, height: 7)
                    Text(target?.name ?? "No presentation input").font(.system(size: 11, weight: .semibold))
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Which input receives the slides you click")

            Divider().frame(height: 18)
            Button { present.step(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.ds(.normal, .small)).help("Previous slide (←, Page Up)")
            Button { present.step(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.ds(.normal, .small)).help("Next slide (→, Page Down)")
            Button("Clear text") { present.clearText() }.buttonStyle(.ds(.normal, .small))
            Button(target?.backgroundCleared == true ? "Show BG" : "Hide BG") { present.toggleBackground() }
                .buttonStyle(.ds(.normal, .small, active: target?.backgroundCleared == true))
            Spacer(minLength: 6)
            Button("Preview") { present.sendToPreview() }.buttonStyle(.ds(.preview, .small, active: target.map { engine.previewID == $0.id } ?? false))
            Button("Program") { present.cutToProgram() }.buttonStyle(.ds(.program, .small, active: onAir))
            Button("Key PVW") { if let t = present.ensureTarget() { engine.toggleKeyPreview(t.id) } }
                .buttonStyle(.ds(.amber, .small, active: target.map { engine.isPreviewKeyed($0.id) } ?? false))
                .help("Check the words over the Preview picture first — they go on air with the next CUT/AUTO")
            Button("Key PGM") { present.toggleKey() }.buttonStyle(.ds(.amber, .small, active: keyed))
                .help("Show the slides on top of whatever is on Program (use a transparent background)")
        }
        .padding(.horizontal, 8).frame(height: 38).background(DS.bg2)
        .overlay(Rectangle().fill(DS.lineSoft).frame(height: 1), alignment: .bottom)
    }
}

struct PresentCenter: View {
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var engine: Engine
    var body: some View {
        VStack(spacing: 0) {
            PresentOperatorBar()
            if present.tab == .songs && present.findingLyrics { LyricsFinderView(finder: present.finder) }
            else if present.tab == .songs { songArea } else { ScriptureArea() }
            if !present.status.isEmpty {
                Text(present.status).font(.system(size: 10)).foregroundColor(DS.text2).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 20).background(DS.bg2)
            }
        }
        .background(DS.bg1)
    }

    @ViewBuilder private var songArea: some View {
        if let id = present.selectedSongID, let song = present.song(id) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).font(.system(size: 13, weight: .bold)).foregroundColor(DS.text).lineLimit(1)
                    Text([song.author, song.arrangement].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                        .font(.system(size: 10)).foregroundColor(DS.text2).lineLimit(1)
                }
                Spacer()
                Button { present.findingLyrics = true } label: { Label("Find lyrics online", systemImage: "globe") }
                    .buttonStyle(.ds(.normal, .small))
                Button(present.editingSong ? "Done editing" : "Edit lyrics") { present.editingSong.toggle() }
                    .buttonStyle(.ds(.normal, .small, active: present.editingSong))
            }
            .padding(.horizontal, 10).frame(height: 40)
            if present.editingSong {
                SongEditor(initial: song).id(id)
            } else if let t = present.currentTarget() {
                SongSlideGrid(song: song, source: t)
            } else {
                NoTargetView()
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "music.note.list").font(.system(size: 34)).foregroundColor(DS.text3)
                Text("Choose a song on the left, create a new one, or import song files.").font(DS.label).foregroundColor(DS.text2)
                HStack {
                    Button("New Song") { present.newSong(); present.editingSong = true }.buttonStyle(.ds(.primary))
                    Button("Find lyrics online") { present.findingLyrics = true }.buttonStyle(.ds())
                    Button("Import…") { present.importSongs() }.buttonStyle(.ds())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct NoTargetView: View {
    @EnvironmentObject var present: PresentModel
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 30)).foregroundColor(DS.text3)
            Text("Slides are shown through a Presentation input.").font(DS.label).foregroundColor(DS.text2)
            Button("Add Presentation input") { present.ensureTarget() }.buttonStyle(.ds(.primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SongSlideGrid: View {
    @EnvironmentObject var present: PresentModel
    let song: Song
    @ObservedObject var source: SlideSource
    var body: some View {
        SlideGrid(slides: present.songSlides(song, look: source.look), prefix: "song:\(song.id.uuidString)", source: source)
    }
}

struct SlideGrid: View {
    @EnvironmentObject var present: PresentModel
    let slides: [SlideContent]
    let prefix: String
    @ObservedObject var source: SlideSource
    var body: some View {
        GeometryReader { geo in
            let cols = max(1, Int((geo.size.width - 8) / 210))
            let w = floor((geo.size.width - CGFloat(cols + 1) * 8) / CGFloat(cols))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(max(100, w)), spacing: 8), count: cols), spacing: 8) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { idx, c in
                        SlideCard(index: idx + 1, content: c, source: source, width: max(100, w),
                                  live: present.liveKey == "\(prefix)#\(idx)")
                            .onTapGesture { present.goLive(slides, index: idx, prefix: prefix) }
                            .contextMenu { SlideMenu(slides: slides, index: idx, prefix: prefix, source: source) }
                    }
                }
                .padding(8)
            }
        }
    }
}

struct SlideMenu: View {
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var engine: Engine
    let slides: [SlideContent]
    let index: Int
    let prefix: String
    let source: SlideSource
    var body: some View {
        Button("Show this slide") { present.goLive(slides, index: index, prefix: prefix) }
        Button("Show and put on Preview") { present.goLive(slides, index: index, prefix: prefix); present.sendToPreview() }
        Button("Show and cut to Program") { present.goLive(slides, index: index, prefix: prefix); present.cutToProgram() }
        Divider()
        Button(engine.isPreviewKeyed(source.id) ? "Remove key from Preview" : "Show and key on Preview") {
            present.goLive(slides, index: index, prefix: prefix); engine.toggleKeyPreview(source.id)
        }
        Button(engine.isKeyed(source.id) ? "Remove key from Program" : "Show and key on Program") {
            if engine.isKeyed(source.id) { engine.toggleKey(source.id) }
            else { present.goLive(slides, index: index, prefix: prefix); engine.toggleKey(source.id) }
        }
        Divider()
        Button("Clear text") { present.clearText() }
        Button(source.backgroundCleared ? "Show background" : "Hide background") { present.toggleBackground() }
        Button("Format this input…") { present.targetID = source.id }
        Button("Rename this input…") { engine.renamingSourceID = source.id }
    }
}

struct SlideCard: View {
    @EnvironmentObject var present: PresentModel
    let index: Int
    let content: SlideContent
    @ObservedObject var source: SlideSource
    let width: CGFloat
    let live: Bool
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let img = present.thumbnail(content, source: source) {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(16.0 / 9.0, contentMode: .fit)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            HStack(spacing: 5) {
                Text("\(index)").font(DS.mono(9, .bold)).foregroundColor(live ? .white : DS.text3)
                Text(content.label).font(.system(size: 10, weight: .semibold)).foregroundColor(live ? .white : DS.text2).lineLimit(1)
                Spacer()
                if live { Text("LIVE").font(.system(size: 8, weight: .heavy)).foregroundColor(.white) }
            }
            .padding(.horizontal, 6).frame(width: width, height: 20)
            .background(live ? DS.program : DS.bg2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(live ? DS.program : DS.line, lineWidth: live ? 2 : 1))
        .contentShape(Rectangle())
    }
}

struct ScriptureArea: View {
    @EnvironmentObject var present: PresentModel
    @State private var showSearch = false
    var body: some View {
        scripture
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                var urls: [URL] = []
                let group = DispatchGroup()
                for p in providers {
                    group.enter()
                    _ = p.loadObject(ofClass: URL.self) { u, _ in
                        if let u { DispatchQueue.main.async { urls.append(u) } }
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    let bibleLike = urls.filter { u in
                        var isDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                        return isDir.boolValue || u.pathExtension.lowercased() == "zip" || BibleImporter.fileExtensions.contains(u.pathExtension.lowercased())
                    }
                    if !bibleLike.isEmpty { present.importBibles(bibleLike) }
                }
                return true
            }
    }

    private var scripture: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("", selection: $present.selectedBibleID) {
                    ForEach(present.bibles) { b in Text(b.abbreviation).tag(Optional(b.id)) }
                }
                .labelsHidden().frame(width: 100)
                BibleSmartField()
                Button("Go") { present.lookUp() }.buttonStyle(.ds(.primary, .regular))
                Menu {
                    Text("Show together with \(present.currentStore?.info.abbreviation ?? "the selected version")")
                    ForEach(present.bibles.filter { $0.id != present.selectedBibleID }) { b in
                        Button { present.toggleParallel(b.id) } label: {
                            if present.parallelBibleIDs.contains(b.id) { Label(b.abbreviation + " — " + b.name, systemImage: "checkmark") }
                            else { Text(b.abbreviation + " — " + b.name) }
                        }
                    }
                    if !present.parallelBibleIDs.isEmpty {
                        Divider()
                        Button("Show one version only") { present.parallelBibleIDs = [] }
                    }
                } label: {
                    Label(present.activeParallelStores.isEmpty ? "Versions" : "\(present.activeParallelStores.count + 1) versions",
                          systemImage: "rectangle.split.3x1")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Show several Bible versions on the same screen")
                if !present.activeParallelStores.isEmpty, let t = present.currentTarget() {
                    ParallelLayoutToggle(source: t)
                }
                DSIconButton(symbol: "text.magnifyingglass", help: "Search words and phrases", active: showSearch) {
                    showSearch.toggle()
                    if showSearch { present.updateAssist(present.reference) } else { present.clearAssist() }
                }
            }
            .padding(8)
            if !present.passageError.isEmpty {
                Text(present.passageError).font(.system(size: 11)).foregroundColor(DS.amber)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            if showSearch || !present.suggestions.isEmpty || !present.liveResults.isEmpty {
                BibleAssistPanel(onClose: { showSearch = false; present.clearAssist() })
            }
            if present.bibles.isEmpty {
                Text("No Bibles yet — use Get Bibles…, or drop Bible files, a folder or a .zip here.")
                    .font(.system(size: 11)).foregroundColor(DS.text2).padding(8)
            }
            if let t = present.currentTarget() {
                ScriptureSlideGrid(source: t)
            } else {
                NoTargetView()
            }
        }
    }
}

/// Reference / word box with instant suggestions (↑ ↓ to choose, Return to open, Esc to close).
struct BibleSmartField: View {
    @EnvironmentObject var present: PresentModel
    @FocusState private var focused: Bool
    @State private var monitor: Any?
    @State private var selected = -1

    var body: some View {
        TextField("Reference or words — e.g. John 3:16, Ps 23, “the Lord is my shepherd”, grace", text: $present.reference)
            .dsField()
            .focused($focused)
            .onChange(of: present.reference) { v in if focused { selected = -1; present.updateAssist(v) } }
            .onSubmit { submit() }
            .onChange(of: focused) { f in if f { installKeys() } else { removeKeys() } }
            .onDisappear { removeKeys() }
    }

    private var totalItems: Int { present.suggestions.count + filteredResults.count }
    private var filteredResults: [BibleVerse] { present.liveResults.filter { present.liveBookFilter == nil || $0.book == present.liveBookFilter } }

    private func submit() {
        if selected >= 0 {
            if selected < present.suggestions.count { present.applySuggestion(present.suggestions[selected]) }
            else if filteredResults.indices.contains(selected - present.suggestions.count) { present.openVerse(filteredResults[selected - present.suggestions.count]) }
            selected = -1
            return
        }
        if let first = present.suggestions.first, first.kind == .reference { present.applySuggestion(first); return }
        if let store = present.currentStore, store.parseReference(present.reference) != nil, BibleAssist.looksLikeReference(present.reference, extraNames: store.bookNameMap) {
            present.lookUp(); present.clearAssist(); return
        }
        // words: show every match
        present.liveResults = present.currentStore?.liveSearch(present.reference, limit: 300) ?? []
        if present.liveResults.isEmpty { present.lookUp() }
    }

    private func installKeys() {
        removeKeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            guard focused else { return ev }
            switch ev.keyCode {
            case 125: if totalItems > 0 { selected = min(totalItems - 1, selected + 1); present.assistSelection = selected }; return totalItems > 0 ? nil : ev
            case 126: if selected >= 0 { selected -= 1; present.assistSelection = selected }; return selected >= -1 && totalItems > 0 ? nil : ev
            case 53: present.clearAssist(); selected = -1; present.assistSelection = -1; return nil
            case 48 where !present.suggestions.isEmpty:                                   // Tab completes the first suggestion
                let s = present.suggestions[min(max(0, selected), present.suggestions.count - 1)]
                present.reference = s.text
                present.updateAssist(s.text)
                return nil
            default: return ev
            }
        }
    }
    private func removeKeys() { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }
}

/// Suggestions and matching verses under the Bible box.
struct BibleAssistPanel: View {
    @EnvironmentObject var present: PresentModel
    let onClose: () -> Void

    private var results: [BibleVerse] { present.liveResults.filter { present.liveBookFilter == nil || $0.book == present.liveBookFilter } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle.magnifyingglass").foregroundColor(CP.icon)
                Text(present.assistQuery.isEmpty ? "Type a reference, a book, a theme (love, healing, fear) or words from a verse"
                     : (present.liveResults.isEmpty ? "Suggestions" : "\(present.liveResults.count)\(present.liveResults.count >= 120 ? "+" : "") verses match “\(present.assistQuery)”"))
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(CP.text).lineLimit(1)
                Spacer()
                Text("↑↓ choose · ↩ open · ⇥ complete · esc close").font(.system(size: 9)).foregroundColor(CP.text2)
                Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundColor(CP.text2)
            }
            if !present.suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(present.suggestions.enumerated()), id: \.element.id) { i, s in
                            Button { present.applySuggestion(s) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: icon(s.kind)).font(.system(size: 9))
                                    Text(s.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    Text(s.detail).font(.system(size: 9)).foregroundColor(CP.text2).lineLimit(1)
                                }
                                .foregroundColor(CP.text)
                                .padding(.horizontal, 8).frame(height: 24)
                                .background(Capsule().fill(present.assistSelection == i ? CP.blue : CP.field))
                                .overlay(Capsule().strokeBorder(CP.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if present.liveResults.count > 0 {
                let counts = BibleAssist.bookCounts(present.liveResults)
                if counts.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            chip("All books", "\(present.liveResults.count)", present.liveBookFilter == nil) { present.liveBookFilter = nil }
                            ForEach(counts, id: \.book) { c in
                                chip(present.currentStore?.bookName(c.book) ?? BibleBookInfo.byNumber(c.book)?.name ?? "\(c.book)", "\(c.count)", present.liveBookFilter == c.book) {
                                    present.liveBookFilter = present.liveBookFilter == c.book ? nil : c.book
                                }
                            }
                        }
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element) { idx, v in
                            let rowIndex = present.suggestions.count + idx
                            Button { present.openVerse(v) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(present.currentStore?.bookName(v.book) ?? "") \(v.chapter):\(v.verse)")
                                        .font(.system(size: 10.5, weight: .bold)).foregroundColor(DS.amber)
                                        .frame(width: 118, alignment: .leading)
                                    Text(highlighted(v.text)).font(.system(size: 11.5)).foregroundColor(CP.text).lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(present.assistSelection == rowIndex ? CP.blueSoft : Color.clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Show this verse") { present.openVerse(v) }
                                Button("Show this verse and the next 4") { present.openVerse(v, following: 4) }
                                Button("Show the whole chapter") { present.openVerse(v, wholeChapter: true) }
                                Divider()
                                Button("Copy verse") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("\(v.text) — \(present.currentStore?.bookName(v.book) ?? "") \(v.chapter):\(v.verse)", forType: .string)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(CP.card))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(CP.border, lineWidth: 1))
        .padding(.horizontal, 8).padding(.bottom, 6)
    }

    private func icon(_ k: BibleSuggestion.Kind) -> String {
        switch k {
        case .reference: return "arrow.right.circle.fill"
        case .book: return "book.closed"
        case .popular: return "star.fill"
        case .phrase: return "text.quote"
        }
    }

    private func chip(_ title: String, _ count: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 10, weight: .semibold))
                Text(count).font(.system(size: 9)).foregroundColor(on ? .white.opacity(0.8) : CP.text2)
            }
            .foregroundColor(on ? .white : CP.text)
            .padding(.horizontal, 7).frame(height: 20)
            .background(Capsule().fill(on ? CP.blue : CP.field))
        }
        .buttonStyle(.plain)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        let lower = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for term in BibleAssist.highlightTerms(present.assistQuery) {
            var search = lower.startIndex
            while let r = lower.range(of: term, range: search..<lower.endIndex) {
                let startOffset = lower.distance(from: lower.startIndex, to: r.lowerBound)
                let len = lower.distance(from: r.lowerBound, to: r.upperBound)
                if let s = a.characters.index(a.startIndex, offsetBy: startOffset, limitedBy: a.endIndex),
                   let e = a.characters.index(s, offsetBy: len, limitedBy: a.endIndex) {
                    a[s..<e].foregroundColor = DS.amber
                    a[s..<e].font = .system(size: 11.5, weight: .bold)
                }
                search = r.upperBound
            }
        }
        return a
    }
}

struct ParallelLayoutToggle: View {
    @ObservedObject var source: SlideSource
    var body: some View {
        DSSegmented(selection: $source.look.parallelLayout, options: [(ParallelLayout.sideBySide, "Side by side"), (ParallelLayout.stacked, "Stacked")])
            .frame(width: 170)
    }
}

struct ScriptureSlideGrid: View {
    @EnvironmentObject var present: PresentModel
    @ObservedObject var source: SlideSource
    var body: some View {
        if present.bibles.isEmpty {
            VStack(spacing: 8) {
                Text("No Bibles installed.").font(DS.label).foregroundColor(DS.text2)
                Button("Get Bibles…") { present.showCatalog = true; present.loadCatalog() }.buttonStyle(.ds(.primary))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SlideGrid(slides: present.scriptureSlides(look: source.look), prefix: "bible:\(present.passageTitle)", source: source)
        }
    }
}

/// Text-only slide preview used next to the lyric editor.
struct SlidePreviewGrid: View {
    let song: Song
    var body: some View {
        let slides = song.generatedSlides()
        VStack(spacing: 0) {
            PanelHeader(title: "Slides", icon: "rectangle.grid.2x2") {
                Text("\(slides.count)").font(DS.mono(10)).foregroundColor(DS.text2)
            }
            GeometryReader { geo in
                let cols = max(1, Int(geo.size.width / 200))
                let w = (geo.size.width - CGFloat(cols + 1) * 8) / CGFloat(cols)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(max(80, w)), spacing: 8), count: cols), spacing: 8) {
                        ForEach(Array(slides.enumerated()), id: \.offset) { idx, s in
                            SlideTextCard(index: idx + 1, label: s.label, color: s.kind.color.swiftUI,
                                          text: s.lines.joined(separator: "\n"), width: max(80, w))
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(DS.bg1)
    }
}

// MARK: - Format (look) editor

struct LookColumn: View {
    let dictionary: Bool
    var ai = false
    var showHeader = true
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var dict: DictionaryModel
    @EnvironmentObject var aiModel: AIModel
    var body: some View {
        VStack(spacing: 0) {
            let target: SlideSource? = ai ? (aiModel.currentTarget() as SlideSource?)
                : (dictionary ? (dict.currentTarget() as SlideSource?) : (present.currentTarget() as SlideSource?))
            if showHeader {
                PanelHeader(title: "Format", icon: "paintbrush.pointed") {
                    if let t = target { Text(t.name).font(.system(size: 10)).foregroundColor(DS.text3).lineLimit(1) }
                }
            }
            if let t = target {
                LookEditor(source: t)
            } else {
                VStack(spacing: 8) {
                    Text("Add \(ai ? "an AI Search" : (dictionary ? "a Dictionary" : "a Presentation")) input to format its display.")
                        .font(DS.small).foregroundColor(CP.text2).multilineTextAlignment(.center)
                    Button("Add input") {
                        if ai { _ = aiModel.ensureTarget() } else if dictionary { _ = dict.ensureTarget() } else { _ = present.ensureTarget() }
                    }.buttonStyle(.ds(.primary))
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CP.bg)
    }
}

struct LookEditor: View {
    @ObservedObject var source: SlideSource
    @EnvironmentObject var present: PresentModel
    @State private var showLibrary = false
    @State private var families: [String] = []
    @State private var showSave = false
    @State private var saveName = ""

    var body: some View {
        CPInspector {
            CPCard(title: "Looks", subtitle: source.look.name, icon: "square.stack.3d.up") {
                presetRow.padding(.vertical, 6)
            }
            CPCard(title: "Background", subtitle: backgroundSubtitle, icon: "photo.on.rectangle") {
                backgroundSection.padding(.vertical, 4)
            }
            CPCard(title: "Layout", subtitle: source.look.region.rawValue, icon: "rectangle.dashed") {
                layoutSection.padding(.vertical, 4)
            }
            CPCard(title: "Main text", subtitle: "\(source.look.body.fontName) · \(Int(source.look.body.size)) pt", icon: "textformat") {
                TextStyleEditor(style: $source.look.body, families: families).padding(.vertical, 4)
            }
            if source is DictionarySource || source.look.showTitle {
                CPCard(title: source is DictionarySource ? "Headword" : (source is AISource ? "Question (title)" : "Title"), icon: "textformat.size.larger") {
                    TextStyleEditor(style: $source.look.title, families: families).padding(.vertical, 4)
                }
            }
            CPCard(title: source is DictionarySource ? "Source line" : (source is AISource ? "Credit line (AI name)" : "Reference / credits"), subtitle: source.look.footerPosition.rawValue, icon: "text.append") {
                VStack(alignment: .leading, spacing: 4) {
                    FieldRow(label: "Position") {
                        Picker("", selection: $source.look.footerPosition) {
                            ForEach(FooterPosition.allCases) { p in Text(p.rawValue).tag(p) }
                        }.labelsHidden()
                    }
                    if source.look.footerPosition != .hidden {
                        TextStyleEditor(style: $source.look.footer, families: families)
                    }
                }
                .padding(.vertical, 4)
            }
            CPCard(title: "Text box", icon: "rectangle.fill.on.rectangle.fill") {
                boxSection.padding(.vertical, 4)
            }
            CPCard(title: "Content", icon: "list.bullet.rectangle") {
                VStack(alignment: .leading, spacing: 4) { contentSection }.padding(.vertical, 4)
            }
        }
        .onAppear { if families.isEmpty { families = ["SF Pro"] + NSFontManager.shared.availableFontFamilies.sorted().filter { $0 != "SF Pro" } } }
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            Menu {
                let _ = present.looksRevision
                ForEach(present.looks.all) { l in
                    Button(l.name) { var n = l; n.id = source.look.id; source.look = n }
                }
                if !present.looks.looks.isEmpty {
                    Divider()
                    Menu("Delete saved look") {
                        ForEach(present.looks.looks) { l in Button(l.name) { present.deleteLook(l.id) } }
                    }
                }
            } label: { Label("Looks", systemImage: "square.stack") }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Button("Save look…") { saveName = source.look.name; showSave = true }.buttonStyle(.ds(.normal, .small))
                .popover(isPresented: $showSave) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Save this look").font(.system(size: 12, weight: .bold))
                        TextField("Name", text: $saveName).textFieldStyle(.roundedBorder).frame(width: 220)
                        HStack {
                            Spacer()
                            Button("Save") { present.saveLook(source.look, as: saveName); showSave = false }.keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(12)
                }
        }
    }

    private var backgroundSubtitle: String {
        switch source.look.background.kind {
        case .transparent, .none: return "Transparent"
        case .color: return "Solid colour"
        case .gradient: return "Gradient"
        case .image: return "Image · \(source.look.mediaBlend.rawValue)"
        case .video: return "Video · \(source.look.mediaBlend.rawValue)"
        }
    }

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldRow(label: "Type") {
                Picker("", selection: $source.look.background.kind) {
                    Text("Transparent (for key)").tag(BackgroundKind.transparent)
                    Text("Solid colour").tag(BackgroundKind.color)
                    Text("Gradient").tag(BackgroundKind.gradient)
                    Text("Image").tag(BackgroundKind.image)
                    Text("Video (loops)").tag(BackgroundKind.video)
                }.labelsHidden()
            }
            switch source.look.background.kind {
            case .color:
                DSColorWell(label: "Colour", color: colorBinding($source.look.background.color))
            case .gradient:
                DSColorWell(label: "From", color: colorBinding($source.look.background.color))
                DSColorWell(label: "To", color: colorBinding($source.look.background.color2))
                ParamSlider(label: "Angle", value: $source.look.background.angle, range: 0...360, defaultValue: 90, format: "%.0f°")
            case .image, .video:
                HStack(spacing: 6) {
                    Text(source.look.background.media.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "No file chosen")
                        .font(DS.small).foregroundColor(DS.text2).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Library…") { showLibrary = true }.buttonStyle(.ds(.primary, .small))
                        .popover(isPresented: $showLibrary, arrowEdge: .leading) { LibraryBackgroundPicker(source: source) }
                        .help("Choose from your Media library, generated loops or your inputs")
                    Button("File…") { chooseMedia(video: source.look.background.kind == .video) }.buttonStyle(.ds(.normal, .small))
                }
                if let p = source.backgroundProblem { Text(p).font(.system(size: 10)).foregroundColor(DS.amber) }
                FieldRow(label: "Fit") {
                    DSSegmented(selection: $source.look.background.fit, options: [(FitMode.fill, "Fill"), (FitMode.fit, "Fit"), (FitMode.stretch, "Stretch")])
                }
                SectionLabel("Blending")
                FieldRow(label: "Base") {
                    DSSegmented(selection: $source.look.mediaBase, options: [(MediaBase.color, "Colour"), (MediaBase.gradient, "Gradient")])
                }
                if source.look.mediaBase == .gradient {
                    DSColorWell(label: "Base from", color: colorBinding($source.look.background.color))
                    DSColorWell(label: "Base to", color: colorBinding($source.look.background.color2))
                    ParamSlider(label: "Base angle", value: $source.look.background.angle, range: 0...360, defaultValue: 90, format: "%.0f°")
                } else {
                    DSColorWell(label: "Base colour", color: colorBinding($source.look.background.color))
                }
                FieldRow(label: "Blend mode") {
                    Picker("", selection: $source.look.mediaBlend) {
                        ForEach(MediaBlendMode.allCases) { m in Text(m.rawValue).tag(m) }
                    }.labelsHidden()
                }
                Text(source.look.mediaBlend.hint).font(.system(size: 10)).foregroundColor(DS.text3)
                ParamSlider(label: "Media opacity", value: $source.look.mediaOpacity, range: 0...1, defaultValue: 1, format: "%.2f")
            default:
                Text("Only the text is drawn — key it over Program, or put it in a layout above a camera.")
                    .font(.system(size: 10)).foregroundColor(DS.text3)
            }
            if source.look.background.kind != .transparent && source.look.background.kind != .none {
                ParamSlider(label: "Darken background", value: $source.look.dim, range: 0...0.9, defaultValue: 0, format: "%.2f")
            }
        }
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldRow(label: "Area") {
                Picker("", selection: $source.look.region) {
                    ForEach(LookRegion.allCases) { r in Text(r.rawValue).tag(r) }
                }.labelsHidden()
            }
            if source.look.region == .custom {
                ParamSlider(label: "Left", value: $source.look.custom.x, range: 0...0.95, format: "%.2f")
                ParamSlider(label: "Top", value: $source.look.custom.y, range: 0...0.95, format: "%.2f")
                ParamSlider(label: "Width", value: $source.look.custom.width, range: 0.05...1, format: "%.2f")
                ParamSlider(label: "Height", value: $source.look.custom.height, range: 0.05...1, format: "%.2f")
            }
            FieldRow(label: "Vertical") {
                DSSegmented(selection: $source.look.verticalAlign, options: [(VerticalAlign.top, "Top"), (VerticalAlign.middle, "Middle"), (VerticalAlign.bottom, "Bottom")])
            }
            ParamSlider(label: "Side margin", value: $source.look.marginX, range: 0...0.3, defaultValue: 0.06, format: "%.2f")
            ParamSlider(label: "Top/bottom margin", value: $source.look.marginY, range: 0...0.3, defaultValue: 0.08, format: "%.2f")
            CPToggleRow(label: "Shrink text to fit", isOn: $source.look.shrinkToFit)
            ParamSlider(label: "Fade between slides", value: $source.look.fadeDuration, range: 0...1.5, defaultValue: 0.35, format: "%.2fs")
        }
    }

    private var boxSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            DSColorWell(label: "Box colour (opacity 0 = none)", color: colorBinding($source.look.boxColor))
            if source.look.boxColor.a > 0.001 {
                CPToggleRow(label: "Full-width band", isOn: $source.look.boxFullWidth)
                ParamSlider(label: "Padding", value: $source.look.boxPadding, range: 0...120, defaultValue: 28, format: "%.0f")
                ParamSlider(label: "Corner radius", value: $source.look.boxRadius, range: 0...80, defaultValue: 10, format: "%.0f")
            }
        }
    }

    @ViewBuilder private var contentSection: some View {
        if source is AISource {
            ParamSlider(label: "Max characters per slide", value: intBinding($source.look.maxCharsPerSlide), range: 80...700, defaultValue: 260, format: "%.0f")
            CPToggleRow(label: "Show the question as a title", isOn: $source.look.showTitle)
            CPNote("Changing the length re-splits the answer into slides.")
        } else if source is DictionarySource {
            ParamSlider(label: "Definitions shown", value: intBinding($source.look.maxSenses), range: 1...8, defaultValue: 3, format: "%.0f")
            CPToggleRow(label: "Show examples", isOn: $source.look.showExamples)
            CPToggleRow(label: "Show headword", isOn: $source.look.showTitle)
        } else {
            CPToggleRow(label: "Verse numbers", isOn: $source.look.showVerseNumbers)
            FieldRow(label: "Versions") {
                DSSegmented(selection: $source.look.parallelLayout, options: [(ParallelLayout.sideBySide, "Side by side"), (ParallelLayout.stacked, "Stacked")])
            }
            CPToggleRow(label: "Show version names", isOn: $source.look.showVersionLabels)
            ParamSlider(label: "Gap between versions", value: $source.look.columnGap, range: 0...160, defaultValue: 48, format: "%.0f")
            ParamSlider(label: "Scripture: max characters per slide", value: intBinding($source.look.maxCharsPerSlide), range: 60...700, defaultValue: 280, format: "%.0f")
            ParamSlider(label: "Songs: lines per slide (0 = as written)", value: intBinding($source.look.linesPerSlide), range: 0...8, defaultValue: 0, format: "%.0f")
            CPToggleRow(label: "Show song title", isOn: $source.look.showTitle)
        }
    }

    private func chooseMedia(video: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = video ? [.movie, .video, .mpeg4Movie, .quickTimeMovie] : [.image]
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            FileAccess.remember(url)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            source.look.background.media = MediaRef(path: url.path, bytes: size)
        }
    }
}

/// Pick a background from the Media library (downloaded, generated, imported, shared) or from existing inputs.
struct LibraryBackgroundPicker: View {
    @EnvironmentObject var bg: BackgroundsModel
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @ObservedObject var source: SlideSource
    @Environment(\.dismiss) private var dismiss
    @State private var filter = 0     // 0 all · 1 videos · 2 images · 3 generated · 4 inputs

    private var items: [LocalBackground] {
        switch filter {
        case 1: return bg.items.filter { $0.kind == .video }
        case 2: return bg.items.filter { $0.kind == .image }
        case 3: return bg.items.filter { $0.category == "Generated" }
        default: return bg.items
        }
    }
    private var inputMedia: [(name: String, path: String, video: Bool)] {
        engine.sources.compactMap { s in
            guard let path = s.originLocation, FileManager.default.fileExists(atPath: path) else { return nil }
            if s is FileSource { return (s.name, path, true) }
            if s is ImageSource { return (s.name, path, false) }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Background from library").font(.system(size: 13, weight: .semibold)).foregroundColor(CP.text)
                Spacer()
                Button("Make one in Generator") { present.mediaSection = 2; present.deck = DeckTab.images.rawValue; dismiss() }
                    .buttonStyle(.ds(.ghost, .small))
            }
            DSSegmented(selection: $filter, options: [(0, "All"), (1, "Videos"), (2, "Images"), (3, "Generated"), (4, "Inputs")])
            ScrollView {
                if filter == 4 {
                    if inputMedia.isEmpty { CPNote("No video or image inputs yet.") }
                    VStack(spacing: 4) {
                        ForEach(inputMedia, id: \.path) { m in
                            Button { apply(path: m.path, video: m.video) } label: {
                                HStack {
                                    Image(systemName: m.video ? "film" : "photo").frame(width: 18)
                                    Text(m.name).lineLimit(1)
                                    Spacer()
                                }
                                .font(.system(size: 12)).foregroundColor(CP.text)
                                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(CP.field))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    if items.isEmpty { CPNote("Nothing here yet — download backgrounds, import your own or export a loop from the Generator (Media tab).") }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                        ForEach(items) { item in
                            Button { bg.useAsBackground(item, on: source); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    ZStack(alignment: .topTrailing) {
                                        Color.black
                                        if let img = bg.thumbs[item.id] { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                                        if item.kind == .video {
                                            Image(systemName: "play.fill").font(.system(size: 8)).foregroundColor(.white).padding(3)
                                                .background(Circle().fill(Color.black.opacity(0.6))).padding(3)
                                        }
                                    }
                                    .aspectRatio(16.0 / 9.0, contentMode: .fit).clipped().cornerRadius(4)
                                    Text(item.title).font(.system(size: 10)).foregroundColor(CP.text).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .onAppear { bg.thumbnail(item) }
                        }
                    }
                }
            }
            .frame(height: 320)
        }
        .padding(12)
        .frame(width: 440)
        .background(CP.bg)
        .onAppear { bg.refresh() }
    }

    private func apply(path: String, video: Bool) {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        var look = source.look
        look.background.kind = video ? .video : .image
        look.background.media = MediaRef(path: path, bytes: size)
        source.look = look
        dismiss()
    }
}

struct TextStyleEditor: View {
    @Binding var style: TextStyle
    let families: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldRow(label: "Font") {
                Picker("", selection: $style.fontName) {
                    if !families.contains(style.fontName) { Text(style.fontName).tag(style.fontName) }
                    ForEach(families, id: \.self) { f in Text(f).tag(f) }
                }.labelsHidden()
            }
            HStack(spacing: 4) {
                Toggle(isOn: $style.bold) { Image(systemName: "bold") }.toggleStyle(.button)
                Toggle(isOn: $style.italic) { Image(systemName: "italic") }.toggleStyle(.button)
                Toggle(isOn: $style.underline) { Image(systemName: "underline") }.toggleStyle(.button)
                Spacer()
                Text("Colour").font(.system(size: 11.5)).foregroundColor(CP.text)
                ColorPicker("", selection: colorBinding($style.color), supportsOpacity: true).labelsHidden()
            }
            .controlSize(.small)
            .frame(minHeight: 26)
            DSSegmented(selection: $style.align, options: [(TextAlign.left, "Left"), (TextAlign.center, "Centre"), (TextAlign.right, "Right"), (TextAlign.justified, "Justify")])
            ParamSlider(label: "Size", value: $style.size, range: 12...240, defaultValue: 80, format: "%.0f pt")
            ParamSlider(label: "Line spacing", value: $style.lineSpacing, range: 0.7...2.2, defaultValue: 1.05, format: "%.2f×")
            ParamSlider(label: "Letter spacing", value: $style.letterSpacing, range: -5...30, defaultValue: 0, format: "%.1f")
            FieldRow(label: "Letters") {
                Picker("", selection: $style.textCase) {
                    Text("As typed").tag(TextCase.asTyped); Text("UPPERCASE").tag(TextCase.upper)
                    Text("lowercase").tag(TextCase.lower); Text("Title Case").tag(TextCase.title)
                }.labelsHidden()
            }
            CPColorRow(label: "Outline", color: colorBinding($style.outlineColor))
            ParamSlider(label: "Outline width", value: $style.outlineWidth, range: 0...12, defaultValue: 0, format: "%.1f")
            HStack(spacing: 8) {
                CPToggleRow(label: "Shadow", isOn: $style.shadow)
                if style.shadow { ColorPicker("", selection: colorBinding($style.shadowColor), supportsOpacity: true).labelsHidden().controlSize(.small) }
            }
            if style.shadow {
                ParamSlider(label: "Shadow softness", value: $style.shadowBlur, range: 0...40, defaultValue: 8, format: "%.0f")
            }
        }
    }
}

// MARK: - Dictionary deck

struct DictionaryDeck: View {
    @EnvironmentObject var dict: DictionaryModel
    @EnvironmentObject var engine: Engine
    var body: some View {
        HSplitView {
            DictionarySearchColumn()
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
            DictionaryPreviewColumn()
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DictionarySearchColumn: View {
    @EnvironmentObject var dict: DictionaryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldRow(label: "Dictionary", labelWidth: 70) {
                Picker("", selection: $dict.kind) {
                    ForEach(DictionaryKind.allCases) { k in Text(k.rawValue).tag(k) }
                }.labelsHidden()
            }
            Text(dict.kind.detail).font(.system(size: 10)).foregroundColor(DS.text3).fixedSize(horizontal: false, vertical: true)
            if dict.kind.usesLanguage {
                FieldRow(label: "Language", labelWidth: 70) {
                    TextField("en", text: $dict.language).dsField().frame(width: 70)
                    Text("code: en, fr, es, pt, de, sw, ak…").font(.system(size: 9)).foregroundColor(DS.text3)
                }
            }
            if dict.kind == .custom {
                HStack {
                    Button("Import…") { dict.importCustom() }.buttonStyle(.ds(.normal, .small))
                    Spacer()
                }
                ForEach(dict.customList) { d in
                    HStack {
                        Toggle(d.name, isOn: Binding(get: { d.enabled }, set: { dict.toggleCustom(d.id, $0) })).font(DS.small)
                        Spacer()
                        Text("\(d.entries.count)").font(DS.mono(9)).foregroundColor(DS.text3)
                        Button { dict.removeCustom(d.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundColor(DS.text3)
                    }
                }
            }
            if dict.kind == .offline { OfflineDictionaryStatusView() }
            HStack(spacing: 6) {
                TextField("Type a word or name", text: $dict.query).dsField().onSubmit { dict.search() }
                Button("Search") { dict.search() }.buttonStyle(.ds(.primary))
            }
            if dict.kind == .offline { OfflineSuggestions(query: dict.query) { w in dict.query = w; dict.search() } }
            if dict.loading { HStack { ProgressView().controlSize(.small); Text("Looking up…").font(DS.small).foregroundColor(DS.text2) } }
            if !dict.message.isEmpty { Text(dict.message).font(.system(size: 10)).foregroundColor(DS.amber) }
            List(selection: $dict.selectedID) {
                ForEach(dict.results) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(e.word).font(.system(size: 12, weight: .bold))
                            Text(e.phonetic).font(.system(size: 10)).foregroundColor(DS.text3)
                        }
                        Text(e.senses.first?.definition ?? e.synonyms.joined(separator: ", "))
                            .font(.system(size: 10)).foregroundColor(DS.text2).lineLimit(2)
                        Text(e.source).font(.system(size: 9)).foregroundColor(DS.text3)
                    }
                    .tag(e.id)
                }
            }
            .listStyle(.plain)
        }
        .padding(10)
        .background(DS.bg1)
    }
}

struct DictionaryPreviewColumn: View {
    @EnvironmentObject var dict: DictionaryModel
    @EnvironmentObject var engine: Engine
    var body: some View {
        let target = dict.currentTarget()
        let keyed = target.map { engine.isKeyed($0.id) } ?? false
        let onAir = target.map { engine.programID == $0.id } ?? false
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(engine.sources.compactMap { $0 as? DictionarySource }, id: \.id) { s in
                        Button(s.name) { dict.targetID = s.id }
                    }
                    Divider()
                    Button("New Dictionary input") { let s = engine.addDictionaryInput(); dict.targetID = s.id }
                    if let t = target { Button("Rename “\(t.name)”…") { engine.renamingSourceID = t.id } }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(onAir ? DS.program : (keyed ? DS.amber : DS.text3)).frame(width: 7, height: 7)
                        Text(target?.name ?? "No dictionary input").font(.system(size: 11, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("Load into input") { dict.loadIntoInput() }.buttonStyle(.ds(.normal, .small)).disabled(dict.selected == nil)
                Button("Preview") { dict.preview() }.buttonStyle(.ds(.preview, .small)).disabled(dict.selected == nil)
                Button("Program") { dict.program() }.buttonStyle(.ds(.program, .small, active: onAir)).disabled(dict.selected == nil)
                Button("Key PVW") { dict.loadIntoInput(); if let t = dict.currentTarget() { engine.toggleKeyPreview(t.id) } }
                    .buttonStyle(.ds(.amber, .small, active: target.map { engine.isPreviewKeyed($0.id) } ?? false)).disabled(dict.selected == nil && target == nil)
                Button("Key PGM") { dict.key() }.buttonStyle(.ds(.amber, .small, active: keyed)).disabled(dict.selected == nil && !keyed)
                Button("As overlay layer") { dict.overlayLayer() }.buttonStyle(.ds(.normal, .small)).disabled(dict.selected == nil)
                Button("Clear") { dict.clear() }.buttonStyle(.ds(.ghost, .small))
            }
            .padding(.horizontal, 8).frame(height: 38).background(DS.bg2)
            .overlay(Rectangle().fill(DS.lineSoft).frame(height: 1), alignment: .bottom)

            GeometryReader { geo in
                let w = min(geo.size.width - 24, (geo.size.height - 44) * 16 / 9)
                VStack(spacing: 8) {
                    if let t = target, let e = dict.selected {
                        DictionaryCandidate(source: t, entry: e, width: max(120, w))
                            .contextMenu {
                                Button("Load into input") { dict.loadIntoInput() }
                                Button("Put on Preview") { dict.preview() }
                                Button("Cut to Program") { dict.program() }
                                Divider()
                                Button("Key on Preview") { dict.loadIntoInput(); engine.toggleKeyPreview(t.id) }
                                Button(engine.isKeyed(t.id) ? "Remove key from Program" : "Key on Program") { dict.key() }
                                Divider()
                                Button("Add as overlay layer") { dict.overlayLayer() }
                                Button("Clear") { dict.clear() }
                            }
                        Text("Preview of the search result — not on air until you load it or press Preview / Program / Key.")
                            .font(.system(size: 10)).foregroundColor(DS.text3)
                    } else if target == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "character.book.closed").font(.system(size: 30)).foregroundColor(DS.text3)
                            Text("Search a word, then show it on its own Dictionary input.").font(DS.label).foregroundColor(DS.text2)
                            Button("Add Dictionary input") { dict.ensureTarget() }.buttonStyle(.ds(.primary))
                        }
                    } else {
                        Text("Search for a word to preview its card here.").font(DS.label).foregroundColor(DS.text2)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(DS.bg1)
    }
}

struct DictionaryCandidate: View {
    @EnvironmentObject var present: PresentModel
    @ObservedObject var source: SlideSource
    let entry: WordEntry
    let width: CGFloat
    var body: some View {
        let content = DictionarySource.content(for: entry, look: source.look)
        ZStack {
            Color.black
            if let img = present.thumbnail(content, source: source, width: 960) {
                Image(decorative: img, scale: 1).resizable().aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DS.line, lineWidth: 1))
    }
}


// MARK: - Find lyrics online

final class LyricsFinder: ObservableObject {
    enum Mode: Int { case databases = 0, websites = 1 }

    @Published var mode: Mode = .databases
    @Published var provider: LyricsProvider = .lrclib
    @Published var title = ""
    @Published var artist = ""
    @Published var words = ""
    @Published var hits: [LyricsHit] = []
    @Published var selectedID: String? { didSet { if let h = hits.first(where: { $0.id == selectedID }) { use(h) } } }
    @Published var loading = false
    @Published var message = ""

    // editor
    @Published var editTitle = ""
    @Published var editArtist = ""
    @Published var editText = ""
    @Published var editSource = ""

    // web
    @Published var webQuery = ""
    @Published var site: LyricsWebSite?
    @Published var webURL: URL?
    weak var webView: WKWebView?

    func search() {
        message = ""; hits = []; loading = true
        let p = provider
        LyricsSearch.search(p, query: words, title: title, artist: artist) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                switch result {
                case .success(let list):
                    self.hits = list
                    if list.isEmpty { self.message = "No lyrics found. Try fewer words, check the spelling, or search the web sites." }
                    else { self.selectedID = list.first?.id }
                case .failure(let e):
                    self.message = "Search failed: \(e.localizedDescription)"
                }
            }
        }
    }

    func use(_ h: LyricsHit) {
        editTitle = h.title
        editArtist = h.artist
        editText = h.lyrics
        editSource = h.provider
    }

    func open(_ s: LyricsWebSite) {
        site = s
        let q = webQuery.trimmingCharacters(in: .whitespaces).isEmpty
            ? [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
            : webQuery
        webURL = s.url(for: q)
        if editSource.isEmpty { editSource = s.name }
    }

    /// Copies the text selected in the built-in browser into the editor.
    func grabSelection(replace: Bool) {
        webView?.evaluateJavaScript("window.getSelection().toString()") { [weak self] value, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let text = LyricsSearch.clean((value as? String) ?? "")
                guard !text.isEmpty else { self.message = "Select the lyrics on the page first (click and drag), then press Use selection."; return }
                self.editText = replace || self.editText.isEmpty ? text : self.editText + "\n\n" + text
                if let host = self.webView?.url?.host { self.editSource = host }
                if self.editTitle.isEmpty, let t = self.webView?.title { self.editTitle = t.components(separatedBy: " - ").first ?? t }
                self.message = ""
            }
        }
    }

    func pasteClipboard() {
        if let t = NSPasteboard.general.string(forType: .string) {
            let text = LyricsSearch.clean(t)
            editText = editText.isEmpty ? text : editText + "\n\n" + text
        }
    }

    func clearEditor() { editTitle = ""; editArtist = ""; editText = ""; editSource = "" }
}

struct LyricsFinderView: View {
    @EnvironmentObject var present: PresentModel
    @ObservedObject var finder: LyricsFinder

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundColor(DS.accentText)
                Text("Find lyrics online").font(.system(size: 13, weight: .bold)).foregroundColor(DS.text)
                DSSegmented(selection: $finder.mode, options: [(LyricsFinder.Mode.databases, "Lyrics databases"), (LyricsFinder.Mode.websites, "Web sites")])
                    .frame(width: 250)
                Spacer()
                Button("Close") { present.findingLyrics = false }.buttonStyle(.ds(.ghost, .small))
            }
            .padding(.horizontal, 10).frame(height: 40)
            .overlay(Rectangle().fill(DS.lineSoft).frame(height: 1), alignment: .bottom)

            HSplitView {
                Group {
                    if finder.mode == .databases { databaseColumn } else { websiteColumn }
                }
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)

                VStack(spacing: 0) {
                    if finder.mode == .websites { browser.frame(minHeight: 180, maxHeight: .infinity) }
                    editor.frame(minHeight: 220, maxHeight: .infinity)
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DS.bg1)
    }

    // MARK: databases

    private var databaseColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldRow(label: "Source", labelWidth: 56) {
                Picker("", selection: $finder.provider) {
                    ForEach(LyricsProvider.allCases) { p in Text(p.rawValue).tag(p) }
                }.labelsHidden()
            }
            Text(finder.provider.detail).font(.system(size: 10)).foregroundColor(DS.text3).fixedSize(horizontal: false, vertical: true)
            TextField("Song title", text: $finder.title).dsField().onSubmit { finder.search() }
            TextField("Artist / writer" + (finder.provider == .lyricsOvh ? " (required)" : " (optional)"), text: $finder.artist).dsField()
                .onSubmit { finder.search() }
            if finder.provider == .lrclib {
                TextField("…or any words from the song", text: $finder.words).dsField().onSubmit { finder.search() }
            }
            HStack {
                Button { finder.search() } label: { Label("Search", systemImage: "magnifyingglass") }.buttonStyle(.ds(.primary))
                if finder.loading { ProgressView().controlSize(.small) }
                Spacer()
            }
            if !finder.message.isEmpty { Text(finder.message).font(.system(size: 10)).foregroundColor(DS.amber).fixedSize(horizontal: false, vertical: true) }
            List(selection: $finder.selectedID) {
                ForEach(finder.hits) { h in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text([h.artist, h.album].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundColor(DS.text2).lineLimit(1)
                        Text(h.firstLine).font(.system(size: 10)).foregroundColor(DS.text3).lineLimit(1)
                    }
                    .tag(h.id)
                }
            }
            .listStyle(.plain)
        }
        .padding(10)
    }

    // MARK: web sites

    private var websiteColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Song title and artist", text: $finder.webQuery).dsField()
                .onSubmit { if let s = finder.site ?? LyricsWebSite.all.first { finder.open(s) } }
            Text("Choose a site. When the lyrics appear, select them on the page and press **Use selection** — or copy them and press **Paste**.")
                .font(.system(size: 10)).foregroundColor(DS.text3).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(LyricsWebSite.all) { site in
                        Button { finder.open(site) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(site.name).font(.system(size: 12, weight: .semibold)).foregroundColor(DS.text)
                                    Text(site.detail).font(.system(size: 10)).foregroundColor(DS.text2).lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundColor(DS.text3)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(finder.site == site ? DS.accent.opacity(0.18) : DS.bg2))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(finder.site == site ? DS.accentText : DS.lineSoft, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !finder.message.isEmpty { Text(finder.message).font(.system(size: 10)).foregroundColor(DS.amber) }
        }
        .padding(10)
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                DSIconButton(symbol: "chevron.left", help: "Back") { finder.webView?.goBack() }
                DSIconButton(symbol: "chevron.right", help: "Forward") { finder.webView?.goForward() }
                DSIconButton(symbol: "arrow.clockwise", help: "Reload") { finder.webView?.reload() }
                Text(finder.webURL?.host ?? "Choose a site on the left").font(.system(size: 10)).foregroundColor(DS.text2).lineLimit(1)
                Spacer()
                Button { finder.grabSelection(replace: true) } label: { Label("Use selection", systemImage: "text.cursor") }
                    .buttonStyle(.ds(.primary, .small)).disabled(finder.webURL == nil)
                Button("Add selection") { finder.grabSelection(replace: false) }.buttonStyle(.ds(.normal, .small)).disabled(finder.webURL == nil)
                Button { if let u = finder.webView?.url ?? finder.webURL { NSWorkspace.shared.open(u) } } label: { Image(systemName: "safari") }
                    .buttonStyle(.ds(.normal, .small)).help("Open in your web browser").disabled(finder.webURL == nil)
            }
            .padding(.horizontal, 8).frame(height: 36).background(DS.bg2)
            ZStack {
                Color.white.opacity(0.03)
                if let u = finder.webURL {
                    LyricsWebView(url: u, finder: finder)
                } else {
                    Text("The site opens here.").font(DS.label).foregroundColor(DS.text3)
                }
            }
        }
    }

    // MARK: editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Title", text: $finder.editTitle).dsField()
                TextField("Author / artist", text: $finder.editArtist).dsField().frame(maxWidth: 220)
            }
            TextEditor(text: $finder.editText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(DS.bg0))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.line, lineWidth: 1))
            Text("Edit freely. Put Verse 1, Chorus, Bridge… on their own lines; a blank line starts a new slide. Repeated choruses are merged automatically.")
                .font(.system(size: 10)).foregroundColor(DS.text3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Tidy spacing") { finder.editText = LyricsSearch.clean(finder.editText) }.buttonStyle(.ds(.normal, .small))
                Button("Paste") { finder.pasteClipboard() }.buttonStyle(.ds(.normal, .small))
                Button("Clear") { finder.clearEditor() }.buttonStyle(.ds(.ghost, .small))
                Spacer()
                Text(finder.editSource.isEmpty ? "" : "Source: \(finder.editSource)").font(.system(size: 10)).foregroundColor(DS.text3).lineLimit(1)
                Button { present.saveFoundLyrics(title: finder.editTitle, artist: finder.editArtist, text: finder.editText, source: finder.editSource) } label: {
                    Label("Save to Song Library", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.ds(.primary))
                .disabled(finder.editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Lyrics belong to their writers and publishers. Public-domain hymns are free to project; for copyrighted songs make sure your church holds a licence such as CCLI or OneLicense.")
                .font(.system(size: 9.5)).foregroundColor(DS.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
    }
}

/// Built-in browser for lyrics sites (selection can be copied into the editor).
struct LyricsWebView: NSViewRepresentable {
    let url: URL
    let finder: LyricsFinder
    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        wv.load(URLRequest(url: url))
        finder.webView = wv
        context.coordinator.lastURL = url
        return wv
    }
    func updateNSView(_ wv: WKWebView, context: Context) {
        finder.webView = wv
        if context.coordinator.lastURL != url {
            context.coordinator.lastURL = url
            wv.load(URLRequest(url: url))
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastURL: URL? }
}


// MARK: - Offline dictionary status and suggestions

struct OfflineDictionaryStatusView: View {
    @ObservedObject var store = OfflineDictionaryStore.shared
    var body: some View {
        Group {
            switch store.status {
            case .ready(let n):
                Label("Offline dictionary ready · \(n.formatted()) words", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10.5)).foregroundColor(DS.ok)
            case .working(let step):
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(step).font(.system(size: 10.5)).foregroundColor(DS.text2) }
            case .failed(let m):
                VStack(alignment: .leading, spacing: 4) {
                    Text(m).font(.system(size: 10.5)).foregroundColor(DS.amber).fixedSize(horizontal: false, vertical: true)
                    Button("Download again") { store.download() }.buttonStyle(.ds(.normal, .small))
                }
            case .notInstalled:
                HStack(spacing: 6) {
                    if store.bundledArchive != nil {
                        Button("Install offline dictionary") { store.prepare() }.buttonStyle(.ds(.primary, .small))
                        Text("included with LiveDeck — no internet needed").font(.system(size: 10)).foregroundColor(DS.text3)
                    } else {
                        Button("Download offline dictionary") { store.download() }.buttonStyle(.ds(.primary, .small))
                        Text("about 25 MB, once").font(.system(size: 10)).foregroundColor(DS.text3)
                    }
                }
            }
        }
        .onAppear { if store.status == .notInstalled && store.bundledArchive != nil { store.prepare() } }
    }
}

struct OfflineSuggestions: View {
    let query: String
    let pick: (String) -> Void
    @ObservedObject var store = OfflineDictionaryStore.shared
    var body: some View {
        let words = store.isReady ? store.suggestions(query) : []
        if !words.isEmpty && !(words.count == 1 && words[0].lowercased() == query.lowercased()) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(words, id: \.self) { w in
                        Button(w) { pick(w) }.buttonStyle(.ds(.ghost, .small))
                    }
                }
            }
        }
    }
}
