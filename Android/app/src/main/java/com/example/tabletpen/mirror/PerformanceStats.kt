package com.example.tabletpen.mirror

import android.content.Context
import android.os.Environment
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.math.roundToInt

/**
 * Comprehensive performance statistics tracker.
 * Tracks FPS, latency, frame times, and provides 1% low / 5% low metrics.
 */
class PerformanceStats(private val context: Context? = null) {

    // Frame time tracking (in ms)
    private val frameTimes = ConcurrentLinkedQueue<Float>()
    private val latencies = ConcurrentLinkedQueue<Long>()
    private val maxSamples = 300 // 5 seconds at 60fps

    // Counters
    private var totalFramesDecoded = 0L
    var totalFramesDropped = 0L
        private set
    private var totalFramesReceived = 0L
    private var totalKeyframes = 0L
    private var lastKeyframeTime = 0L

    // For E2E latency - track time from receive to display
    private var lastReceiveTime = 0L

    // Timing
    private var lastFrameTime = 0L
    private var lastStatsTime = 0L
    private var framesInLastSecond = 0

    // Current stats
    var currentFps = 0f
        private set
    var avgFrameTime = 0f
        private set
    var onePercentLow = 0f
        private set
    var fivePercentLow = 0f
        private set
    var avgLatency = 0L
        private set
    var maxLatency = 0L
        private set
    var minLatency = Long.MAX_VALUE
        private set
    var queueDepth = 0
        private set
    var keyframeInterval = 0L  // ms since last keyframe
        private set
    var keyframeCount = 0L
        private set

    // Video info
    var sourceWidth = 0
    var sourceHeight = 0
    var decodedWidth = 0
    var decodedHeight = 0

    // Logging
    private var logWriter: FileWriter? = null
    private var loggingEnabled = false
    private val dateFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    // Detailed pipeline timing
    private var pipelineLogWriter: FileWriter? = null
    private var pipelineLoggingEnabled = false

    // Per-frame timing data
    data class FrameTiming(
        val frameNumber: Int,
        var receiveTime: Long = 0,      // When network bytes received
        var parseTime: Long = 0,        // When message parsed
        var queueTime: Long = 0,        // When added to decode queue
        var decodeInputTime: Long = 0,  // When fed to decoder
        var decodeOutputTime: Long = 0, // When output buffer received
        var renderTime: Long = 0,       // When released to surface
        var nalSize: Int = 0,
        var isKeyframe: Boolean = false
    )

    private val frameTimings = LinkedHashMap<Int, FrameTiming>()
    private val maxFrameTimings = 100

    // Pipeline stage averages (ms)
    var avgNetworkToQueue = 0f
        private set
    var avgQueueWait = 0f
        private set
    var avgDecodeTime = 0f
        private set
    var avgDecodeToRender = 0f
        private set
    var avgTotalPipeline = 0f
        private set

    /**
     * Record a frame being received (before decode).
     */
    fun onFrameReceived(captureTimestampNs: Long, currentQueueDepth: Int) {
        totalFramesReceived++
        queueDepth = currentQueueDepth
        lastReceiveTime = System.currentTimeMillis()
    }

    /**
     * Record a frame being decoded and displayed.
     */
    fun onFrameDecoded(captureTimestampNs: Long) {
        val now = System.currentTimeMillis()
        totalFramesDecoded++
        framesInLastSecond++

        // Frame time calculation
        if (lastFrameTime > 0) {
            val frameTime = (now - lastFrameTime).toFloat()
            frameTimes.offer(frameTime)
            while (frameTimes.size > maxSamples) {
                frameTimes.poll()
            }
        }
        lastFrameTime = now

        // Calculate E2E latency from receive time to display time
        // This measures queue + decode time (not network latency)
        if (lastReceiveTime > 0) {
            val latency = now - lastReceiveTime
            if (latency in 0..5000) {  // Reasonable range 0-5 seconds
                latencies.offer(latency)
                while (latencies.size > maxSamples) {
                    latencies.poll()
                }
                if (latency > maxLatency) maxLatency = latency
                if (latency < minLatency) minLatency = latency
            }
        }

        // Update stats every second
        if (lastStatsTime == 0L) lastStatsTime = now
        if (now - lastStatsTime >= 1000) {
            calculateStats()
            lastStatsTime = now
            framesInLastSecond = 0
        }
    }

    /**
     * Record a dropped frame.
     */
    fun onFrameDropped() {
        totalFramesDropped++
    }

    /**
     * Record a keyframe received.
     */
    fun onKeyframe() {
        val now = System.currentTimeMillis()
        totalKeyframes++
        keyframeCount = totalKeyframes
        if (lastKeyframeTime > 0) {
            keyframeInterval = now - lastKeyframeTime
        }
        lastKeyframeTime = now
    }

    // MARK: - Detailed Pipeline Timing

