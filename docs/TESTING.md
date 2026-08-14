# Testing

Status legend: **PASS** verified on this machine · **BLOCKED** cannot run until
the extension installs (see [INSTALLATION.md](INSTALLATION.md)) · **MANUAL** needs
hardware or a human.

Environment: MacBook Pro (Apple Silicon), macOS 26.6.1, Xcode 26.0.1,
built-in camera reporting 1920×1080.

---

## 1. Build

| # | Check | Result |
|---|---|---|
| 1.1 | Debug build, zero errors | **PASS** |
| 1.2 | Debug build, zero warnings | **PASS** |
| 1.3 | Release build, zero warnings | **PASS** |
| 1.4 | Extension embedded at `Contents/Library/SystemExtensions/` | **PASS** |
| 1.5 | Extension `CFBundlePackageType` = `SYSX` | **PASS** |
| 1.6 | `CMIOExtensionMachServiceName` = `C37NWJLS6S.com.harshanacz.Fuzzcam.Extension` | **PASS** |
| 1.7 | No `NSExtension` dict in the extension plist | **PASS** |
| 1.8 | App entitlements: sandbox, camera, app group, system-extension.install | **PASS** |
| 1.9 | Extension entitlements: sandbox, app group | **PASS** |
| 1.10 | Release signature carries no `get-task-allow` | **PASS** |
| 1.11 | App group resolves to `C37NWJLS6S.com.harshanacz.Fuzzcam` in both targets | **PASS** |

## 2. Camera

| # | Check | Result | Evidence |
|---|---|---|---|
| 2.1 | Built-in camera opens | **PASS** | `capture running: MacBook Pro Camera 1920×1080` |
| 2.2 | Frames delivered in the expected format | **PASS** | `first frame delivered: 1920×1080 fourcc=BGRA` |
| 2.3 | Permission prompt uses the standard TCC API | **PASS** | `TCCAccessRequest ... kTCCServiceCamera` |
| 2.4 | Permission denied shows an actionable message + Settings deep link | **PASS** | `CaptureError.permissionDenied` |
| 2.5 | Format capped at ≤1080p to avoid wasted work | **PASS** | selects 1920×1080, not 4K |
| 2.6 | Continuity Camera enabled via Info.plist key | **PASS** | AVFoundation warning gone after adding the key |
| 2.7 | External USB webcam appears and can be selected | **MANUAL** | no external camera available |
| 2.8 | Disconnect mid-capture → "camera disconnected", no crash | **MANUAL** | logic covered by `wasDisconnectedNotification` + 2 s retry |
| 2.9 | Reconnect → capture resumes automatically | **MANUAL** | `wasConnectedNotification` → `configureAndRun` |
| 2.10 | Another app steals the camera → interruption handled | **MANUAL** | `AVCaptureSessionWasInterrupted` |

## 3. Processing

Measured from one live camera frame, every image compared at the virtual
camera's 1280×720 output size so only *detail* differs. Laplacian variance is
the standard sharpness proxy; HF% is the share of FFT energy above a quarter of
Nyquist.

| # | Preset | Processing size | Detail vs source | HF% | Result |
|---|---|---|---|---|---|
| 3.1 | source | 1920×1080 | 100.0% | 71.6% | — |
| 3.2 | Original | 1920×1080 | 102.7% | 72.8% | **PASS** (no degradation) |
| 3.3 | High | 1280×720 | 101.9% | 72.5% | **PASS** |
| 3.4 | Medium | 854×480 | 55.8% | 66.4% | **PASS** |
| 3.5 | Low | 640×360 | 30.6% | 60.7% | **PASS** |
| 3.6 | Very Low | 480×270 | 15.0% | 55.0% | **PASS** |

Monotonic in both metrics. Reproduce with `FUZZCAM_DUMP=1` (see
[DEVELOPMENT.md](DEVELOPMENT.md)).

| # | Control | Result | Effect at Low preset |
|---|---|---|---|
| 3.7 | Sharpness 100% | **PASS** | detail 30.6% → 65.5% |
| 3.8 | Sharpness 0% | **PASS** | detail 30.6% → 12.5% |
| 3.9 | Sharpness 30% (default) is not a visible blur | **PASS** | sub-pixel radius at intermediate resolution |
| 3.10 | Compression 85% | **PASS** | detail → 5.6%, 8×8 blocking + banding |
| 3.11 | Compression 0% (default) costs nothing | **PASS** | filter skipped entirely |
| 3.12 | Noise 80% | **PASS** | HF energy rises as expected for grain |
| 3.13 | Noise 0% (default) costs nothing | **PASS** | filter skipped entirely |
| 3.14 | Blur is off by default | **PASS** | `blurEnabled = false` |
| 3.15 | Aspect ratio preserved, never stretched | **PASS** | `intermediateSize(forSource:)` matches on height; `fitToOutput` letterboxes |
| 3.16 | Output is always 1280×720 | **PASS** | all dumps 1280×720 |
| 3.17 | Preset change takes effect without restarting capture | **PASS** | settings read per frame under lock |

## 4. Performance

