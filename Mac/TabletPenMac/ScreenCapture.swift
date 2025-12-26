import Foundation
import CoreGraphics
import CoreImage
import AppKit

/// Captures the Mac screen for streaming to Android.
class ScreenCapture {
    private var displayStream: CGDisplayStream?
    private var isCapturing = false
    private let captureQueue = DispatchQueue(label: "ScreenCapture", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Callback for each captured frame.
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?

    /// Current capture configuration.
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var fps: Int = 30

    /// Current region of interest (normalized 0.0-1.0)
    private var currentROI: RegionOfInterest?
    private let roiLock = NSLock()

    /// Buffer for cropped frames
    private var croppedBuffer: CVPixelBuffer?

    /// Get main display ID.
    private var mainDisplayID: CGDirectDisplayID {
        return CGMainDisplayID()
    }

    /// Get the native screen size.
    var nativeScreenSize: CGSize {
        let displayID = mainDisplayID
        let width = CGDisplayPixelsWide(displayID)
        let height = CGDisplayPixelsHigh(displayID)
        return CGSize(width: width, height: height)
    }

    // MARK: - Permission Handling

    /// Check if screen recording permission is granted.
    static func hasScreenRecordingPermission() -> Bool {
        // On macOS 10.15+, we need screen recording permission
        if #available(macOS 10.15, *) {
            // Try to capture a small test image to check permission
            let displayID = CGMainDisplayID()
            if let _ = CGDisplayCreateImage(displayID) {
                return true
            }
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    /// Request screen recording permission.
    static func requestScreenRecordingPermission() {
        if #available(macOS 10.15, *) {
            // This will trigger the permission dialog
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: - Capture Control

    /// Start capturing the screen.
    /// - Parameters:
    ///   - targetWidth: Desired output width (will be scaled if different from native)
    ///   - targetHeight: Desired output height
    ///   - fps: Frames per second
    func start(targetWidth: Int, targetHeight: Int, fps: Int = 30) -> Bool {
        guard !isCapturing else {
            print("Screen capture already running")
            return true
        }

        // Check permission first
        guard ScreenCapture.hasScreenRecordingPermission() else {
            print("Screen recording permission not granted")
            ScreenCapture.requestScreenRecordingPermission()
            return false
        }

        self.width = targetWidth
        self.height = targetHeight
        self.fps = fps

        let displayID = mainDisplayID

        // Configure the display stream
        let properties: [CFString: Any] = [
            CGDisplayStream.minimumFrameTime: 1.0 / Double(fps),
            CGDisplayStream.showCursor: true,
            CGDisplayStream.queueDepth: 3,
        ] as [CFString: Any]

        // Create the display stream
        guard let stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: targetWidth,
            outputHeight: targetHeight,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: properties as CFDictionary,
            queue: captureQueue,
            handler: { [weak self] status, displayTime, frameSurface, updateRef in
                self?.handleFrame(status: status, displayTime: displayTime, frameSurface: frameSurface)
            }
        ) else {
            print("Failed to create display stream")
            return false
        }

        displayStream = stream

        // Start the stream
        let result = stream.start()
        if result == .success {
            isCapturing = true
            print("Screen capture started: \(targetWidth)x\(targetHeight) @ \(fps)fps")
            return true
        } else {
            print("Failed to start display stream: \(result)")
            return false
        }
    }

    /// Stop capturing.
    func stop() {
        guard isCapturing else { return }

        displayStream?.stop()
        displayStream = nil
        isCapturing = false
        croppedBuffer = nil
        print("Screen capture stopped")
    }

    /// Update the region of interest for cropped streaming.
    /// Pass nil to reset to full screen.
    func updateROI(_ roi: RegionOfInterest?) {
        roiLock.lock()
        defer { roiLock.unlock() }

        // Validate ROI values
        if let roi = roi {
            // Check for invalid values
            guard roi.x >= 0 && roi.x <= 1 &&
                  roi.y >= 0 && roi.y <= 1 &&
                  roi.width > 0 && roi.width <= 1 &&
                  roi.height > 0 && roi.height <= 1 &&
                  roi.x + roi.width <= 1.01 &&  // Allow small epsilon
                  roi.y + roi.height <= 1.01 else {
                print("Invalid ROI values: x=\(roi.x), y=\(roi.y), w=\(roi.width), h=\(roi.height)")
                currentROI = nil
                return
            }
        }

        // Only update if ROI actually changed
        if let roi = roi, !roi.isFullScreen {
            currentROI = roi
            print("ROI set: x=\(roi.x), y=\(roi.y), w=\(roi.width), h=\(roi.height)")
        } else {
            if currentROI != nil {
                print("ROI reset to full screen")
            }
            currentROI = nil
        }
    }

    private func handleFrame(status: CGDisplayStreamFrameStatus, displayTime: UInt64, frameSurface: IOSurfaceRef?) {
        guard status == .frameComplete else { return }
        guard let surface = frameSurface else { return }

        // Create CVPixelBuffer from IOSurface
        var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        let result = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            attrs as CFDictionary,
            &unmanagedPixelBuffer
        )

        guard result == kCVReturnSuccess, let unmanaged = unmanagedPixelBuffer else {
            return
        }

        let sourceBuffer = unmanaged.takeRetainedValue()

        // Check if we need to crop
        roiLock.lock()
        let roi = currentROI
        roiLock.unlock()

        if let roi = roi, !roi.isFullScreen {
            // Crop the frame to the ROI (with fallback to full frame if crop fails)
            if let croppedBuffer = cropFrame(sourceBuffer, to: roi) {
                onFrame?(croppedBuffer, displayTime)
            } else {
                // Fallback to full frame if crop fails
                onFrame?(sourceBuffer, displayTime)
            }
        } else {
            // Full screen - use source buffer directly
            onFrame?(sourceBuffer, displayTime)
        }
    }

    /// Crop a frame to the specified region of interest and scale to output size.
    /// The output size matches the original capture size so the encoder doesn't need reconfiguring.
    private func cropFrame(_ sourceBuffer: CVPixelBuffer, to roi: RegionOfInterest) -> CVPixelBuffer? {
        // Ensure we have valid output dimensions
        guard width > 0 && height > 0 else {
            print("cropFrame: Invalid output dimensions: \(width)x\(height)")
            return nil
        }

        let sourceWidth = CVPixelBufferGetWidth(sourceBuffer)
        let sourceHeight = CVPixelBufferGetHeight(sourceBuffer)

        guard sourceWidth > 0 && sourceHeight > 0 else {
            print("cropFrame: Invalid source dimensions: \(sourceWidth)x\(sourceHeight)")
            return nil
        }

        // Calculate crop rect in pixels
        let cropX = Int(Float(sourceWidth) * max(0, min(roi.x, 1)))
        let cropY = Int(Float(sourceHeight) * max(0, min(roi.y, 1)))
        var cropWidth = Int(Float(sourceWidth) * max(0.01, min(roi.width, 1)))
        var cropHeight = Int(Float(sourceHeight) * max(0.01, min(roi.height, 1)))

        // Clamp to source bounds
        cropWidth = min(cropWidth, sourceWidth - cropX)
        cropHeight = min(cropHeight, sourceHeight - cropY)

        // Ensure valid dimensions
        guard cropWidth > 0 && cropHeight > 0 else {
            print("cropFrame: Invalid crop dimensions: \(cropWidth)x\(cropHeight)")
            return nil
        }

        // Create CIImage from source
        let ciImage = CIImage(cvPixelBuffer: sourceBuffer)

        // Crop the image (CIImage origin is bottom-left, so flip Y)
        let flippedY = sourceHeight - cropY - cropHeight
        let cropRect = CGRect(x: cropX, y: flippedY, width: cropWidth, height: cropHeight)
        let croppedImage = ciImage.cropped(to: cropRect)

        // Translate to origin
        let translatedImage = croppedImage.transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        // Scale up to original output size (so encoder doesn't need reconfiguring)
        // This gives us higher detail in the zoomed region
        let scaleX = CGFloat(width) / CGFloat(cropWidth)
        let scaleY = CGFloat(height) / CGFloat(cropHeight)
        let scaledImage = translatedImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Create or reuse output buffer at ORIGINAL size (not crop size)
        if croppedBuffer == nil ||
           CVPixelBufferGetWidth(croppedBuffer!) != width ||
           CVPixelBufferGetHeight(croppedBuffer!) != height {

            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferMetalCompatibilityKey: true
            ]

            var newBuffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &newBuffer
            )
            croppedBuffer = newBuffer
        }

        guard let outputBuffer = croppedBuffer else { return nil }

        // Render scaled cropped image to output buffer
        ciContext.render(scaledImage, to: outputBuffer)

        return outputBuffer
    }

    // MARK: - Utility

    /// Capture a single frame as an image (for preview/testing).
    func captureImage() -> CGImage? {
        return CGDisplayCreateImage(mainDisplayID)
    }
}

// MARK: - CGDisplayStreamFrameStatus Extension
extension CGDisplayStreamFrameStatus: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .frameComplete: return "frameComplete"
        case .frameIdle: return "frameIdle"
        case .frameBlank: return "frameBlank"
        case .stopped: return "stopped"
        @unknown default: return "unknown"
        }
    }
}
