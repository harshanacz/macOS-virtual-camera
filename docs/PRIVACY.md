# Privacy

**Fuzzcam processes your camera locally on your Mac. Video is not uploaded or recorded.**

## What Fuzzcam does with your camera

Frames go from the camera into memory, through a Core Image filter chain on the
GPU, and out to the virtual camera. That is the entire journey. Every step
happens inside your own machine, in two processes that both belong to Fuzzcam.

## What Fuzzcam does not do

- No network access. The app makes no outbound connections; there is no
  analytics, telemetry, crash reporting, or update check.
- No recording. Frames live in a small pool of reused buffers and are overwritten
  roughly thirty times a second. Nothing is written to disk.
- No screenshots or screen recording. Fuzzcam never asks for Screen Recording
  permission because it never captures your screen.
- No microphone. Fuzzcam is video only and does not request audio permission.
- No collection of anything about you, your device, or your meetings.

## Permissions Fuzzcam asks for, and why

| Permission | Why it is needed |
|---|---|
| **Camera** | To read frames from your webcam. This is the entire product. |
| **System Extension approval** | To publish "Fuzzcam" as a camera other apps can select. macOS requires you to approve this once. |

Nothing else is requested. Fuzzcam does not ask for Files, Contacts, Screen
Recording, Location, or Full Disk Access.

## Data stored on disk

Only your settings — the selected camera, quality preset and slider values —
written as a small JSON blob to the App Group container shared between the app
and the camera extension:

```
~/Library/Group Containers/C37NWJLS6S.com.harshanacz.Fuzzcam/
```

Delete that folder to reset Fuzzcam completely.

In debug builds only, setting `FUZZCAM_DUMP=1` writes a handful of sample frames
into that container so the processing pipeline can be verified. That code is
compiled out of release builds entirely and never runs unless you set the
variable yourself.

## Security posture

- The app and the camera extension both run in the **App Sandbox**.
- The app runs with the **hardened runtime**.
- No kernel extensions. The virtual camera is a userspace Core Media I/O system
  extension, which is Apple's supported mechanism.
- No macOS privacy or security control is bypassed, disabled, or worked around.
  Camera access is requested through the standard TCC prompt, and the extension
  is installed through `OSSystemExtensionManager` with the approval step macOS
  requires.

## One thing worth knowing

While a meeting app is using the Fuzzcam camera, your **real** camera is open —
Fuzzcam has to read it to degrade it. Your Mac's green camera indicator will be
lit, and that is correct: a camera really is in use.
