import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import Darwin

/// Set the current thread to realtime priority for time-critical operations.
/// This is similar to what game streaming apps like Parsec do.
private func setRealtimeThreadPriority() {
    // Use THREAD_TIME_CONSTRAINT_POLICY for realtime scheduling
    var timeConstraint = thread_time_constraint_policy_data_t()

    // Get the conversion factor for nanoseconds to Mach absolute time units
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let nanoToAbs = Double(info.denom) / Double(info.numer)

    // For 60fps video, we need frames every ~16.67ms
    // Set period to 16ms, computation to 8ms (encoding time budget)
    let periodNs: UInt32 = 16_000_000  // 16ms period
    let computeNs: UInt32 = 8_000_000  // 8ms compute time
    let constraintNs: UInt32 = 16_000_000  // 16ms constraint (deadline)

    timeConstraint.period = UInt32(Double(periodNs) * nanoToAbs)
    timeConstraint.computation = UInt32(Double(computeNs) * nanoToAbs)
    timeConstraint.constraint = UInt32(Double(constraintNs) * nanoToAbs)
    timeConstraint.preemptible = 1  // Can be preempted if we exceed budget

    // Calculate policy count: struct size / integer_t size
    let policyCount = mach_msg_type_number_t(
        MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size
    )

    let result = withUnsafeMutablePointer(to: &timeConstraint) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(policyCount)) { intPtr in
            thread_policy_set(
                pthread_mach_thread_np(pthread_self()),
                thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
                intPtr,
                policyCount
            )
        }
    }

    if result != KERN_SUCCESS {
        // Fallback to high QoS if realtime fails
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    }
}

/// HEVC video encoder using VideoToolbox with low-latency optimizations.
/// Optimized for real-time streaming with minimal encoding delay.
/// HEVC is faster on Apple Silicon than H.264.
class VideoEncoder {
    private var compressionSession: VTCompressionSession?
    private let encoderQueue = DispatchQueue(label: "VideoEncoder", qos: .userInteractive)
    private var hasSetThreadPriority = false

    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var fps: Int = 30
    private(set) var bitrate: Int = 4_000_000  // 4 Mbps default
    private(set) var useHEVC: Bool = true  // Track codec type
    private(set) var encoderName: String = "unknown"

    private var frameNumber: UInt32 = 0
    private var lastKeyframeNumber: UInt32 = 0
    private var keyframeInterval: UInt32 = 30  // Keyframe every 0.5 seconds for faster error recovery

    /// Callback for encoded frames.
    /// Parameters: NAL data, is keyframe, timestamp
    var onEncodedFrame: ((Data, Bool, UInt64) -> Void)?

    /// Initialize the encoder with specified parameters.
    /// Uses HEVC with low-latency optimizations (faster on Apple Silicon).
    func initialize(width: Int, height: Int, fps: Int = 30, bitrate: Int = 4_000_000) -> Bool {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        // Keyframe every 1 second for streaming (less frequent = better compression)
        self.keyframeInterval = UInt32(fps)

        // Try HEVC first (faster on Apple Silicon)
        if initializeHEVC() {
            return true
        }

        // Fallback to H.264 if HEVC fails
        print("HEVC failed, trying H.264...")
        return initializeH264LowLatency()
    }

    private func initializeH264LowLatency() -> Bool {
        // Enable low-latency rate control - this is the key for minimal latency!
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,  // H.264 for best low-latency support
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("Failed to create H.264 low-latency session: \(status)")
            return false
        }

        compressionSession = session
        useHEVC = false
        configureH264Session(session)
        VTCompressionSessionPrepareToEncodeFrames(session)