    /**
     * Record when frame bytes are received from network.
     */
    fun onNetworkReceive(frameNumber: Int, nalSize: Int, isKeyframe: Boolean) {
        synchronized(frameTimings) {
            val timing = FrameTiming(frameNumber).apply {
                receiveTime = System.nanoTime()
                this.nalSize = nalSize
                this.isKeyframe = isKeyframe
            }
            frameTimings[frameNumber] = timing

            // Limit size
            while (frameTimings.size > maxFrameTimings) {
                frameTimings.remove(frameTimings.keys.first())
            }
        }
    }

    /**
     * Record when frame is parsed and ready for decode.
     */
    fun onFrameParsed(frameNumber: Int) {
        synchronized(frameTimings) {
            frameTimings[frameNumber]?.parseTime = System.nanoTime()
        }
    }

    /**
     * Record when frame is added to decode queue.
     */
    fun onQueueEntry(frameNumber: Int) {
        synchronized(frameTimings) {
            frameTimings[frameNumber]?.queueTime = System.nanoTime()
        }
    }

    /**
     * Record when frame is fed to decoder input.
     */
    fun onDecodeInput(frameNumber: Int) {
        synchronized(frameTimings) {
            frameTimings[frameNumber]?.decodeInputTime = System.nanoTime()
        }
    }

    /**
     * Record when decoder produces output.
     */
    fun onDecodeOutput(frameNumber: Int) {
        synchronized(frameTimings) {
            frameTimings[frameNumber]?.decodeOutputTime = System.nanoTime()
        }
    }

    /**
     * Record when frame is rendered to surface.
     */
    fun onRender(frameNumber: Int) {
        synchronized(frameTimings) {
            val timing = frameTimings[frameNumber] ?: return@synchronized
            timing.renderTime = System.nanoTime()

            // Log this frame
            logPipelineTiming(timing)

            // Update averages
            updatePipelineAverages(timing)
        }
    }

    private fun updatePipelineAverages(timing: FrameTiming) {
        if (timing.receiveTime == 0L || timing.renderTime == 0L) return

        val networkToQueue = if (timing.queueTime > 0 && timing.receiveTime > 0)
            (timing.queueTime - timing.receiveTime) / 1_000_000f else 0f
        val queueWait = if (timing.decodeInputTime > 0 && timing.queueTime > 0)
            (timing.decodeInputTime - timing.queueTime) / 1_000_000f else 0f
        val decodeTime = if (timing.decodeOutputTime > 0 && timing.decodeInputTime > 0)
            (timing.decodeOutputTime - timing.decodeInputTime) / 1_000_000f else 0f
        val decodeToRender = if (timing.renderTime > 0 && timing.decodeOutputTime > 0)
            (timing.renderTime - timing.decodeOutputTime) / 1_000_000f else 0f
        val total = (timing.renderTime - timing.receiveTime) / 1_000_000f

        // Exponential moving average (alpha = 0.1)
        val alpha = 0.1f
        avgNetworkToQueue = avgNetworkToQueue * (1 - alpha) + networkToQueue * alpha
        avgQueueWait = avgQueueWait * (1 - alpha) + queueWait * alpha
        avgDecodeTime = avgDecodeTime * (1 - alpha) + decodeTime * alpha
        avgDecodeToRender = avgDecodeToRender * (1 - alpha) + decodeToRender * alpha
        avgTotalPipeline = avgTotalPipeline * (1 - alpha) + total * alpha
    }

