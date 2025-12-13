import Foundation
import CoreGraphics
import AppKit

/// Captures the Mac screen for streaming to Android.
class ScreenCapture {
    private var displayStream: CGDisplayStream?
    private var isCapturing = false
    private let captureQueue = DispatchQueue(label: "ScreenCapture", qos: .userInteractive)

    /// Callback for each captured frame.
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?

    /// Current capture configuration.
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var fps: Int = 30

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
        print("Screen capture stopped")
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

        let buffer = unmanaged.takeRetainedValue()

        // Notify callback
        onFrame?(buffer, displayTime)
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
