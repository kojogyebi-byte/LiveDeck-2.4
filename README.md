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
