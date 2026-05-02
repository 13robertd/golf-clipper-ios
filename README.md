# Golf Clipper — V1

> Import a golf video and automatically split it into individual swing clips.

A small native iOS app written in SwiftUI. It reads the audio track of an
imported video, finds the loud "click" of every ball strike, and saves a
short clip around each swing. Manual fallback included for missed swings.

---

## What's in the box

```
GolfClipper/
├── GolfClipper.xcodeproj/            # Xcode project file
├── GolfClipper/
│   ├── GolfClipperApp.swift          # @main entry point
│   ├── AppState.swift                # Shared ObservableObject
│   ├── Models/
│   │   ├── ImportedVideo.swift
│   │   ├── SwingClip.swift
│   │   └── DetectionSettings.swift
│   ├── Services/
│   │   ├── VideoImportService.swift  # PhotosPicker → Documents
│   │   ├── AudioImpactDetector.swift # The swing-detection engine
│   │   ├── ClipExportService.swift   # AVAssetExportSession per clip
│   │   ├── PhotosSaveService.swift   # Save back to Photos
│   │   ├── LocalStorageService.swift # JSON on disk
│   │   └── ThumbnailGenerator.swift  # AVAssetImageGenerator
│   ├── Views/
│   │   ├── HomeView.swift
│   │   ├── VideoAnalysisView.swift
│   │   ├── ClipReviewView.swift
│   │   ├── ClipPlayerView.swift
│   │   ├── ManualClipView.swift
│   │   └── SettingsDebugView.swift
│   ├── Utilities/
│   │   ├── TimeFormatter.swift
│   │   └── FileManagerHelpers.swift
│   ├── Assets.xcassets/
│   └── Preview Content/
└── README.md
```

No backend. No login. No third-party dependencies. iOS 17+.

---

## Xcode setup

### Option A — open the included project (recommended)

1. **Install Xcode 15 or newer** from the Mac App Store.
2. **Open** `GolfClipper/GolfClipper.xcodeproj` in Xcode (double-click).
3. In the Project navigator (left), click the blue **GolfClipper** icon at
   the top, then select the **GolfClipper** target.
4. **Signing & Capabilities** tab:
   - Pick your personal **Team**.
   - Change **Bundle Identifier** to something unique you own, e.g.
     `com.yourname.golfclipper`. (The default `com.example.GolfClipper`
     will collide if anyone else built this.)
5. **Plug your iPhone in via USB.** First time? On the iPhone go to
   *Settings → Privacy & Security → Developer Mode* and enable it, then
   reboot.
6. In Xcode's top bar, change the run destination from "iPhone simulator"
   to your physical iPhone.
7. Press **⌘R** to build and run.
8. The first launch will fail with "Untrusted Developer." On the iPhone go
   to *Settings → General → VPN & Device Management → your Apple ID →
   Trust*, then launch again from the home screen.

### Option B — create a fresh Xcode project (Plan B if Option A fails)

If the included `.xcodeproj` ever gets out of sync, you can rebuild it in
about 5 minutes:

1. Xcode → **File → New → Project → iOS → App**.
2. Product Name: `GolfClipper`. Interface: **SwiftUI**. Language: **Swift**.
   Storage: **None**. Tests: off (for V1 simplicity).
3. Save it next to the existing `GolfClipper/` folder, then **delete** the
   auto-generated `ContentView.swift` and `GolfClipperApp.swift`.
4. Right-click the `GolfClipper` group in the Project navigator and choose
   **Add Files to "GolfClipper"…**. Select every file in
   `GolfClipper/GolfClipper/` (Models/, Services/, Views/, Utilities/,
   GolfClipperApp.swift, AppState.swift, Assets.xcassets, Preview Content).
   Make sure **Copy items if needed** is OFF and the **GolfClipper** target
   is checked.
