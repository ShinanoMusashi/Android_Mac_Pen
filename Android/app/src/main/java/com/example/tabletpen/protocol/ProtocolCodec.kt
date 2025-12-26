package com.example.tabletpen.protocol

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.nio.ByteBuffer

/**
 * Encodes and decodes protocol messages.
 *
 * Protocol format:
 * [Type: 1 byte][Length: 4 bytes BE][Payload: variable]
 */
object ProtocolCodec {

    /**
     * Write a message to the output stream.
     */
    fun writeMessage(output: DataOutputStream, type: MessageType, payload: ByteArray) {
        output.writeByte(type.value.toInt())
        output.writeInt(payload.size)
        if (payload.isNotEmpty()) {
            output.write(payload)
        }
        output.flush()
    }

    /**
     * Write pen data message.
     */
    fun writePenData(output: DataOutputStream, penDataCsv: String) {
        val payload = penDataCsv.toByteArray(Charsets.UTF_8)
        writeMessage(output, MessageType.PEN_DATA, payload)
    }

    /**
     * Write mode request message.
     */
    fun writeModeRequest(output: DataOutputStream, mode: AppMode) {
        writeMessage(output, MessageType.MODE_REQUEST, byteArrayOf(mode.value))
    }

    /**
     * Write ping message.
     */
    fun writePing(output: DataOutputStream) {
        writeMessage(output, MessageType.PING, ByteArray(0))
    }

    /**
     * Write quality request message.
     * @param bitrateMbps Desired bitrate in Mbps (e.g., 35 for WiFi, 50 for USB)
     */
    fun writeQualityRequest(output: DataOutputStream, bitrateMbps: Int) {
        val payload = ByteArray(4)
        val buffer = java.nio.ByteBuffer.wrap(payload)
        buffer.putInt(bitrateMbps)
        writeMessage(output, MessageType.QUALITY_REQUEST, payload)
    }

    /**
     * Write ROI (Region of Interest) update message.
     * All values are normalized (0.0 to 1.0) relative to screen size.
     * @param x Left position (0.0 = left edge)
     * @param y Top position (0.0 = top edge)
     * @param width Width of region
     * @param height Height of region
     */
    fun writeROIUpdate(output: DataOutputStream, x: Float, y: Float, width: Float, height: Float) {
        val payload = ByteArray(16)
        val buffer = java.nio.ByteBuffer.wrap(payload)
        buffer.putFloat(x)
        buffer.putFloat(y)
        buffer.putFloat(width)
        buffer.putFloat(height)
        writeMessage(output, MessageType.ROI_UPDATE, payload)
    }

    /**
     * Write pong message.
     */
    fun writePong(output: DataOutputStream) {
        writeMessage(output, MessageType.PONG, ByteArray(0))
    }

    /**
     * Write log data message.
     * Format: filename + newline + file content
     */
    fun writeLogData(output: DataOutputStream, filename: String, content: String) {
        val payload = "$filename\n$content".toByteArray(Charsets.UTF_8)
        writeMessage(output, MessageType.LOG_DATA, payload)
    }

    /**
     * Read a message from the input stream.
     * Returns null if stream is closed or error occurs.
     */
    fun readMessage(input: DataInputStream): ProtocolMessage? {
        return try {
            val typeByte = input.readByte()
            val type = MessageType.fromValue(typeByte) ?: return null

            val length = input.readInt()
            val payload = if (length > 0) {
                val bytes = ByteArray(length)
                input.readFully(bytes)
                bytes
            } else {
                ByteArray(0)
            }

            ProtocolMessage(type, payload)
        } catch (e: IOException) {
            null
        }
    }

    /**
     * Parse video config from payload.
     */
    fun parseVideoConfig(payload: ByteArray): VideoConfig? {
        if (payload.size < 9) return null
        val buffer = ByteBuffer.wrap(payload)
        return VideoConfig(
            width = buffer.short.toInt() and 0xFFFF,
            height = buffer.short.toInt() and 0xFFFF,
            fps = buffer.get().toInt() and 0xFF,
            bitrate = buffer.int
        )
    }

    /**
     * Parse video frame from payload.
     */
    fun parseVideoFrame(payload: ByteArray): VideoFrame? {
        if (payload.size < 13) return null
        val buffer = ByteBuffer.wrap(payload)
        val frameTypeByte = buffer.get()
        val frameType = FrameType.fromValue(frameTypeByte) ?: return null
        val timestamp = buffer.long
        val frameNumber = buffer.int
        val nalData = ByteArray(payload.size - 13)
        buffer.get(nalData)

        return VideoFrame(
            frameType = frameType,
            timestamp = timestamp,
            frameNumber = frameNumber,
            nalData = nalData
        )
    }
}

/**
 * Represents a protocol message.
 */
data class ProtocolMessage(
    val type: MessageType,
    val payload: ByteArray
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as ProtocolMessage
        if (type != other.type) return false
        if (!payload.contentEquals(other.payload)) return false
        return true
    }

    override fun hashCode(): Int {
        var result = type.hashCode()
        result = 31 * result + payload.contentHashCode()
        return result
    }
}

/**
 * Video configuration received from Mac.
 */
data class VideoConfig(
    val width: Int,
    val height: Int,
    val fps: Int,
    val bitrate: Int
)

/**
 * Video frame received from Mac.
 */
data class VideoFrame(
    val frameType: FrameType,
    val timestamp: Long,
    val frameNumber: Int,
    val nalData: ByteArray
) {
    val isKeyframe: Boolean get() = frameType == FrameType.KEYFRAME

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as VideoFrame
        if (frameType != other.frameType) return false
        if (timestamp != other.timestamp) return false
        if (frameNumber != other.frameNumber) return false
        if (!nalData.contentEquals(other.nalData)) return false
        return true
    }

    override fun hashCode(): Int {
        var result = frameType.hashCode()
        result = 31 * result + timestamp.hashCode()
        result = 31 * result + frameNumber
        result = 31 * result + nalData.contentHashCode()
        return result
    }
}
