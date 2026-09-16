import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PresentationKit

// MARK: - Lower deck tabs (same page as the switcher)

enum DeckTab: Int { case inputs = 0, present = 1, dictionary = 2 }

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
    @Published var deck: Int = DeckTab.inputs.rawValue
    @Published var tab: PresentLibraryTab = .songs
    @Published var editingSong = false

    let library: PresentationLibrary
    let looks: LookLibrary
    @Published var looksRevision = 0
    weak var engine: Engine?

    // Live control
    @Published var targetID: UUID?
    @Published var liveKey: String?
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
                    for s in imported { try? self.library.songs.save(s) }
                    self.refreshSongs()
                    if let first = imported.first { self.selectedSongID = first.id }
                    self.status = "Imported \(imported.count) song(s)" + (failures > 0 ? ", \(failures) file(s) not recognised." : ".")
                }
            }
        }
    }

    // MARK: Bibles

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
        panel.canChooseDirectories = false
        panel.message = "Choose a Zefania XML, OSIS XML, CSV/TSV or Free Use Bible JSON file — or all the USFM book files of one translation"
        panel.begin { [weak self] resp in
            guard resp == .OK, let self else { return }
            let urls = panel.urls
            let dir = self.library.bibles.directory
            self.status = "Importing Bible…"
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try BibleImporter.importFiles(urls, into: dir) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let info):
                        self.refreshBibles()
                        self.selectedBibleID = info.id
                        self.status = "Imported \(info.name) — \(info.verseCount) verses."
                    case .failure(let e):
                        self.status = "Bible import failed: \(e.localizedDescription)"
                    }
                }
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

    func scriptureSlides(look: SlideLook) -> [SlideContent] {
        guard let store = currentStore, !passage.isEmpty else { return [] }
        let abbr = store.info.abbreviation
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
                    .font(.system(size: 12, design: .monospaced))
                Button("As written") { draft.arrangement = "" }.font(.system(size: 10))
            }
            HStack(spacing: 8) {
                Text("Lines per slide").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                Stepper(draft.linesPerSlide == 0 ? "Use blank-line breaks" : "\(draft.linesPerSlide)",
                        value: $draft.linesPerSlide, in: 0...8)
                    .font(.system(size: 11))
                Spacer()
                Text("Sections: " + (draft.sections.isEmpty ? "—" : draft.sections.map { $0.code }.joined(separator: " ")))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
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
            Text(t.shortName ?? t.id).font(.system(size: 11, weight: .heavy, design: .monospaced)).frame(width: 80, alignment: .leading)
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
        kind = DictionaryKind(rawValue: UserDefaults.standard.string(forKey: "dict.kind") ?? "") ?? .macOS
        language = UserDefaults.standard.string(forKey: "dict.lang") ?? "en"
        customList = custom.dictionaries
    }

    var selected: WordEntry? { results.first { $0.id == selectedID } ?? results.first }

    func search() {
        let word = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        message = ""; results = []; selectedID = nil
        switch kind {
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

            LookColumn(dictionary: false)
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 400)
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
            Button("Key over Program") { present.toggleKey() }.buttonStyle(.ds(.amber, .small, active: keyed))
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
            if present.tab == .songs { songArea } else { ScriptureArea() }
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
                    }
                }
                .padding(8)
            }
        }
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
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("", selection: $present.selectedBibleID) {
                    ForEach(present.bibles) { b in Text(b.abbreviation).tag(Optional(b.id)) }
                }
                .labelsHidden().frame(width: 100)
                TextField("Reference — e.g. John 3:16-18, Ps 23, 1 Cor 13:4-7", text: $present.reference)
                    .dsField()
                    .onSubmit { present.lookUp() }
                Button("Go") { present.lookUp() }.buttonStyle(.ds(.primary, .regular))
                DSIconButton(symbol: "text.magnifyingglass", help: "Search words", active: showSearch) { showSearch.toggle() }
            }
            .padding(8)
            if !present.passageError.isEmpty {
                Text(present.passageError).font(.system(size: 11)).foregroundColor(DS.amber)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            if showSearch {
                VStack(spacing: 4) {
                    TextField("Search words in this Bible", text: $present.searchText).dsField()
                        .onSubmit { present.runSearch() }
                    List(present.searchResults, id: \.self) { v in
                        Button {
                            present.reference = "\(present.currentStore?.bookName(v.book) ?? "") \(v.chapter):\(v.verse)"
                            present.lookUp()
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(present.currentStore?.bookName(v.book) ?? "") \(v.chapter):\(v.verse)")
                                    .font(.system(size: 10, weight: .bold)).foregroundColor(DS.amber)
                                Text(v.text).font(.system(size: 11)).lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(height: 150)
                }
                .padding(.horizontal, 8)
            }
            if let t = present.currentTarget() {
                ScriptureSlideGrid(source: t)
            } else {
                NoTargetView()
            }
        }
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
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var present: PresentModel
    @EnvironmentObject var dict: DictionaryModel
    var body: some View {
        VStack(spacing: 0) {
            let target: SlideSource? = dictionary ? (dict.currentTarget() as SlideSource?) : (present.currentTarget() as SlideSource?)
            PanelHeader(title: "Format", icon: "paintbrush.pointed") {
                if let t = target { Text(t.name).font(.system(size: 10)).foregroundColor(DS.text3).lineLimit(1) }
            }
            if let t = target {
                LookEditor(source: t)
            } else {
                VStack(spacing: 8) {
                    Text("Add a \(dictionary ? "Dictionary" : "Presentation") input to format its display.")
                        .font(DS.small).foregroundColor(DS.text2).multilineTextAlignment(.center)
                    Button("Add input") { if dictionary { _ = dict.ensureTarget() } else { _ = present.ensureTarget() } }.buttonStyle(.ds(.primary))
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DS.bg1)
    }
}

struct LookEditor: View {
    @ObservedObject var source: SlideSource
    @EnvironmentObject var present: PresentModel
    @State private var families: [String] = []
    @State private var showSave = false
    @State private var saveName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                presetRow
                backgroundSection
                SectionLabel("Layout")
                layoutSection
                SectionLabel("Main text")
                TextStyleEditor(style: $source.look.body, families: families)
                if source is DictionarySource || source.look.showTitle {
                    SectionLabel(source is DictionarySource ? "Headword" : "Title")
                    TextStyleEditor(style: $source.look.title, families: families)
                }
                SectionLabel(source is DictionarySource ? "Source line" : "Reference / credits")
                FieldRow(label: "Position") {
                    Picker("", selection: $source.look.footerPosition) {
                        ForEach(FooterPosition.allCases) { p in Text(p.rawValue).tag(p) }
                    }.labelsHidden()
                }
                if source.look.footerPosition != .hidden {
                    TextStyleEditor(style: $source.look.footer, families: families)
                }
                SectionLabel("Text box")
                boxSection
                SectionLabel("Content")
                contentSection
            }
            .padding(10)
        }
        .onAppear { if families.isEmpty { families = NSFontManager.shared.availableFontFamilies.sorted() } }
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

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Background")
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
                    Button("Choose…") { chooseMedia(video: source.look.background.kind == .video) }.buttonStyle(.ds(.normal, .small))
                }
                if let p = source.backgroundProblem { Text(p).font(.system(size: 10)).foregroundColor(DS.amber) }
                FieldRow(label: "Fit") {
                    DSSegmented(selection: $source.look.background.fit, options: [(FitMode.fill, "Fill"), (FitMode.fit, "Fit"), (FitMode.stretch, "Stretch")])
                }
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
        VStack(alignment: .leading, spacing: 8) {
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
            Toggle("Shrink text to fit", isOn: $source.look.shrinkToFit).font(DS.small)
            ParamSlider(label: "Fade between slides", value: $source.look.fadeDuration, range: 0...1.5, defaultValue: 0.35, format: "%.2fs")
        }
    }

    private var boxSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DSColorWell(label: "Box colour (set opacity for none)", color: colorBinding($source.look.boxColor))
            if source.look.boxColor.a > 0.001 {
                Toggle("Full-width band", isOn: $source.look.boxFullWidth).font(DS.small)
                ParamSlider(label: "Padding", value: $source.look.boxPadding, range: 0...120, defaultValue: 28, format: "%.0f")
                ParamSlider(label: "Corner radius", value: $source.look.boxRadius, range: 0...80, defaultValue: 10, format: "%.0f")
            }
        }
    }

    @ViewBuilder private var contentSection: some View {
        if source is DictionarySource {
            ParamSlider(label: "Definitions shown", value: intBinding($source.look.maxSenses), range: 1...8, defaultValue: 3, format: "%.0f")
            Toggle("Show examples", isOn: $source.look.showExamples).font(DS.small)
            Toggle("Show headword", isOn: $source.look.showTitle).font(DS.small)
        } else {
            Toggle("Verse numbers", isOn: $source.look.showVerseNumbers).font(DS.small)
            ParamSlider(label: "Scripture: max characters per slide", value: intBinding($source.look.maxCharsPerSlide), range: 60...700, defaultValue: 280, format: "%.0f")
            ParamSlider(label: "Songs: lines per slide (0 = as written)", value: intBinding($source.look.linesPerSlide), range: 0...8, defaultValue: 0, format: "%.0f")
            Toggle("Show song title", isOn: $source.look.showTitle).font(DS.small)
        }
    }

    private func chooseMedia(video: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = video ? [.movie, .video, .mpeg4Movie, .quickTimeMovie] : [.image]
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            source.look.background.media = MediaRef(path: url.path, bytes: size)
        }
    }
}

struct TextStyleEditor: View {
    @Binding var style: TextStyle
    let families: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                ColorPicker("", selection: colorBinding($style.color), supportsOpacity: true).labelsHidden()
            }
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
            HStack {
                Text("Outline").font(DS.small).foregroundColor(DS.text2)
                Spacer()
                ColorPicker("", selection: colorBinding($style.outlineColor), supportsOpacity: true).labelsHidden()
            }
            ParamSlider(label: "Outline width", value: $style.outlineWidth, range: 0...12, defaultValue: 0, format: "%.1f")
            HStack {
                Toggle("Shadow", isOn: $style.shadow).font(DS.small)
                Spacer()
                if style.shadow { ColorPicker("", selection: colorBinding($style.shadowColor), supportsOpacity: true).labelsHidden() }
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
            LookColumn(dictionary: true)
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 400)
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
            HStack(spacing: 6) {
                TextField("Type a word or name", text: $dict.query).dsField().onSubmit { dict.search() }
                Button("Search") { dict.search() }.buttonStyle(.ds(.primary))
            }
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
                Button("Key over Program") { dict.key() }.buttonStyle(.ds(.amber, .small, active: keyed)).disabled(dict.selected == nil && !keyed)
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
