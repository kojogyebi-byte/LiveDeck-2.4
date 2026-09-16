import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PresentationKit

// MARK: - Workspace switch

enum Workspace: String, CaseIterable, Identifiable {
    case production = "PRODUCTION"
    case present = "PRESENT"
    var id: String { rawValue }
}

enum PresentLibraryTab: String, CaseIterable, Identifiable {
    case songs = "Songs"
    case bibles = "Bibles"
    var id: String { rawValue }
}

private let pPanel = Color(red: 0.14, green: 0.14, blue: 0.17)
private let pBar = Color(red: 0.17, green: 0.17, blue: 0.20)
private let pBG = Color(red: 0.10, green: 0.10, blue: 0.12)
private let pAccent = Color(red: 0.88, green: 0.55, blue: 0.18)
private let pGreen = Color(red: 0.18, green: 0.70, blue: 0.30)

extension RGBAColor {
    var swiftUI: Color { Color(red: r, green: g, blue: b, opacity: a) }
}

// MARK: - Model

/// State for the PRESENT workspace. 4.0-a: song library + Bible library & lookup.
/// Nothing here touches the video engine, so presentation work can never stall Program.
final class PresentModel: ObservableObject {
    @Published var workspace: Workspace = .production
    @Published var tab: PresentLibraryTab = .songs

    let library: PresentationLibrary

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
}

// MARK: - Workspace root

struct PresentWorkspace: View {
    @EnvironmentObject var present: PresentModel
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                PresentSidebar()
                    .frame(minWidth: 240, idealWidth: 290, maxWidth: 420)
                Group {
                    if present.tab == .songs { SongWorkArea() } else { ScriptureWorkArea() }
                }
                .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                Text("PRESENT").font(.system(size: 9, weight: .heavy)).kerning(2).foregroundColor(pAccent)
                Text(present.status).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                Text("Library: \(present.library.root.path)").font(.system(size: 9)).foregroundColor(Color(white: 0.4)).lineLimit(1)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10).frame(height: 22).background(pBar)
        }
        .background(pBG)
        .sheet(isPresented: $present.showCatalog) { BibleCatalogView().environmentObject(present) }
    }
}

// MARK: - Sidebar

struct PresentSidebar: View {
    @EnvironmentObject var present: PresentModel
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $present.tab) {
                ForEach(PresentLibraryTab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            Divider()
            if present.tab == .songs { SongListPane() } else { BibleListPane() }
        }
        .background(pPanel)
    }
}

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

// MARK: - Song editor

struct SongWorkArea: View {
    @EnvironmentObject var present: PresentModel
    var body: some View {
        if let id = present.selectedSongID, let song = present.song(id) {
            SongEditor(initial: song).id(id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "music.note.list").font(.system(size: 40)).foregroundColor(Color(white: 0.3))
                Text("Select a song, create a new one, or import song files.").foregroundColor(.secondary)
                HStack {
                    Button("New Song") { present.newSong() }
                    Button("Import…") { present.importSongs() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Lightweight slide preview (text only). Real rendered thumbnails arrive with the slide renderer in 4.0-b.
struct SlidePreviewGrid: View {
    let song: Song
    var body: some View {
        let slides = song.generatedSlides()
        VStack(spacing: 0) {
            HStack {
                Text("SLIDES").font(.system(size: 9, weight: .heavy)).kerning(2).foregroundColor(.secondary)
                Spacer()
                Text("\(slides.count)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 10).frame(height: 24).background(pBar)
            GeometryReader { geo in
                let cols = max(1, Int(geo.size.width / 230))
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
        .background(pPanel)
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

// MARK: - Bibles

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

struct ScriptureWorkArea: View {
    @EnvironmentObject var present: PresentModel
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Picker("", selection: $present.selectedBibleID) {
                        ForEach(present.bibles) { b in Text(b.abbreviation).tag(Optional(b.id)) }
                    }
                    .labelsHidden().frame(width: 110)
                    TextField("Reference, e.g. John 3:16-18", text: $present.reference)
                        .textFieldStyle(.roundedBorder).font(.system(size: 14))
                        .onSubmit { present.lookUp() }
                    Button("Go") { present.lookUp() }.keyboardShortcut(.defaultAction)
                }
                if !present.passageError.isEmpty {
                    Text(present.passageError).font(.system(size: 11)).foregroundColor(.orange)
                }
                Text(present.passageTitle).font(.system(size: 13, weight: .heavy)).foregroundColor(pAccent)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(present.passage, id: \.self) { v in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(v.chapter):\(v.verse)").font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary).frame(width: 46, alignment: .trailing)
                                Text(v.text).font(.system(size: 13)).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass").foregroundColor(.secondary)
                    TextField("Search words in this Bible", text: $present.searchText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { present.runSearch() }
                    Text("\(present.searchResults.count)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                }
                List(present.searchResults, id: \.self) { v in
                    Button {
                        let name = present.currentStore?.bookName(v.book) ?? ""
                        present.reference = "\(name) \(v.chapter):\(v.verse)"
                        present.lookUp()
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(present.currentStore?.bookName(v.book) ?? "") \(v.chapter):\(v.verse)")
                                .font(.system(size: 10, weight: .bold)).foregroundColor(pAccent)
                            Text(v.text).font(.system(size: 11)).lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 120, maxHeight: 220)
            }
            .padding(12)
            .frame(minWidth: 360, idealWidth: 480)

            ScriptureSlidePreview().frame(minWidth: 260)
        }
    }
}

struct ScriptureSlidePreview: View {
    @EnvironmentObject var present: PresentModel
    var body: some View {
        let parts = BibleStore.slideTexts(present.passage, maxChars: present.maxCharsPerSlide)
        VStack(spacing: 0) {
            HStack {
                Text("SLIDES").font(.system(size: 9, weight: .heavy)).kerning(2).foregroundColor(.secondary)
                Spacer()
                Stepper("≤ \(present.maxCharsPerSlide) chars", value: $present.maxCharsPerSlide, in: 80...600, step: 20)
                    .font(.system(size: 10))
            }
            .padding(.horizontal, 10).frame(height: 26).background(pBar)
            GeometryReader { geo in
                let cols = max(1, Int(geo.size.width / 230))
                let w = (geo.size.width - CGFloat(cols + 1) * 8) / CGFloat(cols)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(max(80, w)), spacing: 8), count: cols), spacing: 8) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { idx, p in
                            SlideTextCard(index: idx + 1, label: "\(p.first.chapter):\(p.first.verse)–\(p.last.chapter):\(p.last.verse)",
                                          color: Color(red: 0.2, green: 0.45, blue: 0.85), text: p.text, width: max(80, w))
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(pPanel)
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
