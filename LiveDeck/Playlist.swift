import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import PresentationKit

// MARK: - Playlist input: videos, audio and images played one after another in a single holder

final class PlaylistSource: Source {
    @Published var playlist: Playlist
    @Published private(set) var index: Int?
    @Published private(set) var playing = false
    @Published private(set) var itemElapsed: Double = 0
    @Published private(set) var itemDuration: Double = 0
    private(set) var current: Source?
    private var imageTimer: Timer?
    private var tick: Timer?
    private var wasOnAir = false
    var audioRouted = false { didSet { (current as? FileSource)?.audioRouted = audioRouted; (current as? AudioFileSource)?.audioRouted = audioRouted } }

    init(playlist: Playlist = Playlist(), name: String? = nil) {
        self.playlist = playlist
        super.init(name: name ?? playlist.name, kindLabel: "PLAYLIST")
        if let first = playlist.nextIndex(after: nil) { load(first, play: false) }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateProgress() }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    var currentItem: PlaylistItem? { index.flatMap { playlist.items.indices.contains($0) ? playlist.items[$0] : nil } }
    var audioItem: AVPlayerItem? { (current as? FileSource)?.audioItem ?? (current as? AudioFileSource)?.audioItem }

    // MARK: control

    func load(_ i: Int, play: Bool) {
        guard playlist.items.indices.contains(i) else { return }
        imageTimer?.invalidate(); imageTimer = nil
        current?.onReachedEnd = nil
        current?.stop()
        current = nil
        audioRouted = false
        let item = playlist.items[i]
        index = i
        itemElapsed = 0
        guard item.exists else { itemDuration = 0; if play { advanceSoon() }; return }
        let url = URL(fileURLWithPath: item.path)
        switch item.kind {
        case .video:
            let f = FileSource(url: url, displayName: item.title, startLooping: false, autoplay: false)
            f.onReachedEnd = { [weak self] in self?.itemFinished() }
            current = f
            if play { f.togglePlay() }
        case .audio:
            let a = AudioFileSource(url: url, autoplay: false)
            a.loop = false
            a.onReachedEnd = { [weak self] in self?.itemFinished() }
            current = a
            if play { a.togglePlay() }
        case .image:
            current = ImageSource(url: url)
            itemDuration = playlist.seconds(for: item)
            if play { startImageTimer() }
        }
        playing = play
    }

    func togglePlay() {
        guard index != nil else { if let f = playlist.nextIndex(after: nil) { load(f, play: true) }; return }
        playing.toggle()
        if let f = current as? FileSource, f.paused == playing { f.togglePlay() }
        if let a = current as? AudioFileSource, a.paused == playing { a.togglePlay() }
        if currentItem?.kind == .image { if playing { startImageTimer() } else { imageTimer?.invalidate() } }
    }

    func next() {
        if let n = playlist.nextIndex(after: index) { load(n, play: playing || index == nil) }
        else { stopPlayback() }
    }

    func previous() {
        if let p = playlist.previousIndex(before: index) { load(p, play: playing) }
    }

    func restartItem() { if let i = index { load(i, play: playing) } }

    func stopPlayback() {
        playing = false
        if let f = current as? FileSource, !f.paused { f.togglePlay() }
        if let a = current as? AudioFileSource, !a.paused { a.togglePlay() }
        imageTimer?.invalidate()
    }

    /// Called by the engine: starts when taken to Program (if the playlist asks for it).
    func updateOnAir(_ onAir: Bool) {
        if onAir && !wasOnAir && playlist.startOnProgram && !playing { togglePlay() }
        wasOnAir = onAir
    }

    /// Re-applies edits (keeps the current item when it still exists).
    func playlistEdited() {
        name = playlist.name
        if let i = index, !playlist.items.indices.contains(i) { index = nil; current?.stop(); current = nil }
        if index == nil, let f = playlist.nextIndex(after: nil) { load(f, play: false) }
    }

    private func itemFinished() {
        guard playlist.autoAdvance else { playing = false; return }
        if let n = playlist.nextIndex(after: index) { load(n, play: true) } else { playing = false }
    }

