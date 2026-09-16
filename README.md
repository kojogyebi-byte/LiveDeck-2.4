# LiveDeck Studio (macOS) — v4.9.7

**4.9.7 — Stream bitrate split into video and audio.** Stream settings → Quality & audio: video bitrate from **128 kb/s** up to 51 Mb/s (24 steps or any typed value), AAC stereo audio bitrate **128 / 160 / 192 / 256 / 320 kb/s**, the usual range for the current format, advice when too low/high, total per destination and the upload speed needed (all destinations + 50% headroom). Stream details show video and audio targets separately. **90 automated tests.**


**4.9.6:**
- **Frame rates:** progressive 23.976, 24, 25, 29.97, 30, 50, 59.94, 60p and **interlaced 50i, 59.94i, 60i** (top field first). Exact NTSC fractions (30000/1001…). Interlaced formats render every field (smooth on displays) and weave two fields into each recorded/streamed frame with field metadata (use ProRes MOV for flagged interlaced files). Streams go out progressive by default; optional true interlaced H.264 (`+ildct+ilme`, tff). Top bar shows e.g. 1080i59.94.
- **Display outputs** (Outputs → External Displays → Output settings, per display, remembered by display name and resolution): **custom size and position on extended displays** (pixels; halves and common sizes as presets), fit **Letterbox / Crop to fill / Squeeze / 1:1 pixels**, **crop** left/right/top/bottom (4:3 centre, remove black bars), **upscale/downscale** to a fixed output resolution with Smooth / Sharp / Pixel-exact quality (shows the exact scale factor), letterbox colour and red alignment edges.
- **88 automated tests.**


**4.9.5:**
- **Menus stay open.** The status-bar numbers (record time, stream stats, audio clip/signal, disk space) moved from `Engine` to `Telemetry`, the automation countdown no longer publishes 4×/s, network station status has its own store, and the main window no longer subscribes to the network/automation models. Nothing refreshes the whole window every second any more (menus were being closed by those refreshes; this also frees CPU for rendering).
- **Keeps running when the Mac is idle.** While streaming, recording or showing Program Out / display outputs, LiveDeck holds a latency-critical power activity: no idle sleep, no display sleep or screen saver, no App Nap throttling (gear menu → Keep Mac awake: while live · always · never). Status bar shows POWER · Staying awake.
- **Stream auto-reconnect.** If ffmpeg exits (internet drop, platform hiccup, after waking) the stream retries every 5 s, then 15 s, until back or stopped; status bar shows RECONNECTING. After wake the audio engine restarts. Toggle in the gear menu or stream details.


**4.9.4 (build fix):** `StreamHealth` now has a public initializer so the app target can create it.

**4.9.3 — On-air status bar** above the monitors: time and date, stage countdown, BLACK (fade to black), keys (Program/Preview), overlays on air, automation, network link, Program Out state, format and live fps, audio (stereo mini-meter, level, CLIP, MUTED, SILENT while live), REC (time, file size, hours of disk left) and **LIVE stream strength** (time on air, five signal bars, bitrate, speed, dropped frames, destinations; click for full stream details and errors). Stream statistics come from ffmpeg `-progress`; health is judged from speed, send backlog and recent dropped frames. Right-click to hide; gear menu to show again. Also fixes the wrapped “DURATION” label. **84 automated tests.**


**4.9.2:** the bundled Bibles were removed from the repository (63 MB was too large for GitHub). Install them from the separate **LiveDeck-English-Bibles.zip** with Songs & Bible → Bible → Import file… (choose the zip), or drop the zip on the Bible area. If a `Resources/Bibles` folder of `.ldbible` files is ever added back, the app still installs them automatically on first launch.