60-second soak, Low preset, Debug build (unoptimised Swift — Release is faster).

| # | Metric | Target | Measured | Result |
|---|---|---|---|---|
| 4.1 | Frame rate | ≥30 fps | 29.6–30.1 fps | **PASS** |
| 4.2 | Processing latency | low | 4.28–4.87 ms | **PASS** |
| 4.3 | Dropped frames | no accumulation | 3 total, all at startup, flat after | **PASS** |
| 4.4 | Memory growth | none | 134.2 → 134.4 MB over 60 s | **PASS** |
| 4.5 | CPU | modest | ~23% of one core | **PASS** |
| 4.6 | Main thread not in the frame path | required | preview ≤20 fps, counters polled at 2 Hz | **PASS** |
| 4.7 | Bounded queues everywhere | required | busy-flag drop in pipeline; depth-3 cap on sink | **PASS** |

## 5. Lifecycle

| # | Check | Result |
|---|---|---|
| 5.1 | Launch with no windows open still starts capture | **PASS** |
| 5.2 | Preview window open/close/reopen leaves memory flat | **PASS** |
| 5.3 | Preview rendering stops when the window closes | **PASS** (`setPreviewActive(false)`) |
| 5.4 | Settings persist across relaunch | **PASS** (App Group JSON) |
| 5.5 | Corrupt/partial settings fall back to defaults | **PASS** (tolerant `init(from:)` + `sanitized`) |
| 5.6 | Quit releases the camera | **PASS** |
| 5.7 | Sleep/wake | **MANUAL** |
| 5.8 | Malformed frame does not crash | **PASS** (nil-guarded, frame dropped) |

## 6. Virtual camera — BLOCKED on notarization credentials

These cannot run until the extension installs. The blocker is a missing
credential, not a code defect.

### What the blocker actually is (measured, not assumed)

macOS loads a camera system extension only from an app Gatekeeper accepts.
Three signing configurations were built and installed to `/Applications` and
tested on this machine:

| Build | `spctl -a -t exec` | `sysextd` result |
|---|---|---|
| Apple Development signed | `rejected` | refused |
| Developer ID signed, not notarized | `rejected` — `source=Unnotarized Developer ID` | refused |
| Developer ID signed **and notarized** | expected `accepted` | **not yet tested — needs credentials** |

Developer ID signing alone was tested and is **not** sufficient. Notarization is
the gate.

Ruled out along the way, each by direct experiment: stale LaunchServices
registrations, `get-task-allow` in the signature, the App Sandbox, launch
responsibility (Finder vs shell), and Xcode's Debug dylib packaging. The
misleading `OSSystemExtensionError` code 4 and the
`no policy, cannot allow apps outside /Applications` log line are both generic
refusal messages, confirmed by the strings in `sysextd` itself.

| # | Check | Result |
|---|---|---|
| 6.1 | `systemextensionsctl list` shows the extension activated | **BLOCKED** |
| 6.2 | "Fuzzcam" appears in `system_profiler SPCameraDataType` | **BLOCKED** |
| 6.3 | Selectable in QuickTime Player | **BLOCKED** |
| 6.4 | Selectable in Google Meet (Chrome) | **BLOCKED** |
| 6.5 | Selectable in Zoom | **BLOCKED** |
| 6.6 | Selectable in Microsoft Teams | **BLOCKED** |
| 6.7 | Receiving app gets the **processed** feed, not the original | **BLOCKED** |
| 6.8 | Changing preset changes what the meeting app receives | **BLOCKED** |
| 6.9 | Placeholder card shows when the app is not running | **BLOCKED** |
| 6.10 | Extension survives the app quitting and relaunching | **BLOCKED** |

What *is* verified about this path today:

- A correct Developer ID artifact is produced end to end: archive → export →
  deep signature valid, both app and extension Developer ID signed, no
  `get-task-allow`, extension correctly embedded.
- The app submits a well-formed activation request — `sysextd` receives, parses
  it and reaches its trust check, failing on policy rather than on bad input.
- `VirtualCameraSink` reports "not installed yet" and retries every 3 seconds
  without spinning or crashing; the app runs at full frame rate indefinitely
  with the extension absent.

### To unblock and finish section 6

```bash
# 1. One-time: app-specific password from appleid.apple.com
xcrun notarytool store-credentials fuzzcam-notary \
  --apple-id "your-apple-id@example.com" --team-id C37NWJLS6S --password "xxxx-xxxx-xxxx-xxxx"

# 2. Build, notarize, staple, assert Gatekeeper acceptance
./scripts/release.sh

# 3. Install and activate
rm -rf /Applications/Fuzzcam.app
cp -R build/export/Fuzzcam.app /Applications/
open /Applications/Fuzzcam.app
#    approve in System Settings > General > Login Items & Extensions

# 4. Confirm
systemextensionsctl list
system_profiler SPCameraDataType | grep -A2 Fuzzcam
```

Then walk 6.1–6.10. For 6.7, the check that matters: point the camera at fine
detail (text on a page) and confirm the meeting app's self-view shows it
illegible at Very Low and legible at Original.
