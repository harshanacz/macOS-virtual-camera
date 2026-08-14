import SwiftUI

/// Displays a `CGImage` by assigning it straight to a layer's contents.
///
/// Deliberately not `Image(decorative:)`: at 20 updates per second that path
/// re-enters SwiftUI's diffing machinery for every frame. Handing the image to
/// Core Animation costs one property assignment and no layout.
struct FrameLayerView: NSViewRepresentable {

    let image: CGImage?

    func makeNSView(context: Context) -> LayerBackedView {
        let view = LayerBackedView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.contentsGravity = .resizeAspect
        view.layer?.minificationFilter = .trilinear
        // Nearest-neighbour on the way up keeps the "cheap webcam" pixels honest
        // instead of smoothing them back into something soft.
        view.layer?.magnificationFilter = .nearest
        return view
    }

    func updateNSView(_ view: LayerBackedView, context: Context) {
        view.layer?.contents = image
    }

    final class LayerBackedView: NSView {
        override var isFlipped: Bool { true }
        override func makeBackingLayer() -> CALayer { CALayer() }
    }
}

/// The preview window.
///
/// Minimal by default — feed, toggle, quality, frame rate. Everything a
/// developer would want beyond that is behind the metrics toggle in Settings.
struct PreviewWindowView: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Picker("", selection: $model.previewMode) {
                ForEach(AppModel.PreviewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.black)

                if model.previewImage != nil {
                    FrameLayerView(image: model.previewImage)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    placeholder
                }

                if model.configuration.showDeveloperMetrics {
                    metricsOverlay
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)

            footer
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 430)
        .onAppear { model.setPreviewActive(true) }
        .onDisappear { model.setPreviewActive(false) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isCapturing ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text("Quality: \(model.configuration.preset.displayName)")
                    .font(.callout)
                if model.previewMode == .processed, model.configuration.preset != .original {
                    Text("\(model.processingDescription) processing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if model.metrics.framesPerSecond > 0 {
                Text("\(Int(model.metrics.framesPerSecond.rounded())) FPS")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let error = model.currentError {
            ContentUnavailableView {
                Label(error.message, systemImage: "video.slash")
            } description: {
                Text(error.recoverySuggestion)
            } actions: {
                if error.needsPrivacySettings {
                    Button("Open Privacy Settings…") { CameraPermission.openPrivacySettings() }
                } else {
                    Button("Try Again") { model.retry() }
                }
            }
        } else {
            ProgressView().controlSize(.large)
        }
    }

    /// Developer diagnostics. Hidden unless explicitly switched on in Settings,
    /// so the production preview stays uncluttered.
    private var metricsOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            metricRow("in", size: model.metrics.inputSize)
            metricRow("proc", size: model.metrics.processingSize)
            metricRow("out", size: model.metrics.outputSize)
            Text(String(format: "latency  %.1f ms", model.metrics.latencyMilliseconds))
            Text("dropped  \(model.metrics.droppedFrames)")
            Text("sink  \(model.virtualCamera.framesDelivered) sent / \(model.virtualCamera.framesDropped) dropped")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white.opacity(0.85))
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
    }

    private func metricRow(_ label: String, size: CGSize) -> Text {
        Text("\(label)  \(Int(size.width))×\(Int(size.height))")
    }
}
