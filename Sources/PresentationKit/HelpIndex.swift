import Foundation

// MARK: - In-app help: user guide topics + tool search

public struct HelpTopic: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let category: String
    public let keywords: [String]
    public let summary: String
    public let steps: [String]
    /// Where "Show me" takes the user (interpreted by the app), e.g. "deck.present", "right.audio".
    public let target: String?

    public init(_ id: String, _ title: String, category: String, keywords: [String], summary: String, steps: [String], target: String? = nil) {
        self.id = id; self.title = title; self.category = category; self.keywords = keywords
        self.summary = summary; self.steps = steps; self.target = target
    }
}

public enum HelpIndex {
    public static let categories = ["Getting started", "Switching", "Inputs", "Songs & Bible", "Dictionary", "Images",
                                    "Audio", "Overlays & scenes", "Outputs & streaming", "Recording", "Presets", "Keyboard & help"]

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
    static func tokens(_ s: String) -> [String] {
        fold(s).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 || Int($0) != nil }
    }

    /// Ranked search. Every word of the query must match somewhere in a topic.
    public static func search(_ query: String, in topics: [HelpTopic] = HelpIndex.topics) -> [HelpTopic] {
        let q = fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let words = tokens(query)
        guard !words.isEmpty else { return topics }
        var scored: [(Int, Int, HelpTopic)] = []
        for (order, t) in topics.enumerated() {
            let title = fold(t.title), titleWords = tokens(t.title)
            let keys = t.keywords.map(fold), keyWords = t.keywords.flatMap(tokens)
            let summary = fold(t.summary), steps = fold(t.steps.joined(separator: " ")), cat = fold(t.category)
            var score = 0
            if title == q { score += 200 }
            if title.contains(q) { score += 80 }
            if keys.contains(q) { score += 60 }
            var allMatched = true
            for w in words {
                var s = 0
                if titleWords.contains(w) { s += 30 } else if titleWords.contains(where: { $0.hasPrefix(w) }) { s += 18 }
                if keyWords.contains(w) { s += 20 } else if keyWords.contains(where: { $0.hasPrefix(w) }) { s += 10 }
                if cat.contains(w) { s += 6 }
                if summary.contains(w) { s += 5 }
                if steps.contains(w) { s += 2 }
                if s == 0 { allMatched = false; break }
                score += s
            }
            if allMatched { scored.append((score, order, t)) }
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map { $0.2 }
    }

    public static func topics(in category: String) -> [HelpTopic] { topics.filter { $0.category == category } }

    // MARK: Content

    public static let topics: [HelpTopic] = [
        // Getting started
        HelpTopic("tour", "Tour of the screen", category: "Getting started",
                  keywords: ["overview", "layout", "interface", "start", "beginner", "where"],
                  summary: "LiveDeck has one main page: monitors on top, a lower deck for inputs and content, and a control panel on the right.",
                  steps: ["Top bar: open/save show, Presets, PROGRAM OUT, STREAM, REC, Help (?), computer load and the settings gear.",
                          "PREVIEW (left, green) shows what goes on air next; PROGRAM (right, red) is what is on air now.",
                          "The column between them holds CUT, AUTO, the transition buttons, the T-bar, duration and FTB (fade to black).",
                          "The lower deck has tabs: Inputs, Songs & Bible, Dictionary, Images and Audio Mixer.",
                          "The right-hand control panel has tabs: Input, Audio, Overlays, Scenes, Outputs and Presets.",
                          "The bottom status bar shows the format, frame rate, disk space, overlay channels 1–4, Snapshot, Outputs, Multiview and Guides."]),
        HelpTopic("first-service", "Run your first service (quick start)", category: "Getting started",
                  keywords: ["quick start", "church", "sunday", "setup", "how to use", "tutorial", "guide"],
                  summary: "The shortest path from opening the app to being live.",
                  steps: ["Right-click the Inputs area → add your cameras, a video file or a screen capture.",
                          "Open Songs & Bible → Songs → New or Find online; add a Presentation input when asked.",
                          "Click an input's picture to put it on PREVIEW, then press CUT or AUTO to send it to PROGRAM.",
                          "Choose STREAM to add YouTube/Facebook destinations and go live; press REC to record.",
                          "Use PROGRAM OUT to show Program full-screen on the projector or LED screen.",
                          "When everything is set, open Presets → Save current as preset so next week starts in one click."]),
        // Switching
        HelpTopic("cut-auto", "Cut, Auto and transitions", category: "Switching",
                  keywords: ["take", "switch", "fade", "wipe", "slide", "zoom", "mix", "transition"],
                  summary: "Move the Preview picture to Program instantly or with a transition.",
                  steps: ["Put an input on Preview: click its picture, press its PVW button, or press its number key (1–9).",
                          "CUT swaps Preview and Program instantly (key C).",
                          "Pick Fade, Wipe, Slide or Zoom, set Duration, then press AUTO (Return key).",
                          "Double-click an input picture to cut it straight to Program."], target: "deck.inputs"),
        HelpTopic("tbar", "T-bar (manual transition)", category: "Switching",
                  keywords: ["t bar", "lever", "manual", "fader"],
                  summary: "Drag the T-bar handle down to perform the transition by hand at your own speed.",
                  steps: ["Put the next input on Preview.", "Drag the T-bar handle from top to bottom; the transition follows your hand.",
                          "Releasing at the bottom completes it; dragging back to the top cancels."]),
        HelpTopic("ftb", "Fade to black (FTB)", category: "Switching",
                  keywords: ["black", "blackout", "fade out", "end"],
                  summary: "Fades the whole Program output, including overlays, to black.",
                  steps: ["Press FTB (or key B). Press again to fade back up."]),
        // Inputs
        HelpTopic("add-input", "Add an input (camera, video, image, screen, web page)", category: "Inputs",
                  keywords: ["camera", "video", "file", "image", "photo", "screen", "capture", "web", "url", "source", "new input", "right click"],
                  summary: "Inputs are the sources you switch between. There are 8 empty holders by default.",
                  steps: ["Right-click an empty part of the Inputs area, or press + Add Input.",
                          "Or click the + in an empty holder to fill that exact slot.",
                          "Or drag files from Finder onto the window.",
                          "Cameras include capture cards (Blackmagic, AJA) when their drivers are installed.",
                          "Web Page accepts addresses with or without https://."], target: "deck.inputs"),
        HelpTopic("stream-input", "Network streams and online videos as inputs", category: "Inputs",
                  keywords: ["hls", "rtmp", "rtsp", "srt", "youtube", "facebook", "twitch", "link", "ffmpeg", "stream input"],
                  summary: "Bring a live stream or an online video in as an input.",
                  steps: ["Add Input → Network Stream (HLS/URL) for .m3u8 links.",
                          "RTMP / RTSP / SRT and YouTube/Twitch/Facebook links need ffmpeg (and yt-dlp for links) installed.",
                          "Right-click the input → Edit address… to change it later."], target: "deck.inputs"),
        HelpTopic("adjust-input", "Zoom, pan, rotate, crop and colour an input", category: "Inputs",
                  keywords: ["geometry", "crop", "brightness", "contrast", "saturation", "rotate", "position", "reset"],
                  summary: "Every input can be framed and colour-corrected in the Input tab of the control panel.",
                  steps: ["Select the input (click its picture) or choose it in Input Channel.",
                          "Drag a slider, or type a number in its value box and press Return.",
                          "The round arrow resets one control; the arrow in a card header resets the whole card; Reset resets everything."], target: "right.input"),
        HelpTopic("playback", "Play, loop and trim video clips", category: "Inputs",
                  keywords: ["play", "pause", "loop", "in point", "out point", "trim", "playlist", "scrub"],
                  summary: "Video and audio files load paused on their first frame.",
                  steps: ["Use the play button on the tile, or the transport in the Input tab.",
                          "Set In / Set Out trims the clip; Clear removes the trim.",
                          "Playlist (Inputs tab) auto-advances Program through clips as each one ends."], target: "right.input"),
        // Songs & Bible
        HelpTopic("songs", "Create, import and edit songs", category: "Songs & Bible",
                  keywords: ["lyrics", "hymn", "worship", "song library", "chorus", "verse", "import", "songselect", "chordpro", "openlyrics", "opensong"],
                  summary: "Songs are typed, pasted, imported or found online, then split into slides automatically.",
                  steps: ["Songs & Bible → Songs → New, then type or paste the words.",
                          "Put Verse 1, Chorus, Bridge… on their own lines; a blank line starts a new slide.",
                          "Import… reads plain text, CCLI SongSelect (.txt/.usr), ChordPro, OpenLyrics and OpenSong files.",
                          "Edits save automatically; the clock icon restores earlier versions; deleted songs go to Trash."], target: "deck.present"),
        HelpTopic("find-lyrics", "Find song lyrics online", category: "Songs & Bible",
                  keywords: ["search lyrics", "internet", "lrclib", "lyrics.ovh", "hymnary", "genius", "musixmatch", "download lyrics"],
                  summary: "Search free lyrics sources, edit the words and save them to the library.",
                  steps: ["Songs & Bible → Songs → Find online.",
                          "Lyrics databases: type the title (and artist) and press Search; pick a result.",
                          "Web sites: choose a site, select the words on the page, press Use selection.",
                          "Edit the words, then Save to Song Library.",
                          "Copyrighted songs need a church licence such as CCLI; public-domain hymns are free."], target: "deck.present"),
        HelpTopic("bible", "Install Bibles and show scripture", category: "Songs & Bible",
                  keywords: ["scripture", "verse", "passage", "translation", "version", "kjv", "niv", "download bible", "search bible"],
                  summary: "Install as many Bible versions as you like and show any passage.",
                  steps: ["Songs & Bible → Bible → Get Bibles… to download free translations (or Import file…).",
                          "Choose the version and type a reference such as John 3:16-18 or Ps 23, then Go.",
                          "The magnifier searches words in the Bible.",
                          "Click a slide to send it to the Presentation input."], target: "deck.present"),
        HelpTopic("go-live-slides", "Put lyrics or scripture on screen", category: "Songs & Bible",
                  keywords: ["presentation input", "live", "next slide", "previous slide", "clicker", "clear", "key", "lower third"],
                  summary: "Slides are shown through a Presentation input that you switch like any other input.",
                  steps: ["Click a slide; it appears on the Presentation input (added automatically if needed).",
                          "Press Preview / Program, or Key over Program to put the words on top of the cameras.",
                          "Next/previous: → / ← on the Songs & Bible tab, or Page Down / Page Up (presentation clickers).",
                          "Clear text removes the words; Hide BG hides the background."], target: "deck.present"),
        HelpTopic("formatting", "Format slides (fonts, position, box, looks)", category: "Songs & Bible",
                  keywords: ["font", "size", "colour", "color", "outline", "shadow", "alignment", "lower third", "look", "theme", "style", "margin"],
                  summary: "The Format column controls exactly how slides look; save your favourite looks.",
                  steps: ["Open Songs & Bible (or Dictionary); Format is the right-hand column.",
                          "Main text, title and reference each have font, size, colour, spacing, outline and shadow.",
                          "Layout chooses the area (full screen, lower third, custom), margins and alignment.",
                          "Text box adds a panel or full-width band behind the words.",
                          "Looks → pick a built-in look; Save look… keeps your own."], target: "deck.present"),
        HelpTopic("backgrounds", "Backgrounds and blend modes for slides", category: "Songs & Bible",
                  keywords: ["background image", "background video", "blend", "blending mode", "multiply", "screen", "overlay", "tint", "opacity", "darken", "gradient"],
                  summary: "Use a colour, gradient, image or looping video behind songs, scripture and dictionary cards — and blend it.",
                  steps: ["Format → Background → Type: Image or Video (loops, muted), then Choose….",
                          "Base under media: pick a colour or gradient.",
                          "Blend mode mixes the media with the base (Multiply tints, Screen lightens, Overlay adds contrast…).",
                          "Media opacity fades the media into the base; Darken background improves readability.",
                          "Images tab → Use as background puts a web image straight into the look."], target: "deck.present"),
        // Dictionary
        HelpTopic("dictionary", "Look up a word and show its definition", category: "Dictionary",
                  keywords: ["define", "definition", "meaning", "thesaurus", "synonym", "wikipedia", "wiktionary", "word"],
                  summary: "Search first, preview the card, then send it to Preview, Program or key it.",
                  steps: ["Open the Dictionary tab and choose a dictionary (macOS, English, Wiktionary, Thesaurus, Wikipedia, My Dictionaries).",
                          "Type the word and press Search; pick a result.",
                          "Load into input, then Preview / Program / Key over Program, or add it as an overlay layer.",
                          "Format the card and background in the right-hand column.",
                          "My Dictionaries → Import… adds CSV/TSV/JSON dictionaries (e.g. a Bible dictionary)."], target: "deck.dictionary"),
        // Images
        HelpTopic("image-search", "Search the web for images", category: "Images",
                  keywords: ["picture", "photo", "image search", "openverse", "wikimedia", "web images", "background", "google images"],
                  summary: "Type a word, choose an image, and use it as an input or a slide background.",
                  steps: ["Open the Images tab, type what you need (e.g. 'sunrise over mountains') and press Search.",
                          "Choose Openverse or Wikimedia Commons; filter by shape (wide suits 16:9 screens).",
                          "Select an image, then Add as input, Preview, Program, or Use as background for slides.",
                          "Web browser mode: right-click an image on a site → Copy Image, then press Paste image.",
                          "The creator and licence are shown — credit them where the licence requires."], target: "deck.images"),
        // Audio
        HelpTopic("mixer", "Audio mixer console", category: "Audio",
                  keywords: ["audio", "sound", "fader", "volume", "gain", "trim", "pan", "mute", "solo", "headphones", "afv", "meter", "levels"],
                  summary: "Each input has a channel strip: input trim, EQ, dynamics, level meters, fader, pan and on/AFV.",
                  steps: ["Open the Audio Mixer tab (or Audio in the control panel).",
                          "Assign an audio device to an input in Input → Audio so its meters move.",
                          "Input knob = trim (drag up/down, double-click to reset); fader = channel level; value boxes accept typed numbers.",
                          "ON keeps the channel in the mix; AFV (audio follows video) only when the input is on Program or keyed; both off = silent.",
                          "Headphones = solo. The red bar above a channel means it is live in the mix.",
                          "Enable ‘Mix input faders into recording & stream’ in the gear menu so the mix is what is recorded and streamed."], target: "deck.audio"),
        HelpTopic("audio-effects", "EQ, gate and compressor", category: "Audio",
                  keywords: ["equalizer", "eq", "dynamics", "compressor", "limiter", "noise gate", "hum", "hiss", "de-ess", "voice"],
                  summary: "Clean up and even out a channel's sound.",
                  steps: ["Click a channel's Equalizer or Dynamics display to open its effects.",
                          "Turn the effects On, then pick a preset (Voice clarity, De-hum…) or turn the knobs.",
                          "Watch the curves update; double-click a knob to reset it."], target: "deck.audio"),
        HelpTopic("pan", "Pan (left/right)", category: "Audio",
                  keywords: ["stereo", "left", "right", "balance"],
                  summary: "Pan is stored per channel and recalled with presets.",
                  steps: ["Drag the Pan knob; -100 is left, +100 is right, 0 is centre.",
                          "The current recording/stream mix is mono, so pan becomes audible when the stereo mix arrives in a later build."], target: "deck.audio"),
        // Overlays & scenes
        HelpTopic("overlays", "Overlays: lower thirds, logos, tickers, clocks", category: "Overlays & scenes",
                  keywords: ["lower third", "logo", "ticker", "scoreboard", "clock", "qr", "picture in picture", "pip", "chroma key", "green screen", "layer"],
                  summary: "Layers sit on top of Program and fade in/out with channels 1–4.",
                  steps: ["Control panel → Overlays → + to add a layer or template.",
                          "Select a layer to edit text, colours, position and scale.",
                          "Toggle it on air with its switch or the 1–4 buttons in the status bar."], target: "right.overlays"),
        HelpTopic("scenes", "Layouts and scenes (multi-camera screens)", category: "Overlays & scenes",
                  keywords: ["layout", "split", "grid", "multi view", "video wall", "side by side", "scene"],
                  summary: "Show several inputs at once in a layout and save it as a scene.",
                  steps: ["Control panel → Scenes → pick a layout.", "Choose which input goes in each slot.", "Save scene to recall it later."], target: "right.scenes"),
        // Outputs & streaming
        HelpTopic("program-out", "Full-screen output to a projector or LED wall", category: "Outputs & streaming",
                  keywords: ["projector", "second screen", "display", "led", "fullscreen", "full screen", "hdmi", "program out", "external monitor"],
                  summary: "Show clean Program full-screen with no title bar.",
                  steps: ["Press PROGRAM OUT in the top bar; it opens on the second display when one is connected.",
                          "Press Esc or double-click the output to close it.",
                          "Outputs tab: turn individual displays on and choose Program or a specific input for each."], target: "right.outputs"),
        HelpTopic("stream", "Stream live to YouTube, Facebook and others", category: "Outputs & streaming",
                  keywords: ["live stream", "youtube", "facebook", "rtmp", "stream key", "simulcast", "go live", "bitrate"],
                  summary: "Send Program (with audio) to one or several platforms at once.",
                  steps: ["Press STREAM, add a destination and paste its server URL and stream key.",
                          "Enable the destinations you want, then Go Live. Every enabled destination streams at once.",
                          "Needs ffmpeg installed; the stream bitrate is separate from the recording bitrate."]),
        HelpTopic("multiview", "Multiview and safe-area guides", category: "Outputs & streaming",
                  keywords: ["multiview", "monitor all", "guides", "safe area", "title safe"],
                  summary: "Monitor every input at once, and check framing.",
                  steps: ["Status bar → Multiview opens a window with all inputs.", "Guides draws the 90% safe area on Program."]),
        // Recording
        HelpTopic("record", "Record Program to a file", category: "Recording",
                  keywords: ["record", "recording", "save video", "mp4", "mov", "codec", "hevc", "prores", "snapshot", "folder"],
                  summary: "Record what is on Program with its audio.",
                  steps: ["Press REC (key R); the timer shows the length. Press again to stop.",
                          "Gear menu: resolution, frame rate, codec, container, bitrate and recording folder.",
                          "Snapshot (key S) saves a still image of Program."]),
        // Presets
        HelpTopic("presets", "Save and recall presets", category: "Presets",
                  keywords: ["preset", "save settings", "recall", "load settings", "template", "configuration", "profile", "setup"],
                  summary: "Save the current setup — inputs, audio, overlays, scenes, looks and output settings — and recall it later.",
                  steps: ["Top bar → Presets → Save current as preset… (or the Presets tab in the control panel).",
                          "Name it and tick what to include: inputs, audio mixer, overlays & scenes, output & recording settings, transitions.",
                          "Recall a preset from the Presets menu or tab; Update overwrites it with the current setup.",
                          "Export… / Import… share presets with another Mac.",
                          "Cameras and files come back when the same devices and files are available on this Mac."], target: "right.presets"),
        // Keyboard & help
        HelpTopic("shortcuts", "Keyboard shortcuts", category: "Keyboard & help",
                  keywords: ["hotkeys", "keys", "keyboard", "shortcut", "clicker"],
                  summary: "Single-key shortcuts work whenever you are not typing in a text box.",
                  steps: ["1–9 put inputs on Preview; Return = AUTO; C = CUT; B = FTB; R = record; S = snapshot; L = stream.",
                          "Page Up / Page Down step slides (presentation clickers); ← / → on the Songs & Bible tab.",
                          "⌘K opens Find a tool; ⌘? opens Help.",
                          "Gear menu → Keyboard shortcuts… to change keys."]),
        HelpTopic("help", "Using Help and Find a tool", category: "Keyboard & help",
                  keywords: ["find tool", "search tool", "command", "where is", "how do i"],
                  summary: "Type what you want to do and jump straight to the tool.",
                  steps: ["Press ? in the top bar, ⌘K, or Help → LiveDeck Help.",
                          "Type a few words (e.g. 'blend', 'projector', 'lyrics').",
                          "Choose a result to read the steps; Show me opens the right place in the app."])
    ]
}
