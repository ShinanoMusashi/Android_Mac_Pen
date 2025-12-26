package com.example.tabletpen.mirror

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.view.Surface
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread

/**
 * H.265/HEVC video decoder using MediaCodec.
 * Decodes NAL units received from the Mac and renders to a Surface.
 * HEVC provides ~50% better compression than H.264 at same quality.
 */
class VideoDecoder {
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var isRunning = false

    private var width = 0
    private var height = 0

    // Reduced queue size for lower latency (was 30, now 5)
    private val nalQueue = LinkedBlockingQueue<NalUnit>(5)

    // Decoder thread
    private var decoderThread: Thread? = null

    // Track if we've received SPS/PPS
    private var hasReceivedKeyframe = false

    // Performance stats
    var stats: PerformanceStats? = null

    // Legacy callback for backwards compatibility
    var onStatsUpdate: ((fps: Float, dropped: Long) -> Unit)? = null

    data class NalUnit(
        val data: ByteArray,
        val timestamp: Long,  // Capture timestamp from Mac (nanoseconds)
        val isKeyframe: Boolean,
        val frameNumber: Int,  // Frame number from Mac for timing correlation
        val receiveTime: Long = System.currentTimeMillis()  // When we received this frame
    )

    // Track decoder info
    var decoderName: String = "unknown"
        private set
    var isHardwareDecoder: Boolean = false
        private set

