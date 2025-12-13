import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// H.264 video encoder using VideoToolbox.
/// Configured for low-latency streaming.
class VideoEncoder {
    private var compressionSession: VTCompressionSession?
    private let encoderQueue = DispatchQueue(label: "VideoEncoder", qos: .userInteractive)

    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var fps: Int = 30
    private(set) var bitrate: Int = 4_000_000  // 4 Mbps default

    private var frameNumber: UInt32 = 0
    private var lastKeyframeNumber: UInt32 = 0
    private var keyframeInterval: UInt32 = 120  // Keyframe every 2 seconds (set based on fps)

    /// Callback for encoded frames.
    /// Parameters: NAL data, is keyframe, timestamp
    var onEncodedFrame: ((Data, Bool, UInt64) -> Void)?

    /// Initialize the encoder with specified parameters.
    func initialize(width: Int, height: Int, fps: Int = 30, bitrate: Int = 4_000_000) -> Bool {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.keyframeInterval = UInt32(fps * 2)  // Keyframe every 2 seconds

        // Create compression session
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("Failed to create compression session: \(status)")
            return false
        }

        compressionSession = session

        // Configure for low latency
        configureSession(session)

        // Prepare to encode
        VTCompressionSessionPrepareToEncodeFrames(session)

        print("Video encoder initialized: \(width)x\(height) @ \(fps)fps, \(bitrate/1_000_000)Mbps")
        return true
    }

    private func configureSession(_ session: VTCompressionSession) {
        // Real-time encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Profile: Main for better quality (most devices support it)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)

        // Bitrate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)

        // Data rate limits for consistent streaming
        let dataRateLimits = [bitrate * 2, 1] as CFArray  // Allow burst up to 2x bitrate for 1 second
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)

        // Keyframe interval
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: Double(keyframeInterval) / Double(fps) as CFNumber)

        // No B-frames (reduces latency)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Expected frame rate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)

        // Entropy mode: CAVLC (lower latency than CABAC)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CAVLC)
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

        // For keyframes, prepend SPS and PPS
        if isKeyframe {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                // Get SPS
                var spsSize = 0
                var spsCount = 0
                var spsPointer: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil)

                if let sps = spsPointer {
                    // Annex B start code
                    nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    nalData.append(UnsafeBufferPointer(start: sps, count: spsSize))
                }

                // Get PPS
                var ppsSize = 0
                var ppsPointer: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

                if let pps = ppsPointer {
                    nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    nalData.append(UnsafeBufferPointer(start: pps, count: ppsSize))
                }
            }
        }

        // Convert AVCC format to Annex B format
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
