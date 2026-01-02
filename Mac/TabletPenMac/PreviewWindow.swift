import AppKit
import CoreVideo
import QuartzCore
import VideoToolbox

/// Window for displaying decoded video frames for loopback testing.
/// Uses Core Animation layer for efficient pixel buffer display.
class PreviewWindow: NSWindow {
    private let videoLayer = CALayer()
    private var lastFrameTime: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var fpsLabel: NSTextField!

    // FPS calculation
    private var fpsFrameCount: Int = 0
    private var fpsStartTime: UInt64 = 0
    private var currentFPS: Double = 0

    init() {
        let contentRect = NSRect(x: 100, y: 100, width: 640, height: 400)
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        title = "Mac Loopback Preview (Encode → Decode)"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 320, height: 200)

        // Setup content view
        let contentView = NSView(frame: contentRect)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        self.contentView = contentView

        // Setup video layer
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        contentView.layer?.addSublayer(videoLayer)

        // Setup FPS label
        fpsLabel = NSTextField(labelWithString: "FPS: --")
        fpsLabel.textColor = .green
        fpsLabel.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        fpsLabel.isBezeled = false
        fpsLabel.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(fpsLabel)

        NSLayoutConstraint.activate([
            fpsLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            fpsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10)
        ])

        // Layout video layer when window resizes
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            self?.layoutVideoLayer()
        }

        contentView.postsFrameChangedNotifications = true
        layoutVideoLayer()

        fpsStartTime = getCurrentTimeNanos()
    }

    private func layoutVideoLayer() {
        guard let contentView = contentView else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = contentView.bounds
        CATransaction.commit()
    }

    /// Display a decoded pixel buffer.
    func displayFrame(_ pixelBuffer: CVPixelBuffer, timestamp: UInt64) {
        frameCount += 1

        // Update FPS every second
        fpsFrameCount += 1
        let now = getCurrentTimeNanos()
        let elapsed = now - fpsStartTime

        if elapsed >= 1_000_000_000 { // 1 second
            currentFPS = Double(fpsFrameCount) * 1_000_000_000.0 / Double(elapsed)
            fpsFrameCount = 0
            fpsStartTime = now

            DispatchQueue.main.async { [weak self] in
                self?.fpsLabel.stringValue = String(format: "FPS: %.1f", self?.currentFPS ?? 0)
            }
        }

        // Convert pixel buffer to CGImage
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)

        guard let image = cgImage else { return }

        // Display on layer (already on main thread from caller)
        CATransaction.begin()
        CATransaction.setDisableActions(true) // No animation for smooth playback
        videoLayer.contents = image
        CATransaction.commit()

        lastFrameTime = timestamp
    }

    /// Get stats string.
    func getStats() -> String {
        return String(format: "Mac Preview: %.1f FPS, %llu frames", currentFPS, frameCount)
    }
}
