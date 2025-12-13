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

    // Mac -> Android
    MODE_ACK(0x03),
    VIDEO_FRAME(0x10),
    VIDEO_CONFIG(0x11),

    // Bidirectional
    PING(0xF0.toByte()),
    PONG(0xF1.toByte());

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