    private func advanceSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.itemFinished() }
    }

    private func startImageTimer() {
        imageTimer?.invalidate()
        let remaining = max(0.2, itemDuration - itemElapsed)
        let started = Date().addingTimeInterval(-itemElapsed)
        imageStarted = started
        imageTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in self?.itemFinished() }
    }
    private var imageStarted = Date()

    private func updateProgress() {
        if let f = current as? FileSource { itemElapsed = f.currentTime; itemDuration = f.duration }
        else if let a = current as? AudioFileSource { itemElapsed = a.currentTime; itemDuration = a.duration }
        else if currentItem?.kind == .image, playing { itemElapsed = min(itemDuration, Date().timeIntervalSince(imageStarted)) }
    }

    // MARK: drawing

    override func currentImage() -> CGImage? { current?.currentImage() }

    override func draw(in ctx: CGContext, rect: CGRect) {
        if current is AudioFileSource || current == nil {
            ctx.setFillColor(NSColor(white: 0.04, alpha: 1).cgColor); ctx.fill(rect)
            let title = currentItem?.title ?? (playlist.items.isEmpty ? "Empty playlist" : "Playlist")
            let sub = current is AudioFileSource ? "♪  Now playing" : (currentItem.map { $0.exists ? "" : "File not found" } ?? "Add items in the Input panel")
            let scale = rect.height / 1080
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let t = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 72 * scale, weight: .semibold),
                                                                    .foregroundColor: NSColor.white, .paragraphStyle: para])
            let s = NSAttributedString(string: sub, attributes: [.font: NSFont.systemFont(ofSize: 40 * scale),
                                                                  .foregroundColor: NSColor(white: 0.7, alpha: 1), .paragraphStyle: para])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            t.draw(in: CGRect(x: rect.minX + 40 * scale, y: rect.midY - 10 * scale, width: rect.width - 80 * scale, height: 110 * scale))
            s.draw(in: CGRect(x: rect.minX, y: rect.midY - 90 * scale, width: rect.width, height: 60 * scale))
            NSGraphicsContext.restoreGraphicsState()
            if itemDuration > 0 {
                let w = rect.width * 0.6, x = rect.midX - w / 2, y = rect.midY - 160 * scale
                ctx.setFillColor(NSColor(white: 0.25, alpha: 1).cgColor); ctx.fill(CGRect(x: x, y: y, width: w, height: 8 * scale))
                ctx.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor); ctx.fill(CGRect(x: x, y: y, width: w * CGFloat(min(1, itemElapsed / itemDuration)), height: 8 * scale))
            }
            return
        }
        super.draw(in: ctx, rect: rect)
    }

    override func stop() {
        imageTimer?.invalidate(); tick?.invalidate()
        current?.stop()
    }
}

// MARK: - Tile transport

