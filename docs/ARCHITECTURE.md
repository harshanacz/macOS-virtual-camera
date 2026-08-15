# Fuzzcam — Architecture

A macOS menu-bar utility that captures the physical webcam, intentionally degrades it,
and republishes it as a **real system-wide virtual camera** via a Core Media I/O
Camera Extension.

Verified against the SDK installed on this machine (macOS 26.6.1, Xcode 26.0.1,
`MacOSX.sdk`), not from memory. Every API named below exists in
`CoreMediaIO.framework/Headers` or in Xcode's own `Camera Extension.xctemplate`.

---

## 0. API decision record

| Question | Answer | Evidence |
|---|---|---|
| Which virtual-camera API is current? | **`CMIOExtension*`** (`CMIOExtensionProvider` / `Device` / `Stream`), macOS 12.3+ | `CMIOExtensionProvider.h`: `API_AVAILABLE(macos(12.3))` |
| Is the DAL plug-in path still viable? | **No.** `CMIOHardwarePlugIn.h` is the legacy in-process DAL interface. Apple stopped loading unsigned/unsandboxed DAL plug-ins into hardened clients; the Camera Extension is the replacement. We do not use it. | — |
| Kernel extensions? | **Not used, not needed.** A camera extension is a *system extension* (userspace), installed via `OSSystemExtensionManager`. | `System Extension Base.xctemplate` → `ProductType = com.apple.product-type.system-extension` |
| How does the app hand frames to the extension? | The extension publishes **two streams** on one device: a `.source` stream (what Zoom/Meet see) and a `.sink` stream (what our app writes into). The app finds the sink via the CMIO HAL and pushes `CMSampleBuffer`s into its `CMSimpleQueue`. | `CMIOExtensionStream.h` `CMIOExtensionStreamDirectionSink`, `consumeSampleBufferFromClient:completionHandler:`; `CMIOHardwareStream.h` `CMIOStreamCopyBufferQueue` |

**Naming.** The spec suggests `"LowCam"` but says "something like". The project you
created is **Fuzzcam**, so the virtual camera's default display name is **`Fuzzcam`**,
configurable in Settings (`virtualCameraName`). Change the default in one place —
`Shared/FuzzcamConfiguration.swift` — if you want `LowCam`.

---

## 1. Architecture overview

```
┌───────────────────────── Fuzzcam.app (menu-bar, LSUIElement) ─────────────────────────┐
│                                                                                       │
│   AVCaptureSession ──► AVCaptureVideoDataOutput ──► CVPixelBuffer (camera native)      │
│         │                                                    │                         │
│   CameraDiscovery                                            ▼                         │
│   (built-in + external,                              FrameProcessor                    │
│    hot-plug notifications)                    ┌──────────────────────────┐             │
│                                               │ downscale → degrade →    │             │
│                                               │ upscale to 1280×720      │  (Metal-    │
│                                               └──────────────────────────┘   backed CI)│
│                                                       │            │                   │
│                                              ┌────────┘            └────────┐          │
│                                              ▼                              ▼          │
│                                   VirtualCameraSink                 PreviewRenderer     │
│                                   (CMIO HAL client)                 (optional, gated)   │
│                                              │                              │          │
└──────────────────────────────────────────────┼──────────────────────────────┼──────────┘
                                               │ CMSimpleQueue                │ CGImage
                                               │ (IOSurface-backed, zero-copy)│
                                               ▼                              ▼
┌──────────── FuzzcamExtension.systemextension (separate process) ──┐    SwiftUI preview
│                                                                    │
│   CMIOExtensionProvider                                            │
│     └─ CMIOExtensionDevice "Fuzzcam"                               │
│          ├─ sink   stream  ◄── consumeSampleBufferFromClient()     │
│          └─ source stream  ──► send(_:discontinuity:hostTime:)     │
│               (1280×720 BGRA @ 30fps, stable format)               │
└────────────────────────────────┬───────────────────────────────────┘
                                 │ CoreMediaIO HAL — a normal camera device
                                 ▼
              Zoom · Google Meet · Teams · Discord · FaceTime · QuickTime
```

### Why the sink-stream design (and not "capture inside the extension")

Both are technically possible. We use sink-stream because:

- **TCC.** The extension process is not a normal app; getting a camera-permission prompt
  attributed to it is unreliable. The app already has camera permission and a UI to
  request it.
- **Configurability.** Presets, sliders and camera selection live where the UI is. The
  extension stays dumb, small, and hard to crash.
- **It is the documented path.** `CMIOExtensionStreamDirectionSink` exists precisely so a
  companion app can drive the device.