5. Open the target settings → **Info** tab → add these keys:
   - `Privacy - Photo Library Usage Description` → `Choose a golf video from your Photos library to clip swings.`
   - `Privacy - Photo Library Additions Usage Description` → `Save your golf clips back to your Photos library.`
6. Set **iOS Deployment Target** to **17.0**.
7. Build & run.

---

## Using the app

1. **Import** — tap *Import Video*, pick a golf video from Photos.
2. **Watch the analysis sheet** — you'll see Importing → Analyzing →
   Creating clips → Done.
3. **Review** — tap *Review Clips*, swipe-left on any clip to delete or
   save individually, or use the **Save All Clips to Photos** button.
4. **Manual clip** — if a swing was missed, tap *Manual Clip*, scrub to
   the impact, tap *Create Clip Here*.
5. **Settings & Debug** — adjust pre/post-impact seconds, sensitivity,
   minimum spacing. Re-analyze with one tap. The debug section shows the
   loudest 50 audio peaks with their amplitudes — handy for picking a
   sensitivity value just below the quietest real impact.

---

## How the audio swing detection works

A golf-ball impact creates a very sharp, loud "click." Even on a noisy
range, the impact is usually the **loudest single instant** in the few
seconds around a swing. So we don't need ML for V1 — we just look for
short bursts of unusually loud audio.

### Pipeline

```
Imported video
   │
   │ AVAsset / AVAssetReader (decode to 32-bit float mono PCM @ 44.1 kHz)
   ▼
Raw audio samples
   │
   │ Sliding 1024-sample window (~23 ms)
   ▼
Per-window peak amplitude (0…1)
   │
   │ Filter: peak >= sensitivityThreshold
   ▼
Impact candidates
   │
   │ "Loudest wins" cooldown enforcing minimumSpacingSeconds
   ▼
Final impact timestamps (seconds into the source video)
```

### The algorithm in seven sentences

1. We open the imported video with `AVURLAsset`.
2. We use `AVAssetReader` to decode its audio track into 32-bit float
   mono PCM at 44.1 kHz — a normalized format we always know how to
   process.
3. We slide a 1024-sample window (~23 ms) across the audio and, for each
   window, record the loudest single sample inside it.
4. Every window peak above `0.05` is logged for the debug screen so you
   can see the noise floor.
5. We pick "impact candidates": every window whose peak is `>=`
   `sensitivityThreshold`.
6. We sort candidates **by amplitude (loudest first)** and greedily accept
   each one only if it is at least `minimumSpacingSeconds` away from every
   already-accepted impact — this keeps the loudest peak in any cluster
   and stops one swing being detected several times.
7. The list of accepted timestamps is sorted ascending and returned to
   the clip exporter.

### Tuning

`DetectionSettings` are persisted across launches. The defaults are
calibrated for handheld iPhone video at the range:

| Setting | Default | Effect |
|---|---|---|
| `sensitivityThreshold` | 0.35 | Lower → more sensitive (more detections, more false positives) |
| `minimumSpacingSeconds` | 3.5 | Two impacts closer than this are merged into one swing |
| `preImpactSeconds` | 2.5 | How much video before impact to keep in the clip |
| `postImpactSeconds` | 2.5 | How much video after impact to keep in the clip |

The debug list in *Settings & Debug* shows you the top 50 audio peaks
with their amplitudes. To tune sensitivity:

- Look at the loudest peaks. The ones that **are** swings should be in
  green (above your current threshold). False alarms should be below it.
- If real swings are showing as gray (below threshold), drop sensitivity.
- If voices/wind are showing as green, raise sensitivity.

---

## Testing checklist