    /**
     * Initialize the decoder with video configuration.
     */
    fun initialize(surface: Surface, width: Int, height: Int): Boolean {
        this.surface = surface
        this.width = width
        this.height = height

        // Update stats
        stats?.sourceWidth = width
        stats?.sourceHeight = height

        try {
            // Find and prefer hardware HEVC decoder
            val codecName = findHardwareDecoder() ?: MediaFormat.MIMETYPE_VIDEO_HEVC

            codec = if (codecName != MediaFormat.MIMETYPE_VIDEO_HEVC) {
                // Use specific codec by name
                MediaCodec.createByCodecName(codecName)
            } else {
                // Fallback to default selection
                MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
            }

            decoderName = codec?.name ?: "unknown"
            isHardwareDecoder = !decoderName.contains("google", ignoreCase = true) &&
                               !decoderName.contains("c2.android", ignoreCase = true)

            android.util.Log.i("VideoDecoder", "Using HEVC decoder: $decoderName (hardware: $isHardwareDecoder)")

            // Configure with HEVC format
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height)

            // Low latency mode if available (Android 11+)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }

            // Additional low-latency settings
            format.setInteger(MediaFormat.KEY_PRIORITY, 0) // Real-time priority

            codec?.configure(format, surface, null, 0)
            codec?.start()

            isRunning = true
            startDecoderThread()

            android.util.Log.i("VideoDecoder", "Initialized: ${width}x${height}, queue size: ${nalQueue.remainingCapacity() + nalQueue.size}")

            return true
        } catch (e: Exception) {
            android.util.Log.e("VideoDecoder", "Failed to initialize", e)
            return false
        }
    }

    /**
     * Find a hardware H.265/HEVC decoder.
     * Returns codec name if found, null otherwise.
     */
    private fun findHardwareDecoder(): String? {
        val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)

        for (codecInfo in codecList.codecInfos) {
            if (codecInfo.isEncoder) continue

            for (type in codecInfo.supportedTypes) {
                if (type.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true)) {
                    val name = codecInfo.name
                    // Prefer hardware decoders (not google/android software)
                    if (!name.contains("google", ignoreCase = true) &&
                        !name.contains("c2.android", ignoreCase = true)) {
                        android.util.Log.i("VideoDecoder", "Found hardware HEVC decoder: $name")
                        return name
                    }
                }
            }
        }

        android.util.Log.w("VideoDecoder", "No hardware HEVC decoder found, using default")
        return null
    }

    /**
     * Queue NAL data for decoding.
     * @param frameNumber Frame number from Mac for timing correlation
     */
    fun decode(nalData: ByteArray, timestamp: Long, isKeyframe: Boolean, frameNumber: Int) {
        if (!isRunning) return

        // If we haven't received a keyframe yet, wait for one
        if (!hasReceivedKeyframe && !isKeyframe) {
            return
        }

        if (isKeyframe) {
            hasReceivedKeyframe = true
            stats?.onKeyframe()
            // On keyframe, optionally clear queue to reduce latency
            // nalQueue.clear()  // Uncomment for aggressive latency reduction
        }

        val nalUnit = NalUnit(nalData, timestamp, isKeyframe, frameNumber)

        // Track queue depth
        stats?.onFrameReceived(timestamp, nalQueue.size)

        // Timing: frame entering decode queue
        stats?.onQueueEntry(frameNumber)

        // Queue the NAL unit (drop if queue is full to prevent latency buildup)
        val queued = nalQueue.offer(nalUnit)
        if (!queued) {
            stats?.onFrameDropped()
            android.util.Log.w("VideoDecoder", "Frame dropped - queue full (${nalQueue.size})")
        }
    }

    private fun startDecoderThread() {
        decoderThread = thread(name = "VideoDecoder") {
            val bufferInfo = MediaCodec.BufferInfo()

            while (isRunning) {
                try {
                    // Get NAL unit from queue with shorter timeout
                    val nalUnit = nalQueue.poll(50, java.util.concurrent.TimeUnit.MILLISECONDS)
                        ?: continue

                    // Log queue latency
                    val queueLatency = System.currentTimeMillis() - nalUnit.receiveTime
                    if (queueLatency > 100) {
                        android.util.Log.w("VideoDecoder", "High queue latency: ${queueLatency}ms")
                    }

                    // Feed to decoder
                    feedDecoder(nalUnit)

                    // Drain output
                    drainDecoder(bufferInfo, nalUnit.timestamp, nalUnit.frameNumber)
                } catch (e: InterruptedException) {
                    break
                } catch (e: Exception) {
                    android.util.Log.e("VideoDecoder", "Decoder error", e)
                }
            }
        }
    }

    private fun feedDecoder(nalUnit: NalUnit) {
        val codec = codec ?: return

        // Get input buffer with shorter timeout
        val inputIndex = codec.dequeueInputBuffer(5000) // 5ms timeout
        if (inputIndex < 0) {
            android.util.Log.w("VideoDecoder", "No input buffer available")
            return
        }

        val inputBuffer = codec.getInputBuffer(inputIndex) ?: return
        inputBuffer.clear()
        inputBuffer.put(nalUnit.data)

        // Timing: frame being fed to decoder
        stats?.onDecodeInput(nalUnit.frameNumber)

        // Queue to decoder with capture timestamp
        codec.queueInputBuffer(
            inputIndex,
            0,
            nalUnit.data.size,
            nalUnit.timestamp / 1000, // Convert ns to us for MediaCodec
            if (nalUnit.isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
        )
    }

    private fun drainDecoder(bufferInfo: MediaCodec.BufferInfo, captureTimestamp: Long, frameNumber: Int) {
        val codec = codec ?: return

        while (true) {
            val outputIndex = codec.dequeueOutputBuffer(bufferInfo, 0)

            when {
                outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    break
                }
                outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val format = codec.outputFormat
                    val newWidth = format.getInteger(MediaFormat.KEY_WIDTH)
                    val newHeight = format.getInteger(MediaFormat.KEY_HEIGHT)
                    stats?.decodedWidth = newWidth
                    stats?.decodedHeight = newHeight
                    android.util.Log.i("VideoDecoder", "Output format changed: ${newWidth}x${newHeight}")
                }
                outputIndex >= 0 -> {
                    // Timing: decoder produced output
                    stats?.onDecodeOutput(frameNumber)

                    // Got output frame, release to surface for rendering
                    codec.releaseOutputBuffer(outputIndex, true)

                    // Timing: frame rendered to surface
                    stats?.onRender(frameNumber)

                    // Update stats
                    stats?.onFrameDecoded(captureTimestamp)

                    // Legacy callback
                    val currentStats = stats
                    if (currentStats != null) {
                        onStatsUpdate?.invoke(currentStats.currentFps, currentStats.queueDepth.toLong())
                    }
                }
                else -> {
                    break
                }
            }
        }
    }

    /**
     * Get current queue depth.
     */
    fun getQueueDepth(): Int = nalQueue.size

    /**
     * Stop the decoder and release resources.
     */
    fun release() {
        isRunning = false

        decoderThread?.interrupt()
        decoderThread?.join(1000)
        decoderThread = null

        try {
            codec?.stop()
            codec?.release()
        } catch (e: Exception) {
            e.printStackTrace()
        }

        codec = null
        surface = null
        hasReceivedKeyframe = false
        nalQueue.clear()

        android.util.Log.i("VideoDecoder", "Released")
    }

    /**
     * Flush the decoder (call when seeking or after discontinuity).
     */
    fun flush() {
        nalQueue.clear()
        hasReceivedKeyframe = false
        try {
            codec?.flush()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
