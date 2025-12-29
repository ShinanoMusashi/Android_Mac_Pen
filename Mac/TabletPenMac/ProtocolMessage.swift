import Foundation

/// Protocol message types for communication between Android and Mac.
///
/// Protocol format:
/// [Type: 1 byte][Length: 4 bytes BE][Payload: variable]
enum MessageType: UInt8 {
    // Android -> Mac
    case penData = 0x01
    case modeRequest = 0x02
    case qualityRequest = 0x04  // Request quality/bitrate settings
    case roiUpdate = 0x05       // Region of interest update for zoomed streaming
    case logData = 0x06         // Log file transfer from Android to Mac

    // Mac -> Android
    case modeAck = 0x03
    case videoFrame = 0x10
    case videoConfig = 0x11

    // Bidirectional
    case ping = 0xF0
    case pong = 0xF1

    // Clock synchronization (for accurate E2E latency measurement)
    case syncRequest = 0xF2   // Android -> Mac: [T1: 8 bytes] (Android's send timestamp)
    case syncResponse = 0xF3  // Mac -> Android: [T1: 8 bytes][T2: 8 bytes][T3: 8 bytes]
                              // T1 = Android's original timestamp (echo)
                              // T2 = Mac's receive timestamp
                              // T3 = Mac's send timestamp
}

/// Mode identifiers for MODE_REQUEST and MODE_ACK messages.
enum AppMode: UInt8 {
    case touchpad = 0x00
    case screenMirror = 0x01
}

/// Video frame type for VIDEO_FRAME messages.
enum FrameType: UInt8 {
    case keyframe = 0x00    // I-frame
    case deltaFrame = 0x01  // P-frame
}

/// Region of Interest for cropped streaming.
/// All values are normalized (0.0 to 1.0) relative to screen size.
struct RegionOfInterest {
    let x: Float      // Left position (0.0 = left edge)
    let y: Float      // Top position (0.0 = top edge)
    let width: Float  // Width of region
    let height: Float // Height of region

    /// Check if this is the full screen (no crop needed)
    var isFullScreen: Bool {
        return x <= 0.001 && y <= 0.001 && width >= 0.999 && height >= 0.999
    }
}

/// Represents a protocol message.
struct ProtocolMessage {
    let type: MessageType
    let payload: Data

    /// Serialize the message to bytes.
    func serialize() -> Data {
        var data = Data()
        data.append(type.rawValue)

        // Length as big-endian 4 bytes
        var length = UInt32(payload.count).bigEndian
        data.append(Data(bytes: &length, count: 4))

        data.append(payload)
        return data
    }

    /// Parse a message from data buffer.
    /// Returns the message and the number of bytes consumed, or nil if incomplete.
    static func parse(from data: Data) -> (ProtocolMessage, Int)? {
        guard data.count >= 5 else { return nil }

        // Convert to Array for safe indexing (Data can have non-zero startIndex)
        let bytes = Array(data.prefix(5))
        guard bytes.count >= 5 else { return nil }

        guard let type = MessageType(rawValue: bytes[0]) else { return nil }

        // Parse length from bytes 1-4 (big-endian)
        let length = Int(UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4]))

        let totalLength = 5 + length
        guard data.count >= totalLength else { return nil }

        // Extract payload safely
        let payloadStart = data.startIndex + 5
        let payloadEnd = data.startIndex + totalLength
        let payload = Data(data[payloadStart..<payloadEnd])

        return (ProtocolMessage(type: type, payload: payload), totalLength)
    }
}

/// Protocol encoder/decoder utilities.
class ProtocolCodec {

    // MARK: - Encoding

    /// Create a pen data message.
    static func encodePenData(_ csvString: String) -> Data {
        let payload = csvString.data(using: .utf8) ?? Data()
        return ProtocolMessage(type: .penData, payload: payload).serialize()
    }

    /// Create a mode request message.
    static func encodeModeRequest(_ mode: AppMode) -> Data {
        let payload = Data([mode.rawValue])
        return ProtocolMessage(type: .modeRequest, payload: payload).serialize()
    }

    /// Create a mode acknowledgment message.
    static func encodeModeAck(_ mode: AppMode) -> Data {
        let payload = Data([mode.rawValue])
        return ProtocolMessage(type: .modeAck, payload: payload).serialize()
    }

