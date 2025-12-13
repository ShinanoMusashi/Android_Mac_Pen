package com.example.tabletpen.mirror

import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread

/**
 * H.264 video decoder using MediaCodec.
 * Decodes NAL units received from the Mac and renders to a Surface.
 */
class VideoDecoder {
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var isRunning = false

    private var width = 0
    private var height = 0

    // Queue for incoming NAL data
    private val nalQueue = LinkedBlockingQueue<NalUnit>(30)

    // Decoder thread
    private var decoderThread: Thread? = null

    // Track if we've received SPS/PPS
    private var hasReceivedKeyframe = false

    data class NalUnit(
        val data: ByteArray,
        val timestamp: Long,
        val isKeyframe: Boolean
    )

    /**
     * Initialize the decoder with video configuration.
     */
    fun initialize(surface: Surface, width: Int, height: Int): Boolean {
        this.surface = surface
        this.width = width
        this.height = height

        try {
            // Create H.264 decoder
            codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)

            // Configure with format
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)

            // Low latency mode if available (Android 11+)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }

            codec?.configure(format, surface, null, 0)
            codec?.start()

            isRunning = true
            startDecoderThread()

            return true
        } catch (e: Exception) {
            e.printStackTrace()
            return false
        }
    }

    /**
     * Queue NAL data for decoding.
     */
    fun decode(nalData: ByteArray, timestamp: Long, isKeyframe: Boolean) {
        if (!isRunning) return

        // If we haven't received a keyframe yet, wait for one
        if (!hasReceivedKeyframe && !isKeyframe) {
            return
        }

        if (isKeyframe) {
            hasReceivedKeyframe = true
        }

        // Queue the NAL unit (drop if queue is full to prevent latency buildup)
        nalQueue.offer(NalUnit(nalData, timestamp, isKeyframe))
    }

    private fun startDecoderThread() {
        decoderThread = thread(name = "VideoDecoder") {
            val bufferInfo = MediaCodec.BufferInfo()

            while (isRunning) {
                try {
                    // Get NAL unit from queue
                    val nalUnit = nalQueue.poll(100, java.util.concurrent.TimeUnit.MILLISECONDS)
                        ?: continue

                    // Feed to decoder
                    feedDecoder(nalUnit)

                    // Drain output
                    drainDecoder(bufferInfo)
                } catch (e: InterruptedException) {
                    break
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        }
    }

    private fun feedDecoder(nalUnit: NalUnit) {
        val codec = codec ?: return

        // Get input buffer
        val inputIndex = codec.dequeueInputBuffer(10000) // 10ms timeout
        if (inputIndex < 0) return

        val inputBuffer = codec.getInputBuffer(inputIndex) ?: return
        inputBuffer.clear()
        inputBuffer.put(nalUnit.data)

        // Queue to decoder
        codec.queueInputBuffer(
            inputIndex,
            0,
            nalUnit.data.size,
            nalUnit.timestamp / 1000, // Convert ns to us
            if (nalUnit.isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
        )
    }

    private fun drainDecoder(bufferInfo: MediaCodec.BufferInfo) {
        val codec = codec ?: return

        while (true) {
            val outputIndex = codec.dequeueOutputBuffer(bufferInfo, 0)

            when {
                outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    // No output available yet
                    break
                }
                outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    // Format changed, ignore for now
                }
                outputIndex >= 0 -> {
                    // Got output frame, release to surface for rendering
                    codec.releaseOutputBuffer(outputIndex, true)
                }
                else -> {
                    break
                }
            }
        }
    }

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