    private fun logPipelineTiming(timing: FrameTiming) {
        if (!pipelineLoggingEnabled || pipelineLogWriter == null) return

        try {
            val networkToQueue = if (timing.queueTime > 0)
                (timing.queueTime - timing.receiveTime) / 1_000_000f else 0f
            val queueWait = if (timing.decodeInputTime > 0 && timing.queueTime > 0)
                (timing.decodeInputTime - timing.queueTime) / 1_000_000f else 0f
            val decodeTime = if (timing.decodeOutputTime > 0 && timing.decodeInputTime > 0)
                (timing.decodeOutputTime - timing.decodeInputTime) / 1_000_000f else 0f
            val decodeToRender = if (timing.renderTime > 0 && timing.decodeOutputTime > 0)
                (timing.renderTime - timing.decodeOutputTime) / 1_000_000f else 0f
            val total = (timing.renderTime - timing.receiveTime) / 1_000_000f

            val line = "${timing.frameNumber},${networkToQueue},${queueWait},${decodeTime},${decodeToRender},${total},${timing.nalSize},${if (timing.isKeyframe) 1 else 0}\n"
            pipelineLogWriter?.write(line)
            pipelineLogWriter?.flush()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /**
     * Start detailed pipeline logging.
     */
    fun startPipelineLogging() {
        try {
            val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
            val dir = context?.getExternalFilesDir(null) ?: return
            val file = File(dir, "pipeline_timing_$timestamp.csv")
            pipelineLogWriter = FileWriter(file, true)
            pipelineLogWriter?.write("frame,net_to_queue_ms,queue_wait_ms,decode_ms,decode_to_render_ms,total_ms,nal_size,keyframe\n")
            pipelineLoggingEnabled = true
            android.util.Log.i("PerformanceStats", "Pipeline logging to: ${file.absolutePath}")
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /**
     * Stop pipeline logging and print summary.
     */
    fun stopPipelineLogging() {
        if (pipelineLoggingEnabled) {
            printPipelineSummary()
        }
        pipelineLoggingEnabled = false
        try {
            pipelineLogWriter?.close()
        } catch (e: Exception) {
            e.printStackTrace()
        }
        pipelineLogWriter = null
    }

    /**
     * Print pipeline timing summary to log.
     */
    fun printPipelineSummary() {
        android.util.Log.i("PerformanceStats", """

            📊 Android Pipeline Timing (averages):
            ┌─────────────────────────────────────────┐
            │ Network → Queue:    ${String.format("%6.2f", avgNetworkToQueue)} ms       │
            │ Queue Wait:         ${String.format("%6.2f", avgQueueWait)} ms       │
            │ Decode Time:        ${String.format("%6.2f", avgDecodeTime)} ms       │
            │ Decode → Render:    ${String.format("%6.2f", avgDecodeToRender)} ms       │
            ├─────────────────────────────────────────┤
            │ Total Android:      ${String.format("%6.2f", avgTotalPipeline)} ms       │
            └─────────────────────────────────────────┘

        """.trimIndent())
    }

    private fun calculateStats() {
        // FPS
        currentFps = framesInLastSecond.toFloat()

        // Frame times
        val times = frameTimes.toList().sorted()
        if (times.isNotEmpty()) {
            avgFrameTime = times.average().toFloat()

            // 1% low = average of worst 1% frame times
            val onePercentCount = maxOf(1, (times.size * 0.01).roundToInt())
            onePercentLow = if (times.size >= onePercentCount) {
                1000f / times.takeLast(onePercentCount).average().toFloat()
            } else {
                currentFps
            }

            // 5% low = average of worst 5% frame times
            val fivePercentCount = maxOf(1, (times.size * 0.05).roundToInt())
            fivePercentLow = if (times.size >= fivePercentCount) {
                1000f / times.takeLast(fivePercentCount).average().toFloat()
            } else {
                currentFps
            }
        }

        // Latency
        val lats = latencies.toList()
        if (lats.isNotEmpty()) {
            avgLatency = lats.average().toLong()
        }

        // Log if enabled
        logStats()
    }

    /**
     * Enable logging to file.
     */
    fun startLogging() {
        try {
            val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
            val dir = context?.getExternalFilesDir(null) ?: return
            val file = File(dir, "mirror_stats_$timestamp.csv")
            logWriter = FileWriter(file, true)
            logWriter?.write("Time,FPS,1%Low,5%Low,AvgFrameTime,AvgLatency,MaxLatency,QueueDepth,Dropped,Total\n")
            loggingEnabled = true
            android.util.Log.i("PerformanceStats", "Logging to: ${file.absolutePath}")
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /**
     * Stop logging.
     */
    fun stopLogging() {
        loggingEnabled = false
        try {
            logWriter?.close()
        } catch (e: Exception) {
            e.printStackTrace()
        }
        logWriter = null
    }

    private fun logStats() {
        if (!loggingEnabled) return
        try {
            val time = dateFormat.format(Date())
            logWriter?.write("$time,$currentFps,$onePercentLow,$fivePercentLow,$avgFrameTime,$avgLatency,$maxLatency,$queueDepth,$totalFramesDropped,$totalFramesDecoded\n")
            logWriter?.flush()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /**
     * Get a formatted stats string for display.
     */
    fun getStatsString(): String {
        return buildString {
            appendLine("FPS: %.1f (1%%: %.1f, 5%%: %.1f)".format(currentFps, onePercentLow, fivePercentLow))
            appendLine("Latency: ${avgLatency}ms (max: ${maxLatency}ms)")
            appendLine("Resolution: ${sourceWidth}x${sourceHeight}")
            appendLine("Queue: $queueDepth | Dropped: $totalFramesDropped")
            appendLine("Frame time: %.1fms".format(avgFrameTime))
        }
    }

    /**
     * Reset all stats.
     */
    fun reset() {
        frameTimes.clear()
        latencies.clear()
        totalFramesDecoded = 0
        totalFramesDropped = 0
        totalFramesReceived = 0
        totalKeyframes = 0
        lastKeyframeTime = 0
        lastReceiveTime = 0
        lastFrameTime = 0
        lastStatsTime = 0
        framesInLastSecond = 0
        currentFps = 0f
        avgFrameTime = 0f
        onePercentLow = 0f
        fivePercentLow = 0f
        avgLatency = 0
        maxLatency = 0
        minLatency = Long.MAX_VALUE
        queueDepth = 0
        keyframeInterval = 0
        keyframeCount = 0
    }

    /**
     * Get stats for graph display (last N samples).
     */
    fun getFpsHistory(): List<Float> {
        return frameTimes.map { 1000f / it }.takeLast(60)
    }

    fun getLatencyHistory(): List<Long> {
        return latencies.toList().takeLast(60)
    }
}
