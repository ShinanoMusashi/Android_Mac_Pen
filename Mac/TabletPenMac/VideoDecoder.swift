import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// HEVC/H.264 video decoder using VideoToolbox for loopback testing.
/// Decodes NAL data back to pixel buffers for display.
class VideoDecoder {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let decoderQueue = DispatchQueue(label: "VideoDecoder", qos: .userInteractive)

    private var width: Int = 0
    private var height: Int = 0
    private var isHEVC: Bool = true

    // Parameter sets for format description creation
    private var vps: Data?  // HEVC only
    private var sps: Data?
    private var pps: Data?

    /// Callback for decoded frames.
    var onDecodedFrame: ((CVPixelBuffer, UInt64) -> Void)?

    /// Stats
    private var framesDecoded: UInt64 = 0
    private var decodeStartTime: UInt64 = 0

    /// Initialize decoder for HEVC or H.264.
    func initialize(width: Int, height: Int, isHEVC: Bool = true) {
        self.width = width
        self.height = height
        self.isHEVC = isHEVC
        print("VideoDecoder initialized for \(isHEVC ? "HEVC" : "H.264") \(width)x\(height)")
    }

    /// Decode a NAL unit (Annex B format with start codes).
    func decode(nalData: Data, timestamp: UInt64) {
        decoderQueue.async { [weak self] in
            self?.decodeInternal(nalData: nalData, timestamp: timestamp)
        }
    }

    private func decodeInternal(nalData: Data, timestamp: UInt64) {
        decodeStartTime = getCurrentTimeNanos()

        // Parse NAL units from Annex B format
        let nalUnits = parseAnnexB(nalData)

        for nalUnit in nalUnits {
            if isHEVC {
                processHEVCNalUnit(nalUnit, timestamp: timestamp)
            } else {
                processH264NalUnit(nalUnit, timestamp: timestamp)
            }
        }
    }

    /// Parse Annex B format into individual NAL units.
    private func parseAnnexB(_ data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var startIndex = 0
        let bytes = [UInt8](data)

        // Find start codes (0x00 0x00 0x00 0x01 or 0x00 0x00 0x01)
        var i = 0
        while i < bytes.count - 3 {
            let isStartCode4 = (i + 3 < bytes.count &&
                               bytes[i] == 0x00 && bytes[i+1] == 0x00 &&
                               bytes[i+2] == 0x00 && bytes[i+3] == 0x01)
            let isStartCode3 = (bytes[i] == 0x00 && bytes[i+1] == 0x00 && bytes[i+2] == 0x01)

            if isStartCode4 || isStartCode3 {
                let startCodeLen = isStartCode4 ? 4 : 3

                // Save previous NAL unit if any
                if startIndex > 0 && i > startIndex {
                    let nalData = Data(bytes[startIndex..<i])
                    if !nalData.isEmpty {
                        nalUnits.append(nalData)
                    }
                }

                startIndex = i + startCodeLen
                i += startCodeLen
            } else {
                i += 1
            }
        }

        // Last NAL unit
        if startIndex < bytes.count {
            let nalData = Data(bytes[startIndex...])
            if !nalData.isEmpty {
                nalUnits.append(nalData)
            }
        }

        return nalUnits
    }

    private func processHEVCNalUnit(_ nalUnit: Data, timestamp: UInt64) {
        guard !nalUnit.isEmpty else { return }

        // HEVC NAL unit type is in bits 1-6 of first byte
        let nalType = (nalUnit[0] >> 1) & 0x3F

        switch nalType {
        case 32: // VPS
            vps = nalUnit
        case 33: // SPS
            sps = nalUnit
        case 34: // PPS
            pps = nalUnit
            // Try to create format description when we have all parameter sets
            if vps != nil && sps != nil {
                createHEVCFormatDescription()
            }
        case 19, 20: // IDR frames
            decodeVideoFrame(nalUnit, timestamp: timestamp, isKeyframe: true)
        case 1: // Non-IDR (P-frame)
            decodeVideoFrame(nalUnit, timestamp: timestamp, isKeyframe: false)
        default:
            // Other NAL types (SEI, etc.)
            break
        }
    }

    private func processH264NalUnit(_ nalUnit: Data, timestamp: UInt64) {
        guard !nalUnit.isEmpty else { return }

        // H.264 NAL unit type is in bits 0-4 of first byte
        let nalType = nalUnit[0] & 0x1F

        switch nalType {
        case 7: // SPS
            sps = nalUnit
        case 8: // PPS
            pps = nalUnit
            if sps != nil {
                createH264FormatDescription()
            }
        case 5: // IDR
            decodeVideoFrame(nalUnit, timestamp: timestamp, isKeyframe: true)
        case 1: // Non-IDR
            decodeVideoFrame(nalUnit, timestamp: timestamp, isKeyframe: false)
        default:
            break
        }
    }

