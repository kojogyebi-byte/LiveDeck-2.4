# LiveDeck Present — Phase 1 Architecture

**Status:** APPROVED (decisions in §17). Build 4.0-a (foundation, songs, Bibles) delivered.
**Applies to:** LiveDeck Studio v3.18 codebase (Swift 5.10 / SwiftUI / AVFoundation, SPM, GitHub Actions `macos-14`).
**Working name:** *LiveDeck Present* — the presentation engine inside LiveDeck. Original naming and UI; no third-party product names, assets or layouts are used in the app.

This document answers the 15 items of "First Task" in the brief, grounded in what LiveDeck already is today, and ends with a condensed functional analysis (brief §27) and an honest risk list. Where something cannot be done (or verified) with the current toolchain, it says so.

---

## 0. Where we start from (v3.18 reality check)

| Area | Today | What the presentation engine needs |
|---|---|---|
| Compositor | Core Graphics, **on the main thread**, one `Timer` at fpsTarget, renders Program into a BGRA `CVPixelBuffer`, then `makeImage()` copies per frame | Off-main render thread first; Metal later for 4K + many outputs |
| Sources | `Source` class hierarchy (camera, screen, file, image, colour, bars, audio file, ffmpeg stream, web, empty) with `currentImage()` / `draw(in:rect:)` | A new `PresentationSource` fits this abstraction directly — the "select PRESENTATION like a camera" requirement is architecturally cheap |
| Overlays | `Layer` + `LayerRenderer` (lower thirds, ticker, countdown, clock, scoreboard, title, logo, QR, PiP, definition), drawn over Program every frame | Becomes the downstream-key (DSK) stack; presentation key output joins it |
| Outputs | External displays with per-display source (`screenSource [Int: UUID]`), fullscreen window, multiview window, recording, RTMP/SRT stream | Generalise into an `OutputManager` with routable targets (Program, input, presentation full/key, stage) |
| Audio | Capture devices only; file/video audio plays to speakers and is **not** in the mix | Presentation videos need their audio in the mix → MTAudioProcessingTap work becomes mandatory |
| Persistence | UserDefaults + `.livedeck` show JSON | A real library: files on disk + SQLite index, autosave, versions |
| Tests | None | New code lives in a testable library target with `swift test` in CI |
| NDI | Runtime detection only; send blocked on SDK headers | Unchanged blocker |

---

## 1. Technical architecture