struct PlaylistTransport: View {
    @ObservedObject var source: PlaylistSource
    var body: some View {
        HStack(spacing: 8) {
            Button { source.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundColor(DS.text2)
            Button { source.togglePlay() } label: { Image(systemName: source.playing ? "pause.fill" : "play.fill").font(.system(size: 14)) }
                .buttonStyle(.plain).foregroundColor(DS.text)
            Button { source.next() } label: { Image(systemName: "forward.fill").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundColor(DS.text2)
            if let i = source.index {
                Text("\(i + 1)/\(source.playlist.items.count)").font(DS.mono(9)).foregroundColor(DS.text3)
            }
        }
    }
}

// MARK: - Editor (Input panel card)

struct PlaylistEditorCard: View {
    @EnvironmentObject var bg: BackgroundsModel
    @ObservedObject var source: PlaylistSource
    @State private var dropTargeted = false
    private static let library = PlaylistLibrary(libraryRoot: PresentationLibrary.defaultRoot)
    @State private var saved: [Playlist] = PlaylistEditorCard.library.playlists

    var body: some View {
        CPCard(title: "Playlist", subtitle: "\(source.playlist.items.count) item\(source.playlist.items.count == 1 ? "" : "s")" + (source.playing ? " · playing" : ""),
               icon: "list.and.film") {
            CPTextRow(label: "Name", text: Binding(get: { source.playlist.name }, set: { source.playlist.name = $0; source.playlistEdited() }), showDivider: true)

            HStack(spacing: 6) {
                CPButton(icon: "backward.fill", title: "") { source.previous() }
                CPButton(icon: source.playing ? "pause.fill" : "play.fill", title: source.playing ? "Pause" : "Play", prominent: true) { source.togglePlay() }
                CPButton(icon: "forward.fill", title: "") { source.next() }
                Spacer()
                if source.itemDuration > 0 {
                    Text("\(timeText(source.itemElapsed)) / \(timeText(source.itemDuration))").font(DS.mono(10)).foregroundColor(CP.text2)
                }
            }
            .padding(.vertical, 6)

            VStack(spacing: 2) {
                if source.playlist.items.isEmpty {
                    CPNote("Add videos, songs/audio and images — drop files here, choose files, or pick from your Media library.")
                }
                ForEach(Array(source.playlist.items.enumerated()), id: \.element.id) { i, item in
                    itemRow(i, item)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 7).fill(dropTargeted ? CP.blueSoft : CP.field))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(dropTargeted ? CP.accentLine : CP.border, style: StrokeStyle(lineWidth: 1, dash: dropTargeted ? [6, 4] : [])))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        var url: URL?
                        if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) } else if let u = item as? URL { url = u }
                        if let url { DispatchQueue.main.async { FileAccess.remember(url); add([url.path]) } }
                    }
                }
                return true
            }

            HStack(spacing: 6) {
                CPButton(icon: "plus", title: "Add files…") { chooseFiles() }
                Menu {
                    if bg.catalog.items.isEmpty { Text("Your Media library is empty") }
                    ForEach(bg.catalog.items) { item in
                        Button(item.title + (item.kind == .video ? "  (video)" : "")) { add([bg.catalog.url(item).path], titles: [item.title]) }
                    }
                } label: { Label("From library", systemImage: "photo.stack") }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }
            .padding(.vertical, 6)

            CPDivider()
            CPToggleRow(label: "Play the next item automatically", isOn: bind(\.autoAdvance))
            CPToggleRow(label: "Loop the playlist", isOn: bind(\.loop))
            CPToggleRow(label: "Shuffle", isOn: bind(\.shuffle))
            CPToggleRow(label: "Start playing when taken to Program", isOn: bind(\.startOnProgram))
            ParamSlider(label: "Image duration", value: Binding(get: { source.playlist.imageSeconds }, set: { source.playlist.imageSeconds = $0 }),
                        range: 2...60, defaultValue: 8, format: "%.0f s")

            CPDivider()
            HStack(spacing: 6) {
                CPButton(icon: "square.and.arrow.down", title: "Save playlist") {
                    PlaylistEditorCard.library.save(source.playlist); saved = PlaylistEditorCard.library.playlists
                }
                Menu {
                    if saved.isEmpty { Text("No saved playlists") }
                    ForEach(saved) { p in
                        Button("\(p.name) (\(p.items.count))") {
                            var copy = p; copy.id = source.playlist.id
                            source.playlist = copy; source.playlistEdited()
                        }
                    }
                    if !saved.isEmpty {
                        Divider()
                        Menu("Delete saved") { ForEach(saved) { p in Button(p.name) { PlaylistEditorCard.library.delete(p.id); saved = PlaylistEditorCard.library.playlists } } }
                    }
                } label: { Label("Open saved", systemImage: "folder") }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }
            .padding(.vertical, 6)
        }
    }

    private func itemRow(_ i: Int, _ item: PlaylistItem) -> some View {
        let isCurrent = source.index == i
        return HStack(spacing: 6) {
            Image(systemName: isCurrent ? (source.playing ? "speaker.wave.2.fill" : "pause.circle") : icon(item.kind))
                .font(.system(size: 11)).foregroundColor(isCurrent ? DS.program : CP.text2).frame(width: 16)
            Toggle("", isOn: Binding(get: { item.enabled }, set: { v in if source.playlist.items.indices.contains(i) { source.playlist.items[i].enabled = v } }))
                .toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundColor(item.exists ? CP.text : DS.program).lineLimit(1)
                if item.kind == .image {
                    Text("\(Int(source.playlist.seconds(for: item))) s").font(.system(size: 9)).foregroundColor(CP.text2)
                } else if !item.exists {
                    Text("file not found").font(.system(size: 9)).foregroundColor(DS.program)
                }
            }
            Spacer()
            Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).foregroundColor(CP.text2).disabled(i == 0)
            Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).foregroundColor(CP.text2).disabled(i == source.playlist.items.count - 1)
        }
        .font(.system(size: 9, weight: .bold))
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(isCurrent ? CP.blueSoft : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { source.load(i, play: true) }
        .contextMenu {
            Button("Play now") { source.load(i, play: true) }
            Button("Cue (load paused)") { source.load(i, play: false) }
            if item.kind == .image {
                Menu("Show for") {
                    ForEach([0, 3, 5, 8, 10, 15, 20, 30, 60], id: \.self) { sec in
                        Button(sec == 0 ? "Playlist default" : "\(sec) seconds") { if source.playlist.items.indices.contains(i) { source.playlist.items[i].imageSeconds = Double(sec) } }
                    }
                }
            }
            Button("Move up") { move(i, -1) }.disabled(i == 0)
            Button("Move down") { move(i, 1) }.disabled(i == source.playlist.items.count - 1)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
            Divider()
            Button("Remove", role: .destructive) { remove(i) }
        }
    }

    private func icon(_ k: PlaylistItemKind) -> String {
        switch k { case .video: return "film"; case .audio: return "music.note"; case .image: return "photo" }
    }

    private func bind(_ kp: WritableKeyPath<Playlist, Bool>) -> Binding<Bool> {
        Binding(get: { source.playlist[keyPath: kp] }, set: { source.playlist[keyPath: kp] = $0 })
    }

    private func add(_ paths: [String], titles: [String]? = nil) {
        var expanded: [String] = []
        for p in paths {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []
                expanded += files.sorted().map { (p as NSString).appendingPathComponent($0) }
            } else { expanded.append(p) }
        }
        let before = source.playlist.items.count
        _ = source.playlist.add(paths: expanded)
        if let titles, titles.count == source.playlist.items.count - before {
            for (k, t) in titles.enumerated() { source.playlist.items[before + k].title = t }
        }
        source.playlistEdited()
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.movie, .audio, .image, .folder]
        panel.message = "Choose videos, audio files and images for the playlist"
        panel.begin { resp in
            guard resp == .OK else { return }
            FileAccess.remember(panel.urls)
            add(panel.urls.map { $0.path })
        }
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard source.playlist.items.indices.contains(i), source.playlist.items.indices.contains(j) else { return }
        source.playlist.items.swapAt(i, j)
        if let cur = source.index { if cur == i { setIndexQuietly(j) } else if cur == j { setIndexQuietly(i) } }
    }
    private func setIndexQuietly(_ i: Int) { source.reindex(i) }

    private func remove(_ i: Int) {
        guard source.playlist.items.indices.contains(i) else { return }
        let wasCurrent = source.index == i
        source.playlist.items.remove(at: i)
        if let cur = source.index, cur > i { source.reindex(cur - 1) }
        if wasCurrent {
            if source.playlist.items.indices.contains(i) { source.load(i, play: source.playing) } else { source.playlistEdited() }
        }
    }

    private func timeText(_ s: Double) -> String {
        guard s.isFinite else { return "--:--" }
        let v = Int(s); return String(format: "%d:%02d", v / 60, v % 60)
    }
}

extension PlaylistSource {
    /// Keeps the playing item when rows are reordered.
    func reindex(_ i: Int) { index = i }
}