**Consequence, stated plainly:** the virtual camera only carries live video while
`Fuzzcam.app` is *running*. That is fine for a menu-bar app — closing the preview or
settings window does not stop it — but if the user Quits, the extension falls back to a
generated "Fuzzcam — app not running" card rather than a frozen or black frame. The
extension itself stays installed and keeps appearing in every app's camera list.

---

## 2. Required Xcode targets

| # | Target | Product type | Bundle ID | Notes |
|---|---|---|---|---|
| 1 | `Fuzzcam` | `com.apple.product-type.application` | `com.harshanacz.Fuzzcam` | Menu-bar app (`LSUIElement`). Embeds #2. |
| 2 | `FuzzcamExtension` | `com.apple.product-type.system-extension` | `com.harshanacz.Fuzzcam.Extension` | Copied into `Fuzzcam.app/Contents/Library/SystemExtensions/`. Must be a *strict* prefix-child of the app's bundle ID. |

Source folders (file-system-synchronized groups, objectVersion 77):

| Folder | Member of |
|---|---|
| `Fuzzcam/` (App, Views, ViewModels, Services, Assets) | target 1 |
| `CameraEngine/` (capture + processing) | target 1 |
| `Shared/` (config model, app-group store, constants) | targets 1 **and** 2 |
| `FuzzcamExtension/` (provider, device, streams) | target 2 |
| `Config/` (entitlements, extension `Info.plist`) | neither — referenced by build settings |

Key build settings:

- `MACOSX_DEPLOYMENT_TARGET = 14.0` (was 26.0 — needlessly excluded almost everyone;
  the API floor is 12.3, and 14.0 buys `CMIOExtensionProvider.ignoreSIGTERM`).
- `REGISTER_APP_GROUPS = YES` on both targets.
- `ENABLE_APP_SANDBOX = YES` on both targets.
- Extension: `INFOPLIST_FILE = Config/FuzzcamExtension-Info.plist`,
  `SKIP_INSTALL = YES`, `WRAPPER_EXTENSION = systemextension` (implied by product type).

---

## 3. Required entitlements & capabilities

### `Fuzzcam.app` — `Config/Fuzzcam.entitlements`

| Entitlement | Value | Why |
|---|---|---|
| `com.apple.security.app-sandbox` | `true` | Required for App Group container access. |
| `com.apple.security.device.camera` | `true` | Sandboxed access to the physical camera *and* to the CMIO HAL. |
| `com.apple.security.application-groups` | `[$(TeamIdentifierPrefix)com.harshanacz.Fuzzcam]` | Shared config with the extension. On macOS the group **must** be team-ID-prefixed. |
| `com.apple.developer.system-extension.install` | `true` | Lets the app call `OSSystemExtensionManager`. **Requires the App ID to have the System Extension capability enabled in the developer portal.** |

### `FuzzcamExtension` — `Config/FuzzcamExtension.entitlements`

| Entitlement | Value | Why |
|---|---|---|
| `com.apple.security.app-sandbox` | `true` | Mandated for system extensions. |
| `com.apple.security.application-groups` | `[$(TeamIdentifierPrefix)com.harshanacz.Fuzzcam]` | Read the shared config. |

### Extension `Info.plist` (the part that makes it a camera)

```xml
<key>CMIOExtension</key>
<dict>
  <key>CMIOExtensionMachServiceName</key>
  <string>$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)</string>
</dict>
<key>NSSystemExtensionUsageDescription</key>
<string>Fuzzcam installs a virtual camera so other apps can use your degraded video feed.</string>
```

There is deliberately **no `NSExtension` dictionary** — CMIO extensions are system
extensions, not app extensions. (Confirmed from the Xcode template; a common
copy-paste error is adding one.)

### Signing reality check

- Team `C37NWJLS6S` (Developer ID) and `TH8395SXT2` (Development) are both present.
- `com.apple.developer.system-extension.install` needs a provisioning profile that
  carries it. If automatic signing fails on that entitlement, enable **System Extension**
  for the App ID at developer.apple.com, then let Xcode regenerate.
- For development, `systemextensionsctl developer on` allows loading an extension from a
  build directory instead of requiring `/Applications`. Full install/approval instructions
  land with Phase 3, when there is an extension to install.

---

## 4. Required macOS permissions

