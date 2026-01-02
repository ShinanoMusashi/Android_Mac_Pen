import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Modern screen capture using ScreenCaptureKit (macOS 12.3+).
/// GPU-accelerated with lower CPU overhead than CGDisplayStream.
@available(macOS 12.3, *)
class SCKScreenCapture: NSObject, SCStreamDelegate, SCStreamOutput {

    private var stream: SCStream?
    private var isCapturing = false
    private let captureQueue = DispatchQueue(label: "SCKScreenCapture", qos: .userInteractive)

    /// Callback for each captured frame.
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?

    /// Current capture configuration.
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var fps: Int = 60

    /// Get the main display for capture.
    private func getMainDisplay() async throws -> SCDisplay {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "SCKScreenCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        return display
    }

    /// Start capturing the screen.
    func start(targetWidth: Int, targetHeight: Int, fps: Int = 60) async -> Bool {
        guard !isCapturing else {
            print("Screen capture already running")
            return true
        }

        self.width = targetWidth
        self.height = targetHeight
        self.fps = fps

        do {
            let display = try await getMainDisplay()

            // Create content filter for the main display
            let filter = SCContentFilter(display: display, excludingWindows: [])

            // Configure stream for low latency
            let config = SCStreamConfiguration()
            config.width = targetWidth
            config.height = targetHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true

            // Queue depth 3 is minimum for ScreenCaptureKit (lower values are ignored)
            // Process frames immediately to minimize latency
            config.queueDepth = 3

            // Capture at native scale for best quality, let encoder handle scaling
            config.scalesToFit = true

            // Use GPU for color conversion and scaling
            config.colorSpaceName = CGColorSpace.sRGB

            // Create and configure stream
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

            // Start capturing
            try await newStream.startCapture()

            stream = newStream
            isCapturing = true

            print("ScreenCaptureKit started: \(targetWidth)x\(targetHeight) @ \(fps)fps (GPU-accelerated)")
            return true

        } catch {
            print("Failed to start ScreenCaptureKit: \(error)")
            return false
        }
    }

    /// Stop capturing.
    func stop() {
        guard isCapturing else { return }

        Task {
            do {
                try await stream?.stopCapture()
            } catch {
                print("Error stopping capture: \(error)")
            }
            stream = nil
            isCapturing = false
            print("ScreenCaptureKit stopped")
        }
    }

    /// Synchronous stop for cleanup.
    func stopSync() {
        guard isCapturing, let stream = stream else { return }
        isCapturing = false
        self.stream = nil

        // Use semaphore for synchronous stop
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            try? await stream.stopCapture()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.0)
        print("ScreenCaptureKit stopped (sync)")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Get presentation timestamp in nanoseconds
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampNs = UInt64(CMTimeGetSeconds(pts) * 1_000_000_000)

        // Deliver frame immediately
        onFrame?(pixelBuffer, timestampNs)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("ScreenCaptureKit stream stopped with error: \(error)")
        isCapturing = false
    }
}

/// Wrapper that uses ScreenCaptureKit on macOS 12.3+ and falls back to CGDisplayStream on older versions.
class ModernScreenCapture {
    private var sckCapture: Any?  // SCKScreenCapture (type-erased for compatibility)
    private var legacyCapture: ScreenCapture?

    private let useScreenCaptureKit: Bool

    var onFrame: ((CVPixelBuffer, UInt64) -> Void)? {
        didSet {
            if #available(macOS 12.3, *), useScreenCaptureKit {
                (sckCapture as? SCKScreenCapture)?.onFrame = onFrame
            } else {
                legacyCapture?.onFrame = onFrame
            }
        }
    }

    var nativeScreenSize: CGSize {
        if let legacy = legacyCapture {
            return legacy.nativeScreenSize
        }
        // For ScreenCaptureKit, get main screen size
        return NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
    }

    init() {
        // Use ScreenCaptureKit if available (macOS 12.3+)
        if #available(macOS 12.3, *) {
            useScreenCaptureKit = true
            sckCapture = SCKScreenCapture()
            print("Using ScreenCaptureKit (GPU-accelerated)")
        } else {
            useScreenCaptureKit = false
            legacyCapture = ScreenCapture()
            print("Using legacy CGDisplayStream")
        }
    }

    func start(targetWidth: Int, targetHeight: Int, fps: Int = 60) -> Bool {
        if #available(macOS 12.3, *), useScreenCaptureKit {
            guard let sck = sckCapture as? SCKScreenCapture else { return false }
            // Use Task to bridge async/sync
            let semaphore = DispatchSemaphore(value: 0)
            var result = false
            Task {
                result = await sck.start(targetWidth: targetWidth, targetHeight: targetHeight, fps: fps)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5.0)
            return result
        } else {
            return legacyCapture?.start(targetWidth: targetWidth, targetHeight: targetHeight, fps: fps) ?? false
        }
    }

    func stop() {
        if #available(macOS 12.3, *), useScreenCaptureKit {
            (sckCapture as? SCKScreenCapture)?.stopSync()
        } else {
            legacyCapture?.stop()
        }
    }

    func updateROI(_ roi: RegionOfInterest?) {
        // ROI only supported on legacy capture for now
        legacyCapture?.updateROI(roi)
    }

    static func hasScreenRecordingPermission() -> Bool {
        return ScreenCapture.hasScreenRecordingPermission()
    }

    static func requestScreenRecordingPermission() {
        ScreenCapture.requestScreenRecordingPermission()
    }
}
