package com.example.tabletpen.protocol

/**
 * Protocol message types for communication between Android and Mac.
 *
 * Protocol format:
 * [Type: 1 byte][Length: 4 bytes BE][Payload: variable]
 */
enum class MessageType(val value: Byte) {
    // Android -> Mac
    PEN_DATA(0x01),
    MODE_REQUEST(0x02),
    QUALITY_REQUEST(0x04),  // Request quality preset (bitrate in Mbps as payload)
    ROI_UPDATE(0x05),       // Region of interest for zoomed streaming
    LOG_DATA(0x06),         // Log file transfer from Android to Mac

    // Mac -> Android
    MODE_ACK(0x03),
    VIDEO_FRAME(0x10),
    VIDEO_CONFIG(0x11),

    // Bidirectional
    PING(0xF0.toByte()),
    PONG(0xF1.toByte()),

    // Clock synchronization (for accurate E2E latency measurement)
    SYNC_REQUEST(0xF2.toByte()),   // Android -> Mac: [T1: 8 bytes] (Android's send timestamp nanos)
    SYNC_RESPONSE(0xF3.toByte());  // Mac -> Android: [T1: 8 bytes][T2: 8 bytes][T3: 8 bytes]

    companion object {
        fun fromValue(value: Byte): MessageType? {
            return entries.find { it.value == value }
        }
    }
}

/**
 * Mode identifiers for MODE_REQUEST and MODE_ACK messages.
 */
enum class AppMode(val value: Byte) {
    TOUCHPAD(0x00),
    SCREEN_MIRROR(0x01);

    companion object {
        fun fromValue(value: Byte): AppMode? {
            return entries.find { it.value == value }
        }
    }
}

/**
 * Video frame type for VIDEO_FRAME messages.
 */
enum class FrameType(val value: Byte) {
    KEYFRAME(0x00),   // I-frame
    DELTA_FRAME(0x01); // P-frame

    companion object {
        fun fromValue(value: Byte): FrameType? {
            return entries.find { it.value == value }
        }
    }
}