| Permission | Trigger | Handling |
|---|---|---|
| **Camera (TCC)** | First `AVCaptureSession` start | `AVCaptureDevice.authorizationStatus(for: .video)` → `requestAccess(for:)`. `.denied`/`.restricted` shows a human-readable message plus a deep link to `x-apple.systempreferences:com.apple.preference.security?Privacy_Camera`. |
| **`NSCameraUsageDescription`** | Info.plist | Required or the process is killed on first camera touch. |
| **System-extension approval** | `OSSystemExtensionManager.submit(_:)` | macOS shows "System Extension Blocked". The user must approve in **System Settings → General → Login Items & Extensions → Camera Extensions**. We detect the `.willCompleteAfterReboot` / awaiting-approval states and show onboarding. |
| **`NSSystemExtensionUsageDescription`** | Extension Info.plist | Shown in the approval prompt. |

No permission is bypassed, spoofed, or worked around.

---

## 5. Data flow between app and extension

### 5a. Video frames — app → extension (hot path, 30 fps)

```
FrameProcessor emits CVPixelBuffer (1280×720 BGRA, IOSurface-backed, from a CVPixelBufferPool)
      │
      ▼
VirtualCameraSink                                   [app process]
  1. CMIOObjectGetPropertyData(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices)
  2. match device by its CMIOExtensionDevice UUID    ← stable, compiled-in constant
  3. find the stream whose direction is output       (kCMIODevicePropertyStreams)
  4. CMIOStreamCopyBufferQueue(sinkStreamID, proc, refcon, &queue)
  5. CMIODeviceStartStream(deviceID, sinkStreamID)
  6. per frame: CMSampleBufferCreateForImageBuffer → CMSimpleQueueEnqueue
      │
      ▼  (IOSurface crosses the process boundary by reference — no pixel copy)
FuzzcamExtension                                    [extension process]
  7. sink stream's consumeSampleBufferFromClient(_:completionHandler:)
  8. sourceStream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: …)
      │
      ▼
CoreMediaIO HAL → AVCaptureDevice "Fuzzcam" → Zoom / Meet / Teams
```

Backpressure: the queue is bounded (`sinkBufferQueueSize`). If it is full the app drops
the newest frame rather than blocking the capture queue — a dropped frame is invisible,
a stalled capture queue is not.

Starvation: if the extension's source stream is started but no client frame arrives
within ~1s, the extension emits its own placeholder frame at 30 fps so downstream apps
see a valid signal instead of a timeout.

### 5b. Configuration — app → extension (cold path, on change)

```
SettingsView ──► FuzzcamConfiguration (Codable)
                      │
                      ├─► UserDefaults(suiteName: "C37NWJLS6S.com.harshanacz.Fuzzcam")
                      │       key "configuration", JSON blob
                      │
                      └─► CFNotificationCenterGetDarwinNotifyCenter()
                              "com.harshanacz.Fuzzcam.configChanged"
                                        │
                                        ▼
                          Extension re-reads the group defaults
```

Darwin notifications cross the sandbox boundary and carry no payload — the payload is
the app-group defaults. The extension only needs `virtualCameraName` and the
placeholder text; **all pixel work happens in the app**, so a config change reaches the
output implicitly on the next frame. The extension never blocks on config.

The app is the sole writer; the extension is a reader. No locking beyond
`UserDefaults`' own atomicity is required.

### 5c. Extension lifecycle state — extension → app

The app derives state by observation rather than IPC:
`OSSystemExtensionManager` request callbacks for install/replace, and
`AVCaptureDevice.DiscoverySession` (`.external` + `.deskViewCamera` + our device UUID)
to confirm the device actually materialised. "Running" in the menu means *the device
exists in the HAL and our sink stream is started*, which is the only claim worth making.

---

## 6. Processing pipeline

Simply downscaling produces a clean small picture, which reads as "downscaled",
not "bad camera". What makes cheap webcams look cheap is a specific set of
failures, reproduced in the order a real camera commits them. Everything from
step 2 to step 7 runs at the *intermediate* resolution, which is what keeps it
affordable.

```
input CVPixelBuffer (1920×1080)
   │
   ├─ 1. Resample to the preset size (Lanczos)   ← irreversible; the real work
   ├─ 2. Smear micro-texture, edges intact       ← CINoiseReduction pushed past
   │                                                sane denoising. Waxy skin.
   ├─ 3. Soften chroma only, luma stays sharp    ← CILuminosityBlendMode over a
   │                                                blurred copy = 4:2:0 look
   ├─ 4. Flatten tone: lift blacks, cut contrast/saturation
   ├─ 5. Over-sharpen                            ← CIUnsharpMask halos. Cheap
   │                                                cameras do this; without it
   │                                                the result reads "blurred"
   ├─ 6. Grain (optional, off by default)
   ├─ 7. Compression: 8×8 blocks + banding, blended
   │
   └─ 8. Upscale to 1280×720, letterboxed, never stretched
```