**4.9.1 — English Bibles:**
- Nine English Bibles, added to the Bible library by importing the pack: **KJV** (Authorized King James Version), **KJV+** (KJV with Strong's — numbers removed for display), **ASV**, **ASVs** (ASV with Strong's), **WEB** (World English Bible), **NET** (NET Bible®), **Geneva** (1587), **Coverdale** (1535) and **Tyndale** (1534; Pentateuch, Jonah and New Testament). Text is cleaned for the screen (Strong's codes, red-letter marks, pilcrows and supplied-word brackets removed) and fully searchable.
- New importer for **Bible SuperSearch JSON** (`{"metadata":…,"verses":[…]}`), plus batch import: choose many files, a folder, or a **.zip** — or drop them on the Bible area. Already-installed versions are skipped; `.ldbible` files install directly.
- Workflow copies `Resources/Bibles` into the app bundle. **80 automated tests.**
- Licence note: the NET Bible text is free for non-commercial use with acknowledgement of Biblical Studies Press; the others are public domain.


**New in 4.9:**
- **Bible search assistant** — one box for references and words. Books and references complete as you type (“1 jo”, “ii cor”, “ps 23”), famous passages appear for a book or theme (love, healing, fear…), and words show matching verses best-first with highlights, phrase completion (“the lord is my” → “the lord is my shepherd”), book filter chips, ↑↓/Return/Tab/Esc, exact phrases in quotes, and right-click to open with the next verses or the whole chapter.
- **Rename any input** — double-click its name on the tile, right-click → Rename…, or from the Songs & Bible / Dictionary / AI target menus.
- **Pre-service check** (CHECK button, ⇧⌘P) — inputs, disconnected cameras, missing media and playlist files, slide backgrounds, empty Program, audio engine, muted master, camera/mic permissions, signal on the meter, disk space and hours left, recording folder, ffmpeg and stream keys, frame rate, Program Out, fade to black, automation and network — with Fix buttons.
- **Stage display** (Outputs → Stage display) — confidence monitor for the pulpit and band: clock, current and next slide, REC/LIVE time, countdown timer (orange/red), operator messages (flash), what is on Program. Full screen on a second display or a window.
- **Chapter markers** — press M (or MARK in the status bar) while recording; optional marker at every cut; saved as `<recording>.chapters.txt` in YouTube chapter format.
- **Auto-save & recovery** — the whole setup is saved every minute; after a crash or power cut a banner offers Restore session.
- **Fixes:** transition Duration now fits its column (value box + slider, right-click presets); the Audio panel no longer stretches or shows empty labels in a narrow panel and has a helpful empty state with Add Input.
- New shortcuts: M marker, ⇧⌘P pre-service check, ⇧Esc clear stage message. `PresentationKit` adds `BibleAssist.swift` and `BibleStore.liveSearch`; **78 automated tests**.

---

# Previous — v4.8.1

**4.8.1 (build fix):** `UI.swift` now imports `PresentationKit` (needed for the new keyboard-shortcut dispatcher: `KeyCombo`, `ShortcutCatalog`).

**New in 4.8:**
- **Playlist input** — one holder that plays videos, audio and images in order (Add Input → Playlist). Drop files/folders, Add files…, From library, or right-click a Media item → Add to playlist. Auto-advance, loop, shuffle, per-image duration, start when taken to Program, reorder, disable, play now / cue; tile transport ◀ ▶ ▶▶ with item number; audio routed through the mixer; save/open named playlists (`Library/playlists.json`); saved in presets.
- **Backgrounds from inside the app** — Format → Background → **Library…** picks downloaded, generated (Generator loops), imported or shared media, or the file of an existing video/image input. **File…** still chooses any file.
- **Switcher buttons under the monitors** — hardware-style PROGRAM (cut) and PREVIEW rows plus CUT/AUTO, shown whenever the Inputs tab is hidden (right-click: always / hide).
- **Tile controls never disappear** — narrow tiles drop keys/transport into a ⋯ menu but always keep the edit button; the edit button now opens the right editor for every input type.
- **Assignable keyboard shortcuts** — 90 actions (switching, inputs 1–9 to Preview/Program, keys over Preview/Program, slides, overlays, output, audio, playlist, tabs, control-panel tabs, presets…). Record any key combination, conflict and macOS-shortcut warnings, **Smart setup** (fill empty actions, reset to recommended, clear). Recommended set is created automatically; old shortcuts are kept.
- **Zoom** — Add Input → **Zoom Meeting / App Window…**: join with an invite link or meeting ID (opens the Zoom app), then add the meeting window as an input with **meeting audio** (ScreenCaptureKit; kept out of the speakers to avoid echo; follows Zoom when it replaces its window). Alternative for hosts: receive Zoom's **Custom Live Streaming** over RTMP (ffmpeg listener with video + audio). Guide for sharing LiveDeck's Program Out window into Zoom. Works with any app window (Teams, browser meetings…).
- `PresentationKit` adds `Shortcuts.swift`, `Playlists.swift` (with Zoom link parsing); **73 automated tests**.

---

# Previous — v4.7.0

**New in 4.7 — LiveDeck Link (several computers on one network):**
- **Automatic discovery:** every Mac running LiveDeck with *Share on this network* turned on appears in the new **Network** tab (Bonjour `_livedeck._tcp`, TCP). Name each station (Front of house, Stage, Media desk…). An optional shared **passcode** keeps other people out — it is checked with a challenge/response, never sent over the network.
- **Live status of other stations:** what is on their Program and Preview, keys, REC time and LIVE, plus the words currently on screen.
- **Messages:** chat to everyone or one station, quick cues (Standby, Ready, Go, Next slide, Camera 1/2, Wrap up…) and **Attention** (amber flash + beep). Messages pop up at the top right; the top-bar **LINK** button shows connected stations and unread messages.
- **Share media:** right-click a Library item, a file/image input, a song or a preset → **Send to computer** (optionally *and add as input*). Or **Browse their media** and **Get** files from another station. Transfers show progress, can be cancelled, and the receiver accepts them (or turns on *Accept files without asking*). Files go to Library → Shared, songs to Songs & Bible, presets to Presets.
- **Illuminated switcher keys:** PVW / PGM / K·P / K·L on input tiles now look like a hardware panel — square keys that glow green, red or amber when lit.
- `PresentationKit` adds `LinkProtocol.swift` (message envelope, binary framing, pure-Swift SHA-256, passcode proof); **67 automated tests**. Info.plist adds `NSLocalNetworkUsageDescription` and `NSBonjourServices`.

---

# Previous — v4.6.0

**New in 4.6:**
- **AI Search tab** — ask **Claude, ChatGPT, Gemini, Grok, DeepSeek, Mistral, Perplexity (web search), Groq, Ollama (local, no key) or any OpenAI-compatible server**. Choose how it writes (Answer, Bible study, Sermon points, Explain simply, Summary, Prayer points, Announcement, Quotes, Translate) plus your own extra rules. Answers are cleaned of Markdown, can be edited, are saved for reuse, and become slides on an **AI Search input** with the same Format editor as songs, scripture and the dictionary (max characters per slide, question as title, AI credit line). Operator bar and right-click: show, Preview, Program, Key PVW, Key PGM, clear. API keys are stored in the macOS Keychain; model ids are editable (defaults: claude-sonnet-5, gpt-5.5, gemini-3.8-flash).
- **Resizable control panel** — PANEL buttons above the Input/Audio/Overlays/Scenes/Outputs/Presets tabs: Narrow, Half the window, Wide (panel fills most of the window) or Free (drag the divider to any width). Right-click the panel for the same choices; the size is remembered.
- **Video search in Media → Web search** — Images | Videos. Videos come from NASA (public domain, no key), Pixabay or Pexels (free keys, shared with the Library). Add as input, Preview, Program, use as a Songs & Bible / Dictionary background, or save to the library.
- **Your own images and videos** — drag files or folders from Finder onto the Media tab, or press **Add from computer…**; they are copied into **Library → My files** and can be used as inputs or slide backgrounds.
- `PresentationKit` adds `AIAssist.swift` (providers, request building for Anthropic / OpenAI-compatible / Gemini wire formats, response parsing, Markdown clean-up, slide splitting, history); **61 automated tests**.

---

# Previous — v4.5.0

**New in 4.5:**
- **Right-click menus everywhere:** Preview and Program monitors (CUT/AUTO, transition, choose inputs, keys, overlays, scenes, meter, guides, Program Out, record), input tiles (keys, mute/solo, audio), slides and dictionary cards (show, Preview, Program, key on Preview/Program, clear, hide background), mixer channels and Master (mute, solo, ON/AFV, effects, presets, reset), top-bar PROGRAM OUT / STREAM / REC, transition column, overlay buttons 1–4, Snapshot/Outputs, overlay layers (including "Automate this overlay"), scenes, layouts, presets, stream destinations, generator presets.
- **KEY on Preview and on Program for every input:** K·P keys an input over the Preview monitor only (it joins Program on the next CUT/AUTO); K·L keys it over Program live. Preview shows the result after the take (Program keys + Preview keys). Songs & Bible and Dictionary gain Key PVW / Key PGM. Monitor headers show a KEY count.
- **Program Out no longer traps a single screen:** with one display it opens in a normal 16:9 window; with a second display it opens full screen there. F, double-click or ⌘⇧F (new Output menu) switches window ↔ full screen; Esc in full screen returns to the window, Esc in a window closes it; right-click PROGRAM OUT to pick a display. Display outputs on your own screen also open in a window first.
- **Audio meter on the Program monitor** (left/right, dB scale) — drawn by the interface only, never on Program Out, recording or stream; toggle from the monitor header or its right-click menu.
- **Compact console-style control panels:** shared controls redesigned (one-line sliders with value box and reset, small switches, compact pickers and colour rows, card headers with summaries). Songs & Bible / Dictionary Format is now collapsible cards (Looks, Background, Layout, Main text, Title, Reference, Text box, Content); Overlays + layer inspector, Scenes, Program Out, Stream settings, Generator and Automation editor use the same cards.

---

# Previous — v4.4.1

**4.4.1 (build fix):** matches the macOS 14.5 SDK (Xcode 15.4) — `MTAudioProcessingTapCreate` takes an `Unmanaged<MTAudioProcessingTap>` out-pointer, and the `AVAudioSourceNode` render block has four parameters. Also silences the unused-result warnings.

**New in 4.4:**
- **Real program audio engine.** Video files, audio files and microphones now all go through one mixer (AVAudioEngine). File audio is taken out of AVPlayer with an MTAudioProcessingTap, so **mute, faders, trim, ON/AFV, pan, solo, effects and the Master fader/mute really change what you hear, record and stream**. Meters read the real samples (left and right). Recording and stream audio are now the stereo Program mix (AAC 192 k). The old "Mix input faders into recording & stream" switch is gone — the console mix is always what goes out.
- **Monitoring:** MONITOR knob on the Master strip; microphones stay out of the Mac's speakers unless "hear mics" is on (no feedback), but are always recorded/streamed; headphones button = solo to the speakers only.
- **Input tab audio redesigned in the console style:** fader with L/R meters and dB readout, INPUT and PAN knobs, AFV/ON, MUTE, solo; **Audio Effects** card with EQ and dynamics graphs and knob grids (same look as the Audio Mixer).
- **Media tab** (was Images) with three sections:
  - *Web images* — as before.
  - *Backgrounds library* — free videos and images from **NASA (public domain, no key)**, **Pixabay** and **Pexels** (free API keys); download into your library, favourites, import your own; use as input/Preview/Program or as the Songs & Bible / Dictionary background. **First launch offers a starter pack** (NASA space & sky media + generated backgrounds).
  - *Generator* — **abstract backgrounds** (gradient flow, aurora, bokeh, light rays, starfield, waves, pulse rings, neon grid) and **transparent effects** to key over Program (rising particles, snow, confetti, sparkles, light leak, vignette); 14 presets, 3 colours, speed/amount/size/softness, shuffle; add as a live input, save a still or export a **seamless loop video**.
- **Automation tab:** cues that Show / Hide / Toggle overlays (lower thirds, logos) and keyed inputs, or Cut/Preview inputs — at a time of day, after a delay, repeating, when an input goes on Program, or when recording/streaming starts; hold time, undo when the condition ends, run limits, countdowns, Run now, activity log. Saved to `Library/automation.json`.
- **Several Bible versions on one screen:** Versions menu (up to 4 translations), side by side or stacked, version names, shared text size, same verses on every version (the longest version decides where slides split).
- Presets now save generator inputs. Help has new topics (automation, backgrounds, generator, parallel versions, monitoring).
- `PresentationKit` gains `Automation.swift`, `Backgrounds.swift`, `ParallelScripture.swift`; **53 automated tests**.
- Known limits: online stream inputs (HLS .m3u8) and web pages still play their sound directly (not through the mixer); file audio reaches the speakers ~30–60 ms later than before because it now passes through the mixer.

---

# Previous — v4.3.0

**New in 4.3:**
- **Help & Find a tool.** Press **⌘K**, the *Find a tool* box in the top bar, or **?** (also Help menu → LiveDeck Help, ⌘?). Type what you want to do — *blend*, *projector*, *lyrics*, *stream*, *preset* — and results appear instantly. Each topic has step-by-step instructions, related topics and a **Show me** button that opens the right tab. The guide covers every part of the app in 12 categories, from *Run your first service* to keyboard shortcuts.
- **Blend modes for slide backgrounds.** Images and looping videos behind songs, scripture and dictionary cards now blend onto a base colour or gradient: Normal, Multiply, Screen, Overlay, Soft/Hard Light, Darken, Lighten, Colour Dodge/Burn, Difference, Exclusion, Hue, Saturation, Colour, Luminosity — plus media opacity. (Format → Background → Blending.)
- **Images tab — web image search.** Type a word and pick from free, openly-licensed images (**Openverse** and **Wikimedia Commons**, filter by shape). Add the image as an input, send it straight to Preview or Program, or use it as the background for Songs & Bible or Dictionary. Creator and licence are shown. A **Web browser** mode (DuckDuckGo / Google / Bing Images) lets you right-click → Copy Image and paste it as an input or background.
- **Console-style audio mixer** (new **Audio Mixer** tab, also in the control panel's Audio tab), modelled on the supplied reference: per-input channel strips with tally bar, **Input trim knob** (-∞…+6 dB), **Equalizer** and **Dynamics** mini displays, peak dB readout, console **fader** (-∞…+10 dB) with scale and L/R meters, **Pan knob**, **AFV / ON** buttons (audio follows video), and headphones **solo**; Master strip with fader, meters, mute, clear solo and "mix to rec/stream". Every knob and fader value box accepts typed numbers; double-click resets.
- **Redesigned audio effects window.** Click a channel's EQ or Dynamics display: a large EQ response graph with knob bands (Low Cut, Low Shelf, Band 1, Band 2, High Shelf, High Cut) and a Dynamics page with Noise Gate and Compressor/Limiter transfer graphs and knobs; presets and an Effects on/off switch.
- **Presets.** Save the current setup and recall it later — choose what to include: inputs (cameras, files, streams, web pages, colours, Songs/Bible/Dictionary inputs with their looks), audio mixer & effects, overlays/layouts/scenes, output format & recording settings, transitions. Recall from the **Presets** menu in the top bar or the **Presets** tab; update, rename, delete, export and import `.ldpreset` files.
- Audio engine: trim and AFV now affect the recorded/streamed mix, the Master fader and mute work, faders go to +10 dB. **Pan is stored and recalled but not yet audible** — the recording/stream mix is still mono (stereo mix is planned).
- `PresentationKit` gains `ImageSearch.swift`, `HelpIndex.swift`, `AudioMath.swift` and blend settings in looks; **42 automated tests** (was 36).

---

# LiveDeck Studio (macOS) — v4.2.0

**New in 4.2:**
- **Redesigned control panel** (right side), following the supplied mockup: large icon tabs (Input · Audio · Overlays · Scenes · Outputs); an **Input Channel** card to pick which input you are adjusting, with Reset; collapsible cards with icons and descriptions for **Geometry**, **Crop**, **Colour** and **Audio**; blue faders with **typed numeric values** and a **reset button on every control and every card**; audio device picker with refresh, gain with a 24-segment level meter, mute switch, and an expandable **Audio Effects (EQ · Compressor · Gate)** card. Songs/Bible/Dictionary inputs show a **Display** card (key over Program, hide text/background, open formatting). The **Outputs** tab and all effect/overlay sliders use the same style.
- **Right-click to add inputs.** Right-click any empty part of the input area for the full Add Input menu. Right-click an empty holder to assign an input to that slot; right-click a live input for Take, Preview, Key, Reload page, Edit address, Remove.
- **Find lyrics online** (Songs & Bible → *Find online*):
  - **Lyrics databases searched inside the app:** **LRCLIB** (free, open lyrics database — title, artist or any words) and **Lyrics.ovh** (free — artist + title). Pick a result, **edit the words** (add *Verse 1*, *Chorus*… lines), **Save to Song Library**; the song opens ready to use and stays in the library for future services.
  - **Web sites in a built-in browser:** Hymnary.org (full texts of public-domain hymns), Hymnal.net, Genius, Musixmatch, AZLyrics, CCLI SongSelect and general web search. Select the words on the page and press **Use selection** (or copy and **Paste**), edit, save.
  - Reminder shown in the app: public-domain hymns are free to project; copyrighted songs need a church licence such as CCLI or OneLicense.
- **Web page inputs now show the page** instead of a white tile. The page renders in an invisible helper window (macOS does not draw web views that are off-screen). Addresses without *https://* are accepted, a loading/error card shows until the page appears, *http* pages load, and **Edit address** on a web input no longer turns it into a video stream.
- `PresentationKit` gains `LyricsSearch.swift`; **36 automated tests** (was 32).

---

# LiveDeck Studio (macOS) — v4.1.0

**New in 4.1 — Songs, Bible and Dictionary on the production page:**
- **One page.** The separate PRESENT screen is gone. Under Preview / Program there are three tabs: **Inputs**, **Songs & Bible** and **Dictionary** — the switcher, monitors and audio stay in view while you run lyrics and scripture.
- **Songs & Bible as an input.** Add Input (or a blank holder's **+**) → **Songs & Bible (Presentation)**. Click a song or scripture slide and it appears on that input; send it to **Preview**, **Program**, or **Key over Program** (text over your cameras, 0.3 s fade). Next/previous with ← / → or a presentation clicker (Page Up / Page Down). **Clear text** and **Hide BG** buttons. You can have several presentation inputs (e.g. full-screen scripture and lower-third lyrics).
- **Backgrounds.** Transparent (for keying), solid colour, gradient, **image** or **looping video** (muted), with fill/fit/stretch and a *Darken background* control for readability.
- **Comprehensive formatting ("looks").** Font, size, bold/italic/underline, colour, alignment, UPPERCASE/Title case, line and letter spacing, outline, shadow — separately for the main text, the title/headword and the reference/credit line. Text area (full screen, lower third, upper third, centre band, left/right half, custom position), margins, vertical alignment, shrink-to-fit, text box or full-width band (colour, opacity, padding, corners), verse numbers, characters per scripture slide, lines per song slide, fade between slides. Five built-in looks; **Save look…** keeps your own.
- **Dictionary with its own input.** Search a word first, preview the card, then **Load into input**, **Preview**, **Program**, **Key over Program**, or add it as an overlay layer. Background and formatting are chosen the same way as for songs.
- **Choice of dictionaries:** macOS Dictionary (offline), English Dictionary (Free Dictionary API), Wiktionary (many languages — choose the language code), Thesaurus (synonyms & antonyms), Wikipedia (people, places, topics — any language), and **My Dictionaries** — import your own CSV/TSV/JSON dictionaries such as a Bible dictionary or glossary.
- **Professional control redesign.** New graphite broadcast look: tally colours used only for meaning (red = on air, green = preview, amber = keyed/armed, blue = selection); compact sliders (drag anywhere, double-click to reset); CUT / AUTO, transition grid and a vertical **T-bar**; tabbed right panel with icons; restyled input tiles with PVW / PGM / KEY buttons; cleaner top and status bars.
- **8 empty inputs** by default (was 5).
- **No title bar in full screen.** The main window hides the macOS title bar and window buttons in full screen. **PROGRAM OUT** opens a borderless full-screen Program on the second display (or covers the main display, hiding the menu bar and Dock); Esc or double-click closes it.
- **Outputs are no longer a pop-up** — they are the **Outputs** tab of the right panel (the status-bar *Outputs* button opens it).
- **Safer hotkeys.** Single-key shortcuts (C cut, R record, S snapshot, L stream…) are ignored while you type in any text field.
- Under the hood: `PresentationKit` gains `Look.swift` and `WordLookup.swift`; **32 automated tests** (was 24). Looks are saved in `Library/looks.json`, imported dictionaries in `Library/Dictionaries/`.
- **Not yet:** presentation/dictionary inputs are not stored in `.livedeck` show files (no inputs are); service plans, slide editor, media audio in the mix (next builds).

---

# LiveDeck Studio (macOS) — v4.0.0 (build 4.0-a)

**New in 4.0 — PRESENT workspace, part 1 (songs & Bibles):**
- **Workspace switch** in the top bar: **PRODUCTION** (switcher, audio, outputs) and **PRESENT** (presentation library). Production keyboard shortcuts pause while in PRESENT, so typing lyrics can't trigger a cut.
- **Song library.** Create songs by typing or pasting lyrics (put *Verse 1*, *Chorus*, *Bridge*… on their own lines; a blank line starts a new slide). Title, author, copyright, CCLI #, folder, tags, favourites, recent, search across titles/authors/lyrics. Song order (e.g. `V1 C V2 C B C`) and lines-per-slide, with a live slide preview. Autosaves as you type; **version history** (clock icon) and a **Trash** you can restore from.
- **Import songs** from plain text, **CCLI SongSelect** exports (.txt and .usr), **ChordPro**, **OpenLyrics** and **OpenSong** — many files at once. Choruses typed out twice are merged into the song order automatically.
- **Unlimited Bible versions.** **Get Bibles…** lists 1000+ free translations in many languages (Free Use Bible API — no account, no usage restrictions); search by name or language and install with one click. Each Bible is stored on this Mac and works offline. **Import file…** adds any translation you are licensed to use from Zefania XML, OSIS XML, USFM, CSV/TSV or Free Use Bible JSON.
- **Scripture lookup.** Type references naturally — *John 3:16-18*, *1 Cor 13*, *Ps 23*, *Gen 1:1–2:3* — or search words; passages are split into readable slides automatically (adjustable length).
- **Input tiles are always 16:9**, including blank holders, at every window size.
- Under the hood: new `PresentationKit` module with 24 automated tests that run on every GitHub build (`swift test`).
- **Not yet:** sending songs/scripture live (next build, 4.0-b), themes, slide editor, service plans.

---

# LiveDeck Studio (macOS) — v3.18

**Changes in 3.18:**
- **Media no longer auto-plays when added.** Video and audio files dropped or assigned into an input (including blank holders) load **paused on their first frame** — press play on the tile when you're ready. Live network streams (HLS/URL) still start immediately.
- **Blank holders look like a switched-off TV.** Empty input slots are now solid black across the whole tile (same size as a live input) with a discreet **+** to assign an input.
- **Input tiles fill the input area.** When all inputs fit, tile screens stretch vertically so the whole region is used; pictures are letterboxed on black instead of cropped. If there are too many inputs to fit, tiles stay 16:9 and the area scrolls.
- **Presentation engine — Phase 1 architecture** added at `docs/PRESENTATION-ARCHITECTURE.md` (proposal, awaiting approval; no presentation code yet).

---

# LiveDeck Studio (macOS) — v3.17

**New in 3.17 — real audio on the live stream + simulcast:**
- **Program audio goes to the stream.** STREAM → **Send program audio** (on by default). The stream now carries the same audio as the recording: the master audio device (with master FX), or — with gear → **Mix input faders into recording & stream** — the per-input mix (faders, MAIN send, mute, solo, per-input FX). Switch it off to fall back to the old silent track.
- **Built to keep A/V in step** (untested on a live platform yet). Video and audio are each written to ffmpeg by their own wall-clock-paced thread, so the stream's timeline follows real time even if the app stutters (the last frame is repeated; silence fills gaps if the audio device stalls).
- **Simulcast.** **Go Live** sends to *every enabled destination at once* (e.g. YouTube + Facebook). If one destination fails, the others keep going.
- **Separate stream bitrate** (2.5–12 Mbps, default 4.5) — no longer tied to the recording bitrate (which could push 20–40 Mbps at a platform).
- **Stream errors are shown.** If ffmpeg stops (wrong key, network drop, server refused) LiveDeck now shows ffmpeg's actual error and resets the Stream button instead of silently staying "live".
- **Fixes:** resolution & frame-rate choices now actually persist across launches (they were being overwritten during settings load); resolution/frame rate are locked while streaming (changing them mid-stream corrupted the feed); guards against LiveDeck being killed if ffmpeg exits mid-write.
- **Still not in the mix:** audio from video/audio-file inputs (plays to speakers only). Workaround: route system audio back in with a loopback device (e.g. BlackHole) as the master device.

---

# LiveDeck Studio (macOS) — v3.16

**New in 3.16 — church-media toolkit:**
- **Web page input.** Add Input → **Web Page…** displays any website as an input (online lyrics, Bible sites, countdowns, dashboards, web graphics). Renders at 1280×720 and refreshes continuously via WKWebView.
- **Per-display source out.** Outputs panel: each external display (HDMI / video card / projector / LED wall) can now send **Program or any individual input** — pick it from the per-display dropdown. Multiple displays run at once, each with its own source.
- **Dictionary → video wall.** Overlays tab has a **Dictionary** search: type a word, get its definition (offline, from macOS Dictionary Services), and **Show on Program / Video Wall** as a clean readable panel overlay. Editable like any overlay.
- NDI output still awaits the SDK headers (detector present; sender stubbed).

---

# LiveDeck Studio (macOS) — v3.15

**Fixes & audio in 3.15:**
- **Colour bars & solid-colour inputs now show in their tiles.** Draw-only sources (test pattern, colour) had no still image, so their thumbnails were black even though they rendered fine in Preview/Program — the tile now renders them directly.
- **Master = the mix of input audios.** The MASTER meter now reflects the summed level of the inputs feeding the main mix (falls back to the master device if none do).
- **Per-input “send to main mix”.** Each channel strip has a new **MAIN** button (green = sending). Turn it off to drop that input from the master mix and the recorded/streamed mix.
- **YouTube / Twitch / Facebook links now play** — when **yt-dlp** and **ffmpeg** are installed. LiveDeck extracts the real stream with yt-dlp and decodes it with ffmpeg. The dialog shows whether both tools are present (install once: `brew install yt-dlp ffmpeg`). Best for live streams.

---

# LiveDeck Studio (macOS) — v3.14

**New in 3.14:**
- **Bigger input controls + loop.** The play/pause, restart and PGM/mute buttons under each input are now ~2× larger, and there's a **loop** toggle on video/audio inputs (lights green when on).
- **Editable network streams.** Stream inputs now have a **pencil edit** button — change the URL or (for HLS) cap the **max ABR bitrate** without removing and re-adding the input.
- **Separate stream input types.** Add Input now lists three distinct network types:
  - **Network Stream (HLS / URL)** — plays natively via AVFoundation, with an optional max-bitrate cap.
  - **RTMP / RTSP / SRT (ffmpeg)** — pulls and decodes the stream via your installed ffmpeg and shows it as an input (best-effort; requires ffmpeg).
  - **YouTube / Twitch / Facebook link** — a clearly-labelled type that explains these page links can't play directly and guides you to paste a real source URL or restream.

---

# LiveDeck Studio (macOS) — v3.13

**New in 3.13:**
- **Playback buttons on each input tile.** Video and audio-file inputs now have **play/pause** and **restart** buttons right on the tile — no need to open the Input tab.
- **Audio meter on each input tile.** A slim level meter sits under every input thumbnail (moves once an audio device is assigned to that input).
- **Customisable keyboard shortcuts.** Gear menu → **Keyboard shortcuts…** lets you assign keys to Take, Cut, Fade-to-black, Record, Snapshot and Stream. Number keys 1–9 always stage that input to Preview. Choices are saved between launches.

---

# LiveDeck Studio (macOS) — v3.12

**New in 3.12 — RTMP / SRT streaming (video) via ffmpeg.** LiveDeck can now push the Program to YouTube / Facebook / Twitch / custom RTMP·RTMPS·SRT.
- **Uses an ffmpeg you install** (`brew install ffmpeg`) — detected at runtime; not bundled (avoids GPL redistribution + signing an external binary). The Stream Settings panel shows whether ffmpeg was found.
- **Go Live / Stop** from Stream Settings, or toggle the **Stream** button in the status bar (green when live). Streams the first destination.
- H.264 (libx264, veryfast, zerolatency), FLV for RTMP/RTMPS and MPEG-TS for SRT chosen automatically; bitrate follows the recording bitrate setting.

**Honest scope (staged on purpose):** this streams **video** with a **silent AAC track** so platforms accept the feed. **Real program audio is the next increment** — I'm shipping video first so you can confirm the connection end-to-end before I wire the audio bus into the encoder. Frames are dropped rather than stalling the app if the network can't keep up. NDI output still awaits the SDK headers.

---

# LiveDeck Studio (macOS) — v3.11

**New in 3.11:**
- **More frame rates:** 24p, 25p (PAL), 30p, 50p, 60p in the gear-menu Frame rate list.
- **More video formats:** Resolution now offers 720p, 1080p (Full HD), 1440p (2K), 2160p (4K UHD) and 4K DCI (4096×2160).
- **More text templates & flexible titles:** New overlay templates — Title + subtitle, Announcement box, Quote, Credits, Now speaking — plus the Title overlay now supports a **subtitle line**, an **optional background box** (colour + opacity), separate title/subtitle colours, size, and left/centre/right alignment.

**Note on interlaced (25i/50i):** LiveDeck's compositor renders **progressive** frames, so the frame-rate options are the progressive equivalents (25p, 50p). True interlaced field output would require an interlacing encoder stage, which isn't part of the current pipeline.

---

# LiveDeck Studio (macOS) — v3.10

**New in 3.10 — CPU / RAM / GPU meters in the top bar.** Live system load, sampled ~every 1.5s:
- **CPU** — system busy % (mach `host_statistics`, HOST_CPU_LOAD_INFO, sample-to-sample delta).
- **RAM** — system memory used % (mach `host_statistics64`, HOST_VM_INFO64: active + wired + compressed).
- **GPU** — utilisation % via the IORegistry accelerator stats (best-effort). It only appears when the running Mac exposes it; on Macs where it isn't published, the GPU readout is simply omitted.

Each shows a value that turns orange >65% and red >85%, with a mini bar. The readouts live in an isolated leaf view so they don't re-render the top bar (keeping the gear menu open).

---

# LiveDeck Studio (macOS) — v3.9

**New in 3.9:**
- **Up to 10 slots per scene.** New **Grid** layout in the Scenes tab with a **Cells** stepper (2–10); the compositor arranges that many sources in an even grid. (Single / Side-by-side / Top-bottom / PiP / Quad still available.) Saved with the show file.
- **Responsive input grid.** The input tiles now reflow into a grid that **rearranges automatically when the window is resized or moved**, and sizes itself to fill the region so there's no wide blank space below.
- **Empty input tiles are now black** (not grey) to match the monitors.

---

# LiveDeck Studio (macOS) — v3.8.1

**Build fix.** Renamed the internal scene type (it was called `Scene`, which clashed with SwiftUI's own `Scene` protocol and broke the app entry point). No feature change from v3.8.

**Layout.** The input region now automatically fills the space beneath the Preview/Program monitors, and the input tiles scale up to fill that region so they're large instead of a thin strip over a black void. Monitors keep their 16:9 size; the SIZE slider still fine-tunes tile size.

---

# LiveDeck Studio (macOS) — v3.8

**New in 3.8 — scene layouts (multi-source composition).** New **Scenes** tab in the right panel. Compose the Program from more than one input:
- **Layouts:** Single, Side-by-side (two-camera split), Top / bottom, Picture-in-picture, and Quad (4-up). Pick one from the layout thumbnails.
- **Slots:** assign a source to each region of the chosen layout.
- **Scenes:** save the current layout + slot assignments as a named scene and recall it with one click (recall cuts the Program to that composition). Choose **Single** to return to the normal Preview/Program switcher.
- Layouts and scenes are saved with the show file (`.livedeck`) — best-effort by input position when reopened.

---

# LiveDeck Studio (macOS) — v3.7.1

**Layout fix.** Restored the proper **16:9 aspect ratio** for the Preview and Program monitors (v3.7 let them fill into a tall box, which looked wrong). The monitors are now top-aligned, and the **input region is larger by default and drag-adjustable** (drag the divider between the monitors and the input bus) so it fills the leftover space instead of leaving a black void. Input tiles are also bigger by default; the SIZE slider still fine-tunes them.

---

# LiveDeck Studio (macOS) — v3.7

**New in 3.7:**
- **Master-bus FX.** The **MASTER** strip in the audio mixer now has an **FX** button opening the same professional EQ / gate / compressor-limiter panel, applied to the whole summed mix. Great for a master limiter, a global de-hum, or overall tone. It processes the recorded audio when its Effects toggle is on — and works even without per-input mixing (enabling master FX routes the master device through the processing bus automatically).
- **Tighter monitor layout.** The Preview and Program monitors now fill the available space instead of floating inside a large empty letterbox area. Video stays aspect-correct inside each monitor; the boxes just no longer leave big unused margins around them.

---

# LiveDeck Studio (macOS) — v3.6

**New in 3.6 — professional per-input audio effects (EQ · Gate · Compressor) that actually process the recording.** Open an input's **FX** panel (Audio mixer, or Input tab). It now has:
- **Parametric EQ** with a live response curve: high-pass, low shelf, two sweepable peaking bands (freq/gain/Q), high shelf, low-pass.
- **Noise gate** with threshold, range, attack, hold, release and a transfer graph.
- **Compressor / limiter** with threshold, ratio, attack, release, make-up and a transfer curve.
- **Presets:** Flat/Reset, De-hum (50/60 Hz), De-rumble, Cut hiss, De-ess, Voice clarity, Warmth, Brightness, Compressor, Limiter, Noise gate.

The DSP (biquad EQ + envelope gate + compressor) runs on each input inside the recording mixer, so with **“Mix input faders into recording”** enabled and **Effects** on for an input, the processing is applied to the recorded audio. Off by default per input.

**Honest scope:** effects are applied to the recorded mix, not a separate live monitor bus; and processing is per-input mono. EQ/dynamics math uses standard biquad + envelope designs — verify a take off-air before relying on it live.

---

# LiveDeck Studio (macOS) — v3.5.1

**Build fix.** Corrected an audio-settings constant name (`AVLinearPCMIsBigEndianKey`) that broke the v3.5 compile, and removed an unused variable warning. Same features as v3.5 (input audio summed into the recording).

---

# LiveDeck Studio (macOS) — v3.5

**New in 3.5 — input audio summed into the recording.** Enable **gear menu → “Mix input faders into recording.”** With it on, every input that has an audio device assigned (Input tab) is summed into the recorded audio track with its **fader, mute and solo** applied, instead of recording only the single master device. Off by default, so the proven single-device path stays the default and you can switch back instantly mid-show.

How it works (kept deliberately robust): each input device is captured in a uniform 48 kHz float format; the first input provides the clock and the others are summed into its buffer in place, so there's no hand-rolled timestamp generation that could desync or produce a silent take.

**Caveats:** this sums **faders / mute / solo** — the per-input EQ/compressor/gate parameters are not yet applied to the mixed audio (that's per-input DSP, a later step). Inputs come from separate hardware devices with independent clocks, so over a long recording non-reference inputs can drift slightly; for true sample-locked multi-device capture, a Core Audio aggregate device is the eventual path.

---

# LiveDeck Studio (macOS) — v3.4

**Fixed — menus and dropdowns now stay open.** Previously the gear menu, the overlay Position/Corner pickers and other dropdowns would snap shut before you could click an item. Cause: the clock, FPS and audio meters were published on the main engine object that the top bar and inspectors observe, so every meter/clock tick invalidated the view hosting the open menu and dismissed it. All fast-changing telemetry now lives in a separate object watched only by the small meter/clock/FPS widgets, so opening a menu no longer triggers a re-render of its host. Menus and pickers stay open.

---

# LiveDeck Studio (macOS) — v3.3

**New in 3.3 — Chroma key (green screen).** The Picture-in-Picture overlay can now key out a background colour so a green-screen presenter composites over your program/slides. Overlays tab → add **Picture in Picture** → pick the source → enable **Chroma key**, choose the key colour (default green), and tune **Similarity** and **Smoothness**. Set the PiP **Size** near 100 to place keyed talent over the whole frame, or keep it small for a cornered cut-out. GPU-accelerated via Core Image; keyed transparency reveals whatever is on Program behind it. Saved with the show file.

---

# LiveDeck Studio (macOS) — v3.2

**New in 3.2:**
- **Test Pattern (Bars)** input — SMPTE-style colour bars for camera/output line-up (Add Input → Test Pattern).
- **Live disk-space readout** in the status bar for the recording volume, which turns red and warns when free space drops below 5 GB.

---

# LiveDeck Studio (macOS) — v3.1

**New in 3.1 — far more flexible overlays.**
- **One-click templates** (Overlays → ＋ → Templates): News, Speaker, Social handle, Breaking, Caption, Sermon, Scripture, and a centred Title card — each pre-styled and ready to edit.
- **Seven lower-third styles:** Accent strip, Boxed, Minimal, Two-tone, Tab header, Outline, and Pill.
- **Full styling controls** on lower thirds: accent colour, **text colour**, **background colour**, **background opacity**, **font size**, and **left / centre / right alignment**. Titles gain alignment too.
- All new styling is saved/restored with the show file.

---

# LiveDeck Studio (macOS) — v3.0

**Fixed:** muting an input now **actually silences its audio**. Previously video files (and in some cases audio files) kept playing through the speakers when muted — both `FileSource` and `AudioFileSource` now drive their output volume from the input's mute + fader.

**Redesigned audio mixer (vMix-style):** segmented **LED meters** mapped to a real −60…0 dB scale (green → amber → red), live **dB readout** per channel and on the Master/Recording buses, a **dB scale ruler**, gain faders showing their level in dB, and proper **SOLO / M / FX** buttons (M lights red and outlines the muted strip; SOLO lights amber).

---

# LiveDeck Studio (macOS) — v2.9

**New in 2.9 — network stream inputs.** Add Input → **Network Stream (HLS / URL)…** (also on empty slots). Paste an **HLS (.m3u8)** live stream or a direct **HTTP(S)** video URL and it becomes a full input with transport, trim and audio — great for IP cameras, CDN feeds and re-streams.

**Honest limits (and the workaround):** RTMP/RTSP pull and YouTube/Twitch/Facebook page links are **not** natively playable on macOS — RTMP/RTSP need an external demuxer (FFmpeg) and the social platforms don't expose a playable URL. The production-proven path: restream those to **HLS** (OBS, FFmpeg, or a media server) and paste the HLS URL here. The Add Stream dialog spells this out.

---

# LiveDeck Studio (macOS) — v2.8

**New in 2.8:**
- **Per-clip In/Out trim.** In the transport (Input tab) use **Set In** / **Set Out** to mark a region of a video or audio clip; **Clear** removes it. Playback (and looping) respects the trimmed region.
- **Playlist (auto-advance).** Toggle **Playlist** in the input bus header. With it on, the Program automatically advances to the next video/audio input each time the current clip reaches its end (or out-point), wrapping around — ideal for pre-roll reels and break loops. (Individual clip looping is disabled while Playlist is on.)
- **NDI:** the Outputs panel now **detects an installed NDI runtime** and shows its version. Sending frames over NDI is not yet active — that requires the NDI **SDK headers** to be wired into the build (see note below). The uploaded `.pkg` files install the runtime, not the SDK.

> **NDI status:** LiveDeck safely loads the installed NDI runtime at launch (via `dlopen`) and reports its version. To actually transmit video over NDI, the build needs the NDI SDK's C headers (`include/Processing.NDI.*.h`) so the frame structures are exactly correct — those are not in the runtime installers. Provide the SDK `include` folder and NDI send can be implemented properly.

---

# LiveDeck Studio (macOS) — v2.7

**New in 2.7 — video/audio playback controls.** Select a video or audio input (Input tab) to get a full transport: a **scrub bar** with current-time / duration, **play-pause**, **skip ±10s**, **restart**, and a **loop** toggle. Scrubbing seeks the clip; works for both video files and dropped audio files.

---

# LiveDeck Studio (macOS) — v2.6

**New in 2.6:**
- **External display output (projectors / LED walls).** Status bar → **Outputs**. Any connected display can show a clean, borderless, fullscreen Program feed. Enable several at once for **simultaneous outputs** — and they run alongside Record, Stream, Program Window and Multiview.
- **Input section is 2× taller** by default (and still draggable / size-adjustable).
- **Double-click an input** to take it straight to Program; **right-click** for a context menu (Take to Program / Set as Preview / Remove).

---

# LiveDeck Studio (macOS) — v2.5

**New in 2.5:**
- **Drag & drop** video, image and audio files straight from the desktop onto the window — they fill the first empty input slot (or append). Audio files become a looping audio-only input.
- **Keyboard hotkeys:** number keys **1–9** stage that input to Preview, **Return** = Take (run the selected transition), **⌘Return** = Cut, **B** = fade to black.
- **Take (Auto)** button in the transition column.
- **Recording folder** is selectable (gear menu → Choose recording folder…), with **Reveal last recording**. Snapshots and recordings both go there.
- **Settings persist** between launches: resolution, frame rate, codec, container, bitrate and input tile size are remembered.

---

# LiveDeck Studio (macOS) — v2.4

**New in 2.4:** new app icon; the input bus has a **SIZE** slider to scale the input tiles (and the section is draggable via the divider); the **Audio mixer now lists every input** as a channel strip (empty slots show as "no input", real inputs get meter/fader/mute/solo/FX); and **recording settings** are in the gear menu — pick **resolution** (720p/1080p/4K), **frame rate** (30/60), **codec** (H.264, HEVC, ProRes 422, ProRes 4444), **container** (MP4/MOV) and **bitrate** (4–40 Mbps). ProRes auto-selects a MOV container.

---

# LiveDeck Studio (macOS) — v2.3.1

**Fixes in 2.3.1:** resolved the UI freeze on every click (audio meters now publish on a steady 12 Hz timer instead of flooding the main thread on every audio buffer), and the transition buttons (Fade/Wipe/Slide/Zoom) now highlight the selected type and act as a proper selector. Note: Fade/Wipe/Slide/Zoom only run a visible transition when a source is staged in **Preview** — with empty inputs they just select the type.

A native Mac live production switcher: Preview/Program buses with a transition T-bar, an input bus with live thumbnails, an audio mixer with VU meters, animated overlay graphics with variants, multiview, and MP4 recording. Built with Swift, SwiftUI, AVFoundation and ScreenCaptureKit. Requires macOS 13 Ventura or newer.

## Build (no terminal needed)

1. Unzip. Reveal the hidden `.github` folder with **Cmd+Shift+.**
2. Create a GitHub repo, **Add file → Upload files**, drag in everything *inside* the `LiveDeck` folder (so `Package.swift` is at the repo root), **Commit**.
3. **Actions** tab → wait ~4–6 min for the green check (the workflow also builds the app icon). Download the **LiveDeck-macOS** artifact, unzip, **right-click → Open** the first time, and grant Camera / Microphone / Screen Recording permissions.

## v2.0 — rebuilt around the vMix workflow

- **Preview → Program switcher.** Click an input to stage it in the Preview monitor (orange). Send it to Program (green) with the transition column or the input tile's **PGM** button.
- **Transitions + T-bar.** Cut, Fade, Wipe, Slide and Zoom. Click a transition to auto-run it, or drag the **T-BAR** to ride it manually. **FTB** fades Program to black.
- **Input bus.** A scrolling row of inputs with live thumbnails, numbers, an on-air/preview border, a per-input audio (mute) toggle, and a direct-to-Program button.
- **Audio mixer panel.** Master and Recording strips with live VU meters, plus a channel strip per input (meter, fader, M-mute), mirroring vMix's mixer.
- **Overlay channels.** Your layers act as overlays; the status-bar buttons 1–4 toggle the first four on air, and the Overlays tab holds the full layer list, inspector and variants.
- **Status bar & top bar.** Resolution/FPS readout, clock + on-air timer, Record/Stream/Snapshot/Multiview, and a vMix-style top bar (Open/Save, Fullscreen output, STREAM, REC).

## v2.3 — playback, mixing, resizable UI & streaming setup

- **Loop & playback control.** Video file inputs have a **Loop** toggle plus **Pause/Play** and **Restart** in the Input tab.
- **Editable input names.** Rename any input in the Input tab; the name updates everywhere (bus, monitors, mixer).
- **Per-input audio metering.** Assign an audio device to each input (Input tab → Audio) and its channel strip shows a **live VU meter**. Strips have fader, **Mute** and **Solo**.
- **Audio effects per input.** An **EQ** (low/mid/high), **Compressor** (threshold/ratio) and **Gate** (threshold) editor on every input and in the mixer's FX popover. Parameters are stored per input.
- **Resizable sections.** The monitors area, input bus and right panel are now separated by draggable dividers — size each section to taste.
- **Stream settings.** The **STREAM** button opens a destinations manager: add multiple targets, pick a **platform** (YouTube / Facebook Live / Twitch / Custom) which auto-fills the ingest URL, choose a **protocol** (RTMP / RTMPS / SRT), and enter your server URL + stream key. Destinations are saved between launches.

> Honest note on audio & streaming: per-input meters are real and effect/fader/mute settings are stored, but the recording still captures the master input device — summing every input through its effects into the recording is the remaining audio-engine milestone. Likewise, stream destinations are saved and the full ingest URL is composed for you, but going live needs a streaming encoder that isn't bundled yet (capture the Program window in OBS / YouTube to broadcast today).

## v2.2 — flexible inputs & external video devices

- **Five blank input slots** are created on launch. Click a slot's **Select input** button to assign it to a camera/device, screen capture, video file, image or colour — just like vMix's input list. **Add Input** (bus header) also has a **Blank Input** option to add more empty slots.
- **External video devices.** The device list now enumerates everything AVFoundation can see: built-in cameras, USB webcams, HDMI/SDI capture cards, and — when their macOS drivers are installed — **Blackmagic DeckLink** and **AJA** inputs, plus virtual cameras (e.g. OBS). This uses the CoreMediaIO opt-in so DAL/hardware devices appear without needing each vendor's SDK. Use **Refresh devices** if you plug something in while running.
- **More video formats.** The file picker now accepts MOV, MP4, M4V, MPEG-4, MPEG/TS, AVI, WMV and MKV containers. Note: playback depends on macOS having a codec for the file — Apple natively decodes H.264/HEVC/ProRes in MOV/MP4/M4V (and MPEG-TS); AVI/WMV/MKV play only if you have the matching codecs installed, otherwise the input stays black.

## v2.1 — live adjustment controls on every element

- **Per-input adjustments (Input tab).** Tap any input's thumbnail, then tune it live: **Zoom, Pan X/Y, Rotate, Crop (each edge), Brightness, Contrast, Saturation**, plus audio **Gain** and **Mute**. A **Reset** button restores defaults. Mirrors vMix's "Zoom, Pan, Rotate, Crop" and real-time colour correction.
- **Per-overlay transform.** Every layer's inspector now has a **Transform** section: **Opacity, Position X/Y, Scale, Rotate** with Reset. Saved inside your `.livedeck` files.
- **Transition speed.** A **Speed** slider in the transition column sets the auto-transition duration (0.2–2.0s).

## Honest scope — what's NOT included

These vMix features need licensed SDKs, Windows-only components, or system extensions and are not in this app: **NDI, virtual camera, vMix Call, Zoom integration, SRT, AJA/Blackmagic hardware *output* (input via drivers now works), instant replay, DVD, web-browser input, and the GT title designer.** Direct RTMP streaming also needs a relay and is not wired (capture the Program window in OBS/YouTube to stream for now).

Audio: meters are real on the Master/Recording/program-input strips; faders and mutes are stored per input. Recorded audio is the single selected input device (route your mixer's USB feed there for a full board mix). True simultaneous multi-source audio mixing into the recording is the next milestone.
