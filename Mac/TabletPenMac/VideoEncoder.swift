import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// H.265/HEVC video encoder using VideoToolbox.
/// Configured for low-latency streaming with better compression than H.264.
class VideoEncoder {
    private var compressionSession: VTCompressionSession?
    private let encoderQueue = DispatchQueue(label: "VideoEncoder", qos: .userInteractive)

    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var fps: Int = 30
    private(set) var bitrate: Int = 4_000_000  // 4 Mbps default

    private var frameNumber: UInt32 = 0
    private var lastKeyframeNumber: UInt32 = 0
    private var keyframeInterval: UInt32 = 30  // Keyframe every 0.5 seconds for faster error recovery

    /// Callback for encoded frames.
    /// Parameters: NAL data, is keyframe, timestamp
    var onEncodedFrame: ((Data, Bool, UInt64) -> Void)?

    /// Initialize the encoder with specified parameters.
    func initialize(width: Int, height: Int, fps: Int = 30, bitrate: Int = 4_000_000) -> Bool {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        // Keyframe every 0.5 seconds for fast error recovery (critical for streaming)
        // More frequent keyframes = faster recovery from corruption, slightly higher bandwidth
        self.keyframeInterval = UInt32(max(fps / 2, 15))  // At least every 0.5s, minimum 15 frames

        // Create compression session with HEVC codec
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,  // H.265/HEVC for better compression
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("Failed to create HEVC compression session: \(status)")
            return false
        }

        compressionSession = session

        // Configure for low latency
        configureSession(session)

        // Prepare to encode
        VTCompressionSessionPrepareToEncodeFrames(session)

        print("HEVC encoder initialized: \(width)x\(height) @ \(fps)fps, \(bitrate/1_000_000)Mbps")
        return true
    }

    private func configureSession(_ session: VTCompressionSession) {
        // Real-time encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Profile: HEVC Main for good quality and broad compatibility
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)

        // Bitrate - set high, let encoder use what it needs
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)

        // Data rate limits - allow up to 3x for keyframes and bursts
        let dataRateLimits = [bitrate * 3, 1] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)

        // Keyframe interval - short for faster error recovery (every 0.5 seconds)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: Double(keyframeInterval) / Double(fps) as CFNumber)

        // No B-frames (reduces latency)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Expected frame rate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)

        // Quality setting - high quality (0.9 for better FPS, use 1.0 for max quality)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.9 as CFNumber)
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

        // Notify callback
        DispatchQueue.main.async {
            self.onEncodedFrame?(nalData, isKeyframe, timestamp)
        }
    }

    private func extractNALData(from sampleBuffer: CMSampleBuffer, isKeyframe: Bool) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard status == noErr, let pointer = dataPointer else { return nil }

        var nalData = Data()

        // For keyframes, prepend VPS, SPS and PPS (HEVC has VPS unlike H.264)
        if isKeyframe {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                // Get VPS (Video Parameter Set) - index 0 for HEVC
                var vpsSize = 0
                var vpsPointer: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &vpsPointer, parameterSetSizeOut: &vpsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

                if let vps = vpsPointer {
                    // Annex B start code
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
        }

        // Convert HVCC format to Annex B format
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
        print("Video encoder stopped")
    }
}