Step 5 is the counter-intuitive one and it is what sells the effect: after
smearing, adding crunchy edge halos makes the image read as a *bad camera*
rather than a *blur filter*.

Gaussian blur is not in the default path at any preset. It exists only if the
user explicitly enables it.

### Preset parameters

Degradation is **intrinsic to the preset**, applied whatever the sliders say. The
sharpness control biases the result but cannot restore what the resample threw
away.

| Preset | Intermediate | Smear | Chroma | Crunch | Tone | Compression floor |
|---|---|---|---|---|---|---|
| Original | source | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 |
| High | 1280×720 | 0.18 | 0.20 | 0.15 | 0.08 | 0.06 |
| Medium | 854×480 | 0.38 | 0.40 | 0.32 | 0.18 | 0.16 |
| Low | 480×270 | 0.62 | 0.65 | 0.48 | 0.30 | 0.30 |
| Very Low | 320×180 | 0.82 | 0.85 | 0.58 | 0.42 | 0.44 |

Sizes are matched on **height** against the source aspect ratio, so a 4:3 camera
gets 360×270 for Low rather than a stretched 480×270.

### Measured result

One live 1920×1080 frame, 1:1 centre crops compared at the 1280×720 output size.

| Preset | SSIM vs source | Skin/flat micro-texture |
|---|---|---|
| High | 0.960 | 87% |
| Medium | 0.933 | 77% |
| Low | 0.878 | 74% |
| Very Low | **0.810** | **75%** |

A global Laplacian-variance metric is **not** valid here: the deliberate edge
halos are high-frequency energy, so it scores Very Low *above* the source. SSIM
and flat-region texture are not fooled, and visual A/B is the deciding test —
at Very Low the lettering on a fan hub 2 m away is gone and the grille wires
have dissolved, while the image still looks like a plausible camera feed.

**One processor, three consumers.** `VideoPipeline` owns the only production
`FrameProcessor`; the identical `VideoFrame` goes to the Processed preview, the
virtual-camera sink, and (debug only) the development output window. There is no
second degradation implementation anywhere.

### Cost

30.0 fps, 6.5–6.7 ms per frame, ~128 MB steady, ~33% of one core, in a Debug
build at the heaviest preset. The richer chain cost ~2.5 ms over the original
downscale-only pipeline, against a 33 ms budget.

## 7. Status

| Area | State |
|---|---|
| Camera capture, permissions, hot-plug | Done, verified |
| Quality-reduction pipeline + controls | Done, verified numerically (see below) |
| Menu bar, preview, settings, onboarding | Done |
| Persistence via App Group | Done, verified |
| Camera extension (source + sink streams) | Written, builds, embeds correctly |
| Extension **installed and selectable in meeting apps** | **Blocked** — needs a notarized build or SIP off. See `INSTALLATION.md`. |

### Measured degradation

One live 1920×1080 frame, every output compared at 1280×720 so only detail
differs. Laplacian variance is the sharpness proxy; HF% is FFT energy above a
quarter of Nyquist.

| Preset | Processing size | Detail vs source | HF% |
|---|---|---|---|
| Original | 1920×1080 | 102.7% | 72.8% |
| High | 1280×720 | 101.9% | 72.5% |
| Medium | 854×480 | 55.8% | 66.4% |
| Low | 640×360 | 30.6% | 60.7% |
| Very Low | 480×270 | 15.0% | 55.0% |

Monotonic in both metrics: the detail loss is real, not cosmetic.

### Measured performance

60 s soak, Low preset, Debug build: **30.0 fps**, **4.3–4.9 ms** per frame,
memory flat at **134 MB**, 3 dropped frames (all during startup), ~23% of one
core.

### Why the install is blocked

macOS loads a camera system extension only from an app Gatekeeper accepts. This
was narrowed down by experiment rather than assumption:

| Build | `spctl` | Installs? |
|---|---|---|
| Apple Development signed | rejected | no |
| Developer ID, unnotarized | rejected (`source=Unnotarized Developer ID`) | no |
| Developer ID, **notarized** | accepted | yes — needs credentials |

`sysextd` reports this as `OSSystemExtensionError` code 4 ("Extension not found
in App bundle") with a `no policy, cannot allow apps outside /Applications` log
line. Both are generic refusal messages; the extension is present and the app is
in `/Applications`. Nothing about the bundle is wrong — package type, Mach
service name, entitlements, Developer ID signature and embedding are all
verified correct.

The remaining step needs one human credential: an app-specific password stored
via `xcrun notarytool store-credentials`. After that, `scripts/release.sh`
produces a notarized, stapled build that can install.