    private func createHEVCFormatDescription() {
        guard let vps = vps, let sps = sps, let pps = pps else { return }

        let vpsArray = [UInt8](vps)
        let spsArray = [UInt8](sps)
        let ppsArray = [UInt8](pps)

        var formatDesc: CMFormatDescription?

        // Use withUnsafeBufferPointer to safely pass pointers
        let status = vpsArray.withUnsafeBufferPointer { vpsPtr in
            spsArray.withUnsafeBufferPointer { spsPtr in
                ppsArray.withUnsafeBufferPointer { ppsPtr in
                    var pointers: [UnsafePointer<UInt8>] = [
                        vpsPtr.baseAddress!,
                        spsPtr.baseAddress!,
                        ppsPtr.baseAddress!
                    ]
                    var sizes = [vpsArray.count, spsArray.count, ppsArray.count]

                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDesc
                    )
                }
            }
        }

        if status == noErr, let desc = formatDesc {
            formatDescription = desc
            createDecompressionSession()
        } else {
            print("Failed to create HEVC format description: \(status)")
        }
    }

    private func createH264FormatDescription() {
        guard let sps = sps, let pps = pps else { return }

        let spsArray = [UInt8](sps)
        let ppsArray = [UInt8](pps)

        var formatDesc: CMFormatDescription?

        // Use withUnsafeBufferPointer to safely pass pointers
        let status = spsArray.withUnsafeBufferPointer { spsPtr in
            ppsArray.withUnsafeBufferPointer { ppsPtr in
                var pointers: [UnsafePointer<UInt8>] = [
                    spsPtr.baseAddress!,
                    ppsPtr.baseAddress!
                ]
                var sizes = [spsArray.count, ppsArray.count]

                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
            }
        }

        if status == noErr, let desc = formatDesc {
            formatDescription = desc
            createDecompressionSession()
        } else {
            print("Failed to create H.264 format description: \(status)")
        }
    }

    private func createDecompressionSession() {
        guard let formatDesc = formatDescription else { return }

        // Clean up existing session
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

        // Output pixel buffer attributes
        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        if status == noErr, let session = session {
            decompressionSession = session

            // Enable low-latency mode
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

            print("VideoDecoder: Decompression session created")
        } else {
            print("Failed to create decompression session: \(status)")
        }
    }

    private func decodeVideoFrame(_ nalUnit: Data, timestamp: UInt64, isKeyframe: Bool) {
        guard let session = decompressionSession, let formatDesc = formatDescription else {
            return
        }

        // Convert NAL unit to AVCC format (length prefix instead of start code)
        var avccData = Data()
        var length = UInt32(nalUnit.count).bigEndian
        avccData.append(Data(bytes: &length, count: 4))
        avccData.append(nalUnit)

        // Create block buffer
        var blockBuffer: CMBlockBuffer?
        avccData.withUnsafeBytes { ptr in
            let baseAddress = ptr.baseAddress!
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: baseAddress),
                blockLength: avccData.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard let buffer = blockBuffer else { return }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avccData.count
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )

        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard let sample = sampleBuffer else { return }

        // Decode
        var flagsOut: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &flagsOut
        ) { [weak self] status, infoFlags, imageBuffer, presentationTime, duration in
            guard let self = self else { return }

            if status == noErr, let pixelBuffer = imageBuffer {
                self.framesDecoded += 1
                let decodeTime = getCurrentTimeNanos() - self.decodeStartTime

                // Log decode time periodically
                if self.framesDecoded % 60 == 0 {
                    print("Mac decode: \(decodeTime / 1_000_000)ms (frame \(self.framesDecoded))")
                }

                DispatchQueue.main.async {
                    self.onDecodedFrame?(pixelBuffer, timestamp)
                }
            }
        }

        if decodeStatus != noErr {
            // Don't spam errors for expected issues
            if decodeStatus != kVTInvalidSessionErr {
                print("Decode error: \(decodeStatus)")
            }
        }
    }

    /// Stop decoder and release resources.
    func stop() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
        vps = nil
        sps = nil
        pps = nil
        framesDecoded = 0
        print("VideoDecoder stopped (decoded \(framesDecoded) frames)")
    }
}
