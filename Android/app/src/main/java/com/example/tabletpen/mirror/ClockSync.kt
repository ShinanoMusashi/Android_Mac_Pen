package com.example.tabletpen.mirror

import android.util.Log

/**
 * Clock synchronization utility for accurate cross-device timing.
 * Uses NTP-like algorithm to calculate RTT and clock offset.
 *
 * Algorithm (NTP symmetric mode):
 * - T1 = Android send time (local nanoTime)
 * - T2 = Mac receive time (Mac's monotonic clock)
 * - T3 = Mac send time (Mac's monotonic clock)
 * - T4 = Android receive time (local nanoTime)
 *
 * RTT = (T4 - T1) - (T3 - T2)
 * Clock offset = ((T2 - T1) + (T3 - T4)) / 2
 *
 * Note: Clock offset lets us convert between device clocks:
 * Mac time ≈ Android nanoTime + clockOffset
 */
class ClockSync {
    companion object {
        private const val TAG = "ClockSync"

        // Exponential moving average smoothing factor (0-1)
        // Higher = more responsive, lower = more stable
        private const val EMA_ALPHA = 0.3

        // Minimum samples before offset is considered stable
        private const val MIN_SAMPLES = 3

        // Maximum acceptable RTT for valid sample (in ms)
        // Samples with higher RTT are likely affected by network jitter
        private const val MAX_VALID_RTT_MS = 100
    }

    // Current estimated clock offset (Android -> Mac)
    // Mac timestamp ≈ Android nanoTime + clockOffsetNanos
    @Volatile
    var clockOffsetNanos: Long = 0
        private set

    // Current RTT (round-trip time) in nanoseconds
    @Volatile
    var rttNanos: Long = 0
        private set

    // RTT in milliseconds for display
    val rttMs: Double
        get() = rttNanos / 1_000_000.0

    // Whether we have a valid clock offset
    @Volatile
    var isSynced: Boolean = false
        private set

    // Number of successful sync samples
    private var sampleCount = 0

    // Best (minimum) RTT seen - used for filtering
    private var minRttNanos: Long = Long.MAX_VALUE

    /**
     * Process a sync response from the Mac.
     *
     * @param t1 Android's send timestamp (echoed back from Mac)
     * @param t2 Mac's receive timestamp
     * @param t3 Mac's send timestamp
     * @param t4 Android's receive timestamp (when this response arrived)
     */
    fun processSyncResponse(t1: Long, t2: Long, t3: Long, t4: Long) {
        // Calculate RTT: total round trip minus Mac processing time
        val rtt = (t4 - t1) - (t3 - t2)

        // Skip invalid samples (negative RTT shouldn't happen)
        if (rtt < 0) {
            Log.w(TAG, "Invalid RTT: $rtt ns (t1=$t1, t2=$t2, t3=$t3, t4=$t4)")
            return
        }

        // Skip high-latency samples (likely affected by jitter)
        val rttMs = rtt / 1_000_000.0
        if (rttMs > MAX_VALID_RTT_MS) {
            Log.d(TAG, "Skipping high-latency sample: ${rttMs.format(1)}ms RTT")
            return
        }

        // Track minimum RTT for filtering quality
        if (rtt < minRttNanos) {
            minRttNanos = rtt
        }

        // Calculate clock offset
        // Positive offset means Mac clock is ahead of Android clock
        val offset = ((t2 - t1) + (t3 - t4)) / 2

        // Update RTT (exponential moving average)
        rttNanos = if (sampleCount == 0) {
            rtt
        } else {
            ((1 - EMA_ALPHA) * rttNanos + EMA_ALPHA * rtt).toLong()
        }

        // Update clock offset (exponential moving average)
        clockOffsetNanos = if (sampleCount == 0) {
            offset
        } else {
            ((1 - EMA_ALPHA) * clockOffsetNanos + EMA_ALPHA * offset).toLong()
        }

        sampleCount++
        isSynced = sampleCount >= MIN_SAMPLES

        Log.d(TAG, "Sync sample #$sampleCount: RTT=${rttMs.format(2)}ms, offset=${(clockOffsetNanos/1_000_000.0).format(2)}ms")
    }

    /**
     * Convert Android nanoTime to estimated Mac time.
     */
    fun androidToMacTime(androidNanos: Long): Long {
        return androidNanos + clockOffsetNanos
    }

    /**
     * Convert Mac time to estimated Android nanoTime.
     */
    fun macToAndroidTime(macNanos: Long): Long {
        return macNanos - clockOffsetNanos
    }

    /**
     * Reset synchronization state.
     */
    fun reset() {
        clockOffsetNanos = 0
        rttNanos = 0
        isSynced = false
        sampleCount = 0
        minRttNanos = Long.MAX_VALUE
    }

    private fun Double.format(decimals: Int): String = "%.${decimals}f".format(this)
}
