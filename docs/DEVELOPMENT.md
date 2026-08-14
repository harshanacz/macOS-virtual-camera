# Development

## Layout

```
Fuzzcam/
├── Fuzzcam/                  app target — UI only, no pixel work
│   ├── App/FuzzcamApp.swift          scenes: menu bar, preview, settings, onboarding
│   ├── ViewModels/AppModel.swift     the one observable object the UI reads
│   ├── Views/                        SwiftUI
│   └── Services/                     camera permission, system-extension install
│
├── CameraEngine/             app target — everything that touches frames
│   ├── CameraCapture.swift           AVCaptureSession, format choice, resilience
│   ├── CameraDiscovery.swift         device list + hot-plug
│   ├── FrameProcessor.swift          the Core Image degradation chain
│   ├── VideoPipeline.swift           capture → process → consumers, bounded
│   ├── VirtualCameraSink.swift       CMIO HAL client, app → extension
│   ├── PixelBufferPool.swift         buffer recycling
│   ├── PreviewRenderer.swift         CVPixelBuffer → CGImage, throttled
│   ├── ProcessingMetrics.swift       instrumentation
│   ├── FrameDumper.swift             DEBUG-only verification harness
│   └── CaptureError.swift            human-readable failures
│
├── FuzzcamExtension/         system extension target
│   ├── main.swift                    CMIOExtensionProvider.startService
│   ├── FuzzcamProviderSource.swift   device + source stream + sink stream
│   └── PlaceholderFrame.swift        the "app is not running" card
│
├── Shared/                   BOTH targets
│   ├── FuzzcamIdentifiers.swift      bundle IDs, app group, stable UUIDs
│   ├── FuzzcamConfiguration.swift    settings model + App Group store
│   └── QualityPreset.swift           presets, frame rates, output format
│
│   └── Views/DevCameraOutput.swift   DEBUG-ONLY OBS bridge (docs/DEV-CAMERA.md)
│
├── Config/                   entitlements + Info.plists (in no target)
├── scripts/release.sh        archive → notarize → staple
└── docs/
```

`Fuzzcam/`, `CameraEngine/`, `Shared/` and `FuzzcamExtension/` are
**file-system-synchronized groups** (pbxproj objectVersion 77). Adding a `.swift`
file to any of those folders puts it in the build automatically — no project edit.
`Shared/` is listed in both targets' `fileSystemSynchronizedGroups`.

## Building

