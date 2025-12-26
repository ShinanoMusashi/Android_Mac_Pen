import Foundation

/// Tracks timing across the video pipeline stages.
/// Logs detailed breakdown of where time is spent.
class PipelineTimer {
    static let shared = PipelineTimer()

    private var enabled = false
    private var logToFile = false
    private var logFile: FileHandle?
    private let queue = DispatchQueue(label: "PipelineTimer")

    // Rolling stats
    private var captureToEncodeSum: Double = 0
    private var encodeTimeSum: Double = 0
    private var encodeToSendSum: Double = 0
    private var totalSum: Double = 0
    private var frameCount: Int = 0
    private let statsInterval = 60 // Log summary every N frames

    // Per-frame timing
    struct FrameTiming {
        let frameNumber: UInt32
        var captureTime: UInt64 = 0      // When frame was captured (ns)
        var encodeStartTime: UInt64 = 0  // When encoding started (ns)
        var encodeEndTime: UInt64 = 0    // When encoding completed (ns)
        var sendTime: UInt64 = 0         // When sent to network (ns)
        var nalSize: Int = 0             // Encoded size in bytes
        var isKeyframe: Bool = false
    }

    private var currentFrame: FrameTiming?

    private init() {}

    func start(logToFile: Bool = false) {
        enabled = true
        self.logToFile = logToFile

        if logToFile {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let logPath = documentsPath.appendingPathComponent("pipeline_timing_\(Date().timeIntervalSince1970).csv")

            FileManager.default.createFile(atPath: logPath.path, contents: nil)
            logFile = try? FileHandle(forWritingTo: logPath)

            // Write header
            let header = "frame,capture_ms,encode_start_ms,encode_end_ms,send_ms,capture_to_encode,encode_time,encode_to_send,total,nal_size,keyframe\n"
            logFile?.write(header.data(using: .utf8)!)

            print("Pipeline timing log: \(logPath.path)")
        }

        print("Pipeline timing started")
    }

    func stop() {
        enabled = false
        logFile?.closeFile()
        logFile = nil
        printSummary()
        print("Pipeline timing stopped")
    }

    // MARK: - Timing Points

    /// Called when screen capture produces a frame
    func onCapture(frameNumber: UInt32, displayTime: UInt64) {
        guard enabled else { return }
        queue.async {
            self.currentFrame = FrameTiming(
                frameNumber: frameNumber,
                captureTime: displayTime
            )
        }
    }

    /// Called when encoder starts processing
    func onEncodeStart(frameNumber: UInt32) {
        guard enabled else { return }
        queue.async {
            if self.currentFrame?.frameNumber == frameNumber {
                self.currentFrame?.encodeStartTime = Self.now()
            }
        }
    }

    /// Called when encoder completes
    func onEncodeComplete(frameNumber: UInt32, nalSize: Int, isKeyframe: Bool) {
        guard enabled else { return }
        queue.async {
            if self.currentFrame?.frameNumber == frameNumber {
                self.currentFrame?.encodeEndTime = Self.now()
                self.currentFrame?.nalSize = nalSize
                self.currentFrame?.isKeyframe = isKeyframe
            }
        }
    }

    /// Called when data is sent to network
    func onSend(frameNumber: UInt32) {
        guard enabled else { return }
        queue.async {
            guard var frame = self.currentFrame, frame.frameNumber == frameNumber else { return }
            frame.sendTime = Self.now()
            self.logFrame(frame)
            self.currentFrame = nil
        }
    }

    // MARK: - Logging

    private func logFrame(_ frame: FrameTiming) {
        // Calculate deltas in milliseconds
        let captureMs = Double(frame.captureTime) / 1_000_000.0
        let encodeStartMs = Double(frame.encodeStartTime) / 1_000_000.0
        let encodeEndMs = Double(frame.encodeEndTime) / 1_000_000.0
        let sendMs = Double(frame.sendTime) / 1_000_000.0

        // Time differences (using encode start as reference since capture time may be in different epoch)
        let captureToEncode = encodeStartMs - captureMs
        let encodeTime = encodeEndMs - encodeStartMs
        let encodeToSend = sendMs - encodeEndMs
        let total = sendMs - captureMs

        // Update rolling stats (only if values are reasonable)
        if captureToEncode >= 0 && captureToEncode < 1000 &&
           encodeTime >= 0 && encodeTime < 1000 &&
           encodeToSend >= 0 && encodeToSend < 1000 {
            captureToEncodeSum += captureToEncode
            encodeTimeSum += encodeTime
            encodeToSendSum += encodeToSend
            totalSum += total
            frameCount += 1
        }

        // Log to file
        if logToFile, let file = logFile {
            let line = String(format: "%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%d\n",
                              frame.frameNumber,
                              captureMs, encodeStartMs, encodeEndMs, sendMs,
                              captureToEncode, encodeTime, encodeToSend, total,
                              frame.nalSize,
                              frame.isKeyframe ? 1 : 0)
            file.write(line.data(using: .utf8)!)
        }

        // Print summary periodically
        if frameCount > 0 && frameCount % statsInterval == 0 {
            printSummary()
        }
    }

    private func printSummary() {
        guard frameCount > 0 else { return }

        let avgCaptureToEncode = captureToEncodeSum / Double(frameCount)
        let avgEncodeTime = encodeTimeSum / Double(frameCount)
        let avgEncodeToSend = encodeToSendSum / Double(frameCount)
        let avgTotal = totalSum / Double(frameCount)

        print("""

        📊 Mac Pipeline Timing (avg over \(frameCount) frames):
        ┌─────────────────────────────────────────┐
        │ Capture → Encode Start: \(String(format: "%6.2f", avgCaptureToEncode)) ms       │
        │ Encode Time:            \(String(format: "%6.2f", avgEncodeTime)) ms       │
        │ Encode → Send:          \(String(format: "%6.2f", avgEncodeToSend)) ms       │
        ├─────────────────────────────────────────┤
        │ Total Mac Pipeline:     \(String(format: "%6.2f", avgTotal)) ms       │
        └─────────────────────────────────────────┘

        """)
    }

    // MARK: - Utility

    private static func now() -> UInt64 {
        var time = mach_timebase_info_data_t()
        mach_timebase_info(&time)
        let machTime = mach_absolute_time()
        return machTime * UInt64(time.numer) / UInt64(time.denom)
    }
}