        print("H.264 LOW-LATENCY encoder initialized: \(width)x\(height) @ \(fps)fps, \(bitrate/1_000_000)Mbps")
        return true
    }

    private func initializeHEVC() -> Bool {
        // Require hardware encoder and enable low-latency
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("Failed to create HEVC session: \(status)")
            return false
        }

        compressionSession = session
        useHEVC = true

        // Get encoder name for diagnostics
        var encoderNameRef: CFString?
        VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &encoderNameRef)
        encoderName = (encoderNameRef as String?) ?? "unknown"

        configureHEVCSession(session)
        VTCompressionSessionPrepareToEncodeFrames(session)

        print("HEVC encoder initialized: \(width)x\(height) @ \(fps)fps, \(bitrate/1_000_000)Mbps")
        print("Encoder: \(encoderName)")
        return true
    }

    private func configureH264Session(_ session: VTCompressionSession) {
        // Real-time encoding - CRITICAL
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Disable power efficiency mode - prioritize performance over battery
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)

        // Prioritize speed over quality for minimum latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)

        // Profile: Baseline for lowest latency, High for better quality
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)

        // Bitrate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)

        // Data rate limits - allow bursts for keyframes
        let dataRateLimits = [bitrate * 2, 1] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)

        // Keyframe interval
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)

        // NO B-frames - critical for low latency (1-in-1-out behavior)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Expected frame rate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)

        // Don't set Quality - let low-latency mode handle it
    }

    private func configureHEVCSession(_ session: VTCompressionSession) {
        // Real-time encoding - CRITICAL for low latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Disable power efficiency mode - prioritize performance over battery
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)

        // DON'T prioritize speed over quality - we want good quality during fast motion
        // VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)

        // Profile: HEVC Main
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)

        // Bitrate - use as average target
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)

        // Data rate limits - allow 4x burst for fast motion (was 2x)
        // Format: [bytes per second, duration in seconds]
        let dataRateLimits = [bitrate * 4, 1] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)

        // Quality setting - maintain reasonable quality even during motion
        // 0.0 = max compression, 1.0 = max quality
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.7 as CFNumber)

        // Keyframe interval - more frequent during streaming for error recovery
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)

        // No B-frames - critical for low latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Expected frame rate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
    }

    /// Encode a frame.
    func encode(pixelBuffer: CVPixelBuffer, timestamp: UInt64) {
        guard let session = compressionSession else { return }

        let presentationTime = CMTime(value: Int64(timestamp), timescale: 1_000_000_000)
        let duration = CMTime(value: 1, timescale: Int32(fps))

        // Check if we need a keyframe
        var properties: [CFString: Any]? = nil
        if frameNumber - lastKeyframeNumber >= keyframeInterval {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
        }

        let currentFrameNumber = frameNumber
        frameNumber += 1

        // Timing: encode start
        PipelineTimer.shared.onEncodeStart(frameNumber: currentFrameNumber)

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: properties as CFDictionary?,
            infoFlagsOut: nil
        ) { [weak self] status, flags, sampleBuffer in
            guard let self = self else { return }

            // Set realtime thread priority on first callback (encoder callback thread)
            if !self.hasSetThreadPriority {
                setRealtimeThreadPriority()
                self.hasSetThreadPriority = true
                print("🎮 Encoder thread set to realtime priority")
            }

            if status != noErr {
                print("Encode error: \(status)")
                return
            }

            guard let sampleBuffer = sampleBuffer else { return }

            self.processSampleBuffer(sampleBuffer, frameNumber: currentFrameNumber)
        }
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, frameNumber: UInt32) {
        // Check if it's a keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isKeyframe = false

        if let attachments = attachments, CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            let notSync = CFDictionaryGetValue(dict, unsafeBitCast(kCMSampleAttachmentKey_NotSync, to: UnsafeRawPointer.self))
            isKeyframe = notSync == nil
        }

        if isKeyframe {
            lastKeyframeNumber = frameNumber
        }

        // Get timestamp
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = UInt64(CMTimeGetSeconds(pts) * 1_000_000_000)

        // Extract NAL units with Annex B format
        guard let nalData = extractNALData(from: sampleBuffer, isKeyframe: isKeyframe) else {
            return
        }

        // Timing: encode complete
        PipelineTimer.shared.onEncodeComplete(frameNumber: frameNumber, nalSize: nalData.count, isKeyframe: isKeyframe)

        // Notify callback immediately (no main thread dispatch for lower latency)
        self.onEncodedFrame?(nalData, isKeyframe, timestamp)
    }

    private func extractNALData(from sampleBuffer: CMSampleBuffer, isKeyframe: Bool) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard status == noErr, let pointer = dataPointer else { return nil }

        var nalData = Data()

        // For keyframes, prepend parameter sets
        if isKeyframe {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                if useHEVC {
                    // HEVC: VPS, SPS, PPS
                    extractHEVCParameterSets(from: formatDesc, into: &nalData)
                } else {
                    // H.264: SPS, PPS only
                    extractH264ParameterSets(from: formatDesc, into: &nalData)
                }
            }
        }

        // Convert AVCC/HVCC format to Annex B format
        var offset = 0
        while offset < totalLength {
            // Read NAL unit length (4 bytes big-endian)
            var nalLength: UInt32 = 0
            memcpy(&nalLength, pointer.advanced(by: offset), 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += 4

            if offset + Int(nalLength) > totalLength {
                break
            }

            // Annex B start code
            nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])

            // NAL unit data
            nalData.append(Data(bytes: pointer.advanced(by: offset), count: Int(nalLength)))
            offset += Int(nalLength)
        }

        return nalData
    }

    private func extractH264ParameterSets(from formatDesc: CMFormatDescription, into nalData: inout Data) {
        // Get SPS (Sequence Parameter Set)
        var spsSize = 0
        var spsPointer: UnsafePointer<UInt8>?
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

        if let sps = spsPointer {
            nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            nalData.append(UnsafeBufferPointer(start: sps, count: spsSize))
        }

        // Get PPS (Picture Parameter Set)
        var ppsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

        if let pps = ppsPointer {
            nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            nalData.append(UnsafeBufferPointer(start: pps, count: ppsSize))
        }
    }

    private func extractHEVCParameterSets(from formatDesc: CMFormatDescription, into nalData: inout Data) {
        // Get VPS (Video Parameter Set) - index 0 for HEVC
        var vpsSize = 0
        var vpsPointer: UnsafePointer<UInt8>?
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &vpsPointer, parameterSetSizeOut: &vpsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

        if let vps = vpsPointer {
            nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            nalData.append(UnsafeBufferPointer(start: vps, count: vpsSize))
        }

        // Get SPS (Sequence Parameter Set) - index 1 for HEVC
        var spsSize = 0
        var spsPointer: UnsafePointer<UInt8>?
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

        if let sps = spsPointer {
            nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            nalData.append(UnsafeBufferPointer(start: sps, count: spsSize))
        }

        // Get PPS (Picture Parameter Set) - index 2 for HEVC
        var ppsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 2, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

        if let pps = ppsPointer {
            nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            nalData.append(UnsafeBufferPointer(start: pps, count: ppsSize))
        }
    }

    /// Force an immediate keyframe.
    func forceKeyframe() {
        // Next encode call will be a keyframe
        lastKeyframeNumber = 0
        frameNumber = keyframeInterval
    }

    /// Stop encoding and release resources.
    func stop() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        compressionSession = nil
        frameNumber = 0
        lastKeyframeNumber = 0
        hasSetThreadPriority = false
        print("Video encoder stopped")
    }
}
