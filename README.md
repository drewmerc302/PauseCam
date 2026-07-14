# PauseCam

**Pause and resume video recording into a single continuous file — the feature the stock iOS Camera never shipped.**

Record a scene, pause, reframe, resume — as many times as you like — and get **one** `.mov` in your Photos library with every paused gap stitched out and audio in perfect sync. No timeline editing, no clip joining, no third-party editor.

Built with SwiftUI + AVFoundation for iOS/iPadOS 17+.

## Features

- 🎬 **Pause/resume recording** into a single continuous clip — the core feature
- 🎞️ Scene counter ("Scene N") that increments on every resume
- ⏱️ Live timer showing *recorded* duration — freezes while paused, derived from actual sample timestamps
- 🔍 **Native zoom**: lens-switch pills (0.5x/1x/tele on multi-camera devices), smooth digital 2x on single-lens devices, pinch-to-zoom
- ☀️ Tap to focus/expose with a stock-camera-style EV slider (drag to adjust exposure bias)
- 🔄 Front/back camera flip (while idle)
- 🖼️ Last-clip thumbnail with in-app playback (session-only, like the stock Camera)
- 🎛️ **Control Center launch button** (iOS 18+) — replace the stock Camera control with PauseCam
- 🎤 Microphone optional: records video-only if mic access is denied
- 📱 iPhone + iPad, all orientations, saves to Photos with add-only permission

## Why the obvious API can't do this

`AVCaptureMovieFileOutput` — the standard "record a movie" API — has **no pause**. The only way to get true in-camera pause into one file is to build the pipeline yourself:

`AVCaptureVideoDataOutput` + `AVCaptureAudioDataOutput` → your code → `AVAssetWriter`

The pause trick is timestamp surgery, in `CameraController.swift`:

1. Keep a cumulative `timeOffset` (`CMTime`).
2. While paused, drop every incoming sample buffer.
3. On resume, add the elapsed gap (`currentPTS − lastAppendedPTS`, less one frame duration) to `timeOffset`.
4. Subtract `timeOffset` from every subsequent sample's presentation/decode timestamps (`CMSampleBufferCreateCopyWithNewTiming`) before appending.
5. Use the **same** offset for video and audio so A/V never drift.

The writer session starts on the first *video* buffer (earlier audio is dropped), timestamps are guarded to stay monotonic on both tracks, and all writer bookkeeping runs on one serial queue — the delegate queue for both outputs — so the state machine is single-threaded by construction.

## Architecture

| File | Role |
|---|---|
| `PauseCam/PauseCamApp.swift` | `@main` SwiftUI app |
| `PauseCam/CameraController.swift` | The engine: capture session, asset-writer pipeline, pause/resume timestamp math, zoom, exposure, rotation |
| `PauseCam/CameraPreview.swift` | Preview layer host + tap-to-focus, EV drag, pinch-zoom gestures |
| `PauseCam/ContentView.swift` | Controls overlay, timer, permission/error UI, last-clip player |
| `Shared/LaunchPauseCamIntent.swift` | App intent compiled into *both* targets (see below) |
| `PauseCamControls/` | Control Center widget extension (iOS 18+) |

Orientation uses `AVCaptureDevice.RotationCoordinator` (iOS 17+): the preview tracks the horizon continuously; the capture angle is fixed at record start for the whole clip.

### The Control Center gotcha

A Control Center button that launches its app **cannot** host its `AppIntent` only in the widget extension: `openAppWhenRun` is rejected there (`LNContextErrorDomain 2001`), and a returned `OpenURLIntent` gets dropped because the extension sandbox can't read the LaunchServices database. The intent must be compiled into the app target too — then the system runs `perform()` in the app process and the launch works. That's why the intent lives in `Shared/` with membership in both targets.

## Requirements

- Xcode 16+
- iOS/iPadOS 17.0+ (Control Center button requires 18.0+)
- A physical device — camera capture does not work in the Simulator

## Building

Open `PauseCam.xcodeproj`, select your development team under **Signing & Capabilities** (both targets), pick your device, and run.

Or from the command line:

```sh
xcodebuild -project PauseCam.xcodeproj -scheme PauseCam \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates build
```

To use the Control Center button: launch the app once, then Control Center → **+** → Add a Control → PauseCam.

## License

[MIT](LICENSE)