```bash
xcodebuild -project Fuzzcam.xcodeproj -scheme Fuzzcam \
    -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

The `Fuzzcam` scheme depends on `FuzzcamExtension` and embeds it into
`Fuzzcam.app/Contents/Library/SystemExtensions/`. Building the app always builds
the extension.

## Build settings that matter

| Setting | Value | Why |
|---|---|---|
| `MACOSX_DEPLOYMENT_TARGET` | `14.0` | `CMIOExtension` needs 12.3; 14.0 is a sane modern floor |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | `nonisolated` | The engine is concurrent by nature. The Xcode default of `MainActor` makes every type main-actor-isolated, which is wrong here and produces Swift 6 errors. UI types are explicitly `@MainActor`. |
| `ENABLE_APP_SANDBOX` | `YES` (both) | Mandatory for the extension, and required for App Group containers |
| `REGISTER_APP_GROUPS` | `YES` (both) | |
| `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` | `NO` (Release) | Keeps `get-task-allow` out of release signatures — a system extension carrying it is treated as a development build |
| `INFOPLIST_FILE` | `Config/*-Info.plist` | `GENERATE_INFOPLIST_FILE` has no alias for `NSCameraUseContinuityCameraDeviceType` or the `CMIOExtension` dict, so both targets use a base plist that Xcode merges its generated keys into |

## Debug environment variables

Both are compiled out of Release.

```bash
BIN=".../Build/Products/Debug/Fuzzcam.app/Contents/MacOS/Fuzzcam"

# Dump one untouched frame + one per preset + control samples, then stop.
# Output lands in the App Group container (the app is sandboxed and cannot
# write elsewhere); the final log line prints the path.
FUZZCAM_DUMP=1 "$BIN"

# Log fps / latency / resolutions / dropped frames every 2 seconds.
FUZZCAM_METRICS=1 "$BIN"
```

```bash
# DEVELOPMENT ONLY: open the window OBS captures as a stand-in virtual camera,
# until the camera extension can be notarized. See docs/DEV-CAMERA.md.
FUZZCAM_DEV_OUTPUT=1 "$BIN"
```

Read the log with:

```bash
/usr/bin/log show --last 2m --predicate 'subsystem == "com.harshanacz.Fuzzcam"' --info
```

Categories: `CameraCapture`, `VideoPipeline`, `FrameProcessor`,
`VirtualCameraSink`, `SystemExtension`, `FrameDumper`, `DevCameraOutput`.

## Threading model

| Queue | Work |
|---|---|
| main | SwiftUI, `AppModel`, `CameraDiscovery` |
| `…session` | `AVCaptureSession` configuration, serialised |
| `…video` | `AVCaptureVideoDataOutput` delivery |
| `…processing` | Core Image chain, frame dumping, sink hand-off |
| `…preview` | `CIImage` → `CGImage` for the preview only |
| `…sink` | CMIO device/stream discovery and connection |

Rules that keep it honest:

- Nothing per-frame touches the main thread. The preview delivers at most 20
  images/sec, and the frame counters are *polled* by a 0.5 s timer rather than
  pushed — an earlier version notified on every frame and that is both wasteful
  and a crash risk.
- `MainActor.assumeIsolated` is only used in callbacks that are documented to
  arrive on the main queue. Getting this wrong crashes with
  `BUG IN CLIENT OF LIBDISPATCH` rather than failing quietly.
- The pipeline drops frames instead of queueing them. There is no unbounded
  buffer anywhere.

## Gotchas discovered the hard way

**Stale LaunchServices registrations.** Every build folder the app has ever run
from stays registered, which can make the wrong copy launch. (This was
investigated as a cause of extension-install failures and ruled out — the real
cause is Gatekeeper trust — but a stray registration is still worth clearing
when an old build keeps appearing.) Audit with:

```bash
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -dump | grep -oE "/[^ ]*Fuzzcam\.app" | sort -u
```

**`get-task-allow` in a system extension.** Development-signed extensions require
developer mode, which requires SIP off. `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`
handles this for Release.

**`OSSystemExtensionError` code 4 lies.** "Extension not found in App bundle" is
returned for *any* refusal to realize the extension, including trust failures.
The accompanying `sysextd: no policy, cannot allow apps outside /Applications`
is equally misleading — it is the result of looking for an MDM policy, not a
statement about your app's path. The real gate is Gatekeeper: check
`spctl -a -vvv -t exec` first, every time. Measured on macOS 26.6: Apple
Development signed and Developer ID unnotarized are both refused; only a
notarized Developer ID build works.

**Archiving with a forced identity fails.** `CODE_SIGN_IDENTITY="Developer ID
Application"` alongside `CODE_SIGN_STYLE=Automatic` errors with "conflicting
provisioning settings". Archive with the project's normal automatic signing and
let `xcodebuild -exportArchive` with `method: developer-id` re-sign for
distribution. `scripts/release.sh` does exactly this.

**No `NSExtension` dictionary.** Camera extensions are *system* extensions, not
app extensions. Adding an `NSExtension` dict — a common copy-paste from other
extension types — breaks them. Only the `CMIOExtension` dict belongs there.

**The extension's device name is fixed at construction.** `CMIOExtensionDevice`
takes its localized name in `init`, so renaming the virtual camera only takes
effect the next time the extension process starts.

## Adding a new video effect

The processing chain is a sequence of pure `CIImage → CIImage` steps in
`FrameProcessor.process(_:)`. To add one:

1. Add the parameter to `FuzzcamConfiguration` (with a default) and to
   `FrameProcessor.Settings`.
2. Write a `private func applyX(_ amount: Double, to image: CIImage) -> CIImage`
   that returns `image` untouched when the amount is zero — the default path
   must cost nothing.
3. Call it in `process(_:)` **before** `fitToOutput`, so it runs at the cheap
   intermediate resolution.
4. Add a slider in `SettingsView.qualityTab`.
5. Add a case to `FrameDumper`'s `extras` and re-measure.