LiveDeck stays **one native macOS app** with three engines sharing one clock, one command bus and one output manager.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                               LiveDeck.app                                   │
│                                                                              │
│  UI (SwiftUI/AppKit)                                                         │
│  ┌──────────────┐ ┌───────────────┐ ┌──────────────┐ ┌─────────────────────┐ │
│  │ PRODUCTION   │ │ PRESENT       │ │ EDIT         │ │ Stage / Output      │ │
│  │ workspace    │ │ workspace     │ │ (slide       │ │ windows             │ │
│  │ (today's UI) │ │ (library,     │ │  editor)     │ │                     │ │
│  │              │ │  slides, live)│ │              │ │                     │ │
│  └──────┬───────┘ └──────┬────────┘ └──────┬───────┘ └─────────┬───────────┘ │
│         │  all actions go through ▼                            │ frames ▲    │
│  ┌──────┴──────────────────────────────────────────────────────┴──────────┐  │
│  │ CommandBus  (UI, hotkeys, remote WebSocket, MIDI/StreamDeck later)     │  │
│  └──────┬──────────────────────┬──────────────────────┬───────────────────┘  │
│         ▼                      ▼                      ▼                      │
│  ┌──────────────┐     ┌────────────────────┐   ┌───────────────────┐         │
│  │ Production   │     │ Presentation       │   │ Library & Storage │         │
│  │ Engine       │◄────│ Engine             │◄──│ (files + SQLite)  │         │
│  │ (Engine.swift│ src │ (PresentationKit)  │   │ songs, scripture, │         │
│  │  switcher,   │     │ cue state, service,│   │ presentations,    │         │
│  │  mixer, rec, │     │ transitions, stage │   │ media, themes,    │         │
│  │  stream)     │     │ data               │   │ autosave/versions │         │
│  └──────┬───────┘     └─────────┬──────────┘   └───────────────────┘         │
│         │                       │                                            │
│         ▼                       ▼                                            │
│  ┌───────────────────────────────────────────────────────────────────────┐   │
│  │ Render Core (dedicated render thread, FrameClock, surface pool)       │   │
│  │  ProgramCompositor · PresentationRenderer · StageRenderer · Multiview │   │
│  └──────────────────────────────┬────────────────────────────────────────┘   │
│                                 ▼                                            │
│  ┌───────────────────────────────────────────────────────────────────────┐   │
│  │ OutputManager: displays · windows · recorder · streamer · NDI · key/fill│  │
│  └───────────────────────────────────────────────────────────────────────┘   │
│  RemoteServer (Network.framework HTTP + WebSocket)   AudioEngine (mix/bus)   │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Design rules**

1. **Presentation state is data, rendering is a pure function of it.** `LiveState + Documents + time → frame`. This is what makes rendering testable and crash recovery possible (re-render from saved state).
2. **One CommandBus.** Keyboard, buttons, remote control and tests all issue the same `Command` values. No UI button calls engine internals directly for new features.
3. **Slides are rendered once, composited every frame.** A static slide is rasterised to a cached surface when it becomes preview/live; per-frame work is a blend, not text layout. Only video elements, animated backgrounds, timers and running transitions update per frame.
4. **Presentation never blocks Program.** If a slide render is slow or fails, the compositor keeps using the last good presentation frame.
5. **No new third-party dependencies.** Everything below uses Apple frameworks, which keeps the GitHub Actions build unchanged apart from the new targets.

---

## 2. Recommended technology stack

| Concern | Choice | Why |
|---|---|---|
| Language / UI | Swift 5.10, SwiftUI + AppKit (existing) | Continuity; AppKit for canvas editing and windows |
| Text layout | **Core Text** (`NSAttributedString` → `CTFramesetter`) | Rich text, kerning, line spacing, outlines (stroke), shadows; already proven in `LayerRenderer.definitionImage` |
| 2D rasterisation (Phases 2–4) | Core Graphics into IOSurface-backed `CVPixelBuffer`s | Works today, testable on CI, fast enough because slides are cached |
| GPU compositing (Phase 7, earlier if needed) | **Metal** + `CVMetalTextureCache`; Core Image on a Metal-backed `CIContext` for filters/keying | Zero-copy IOSurface ↔ texture; 4K60 multi-output |
| Video decode | AVFoundation (`AVPlayerItemVideoOutput`), hardware decode | H.264/HEVC/ProRes, **HEVC-with-alpha and ProRes 4444 alpha** supported |
| WebM | ffmpeg decode path (reuse `FFmpegStreamSource` pattern) | AVFoundation does not play WebM/VP9 — see risks |
| Animated GIF | ImageIO `CGImageSource` frame timing | Native |
| Audio from media | AVPlayer + **MTAudioProcessingTap** → LiveDeck mixer | Needed so presentation/clip audio reaches record/stream |
| Storage | JSON documents on disk (source of truth) + **SQLite3** (system library, `import SQLite3`) index with FTS5 search | No dependency; index is rebuildable; JSON is human-recoverable |
| Remote control | **Network.framework** `NWListener` + `NWProtocolWebSocket`, embedded HTML remote page | No dependency; phone/tablet via browser |
| Tests | XCTest via `swift test` | Runs in the existing CI runner |
| Network video | NDI SDK (blocked on headers); DeckLink SDK for SDI key/fill (future, needs SDK + hardware) | Licensed SDKs — cannot be bundled or guessed |

**Package layout change (additive, existing files untouched in Phase 2):**

```
Package.swift
Sources/
  LiveDeck/                 (executable — existing 5 files + new UI/engine glue)
  PresentationKit/          (library — NO SwiftUI; model, storage, slide generation, renderer)
    Model/  Storage/  Songs/  Scripture/  Render/  Commands/
Tests/
  PresentationKitTests/     (unit + golden-image render tests)
    Fixtures/
```

`build.yml` gains one step: `swift test` before the release build.

---

## 3. Module diagram

```
                        ┌─────────────────────────────┐
                        │        PresentationKit      │  (library, testable, no UI)
                        │                             │
  ┌──────────┐          │  Model ── Codable documents │
  │ Storage  │◄─────────┤  Storage ── LibraryStore    │
  │ (disk,   │          │           AutosaveJournal   │
  │  SQLite) │          │           VersionStore      │
  └──────────┘          │  Songs ── LyricParser       │
                        │           SlideGenerator    │
                        │  Scripture ── BibleImporter │
                        │               VerseQuery    │
                        │  Render ── SlideRasterizer  │
                        │            TransitionMath   │
                        │            StageLayoutRender│
                        │  Cue ── PresentationEngine  │
                        │         (preview/live state)│
                        │  Commands ── Command enum   │
                        └──────────────┬──────────────┘
                                       │ public API
┌──────────────────────────────────────┴───────────────────────────────────────┐
│ LiveDeck (executable)                                                        │
│  PresentationSource : Source      ← appears in input bus ("Presentation")    │
│  PresentationKeyLayer             ← DSK over Program (transparent lyrics)    │
│  OutputManager (+ StageOutput, KeyFillOutput)                                │
│  CommandBus + HotkeyMap + RemoteServer                                       │
│  UI: PresentWorkspace, SlideEditor, LibrarySidebar, ServicePanel,            │
│      SongEditor, ScripturePicker, StageLayoutEditor, OutputsView (extended)  │
│  Existing: Engine, Sources, Layers, UI (unchanged contracts)                 │
└──────────────────────────────────────────────────────────────────────────────┘
```

Each PresentationKit module is independently testable: parsers and generators with pure inputs/outputs, the renderer by rendering to an in-memory bitmap, the cue engine by feeding commands and asserting state.

---

## 4. Data model

Coordinates are stored in **canvas units** of the document's design size (default 1920×1080) and scaled at render time, so a 1080p presentation renders correctly into a 4K program or a 1280×800 stage monitor.

```swift
// ---------- Documents ----------
struct Presentation: Codable, Identifiable {
    var id: UUID
    var meta: PresentationMeta          // title, created, modified, tags, favorite, folderID, kind
    var canvas: CanvasSize              // width, height (design size)
    var themeID: UUID?
    var slides: [Slide]
    var groups: [SlideGroup]            // "Verse 1", "Chorus"… (colour-coded, arrangement-able)
    var arrangements: [Arrangement]     // ordered lists of group IDs (songs)
    var activeArrangementID: UUID?
    var defaultTransition: Transition
    var song: SongInfo?                 // when kind == .song
    var scripture: ScriptureRef?        // when kind == .scripture
    var schemaVersion: Int              // migrations
}
enum PresentationKind: String, Codable { case general, song, scripture, announcement, graphics }

struct Slide: Codable, Identifiable {
    var id: UUID
    var groupID: UUID?
    var label: String                   // shown on thumbnail
    var elements: [SlideElement]        // z-order = array order (last is top)
    var background: Background?         // nil → theme/global background
    var transition: Transition?         // nil → presentation default
    var notes: String                   // speaker notes → stage display
    var enabled: Bool
    var hotkey: String?                 // quick-select key
    var autoAdvance: TimeInterval?      // announcements loop
}

struct SlideElement: Codable, Identifiable {
    var id: UUID
    var name: String
    var frame: CGRectCodable            // canvas units
    var rotation: Double                // degrees
    var opacity: Double
    var locked: Bool, hidden: Bool
    var crop: EdgeInsetsCodable         // 0…1 per edge
    var mask: Mask?                     // rect / roundedRect / ellipse / alpha-image
    var shadow: Shadow?
    var buildIn: ElementAnimation?, buildOut: ElementAnimation?
    var role: ElementRole               // .content, .background, .keyOnly, .stageOnly
    var content: ElementContent
}
enum ElementContent: Codable {
    case text(TextContent)
    case image(MediaRef, fit: FitMode)
    case video(MediaRef, VideoOptions)          // loop, autoplay, volume, fadeIn/Out, in/out
    case shape(ShapeContent)                    // rect, rounded, ellipse, line; fill/stroke
    case timer(TimerContent)                    // countdown to time / duration, clock, service timer
    case liveSource(inputID: UUID)              // camera inside a slide (PiP slides)
    case group([SlideElement])
}

struct TextContent: Codable {
    var runs: [TextRun]                          // rich text: per-run style
    var paragraph: ParagraphStyle                // alignment, lineSpacing, paragraphSpacing
    var verticalAlign: VAlign
    var autoFit: AutoFit                         // none / shrinkToFit (lyrics) / grow
    var box: TextBox?                            // background box: colour, opacity, padding, radius
    var outline: Outline?                        // stroke width + colour
    var placeholder: TextPlaceholder?            // .lyricLine, .scriptureText, .scriptureRef, .songTitle…
}
struct TextRun: Codable { var text: String; var style: TextStyle }
struct TextStyle: Codable {
    var fontFamily: String, fontFace: String, size: Double
    var bold: Bool, italic: Bool, underline: Bool
    var color: RGBA, letterSpacing: Double, capitalization: Capitalization
}

enum Background: Codable {
    case color(RGBA)
    case gradient(stops: [GradientStop], angle: Double)
    case image(MediaRef, FitMode)
    case video(MediaRef, VideoOptions)
    case transparent                              // key output
}

struct Transition: Codable {
    var kind: TransitionKind                      // cut, fade, dissolve, push, slide, wipe, zoom, custom
    var duration: Double
    var direction: Direction
    var easing: Easing
}

struct MediaRef: Codable {
    var id: UUID
    var path: String                              // absolute path at last save
    var relativePath: String?                     // inside library Media/ when copied
    var bytes: Int64, modified: Date              // missing/changed media detection
    var hasAlpha: Bool
}

// ---------- Themes / templates ----------
struct Theme: Codable, Identifiable {
    var id: UUID; var name: String
    var textStyles: [String: TextStyle]           // "lyrics", "reference", "title", "body"
    var background: Background
    var layouts: [SlideLayout]                    // template slides with placeholders
    var transition: Transition
    var keyVariant: SlideLayout?                  // lower-third style layout for key output
}

// ---------- Songs ----------
struct SongInfo: Codable { var title, author, copyright, ccliNumber: String; var key: String?; var tempo: Int? }
struct LyricSection: Codable { var kind: SectionKind; var number: Int?; var lines: [String] }
enum SectionKind: String, Codable { case verse, chorus, preChorus, bridge, tag, intro, ending, other }
// Songs are stored as Presentations (kind .song) generated from [LyricSection] + Theme + lines-per-slide.

// ---------- Scripture ----------
struct BibleVersion: Codable, Identifiable { var id: String; var name: String; var abbreviation: String; var language: String; var license: String }
struct ScriptureRef: Codable { var versionID: String; var book: Int; var chapter: Int; var verseStart: Int; var verseEnd: Int }

// ---------- Service (playlist) ----------
struct Service: Codable, Identifiable {
    var id: UUID; var name: String; var date: Date?
    var items: [ServiceItem]
}
struct ServiceItem: Codable, Identifiable {
    var id: UUID
    var title: String                              // "Opening Song"
    var kind: ServiceItemKind                      // presentation, header, media, countdown, action
    var presentationID: UUID?
    var arrangementID: UUID?                       // per-service song arrangement
    var themeOverrideID: UUID?
    var collapsed: Bool
    var color: RGBA?
    var cueActions: [CueAction]                    // e.g. "switch to Camera 2", "start recording"
}

// ---------- Stage & outputs ----------
struct StageLayout: Codable, Identifiable {
    var id: UUID; var name: String; var canvas: CanvasSize
    var widgets: [StageWidget]                     // currentSlide, nextSlide, clock, countdown, serviceTimer,
                                                   // notes, songInfo, scriptureRef, message, videoCountdown
}
struct OutputConfig: Codable, Identifiable {
    var id: UUID; var name: String                 // "Main LED", "Confidence", "Lobby"
    var target: OutputTarget
    var destination: OutputDestination             // .display(uuid), .window, .ndi(name), .deckLink(port)
    var resolution: CanvasSize?
    var enabled: Bool
}
enum OutputTarget: Codable {
    case program, preview, input(UUID)
    case presentationFull, presentationKeyFill, presentationKeyMatte
    case stage(layoutID: UUID)
    case multiview(layoutID: UUID)
}

// ---------- Live state (autosaved every change + every 2 s) ----------
struct LiveState: Codable {
    var serviceID: UUID?
    var liveCue: Cue?, previewCue: Cue?           // Cue = presentationID + slideID + itemID
    var clearedLayers: Set<PresentationLayer>     // background / slide / media / messages
    var runningTimers: [TimerState]
    var programInputID: UUID?, previewInputID: UUID?
    var dskLive: [UUID]
    var savedAt: Date
}
enum PresentationLayer: String, Codable { case background, slide, media, messages, props }
```

**Presentation layers (the "clear" model).** Like professional presentation tools, the live presentation output is itself a small layer stack so an operator can clear one part without the rest: `background → media → slide text → messages → props/logo`. `Esc` clears slide text; separate buttons clear background / media / all.

---

## 5. Rendering pipeline

### 5.1 Target frame loop (per tick of FrameClock at program fps)

```
FrameClock (render thread, CVDisplayLink-independent DispatchSourceTimer, drift-corrected)
   │
   ├─1─► PresentationRenderer.update(now)
   │        • if live/preview cue changed → rasterise slide once → SlideSurface cache (LRU)
   │        • advance transition t, build-in/out animations, timers
   │        • pull latest video frames for video elements/backgrounds
   │        • compose presentation layers → FULL surface (opaque)  and  KEY surface (premultiplied alpha)
   │
   ├─2─► ProgramCompositor.render(now)
   │        • sources (cameras, files, PresentationSource(full|key), …) per layout/transition
   │        • DSK stack: PresentationKeyLayer + existing overlay Layers
   │        • FTB → PROGRAM surface
   │
   ├─3─► PreviewCompositor (only when a monitor is visible) · StageRenderer (per stage output)
   │
   └─4─► OutputManager.publish(surfaces)
            monitors/displays (CALayer contents = IOSurface, no CGImage copy)
            recorder (AVAssetWriter, IOSurface pixel buffer, zero copy)
            streamer (one memcpy into ffmpeg pipe — unavoidable)
            NDI / key-fill (copy per SDK)
```

### 5.2 Staging of the renderer (important — this is where the brief meets the current code)

| Stage | When | What | Why this order |
|---|---|---|---|
| R1 | Phase 2 | Slide rasterisation in Core Graphics into cached `CVPixelBuffer`s; existing main-thread compositor draws the cached image | Ships a working presentation quickly; per-frame cost is one image draw |
| R2 | Phase 3 | **Move the compositor off the main thread** + `CVPixelBufferPool` + remove per-frame `makeImage()` copies for monitors | Today's biggest bottleneck; required before video elements and multiple outputs |
| R3 | Phase 7 (pull earlier if 1080p60 with 2+ outputs misses budget) | Metal compositor: sources as textures via `CVMetalTextureCache`, shaders for blend/transition/key, Core Image on Metal for chroma key | 4K60 and many outputs |

Everything above R1 keeps the same `SlideRasterizer` output, so the renderer investment is not thrown away.

### 5.3 Text rendering specifics

- Core Text framesetter per text element; result cached with a key of (element content hash, output scale).
- **Shrink-to-fit** for lyrics/scripture: binary search on font size until the framesetter fits the box (max 8 iterations).
- Outline = stroke pass beneath fill pass; shadow via `CGContext.setShadow`; background box drawn from the typographic bounds + padding.
- Fonts missing on a machine → substitute and raise a **missing-font warning** in the library (not a silent fallback).

---

## 6. Presentation → video pipeline

```
                 ┌────────────────────────────── PresentationRenderer ─────────────────────────────┐
                 │  FULL surface  (background + media + slide + messages, opaque)                  │
                 │  KEY surface   (slide + messages + props only, transparent, premultiplied)      │
                 └──────┬───────────────────────────┬───────────────────────────┬─────────────────┘
                        │                           │                           │
          as an INPUT   ▼             as a DSK      ▼             as OUTPUTS    ▼
   ┌────────────────────────────┐  ┌──────────────────────────┐  ┌───────────────────────────────┐
   │ PresentationSource(.full)  │  │ PresentationKeyLayer      │  │ presentationFull → LED wall  │
   │  "Presentation" tile       │  │  over Program, after      │  │ presentationKeyFill → out A  │
   │ PresentationSource(.key)   │  │  switching, before FTB    │  │ presentationKeyMatte → out B │
   │  "Presentation Key" tile   │  │  (lyrics on every camera) │  │ NDI (alpha, when SDK)        │
   └────────────────────────────┘  └──────────────────────────┘  └───────────────────────────────┘
```

- **Selecting PRESENTATION like a camera:** `PresentationSource` subclasses `Source`; `currentImage()` returns the latest FULL (or KEY) surface. It therefore works with Preview/Program, transitions, layouts/scenes, per-display routing and multiview with no special cases.
- **Transparent lyrics over camera (Key mode):** two options, both supported:
  1. *DSK* — `PresentationKeyLayer` is toggled live independently of the switcher (most common for church broadcast).
  2. *Input in a layout* — `PresentationSource(.key)` placed in a scene slot above a camera.
- **Hardware key/fill without an SDK:** render KEY fill (RGB) to one display output and the alpha matte as greyscale to a second display output; feed both into a hardware switcher's key inputs. Works with any two HDMI/DisplayPort outputs (via converters to SDI). True SDI key/fill on one card needs the DeckLink SDK.
- **Different content per output:** an output can target Program (broadcast: camera + transparent lyrics), `presentationFull` (LED wall: "Jesus Saves" on a background), or a stage layout ("Song 4 / Verse 2") — all rendered from one `LiveState`.
- **Resolution independence:** the presentation renders at its output size; `PresentationSource` feeding a 4K program renders a 4K FULL surface only if something consumes it at 4K.
- **Audio:** video elements/backgrounds play through AVPlayer with an MTAudioProcessingTap that feeds a "Presentation" channel strip in the mixer (volume, mute, solo, meter, MAIN send), so presentation audio reaches record and stream.

---

## 7. Multi-output architecture

```swift
final class OutputManager {
    var outputs: [OutputConfig]                       // persisted
    func surface(for target: OutputTarget) -> RenderSurface?
    func attach(_ config: OutputConfig)               // creates sink
}
protocol OutputSink { func publish(_ surface: RenderSurface, at time: FrameTime) }
// Sinks: DisplaySink (borderless window on NSScreen, CALayer IOSurface contents)
//        WindowSink (floating/resizable), RecorderSink, StreamSink, NDISink, KeyMatteSink
```

- Replaces `screenSource [Int: UUID]` + `activeScreens` with persisted `OutputConfig` records, identified by **display UUID** (`CGDisplayCreateUUIDFromDisplayID`) rather than screen index, so outputs survive re-plugging and reboots.
- Each target is rendered **once per tick** no matter how many sinks use it.
- Output panel shows for each output: target, destination, resolution, live thumbnail, fps, dropped-frame counter, "identify" (flashes the output number on that screen).
- Stage outputs render at a low rate for static widgets (clock at 1 Hz, slides on change) to save GPU.

---

## 8. GPU architecture (target state R3)

- **Single `MTLDevice` / command queue**, render thread owns it.
- **IOSurface everywhere:** camera, `AVPlayerItemVideoOutput` (request IOSurface-backed, Metal-compatible pixel buffers), ScreenCaptureKit frames and slide rasters all arrive as `CVPixelBuffer` → `CVMetalTextureCache` → `MTLTexture` without copying.
- **Pipelines:** textured quad (with transform, crop, opacity), transition shaders (dissolve, push, wipe with softness, zoom), key shaders (alpha-over premultiplied, luma key), chroma key via Core Image on Metal (reuse `ChromaKey` logic).
- **Outputs:** render to IOSurface-backed textures from a pool; displays present via `CAMetalLayer`; recorder gets the same IOSurface as a `CVPixelBuffer`.
- **Colour:** BGRA8 sRGB/Rec.709 throughout; HDR out of scope.
- **Failure handling:** if `MTLCreateSystemDefaultDevice()` fails or a command buffer errors repeatedly, fall back to the Core Graphics path (R1/R2) and show a banner — the show continues at reduced performance.
- **Honest limit:** GitHub's hosted macOS runners are not a reliable place to run Metal tests; GPU tests run locally and are skipped on CI when no device is available.

---

## 9. API / WebSocket architecture

**Transport:** `NWListener` on a configurable port (default 8877), off by default. `GET /` serves an embedded mobile web remote; `GET /ws` upgrades to WebSocket; `GET /api/v1/…` provides simple HTTP triggers for Stream Deck/Companion-style controllers.

**Security:** LAN only by default; 6-digit PIN or token required (`?token=`); read-only "stage viewer" token separate from control token; rate limiting per connection. Needs `NSLocalNetworkUsageDescription` in Info.plist.

**Message format**

```json
// client → server
{ "id": "c42", "cmd": "presentation.next" }
{ "id": "c43", "cmd": "presentation.goLive", "args": { "presentationID": "…", "slideIndex": 3 } }
{ "id": "c44", "cmd": "switcher.cut", "args": { "input": 2 } }
{ "id": "c45", "cmd": "audio.setGain", "args": { "input": "…", "db": -6 } }
{ "sub": ["state", "meters", "stage"] }

// server → client
{ "ack": "c42", "ok": true }
{ "ack": "c44", "ok": false, "error": "input 2 is empty" }
{ "event": "state", "live": { "item": "Opening Song", "slide": 3, "group": "Chorus" },
  "program": "Camera 1", "preview": "Presentation", "streaming": true, "recording": false }
{ "event": "meters", "master": -12.4, "inputs": { "…": -18.0 } }      // ≤ 10 Hz
```

**Command namespaces (all map 1:1 to `Command` in PresentationKit / Engine):**
`presentation.{next, previous, goLive, preview, clear, clearAll, clearBackground, clearMedia, selectItem, selectSlide}` ·
`service.{list, open, itemNext, itemPrevious}` · `graphics.{show, hide, toggle}` (DSK/overlays) ·
`timer.{start, stop, reset, set}` · `message.{show, hide}` (stage message) ·
`switcher.{preview, cut, take, ftb, transition}` · `stream.{start, stop}` · `record.{start, stop}` ·
`audio.{mute, unmute, setGain, solo}` · `state.get` · `stage.frame` (JPEG snapshot for network stage display).

**Network stage display:** `GET /stage/<layoutID>` serves a web page that renders stage widgets from `state` events (text-based, very light), plus optional JPEG slide thumbnails. Works on any tablet or smart TV browser without NDI.

---

## 10. Database / storage structure

```
~/Library/Application Support/LiveDeck/
  library.sqlite                    ← index (rebuildable from files)
  Presentations/<uuid>.ldpres/      ← package folder
      document.json                 ← source of truth (atomic write)
      thumbs/<slideID>.jpg
      versions/<ISO8601>.json       ← last 30 versions + daily keep for 30 days
  Services/<uuid>.ldservice.json
  Themes/<uuid>.ldtheme.json
  Stage/<uuid>.ldstage.json
  Media/                            ← optional "copy into library"
  Bibles/<abbrev>.sqlite            ← imported by the user
  Recovery/livestate.json           ← every change + every 2 s
  Recovery/journal/<uuid>.json      ← unsaved edits (autosave every 5 s while editing)
  Logs/livedeck-YYYY-MM-DD.log      ← rotating, 14 days
```

```sql
CREATE TABLE folders      (id TEXT PRIMARY KEY, parent_id TEXT, name TEXT NOT NULL, sort INTEGER);
CREATE TABLE presentations(id TEXT PRIMARY KEY, folder_id TEXT, title TEXT NOT NULL, kind TEXT,
                           favorite INTEGER DEFAULT 0, created REAL, modified REAL, last_opened REAL,
                           path TEXT NOT NULL, slide_count INTEGER, missing_media INTEGER DEFAULT 0);
CREATE TABLE tags         (presentation_id TEXT, tag TEXT, PRIMARY KEY (presentation_id, tag));
CREATE TABLE songs        (presentation_id TEXT PRIMARY KEY, title TEXT, author TEXT, copyright TEXT, ccli TEXT);
CREATE VIRTUAL TABLE search USING fts5(presentation_id UNINDEXED, title, author, lyrics, tags);
CREATE TABLE media        (id TEXT PRIMARY KEY, path TEXT, bytes INTEGER, modified REAL,
                           kind TEXT, has_alpha INTEGER, duration REAL, status TEXT);  -- ok/missing/changed
CREATE TABLE services     (id TEXT PRIMARY KEY, name TEXT, date REAL, path TEXT, modified REAL);

-- Bibles/<abbrev>.sqlite (one per imported version)
CREATE TABLE meta   (key TEXT PRIMARY KEY, value TEXT);              -- name, abbreviation, license, language
CREATE TABLE books  (number INTEGER PRIMARY KEY, name TEXT, short TEXT, chapters INTEGER);
CREATE TABLE verses (book INTEGER, chapter INTEGER, verse INTEGER, text TEXT,
                     PRIMARY KEY (book, chapter, verse));
CREATE VIRTUAL TABLE verses_fts USING fts5(text, content='verses');
```

FTS5 is available in macOS's system SQLite; the store checks at startup and falls back to `LIKE` search if not.

**Import formats (open/public only):** plain text with section headers (`Verse 1`, `Chorus`…), OpenLyrics XML, CCLI SongSelect text export, folders of images (PowerPoint/Keynote exported as images), Bible imports from OSIS XML, USFM, Zefania XML, or simple CSV/JSON supplied by the user. Proprietary presentation file formats from other products are **not** imported.

**Bible licensing:** no translation is bundled. The user imports texts they are licensed to use. A public-domain translation (e.g. KJV, subject to local Crown-copyright rules) can be imported from a file the user provides.

---

## 11. UI wireframes

A workspace switcher is added to the TopBar: **PRODUCTION · PRESENT · EDIT**. PRODUCTION is today's screen with a new right-panel tab *Present* (mini slide grid of the live item), so a one-person crew never has to leave it.

### 11.1 PRESENT workspace (operator)

```
┌ LIVEDECK  [PRODUCTION] [PRESENT] [EDIT]     ● STREAM  ● REC   CPU 22% RAM 41%   12:04:31 ┐
├───────────────────┬──────────────────────────────────────────────┬────────────────────────┤
│ LIBRARY | SERVICE │  OPENING SONG · "Great Is Thy Faithfulness"  │  PREVIEW  (orange)     │
│ ┌───────────────┐ │  Arrangement: [V1 C V2 C B C ▾]  Theme: [▾]  │ ┌────────────────────┐ │
│ │ 🔍 search      │ │                                              │ │                    │ │
│ ├───────────────┤ │  VERSE 1 ─────────────────────────────────── │ │   next slide       │ │
│ │ SUNDAY 21 SEP │ │  ┌──────┐ ┌──────┐                           │ └────────────────────┘ │
│ │ ▸ Countdown   │ │  │  1   │ │  2   │                           │  LIVE  (red)           │
│ │ ▸ Welcome     │ │  └──────┘ └──────┘                           │ ┌────────────────────┐ │
│ │ ▾ Opening Song│ │  CHORUS ──────────────────────────────────── │ │                    │ │
│ │ ▸ Scripture   │ │  ┌──────┐ ┌──────┐   ← live slide = red frame│ │   live slide       │ │
│ │ ▸ Announce.   │ │  │  3 ● │ │  4   │   ← preview = orange      │ └────────────────────┘ │
│ │ ▸ Offering    │ │  └──────┘ └──────┘                           │ [CLEAR TEXT] [CLR BG]  │
│ │ ▸ Sermon      │ │  VERSE 2 ─────────────────────────────────── │ [CLEAR MEDIA][CLR ALL] │
│ │ ▸ Altar Call  │ │  ┌──────┐ ┌──────┐                           │ Key DSK: [ ON  ]       │
│ │ ▸ Closing     │ │  │  5   │ │  6   │                           │ Timers  ⏱ 04:59 ▶ ■   │
│ ├───────────────┤ │                                              │ Stage msg [_______] ⏎ │
│ │ SONGS  BIBLE  │ │  ◀ PREV     ● GO LIVE (⏎)     NEXT (␣) ▶    │ Outputs: LED● Conf● Str│
│ │ MEDIA  THEMES │ │                                              │                        │
├───────────────────┴──────────────────────────────────────────────┴────────────────────────┤
│ SWITCHER STRIP  [PVW mini][PGM mini]  1 Cam1  2 Cam2  3 PRESENT  4 Media  5 NDI   TAKE CUT FTB│
│ AUDIO  Master ▮▮▮▮▯  Pres ▮▮▯▯  Mic1 ▮▮▮▯                                                  │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

Large targets (≥ 44 pt) for GO LIVE / NEXT / PREV / CLEAR; live = red, preview = orange (consistent with the switcher).

### 11.2 EDIT workspace (slide editor)

```
┌ [PRODUCTION] [PRESENT] [EDIT]   File: Great Is Thy Faithfulness   Canvas 1920×1080 ▾  ✓ Saved ┐
├──────────┬───────────────────────────────────────────────────────────────┬─────────────────┤
│ SLIDES   │  ┌ ruler ─────────────────────────────────────────────────┐  │ INSPECTOR        │
│ ┌──────┐ │  │ ┌ safe area ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┐ │  │ Text ▾           │
│ │  1   │ │  │ ┊                                                ┊ │  │ Font  [Inter ▾]  │
│ └──────┘ │  │ ┊   ┌─────────────────────────────────────┐      ┊ │  │ Size  [72] B I U │
│ ┌──────┐ │  │ ┊   │ Great is Thy faithfulness,          │◄ sel ┊ │  │ Align ⟸ ☰ ⟹     │
│ │  2   │ │  │ ┊   │ O God my Father                     │      ┊ │  │ Line  1.1  Kern 0│
│ └──────┘ │  │ ┊   └──────────────○──────────────────────┘      ┊ │  │ Colour ■ 100%    │
│  + slide │  │ ┊            (rotate handle, snap guides)        ┊ │  │ Outline 2px ■    │
│ GROUPS   │  │ └┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┘ │  │ Shadow  on       │
│ V1 C V2  │  └─────────────────────────────────────────────────────────┘  │ Box  ■ 40% pad 20│
│          │  Tools: ▭ Text  🖼 Image  🎞 Video  ◯ Shape  ⏱ Timer  ⧉ Group │ Build in [Fade ▾]│
│          │  Align ⫷ ⫸ ⫶  Distribute  Lock 🔒 Hide 👁  Grid ▦  Snap ✓  Zoom 50%│ Layers ≡ reorder│
└──────────┴───────────────────────────────────────────────────────────────┴─────────────────┘
```

### 11.3 Stage display (default layout)

```
┌──────────────────────────────────────────────────────────────┐
│ CURRENT                                      12:04 PM         │
│  Great is Thy faithfulness,                                   │
│  O God my Father                             SERVICE  01:12:40│
│──────────────────────────────────────────────────────────────│
│ NEXT  ›  There is no shadow of turning with Thee   COUNTDOWN  │
│                                                     04:59     │
│ Song 4 / Chorus · "Great Is Thy Faithfulness"                │
│ ███ MESSAGE: Wrap up in 5 minutes ███                        │
└──────────────────────────────────────────────────────────────┘
```

### 11.4 Default keyboard map (PRESENT workspace; editable in existing Hotkeys sheet)

| Key | Action | Key | Action |
|---|---|---|---|
| Space / → / ↓ | Next slide (auto-advances into next service item at end) | ← / ↑ | Previous slide |
| Return | Send selected slide live | Esc | Clear slide text |
| ⇧Esc | Clear all presentation layers | F1 / F2 / F3 | Clear background / media / messages |
| 1–9 | Quick-select slide N of current item | ⌥1–9 | Jump to service item N |
| ⌘F | Search service / library | Tab | Toggle preview ↔ live focus |

Conflict note: PRODUCTION already uses Return (Take) and 1–9 (stage input). Hotkeys are **scoped per workspace**, and the Present tab in PRODUCTION uses the configurable map to avoid collisions.

---

## 12. Development roadmap (approved order)

Songs and scripture data were moved ahead of the slide editor: a church service needs lyrics and Bible verses long before free-form slide design, and both are fully testable before any rendering exists.

| Build | Delivers | Test gate before next build |
|---|---|---|
| 3.18 | No autoplay on add; TV-black blank holders | Visual check (done) |
| **4.0-a** (app version 4.0.0) | `PresentationKit` library target + unit tests in CI; data model; document library (autosave, versions, trash, folders, tags, favourites, recents, search); **songs** (type/paste, import plain text · SongSelect .txt/.usr · ChordPro · OpenLyrics · OpenSong, arrangements, slide generation); **Bibles** (unlimited versions, 1000+ free translations downloadable in-app, import Zefania · OSIS · USFM · CSV/TSV · Free Use JSON, reference parser, passage lookup, word search, slide splitting); PRESENT workspace; input tiles always 16:9 | Add/import songs; install 2+ Bibles; look up passages; relaunch keeps everything |
| **4.1** (app version 4.1.0; absorbed 4.0-b) | **Single page:** Songs & Bible and Dictionary are tabs under Preview/Program; slide renderer (Core Text); **Presentation input** and **Dictionary input** as normal switcher inputs; **looks** (full formatting: colour/gradient/image/looping-video backgrounds + darken, font/size/B-I-U/colour/alignment/case/line & letter spacing/outline/shadow for text, title and reference; area presets + custom; margins; box/band; verse numbers; lines & characters per slide; fade) with saved looks; **live control** (click slide, ←/→, Page Up/Down clickers, clear text/background, Preview/Program/**Key over Program** downstream key with fade); **dictionary providers** (macOS, Free Dictionary API, Wiktionary, Datamuse thesaurus, Wikipedia, imported CSV/TSV/JSON dictionaries); professional control redesign (design system); 8 default inputs; outputs inline panel; borderless full-screen Program Out; hotkeys suspended while typing | Lyrics and scripture on Program and keyed over a camera; dictionary card to Program; relaunch keeps saved looks |
| 4.2 | Render thread move (R2); key/alpha hardening; key/fill on two outputs; media audio into the mixer | Transparent lyrics over camera on the stream for 2 h; clip audio recorded |
| 4.3 | Service plans (running order, reorder/duplicate/rename/collapse/search, auto-advance) + LiveState crash recovery | Kill the app mid-service → relaunch restores live cue |
| 4.4 | Slide editor (text/images/shapes, snapping, grid, safe areas, undo) for announcements & general presentations | Build an announcement loop by hand |
| 4.5 | OutputManager (display-UUID outputs) + stage display layouts, timers, stage messages | LED + confidence + stream with different content |
| 4.6 | Broadcast graphics (lower thirds, logos, social, speaker) as themeable presentations with build-in/out | Lower third + lyrics + logo together |
| 4.7 | Remote control (WebSocket + HTTP triggers), phone web remote, network stage page | Phone drives slides and switcher |
| 4.8 | Metal compositor (R3), performance HUD, soak-test mode | 1080p30 service config for 4 h without drops on the reference Mac |
| 4.9 | NDI in/out with alpha — once the NDI SDK headers are supplied | NDI monitor receives presentation key |
| 5.0 | Hardening: 8-hour soak, memory audit, GPU fallback | Production checklist signed off |

## 13. Risk assessment

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | **Blind development** — assistant cannot compile or run; large features break builds | High | Medium | Small builds; PresentationKit unit tests in CI; local `swift build`; each build independently useful |
| 2 | **Main-thread CG compositor** can't hold 60 fps once slides, video elements and multiple outputs stack up | High | High | Cached slide rasters (R1); render-thread move in 4.2 (R2); Metal (R3) pulled forward if the HUD shows misses |
| 3 | **Single-process crash isolation** — a Swift trap in presentation code kills the whole app, including the stream (the brief asks that it never does) | Medium | Critical | No force-unwraps/unchecked subscripts in PresentationKit (CI grep lint); validated decoding; last-good-frame fallback; LiveState recovery with fast relaunch. **True isolation** requires an out-of-process renderer (XPC helper sharing IOSurfaces) — possible, but a significant extra build/bundling step; proposed as an option after 4.9, not promised earlier |
| 4 | **WebM** not supported by AVFoundation | Certain | Low | ffmpeg-based decode for WebM (user-installed ffmpeg, as for streams) or recommend HEVC/ProRes |
| 5 | **Transparent video** only in HEVC-alpha / ProRes 4444 (not H.264, not WebM without ffmpeg) | Certain | Low | Detect alpha on import and label it; document export settings |
| 6 | **Media audio not in mix** (existing gap) | Certain | High for services with clips | MTAudioProcessingTap in 4.2 — untested blind, will need ear testing |
| 7 | **NDI / DeckLink SDKs** required for NDI alpha and single-card SDI key/fill | Certain | Medium | Dual-display key/fill works without SDK; NDI waits for headers |
| 8 | **Licensing** — Bible translations and song lyrics (CCLI) | Certain | High (legal) | Nothing bundled; user imports licensed text; copyright/CCLI fields shown on slides/stage when set |
| 9 | **Font mismatch** between editing and show machines | Medium | Medium | Missing-font warnings; optional "embed/collect fonts" into library folder |
| 10 | **Ad-hoc code signing** — macOS firewall and Local Network prompts may reappear after every new build for the remote server | High | Low | Document; stable Developer ID signing later |
| 11 | **SwiftUI performance** with hundreds of slide thumbnails | Medium | Medium | Thumbnails are JPEG files; lazy grids; AppKit collection view fallback |
| 12 | **Scope** — the brief describes several commercial products' worth of work | Certain | High | Phased roadmap with test gates; each build shippable |
| 13 | **Data loss** during a live service | Low | Critical | Atomic writes, versions, journaled autosave, never overwrite a document from a failed decode |

---

## 14. Performance bottlenecks (measured by inspection of v3.18)

Budget: **16.7 ms per frame at 60 fps** (33.3 ms at 30 fps). A 1080p BGRA frame is 8.3 MB; 4K is 33 MB.

| Bottleneck (today) | Cost | Fix |
|---|---|---|
| Compositor on the main thread — UI work (menus, sheets, SwiftUI diffing) competes with rendering | Frame drops during interaction | Render thread (R2) |
| `Source.currentImage()` converts each new pixel buffer to `CGImage` through Core Image | One full GPU→CPU readback per source per frame | Draw pixel buffers directly (R2) / textures (R3) |
| `processedImage()` runs a CI pass per draw when adjustments are set | Extra readback per draw | Cache per frame; shader in R3 |
| Program `makeImage()` then Preview rendered again at full resolution in a second context | 2× full-frame work | Render preview at monitor size; share surfaces |
| External displays / multiview each receive separately built images | N× copies | Render each target once, share IOSurface |
| Overlay text laid out every frame in `LayerRenderer` | CPU per frame per live layer | Cache text rasters by content hash |
| Streaming: one memcpy per frame into ffmpeg pipe + x264 encode on CPU | Unavoidable with ffmpeg; x264 at 1080p60 is heavy | Keep; consider VideoToolbox encode (`h264_videotoolbox`) option |
| New presentation risks: per-frame text layout, many video elements | Would blow budget | Slide raster cache; max concurrent decoders; pre-roll videos on preview |

---

## 15. Testing strategy

**Automated (CI, `swift test`)**

| Suite | Examples |
|---|---|
| Model | Codable round-trip for every type; schema migration from v1 fixtures; unknown-field tolerance |
| Library | create/rename/duplicate/delete/folder/tag/favourite/recent; search ranks title > lyrics; index rebuild from files |
| Autosave & versions | journal written within 5 s; recovery after simulated crash (write journal, discard memory, reload) |
| Songs | parse "Verse 1 / Chorus / Bridge" text; arrangements; lines-per-slide splitting; OpenLyrics import |
| Scripture | reference parsing ("Jn 3:16-18", "1 Cor 13"); range queries; auto-slide splitting by length |
| Rendering (golden images) | render slides (text styles, box, outline, shadow, image fit, crop, rotation) to bitmaps and compare against reference PNGs with tolerance; uses system fonts present on every macOS |
| Alpha | premultiplied over-operation on known pixel values; key matte = alpha |
| Transitions | frame at t = 0, 0.5, 1 for each transition kind |
| Cue engine | next/previous across item boundaries, go live, clear layers, disabled slides skipped |
| Commands / API | every JSON command decodes to the right `Command`; unauthorised token rejected |
| Output routing | mock sinks receive the right target; one render per target per tick |

**Local (Mac, not CI)** — Metal pipelines, AVFoundation playback, audio tap, displays.

**Manual test sheets** per build (short checklists matching the roadmap gates).

**Soak test mode (4.7)** — built into the app: synthetic sources (moving bars, animated gradient background, cycling lyric slides, lower third, running countdown) plus whatever real inputs are connected; logs every 10 s to `Logs/soak-<date>.csv`: fps per output, dropped frames, render time p50/p95/max, CPU, RAM, GPU (existing `SystemMonitor`), stream/record status. Target: 4 hours at 1080p60 with streaming + recording before 4.8; 8 hours before 4.9. The brief's full stress rig (4K camera + NDI input) needs that hardware and the NDI SDK — run manually on site.

---

## 16. Functional analysis (brief §27, condensed)

Based only on publicly observable behaviour common to professional presentation and switching software.

| # | Feature | User workflow | Data model | UI components | Rendering | Video pipeline | API | Test cases |
|---|---|---|---|---|---|---|---|---|
| 1 | Presentation workflow | Open item → click slide = live; arrow/space to advance; clear with Esc | Presentation, Slide, LiveState | Library, slide grid, live/preview monitors | Cached slide raster, transition blend | PresentationSource / DSK | presentation.* | Next/prev across items; clear layers |
| 2 | Slide creation | Add slide → add text/image → style → reorder | Slide, SlideElement, TextContent | Editor canvas, inspector, layer list | Core Text + CG, WYSIWYG = same rasteriser | Thumbnails via same renderer | — | Golden images; undo/redo |
| 3 | Service workflow | Build service before event; reorder; during event step through | Service, ServiceItem | Service sidebar, headers, search | Pre-render next item's first slides | Cue actions can switch cameras | service.* | Reorder persistence; auto-advance into next item |
| 4 | Media management | Drag media into library/slide; offline warnings | MediaRef, media table | Media bin, status badges | Thumbnail/poster extraction | Video elements via AVPlayer, audio tap | — | Missing file → warning, no crash |
| 5 | Live control | Operator uses keys/big buttons; preview before live | LiveState, Cue | GO LIVE/NEXT/PREV/CLEAR, timers | Transition engine | Live cue drives full/key surfaces | presentation.goLive… | Key map; latency < 1 frame after key |
| 6 | Stage display | Per-screen layout of current/next/notes/timers/messages | StageLayout, StageWidget | Stage layout editor, message box | Widget renderer at low rate | Output target .stage | message.*, stage.frame | Next-slide correctness; timer accuracy |
| 7 | Multiple outputs | Assign screens to targets once; persists | OutputConfig | Outputs panel with thumbnails | Render each target once | OutputManager sinks | state.get outputs | Replug display → restored |
| 8 | Graphics | Trigger lower third / logo over program independently | Presentation(kind .graphics), Layer | Graphics panel, DSK buttons | Build-in/out animations | DSK stack | graphics.* | Simultaneous DSKs; alpha correctness |
| 9 | Transitions | Default per presentation, override per slide | Transition | Transition picker | Shaders/CG blend | Presentation and switcher transitions independent | switcher.transition | t = 0/0.5/1 frames |
| 10 | Keyboard shortcuts | Keyboard-first operation, workspace-scoped | Hotkey map (existing) | Hotkeys sheet (extended) | — | — | — | No collisions between workspaces |
| 11 | Video integration | Pick "Presentation" like a camera | PresentationSource | Input tile | Full surface at program size | Source abstraction | switcher.* | Cut/fade from camera to presentation |
| 12 | Alpha / key | Lyrics over camera; key/fill to hardware | Background.transparent, role .keyOnly | Key DSK toggle, output target | Premultiplied KEY surface | DSK / key-fill outputs / NDI | graphics.toggle key | Matte equals alpha; no dark fringes |
| 13 | Remote control | Phone opens LAN URL, enters PIN | Command, session tokens | Remote settings, web remote | JPEG snapshots on request | — | WebSocket + HTTP | Auth, rate limit, reconnect |
| 14 | Performance | Stays smooth for hours | Metrics records | Performance HUD | Render thread → Metal | Zero-copy surfaces | state metrics | Soak CSV thresholds |

---

## 17. Decisions (answered)

1. **Roadmap** — assistant's choice: the order in §12 (songs & scripture data first, then live control).
2. **Workspace** — *revised in 4.1 at the user's request:* Present and Production share **one page**. Songs & Bible and Dictionary are tabs in the lower deck beneath Preview/Program; their output is a **Presentation input** / **Dictionary input** on the switcher, so it can go to Preview, Program, or be keyed over Program. Hotkeys are handled by a key monitor that ignores keys while any text field has focus, so typing lyrics can never trigger a cut.
6. **Dictionaries (4.1)** — user chooses the provider: macOS Dictionary (offline), Free Dictionary API (English), Wiktionary (many languages), Datamuse thesaurus, Wikipedia (encyclopedia), or dictionaries the church imports (CSV/TSV/JSON, e.g. a public-domain Bible dictionary). No bundled licensed dictionaries.
7. **Looks (4.1)** — formatting lives in a `SlideLook` per slide input (`PresentationKit/Look.swift`), saved looks in `Library/looks.json`. Sizes are 1080p points scaled to the output resolution.
3. **Bibles** — unlimited versions, future additions at any time. Chosen storage format: **one SQLite file per version (`*.ldbible`)** in `Library/Bibles/` — compact, opens instantly, only the verses on screen are loaded, full-text search via FTS5 (LIKE fallback). Sources:
   - **In-app download** of 1000+ translations from the **Free Use Bible API** (bible.helloao.org — no key, no usage restrictions; downloaded once, used offline).
   - **Import** of Zefania XML, OSIS XML, USFM (book files), CSV/TSV and Free Use Bible JSON — for any translation the church is licensed to use (e.g. commercial translations that are not freely distributable).
4. **Songs** — typed/pasted lyrics plus import of every open or exportable format: plain text, CCLI SongSelect exports (.txt and .usr), ChordPro, OpenLyrics XML and OpenSong. (SongSelect has no public API; its exports are the licensed route. Other presentation products' proprietary library files are not imported.)
5. **Minimum resources** — set by the assistant:
   - **macOS 13 Ventura or later**, universal binary. **Reference machine: any Apple Silicon Mac (M1, 8 GB)**. Intel Macs supported at reduced targets (1080p30, fewer outputs).
   - Default production format **1080p30**; 60 fps is opt-in.
   - Presentation output renders **only when something changes** (idle slides cost ~0% CPU/GPU); slides cached as images.
   - Bibles stay on disk; at most 4 versions open at once. Song library in memory (~15 MB per 5,000 songs).
   - Imports/downloads run in the background at utility priority; no polling timers in PRESENT.