| # | Test | Expected |
|---|---|---|
| 1 | Import a short video with one obvious swing | One clip created |
| 2 | Import a video of 4 different golfers each taking a swing | 4 clips |
| 3 | Import a longer range-session video | One clip per swing |
| 4 | Confirm each clip starts ~2.5 s before impact and ends ~2.5 s after | Yes, by default |
| 5 | Set sensitivity very high (e.g. 0.85) | Few or zero detections — message: "No swings found. Try lowering sensitivity or use Manual Clip." |
| 6 | Set sensitivity very low (e.g. 0.10) | Lots of detections, including false positives |
| 7 | Use *Manual Clip* on a missed swing | New clip appears in the review list with a "MANUAL" badge |
| 8 | Delete a clip via swipe action | Clip and its thumbnail disappear; file is gone from disk |
| 9 | Save one clip to Photos | Toast/checkmark; clip appears in Photos |
| 10 | Save All Clips to Photos | All clips end up in Photos; second tap is a no-op (already saved) |
| 11 | Import a video with no audio track | Friendly message: "This video has no audio track. Use Manual Clip." |
| 12 | Import a non-golf video (talking, music) | Likely 0 detections at default sensitivity, or false positives if you lower it — both are acceptable |
| 13 | Re-analyze with new settings from the debug screen | Old clips are wiped, new clips generated with current settings |
| 14 | Quit and relaunch the app | The imported video and clips list are still there |

---

## Known V1 limitations

- **Quiet impacts can be missed.** Soft contact (e.g. half-swing chips
  recorded from far away) may sit below the noise floor.
- **False positives are possible.** Claps, voices, and clubs hitting the
  mat or bag can register as impacts. Tune sensitivity in Settings.
- **Wind ruins everything.** Strong wind hitting the iPhone mic can
  saturate the audio and either mask real impacts or create constant
  false positives.
- **Two close swings may merge.** Two real impacts within
  `minimumSpacingSeconds` (default 3.5 s) will be reported as one. This
  is intentional — it stops one swing being detected multiple times —
  but you can lower the spacing if you take rapid-fire swings.
- **Audio only.** No video / vision detection in V1. If a video has the
  audio muted or stripped, only Manual Clip works.
- **Clips are exported one at a time.** Long videos with many swings will
  take a noticeable amount of time to export. Progress is shown.
- **No live recording yet.** V1 is import-only.

---

## V2 roadmap

In rough priority order:

1. **Live camera recording mode** with a rolling buffer (auto-save the
   last N seconds when an impact is detected live).
2. **Video-based swing detection** to back up audio:
   - Frame-difference / optical-flow burst detection.
   - Apple Vision body-pose detection for address → backswing → impact →
     finish.
   - Core ML model fine-tuned on golf swings.
3. **Better sensitivity heuristics**: adaptive baseline (mean + N·σ over
   a rolling window) instead of a fixed threshold; spectral fingerprint
   of a club–ball strike.
4. **Best-swing selection** (one tap to keep the best of N attempts).
5. **Swing ranking** based on tempo / impact loudness consistency.
6. **Slow-motion export** with frame interpolation around the impact.
7. **Reels / Shorts / TikTok export presets** (9:16 crop, captions).
8. **Club tagging** on each clip.
9. **iCloud / Drive sync** of clips.
10. **Backend (Supabase or Firebase) + web dashboard (Vercel)** if/when
    multi-device or sharing becomes needed.

---

## Build steps that were followed

The project was built in the order requested:

1. SwiftUI app shell (`GolfClipperApp` + `HomeView` + `AppState`).
2. Video import via `PhotosPicker` (`VideoImportService`).
3. Local Documents storage (`FileManagerHelpers`, `LocalStorageService`).
4. Clip preview (`ClipPlayerView` using `AVKit.VideoPlayer`).
5. Audio impact detection (`AudioImpactDetector`).
6. Clip export (`ClipExportService` using `AVAssetExportSession`).
7. Clip review list (`ClipReviewView`).
8. Save to Photos (`PhotosSaveService`).
9. Manual fallback (`ManualClipView`).
10. Settings & debug (`SettingsDebugView`).

Each layer compiles on its own, so if you ever need to gut a piece you
can do it without breaking the whole app.
