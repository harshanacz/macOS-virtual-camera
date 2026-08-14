# fuzzcam-virtual-camera

A macOS menu-bar utility that captures the physical webcam, intentionally degrades it with configurable quality presets (retro/low-bandwidth effects), and republishes it as a **system-wide virtual camera** via Apple's modern Core Media I/O (CMIO) Camera Extension.

## 🚀 Features

- **Real Virtual Camera**: Implemented using macOS 12.3+ `CMIOExtension` (System Extension), recognized by Zoom, Google Meet, Microsoft Teams, FaceTime, OBS, and browsers.
- **Intentional Video Degradation**:
  - Downscaling / Pixelation
  - Variable framerate simulation / jitter
  - Artifact & noise injection
  - Audio/Video glitch presets
- **Menu Bar Controls**: Lightweight `LSUIElement` menu-bar companion app for live preview and real-time preset adjustments.
- **Metal-Accelerated Processing**: High-performance CI/Metal frame processing pipeline.

## 📁 Project Structure

```
├── CameraEngine/          # Core capture, video pipeline & frame processing
├── Config/                # Entitlements and Info.plist configurations
├── Fuzzcam/               # Menu bar macOS companion application (SwiftUI)
├── FuzzcamExtension/      # CMIO Virtual Camera System Extension
├── Shared/                # Shared configurations, quality presets & identifiers
├── docs/                  # Architecture, setup, development, and testing guides
└── scripts/               # Build, signing, and notarization release scripts
```

## 📖 Documentation

- [Architecture Guide](docs/ARCHITECTURE.md)
- [Development Setup](docs/DEVELOPMENT.md)
- [Installation & Activation](docs/INSTALLATION.md)
- [Testing & Verification](docs/TESTING.md)
- [Virtual Camera Internals](docs/DEV-CAMERA.md)
- [Privacy & Security](docs/PRIVACY.md)

## 🛠️ Building & Releasing

For building and notarizing the system extension:

```bash
./scripts/release.sh [notarytool-keychain-profile]
```

## 📄 License

MIT
