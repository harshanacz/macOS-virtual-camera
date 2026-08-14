# Development camera (temporary)

**This is a stop-gap, not the product.** It exists only until the Fuzzcam camera
extension can be notarized. All of it is behind `#if DEBUG` and is absent from
Release builds. The production Camera Extension is untouched and ready.

---

## Why this exists

macOS only loads a camera system extension from an app Gatekeeper accepts. That
means notarized, and notarization needs Apple ID access. Verified on this
machine:

| Path | Result |
|---|---|
| Apple Development signed | refused |
| Developer ID, unnotarized | refused |
| Legacy DAL plug-in | dead — deprecated, and Zoom runs hardened without `disable-library-validation`, so it would not load one |
| `spctl` per-app exception | removed in macOS 26 (`spctl --add` no longer exists) |
| SIP off + developer mode | ruled out |

So **no camera device named "Fuzzcam" can exist yet**. What *can* work is
routing the real processed frames through a virtual camera that is already
notarized. OBS is free and notarized, and its camera extension installs without
issue.

```
MacBook camera
  → Fuzzcam FrameProcessor            (Low / Very Low — the real pipeline)
  → "Fuzzcam Dev Output" window       (1280×720 backing pixels, exact)
  → OBS macOS Screen Capture (window)
  → OBS Virtual Camera                ← Zoom selects this
  → Zoom
```

The window is fed the **same `VideoFrame` objects** the Processed preview
receives, straight off the same `FrameProcessor`. The untouched camera image is
never drawn there, so what OBS captures can only be the degraded output.

**In Zoom the camera is called "OBS Virtual Camera", not "Fuzzcam".** That is
unavoidable without notarization.

---

## One-time setup

### 1. Run Fuzzcam from Xcode

Open `Fuzzcam.xcodeproj`, scheme **Fuzzcam**, Debug, and Run.

To have the output window open automatically, add an environment variable to the
scheme — **Product → Scheme → Edit Scheme → Run → Arguments → Environment
Variables**:

| Name | Value |
|---|---|
| `FUZZCAM_DEV_OUTPUT` | `1` |

Otherwise open it from the menu bar: **Fuzzcam → Start Development Camera
Output…**

A small black window titled **Fuzzcam Dev Output** appears, showing the degraded
feed. Park it anywhere; it does not need to stay in front, and it never takes
focus.

### 2. Set the quality

Menu bar → **Quality → Low** (or **Very Low**). Changes apply on the next frame.

### 3. Configure OBS

1. Open **OBS**. Skip or run the auto-configuration wizard — it does not matter.
2. **Settings → Video**: set *Base (Canvas) Resolution* and *Output (Scaled)
   Resolution* both to **1280×720**. Set FPS to **30**. Apply.
3. In **Sources**, click **+** → **macOS Screen Capture**. Name it *Fuzzcam*.
4. In its properties:
   - **Method**: `Window`
   - **Window**: `Fuzzcam Dev Output` (owned by *Fuzzcam*)
   - Uncheck **Show Window Title Bar** so only the video is captured.
   - Uncheck **Show Cursor**.
5. macOS will ask for **Screen Recording** permission for OBS. Grant it, then
   restart OBS.
6. Right-click the source → **Transform → Fit to Screen** (`⌘F`).

### 4. Start the OBS virtual camera

Click **Start Virtual Camera** in the Controls panel.

The first time, macOS blocks the OBS camera extension. Approve it in
**System Settings → General → Login Items & Extensions → Camera Extensions →
enable OBS**, then click Start Virtual Camera again.

Confirm:

```bash
systemextensionsctl list | grep -i obs
system_profiler SPCameraDataType | grep -i "OBS"
```

### 5. Select it in Zoom

**Zoom → Settings → Video → Camera → OBS Virtual Camera**

Zoom caches its device list, so if it does not appear, quit and reopen Zoom.

---

## Every time after that

1. Run Fuzzcam from Xcode (window opens if the env var is set).
2. Pick a quality preset.
3. Open OBS, click **Start Virtual Camera**.
4. Zoom → Settings → Video → **OBS Virtual Camera**.

---

## Checking it is really the degraded feed

The point of the exercise is that Zoom gets *processed* frames, not the raw
camera. Two ways to confirm:

- Hold printed text up to the camera. At **Very Low** it should be illegible in
  Zoom's self-view; switch to **Original** and it should become readable. If it
  is readable at Very Low, Zoom is on the wrong camera.
- Open Fuzzcam's **Preview** window and toggle **Original / Processed**. The
  Processed view and the Zoom self-view must look the same. They are the same
  frames.

---

## Escape hatches

All optional, set as scheme environment variables:

| Variable | Effect |
|---|---|
| `FUZZCAM_DEV_OUTPUT=1` | Open the output window automatically at launch |
| `FUZZCAM_DEV_OUTPUT_BORDERLESS=1` | No title bar at all, so the OBS checkbox does not matter. Drag the window by its body. |
| `FUZZCAM_DEV_OUTPUT_CGIMAGE=1` | Render via `CGImage` instead of handing Core Animation the `IOSurface`. Slower. Use only if the window renders black. |
| `FUZZCAM_METRICS=1` | Log fps / latency / resolutions every 2 s |

---

## Known limitations

- The camera is named **OBS Virtual Camera** in Zoom.
- Fuzzcam, OBS and Zoom must all be running.
- One extra frame of latency from the window-capture hop.
- The window must not be **minimised** — ScreenCaptureKit can capture an
  occluded or background window, but not a minimised one.
- Debug builds only.

---

## Removing it

Nothing to undo in the project — it is all `#if DEBUG` and never ships. To
remove the tooling:

```bash
brew uninstall --cask obs
systemextensionsctl uninstall 2MMRE5MTB8 com.obsproject.obs-studio.mac-camera-extension
```

Once the Fuzzcam extension is notarized (`./scripts/release.sh`), drop this whole
path: install the notarized app, approve the extension, and select **Fuzzcam**
directly in Zoom. See [INSTALLATION.md](INSTALLATION.md).