    /// Create a video config message.
    static func encodeVideoConfig(width: Int, height: Int, fps: Int, bitrate: Int) -> Data {
        var payload = Data()

        // Width (2 bytes BE)
        var w = UInt16(width).bigEndian
        payload.append(Data(bytes: &w, count: 2))

        // Height (2 bytes BE)
        var h = UInt16(height).bigEndian
        payload.append(Data(bytes: &h, count: 2))

        // FPS (1 byte)
        payload.append(UInt8(fps))

        // Bitrate (4 bytes BE)
        var br = UInt32(bitrate).bigEndian
        payload.append(Data(bytes: &br, count: 4))

        return ProtocolMessage(type: .videoConfig, payload: payload).serialize()
    }

    /// Create a video frame message.
    static func encodeVideoFrame(frameType: FrameType, timestamp: UInt64, frameNumber: UInt32, nalData: Data) -> Data {
        var payload = Data()

        // Frame type (1 byte)
        payload.append(frameType.rawValue)

        // Timestamp (8 bytes BE)
        var ts = timestamp.bigEndian
        payload.append(Data(bytes: &ts, count: 8))

        // Frame number (4 bytes BE)
        var fn = frameNumber.bigEndian
        payload.append(Data(bytes: &fn, count: 4))

        // NAL data
        payload.append(nalData)

        return ProtocolMessage(type: .videoFrame, payload: payload).serialize()
    }

    /// Create a ping message.
    static func encodePing() -> Data {
        return ProtocolMessage(type: .ping, payload: Data()).serialize()
    }

    /// Create a pong message.
    static func encodePong() -> Data {
        return ProtocolMessage(type: .pong, payload: Data()).serialize()
    }

    /// Create a sync response message.
    /// T1 = Android's original timestamp (echoed back)
    /// T2 = Mac's receive timestamp (nanoseconds)
    /// T3 = Mac's send timestamp (nanoseconds)
    static func encodeSyncResponse(t1: UInt64, t2: UInt64, t3: UInt64) -> Data {
        var payload = Data()

        var t1BE = t1.bigEndian
        var t2BE = t2.bigEndian
        var t3BE = t3.bigEndian

        payload.append(Data(bytes: &t1BE, count: 8))
        payload.append(Data(bytes: &t2BE, count: 8))
        payload.append(Data(bytes: &t3BE, count: 8))

        return ProtocolMessage(type: .syncResponse, payload: payload).serialize()
    }

    // MARK: - Decoding

    /// Parse pen data from payload.
    static func decodePenData(from payload: Data) -> PenData? {
        guard let string = String(data: payload, encoding: .utf8) else { return nil }
        return PenData.parse(from: string)
    }

    /// Parse mode from payload.
    static func decodeMode(from payload: Data) -> AppMode? {
        guard payload.count >= 1 else { return nil }
        return AppMode(rawValue: payload[payload.startIndex])
    }

    /// Parse quality request from payload.
    /// Returns bitrate in Mbps.
    static func decodeQualityRequest(from payload: Data) -> Int? {
        guard payload.count >= 4 else { return nil }
        let bytes = Array(payload.prefix(4))
        let bitrateMbps = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        return bitrateMbps
    }

    /// Parse ROI update from payload.
    /// Payload format: [x: 4 bytes float BE][y: 4 bytes][width: 4 bytes][height: 4 bytes]
    static func decodeROI(from payload: Data) -> RegionOfInterest? {
        guard payload.count >= 16 else { return nil }
        let bytes = Array(payload)

        // Parse floats from big-endian bytes
        func parseFloat(at offset: Int) -> Float {
            let bits = UInt32(bytes[offset]) << 24 |
                       UInt32(bytes[offset + 1]) << 16 |
                       UInt32(bytes[offset + 2]) << 8 |
                       UInt32(bytes[offset + 3])
            return Float(bitPattern: bits)
        }

        let x = parseFloat(at: 0)
        let y = parseFloat(at: 4)
        let width = parseFloat(at: 8)
        let height = parseFloat(at: 12)

        return RegionOfInterest(x: x, y: y, width: width, height: height)
    }

    /// Parse sync request from payload.
    /// Returns T1 (Android's send timestamp in nanoseconds).
    static func decodeSyncRequest(from payload: Data) -> UInt64? {
        guard payload.count >= 8 else { return nil }
        let bytes = Array(payload.prefix(8))
        let t1 = UInt64(bytes[0]) << 56 |
                 UInt64(bytes[1]) << 48 |
                 UInt64(bytes[2]) << 40 |
                 UInt64(bytes[3]) << 32 |
                 UInt64(bytes[4]) << 24 |
                 UInt64(bytes[5]) << 16 |
                 UInt64(bytes[6]) << 8 |
                 UInt64(bytes[7])
        return t1
    }
}
