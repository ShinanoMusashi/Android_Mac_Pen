package com.example.tabletpen.mirror

import android.util.Log
import kotlinx.coroutines.*
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.coroutineContext

/**
 * UDP video receiver for low-latency video streaming.
 * Receives fragmented video frames and reassembles them.
 *
 * Packet format (18-byte header + payload):
 * [0]      Packet type (0x20 = video fragment)
 * [1-4]    Frame number (4 bytes BE)
 * [5-6]    Fragment index (2 bytes BE)
 * [7-8]    Total fragments (2 bytes BE)
 * [9]      Flags (bit0 = keyframe)
 * [10-17]  Timestamp (8 bytes BE)
 * [18...]  NAL data fragment
 */
class UDPVideoReceiver(private val port: Int = 9878) {

    companion object {
        private const val TAG = "UDPVideoReceiver"
        private const val PACKET_TYPE_VIDEO: Byte = 0x20
        private const val HEADER_SIZE = 18
        private const val MAX_PACKET_SIZE = 1500
        private const val FRAME_TIMEOUT_MS = 100L  // Discard incomplete frames after this
    }

    private var socket: DatagramSocket? = null
    private var receiveJob: Job? = null
    private var cleanupJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // Frame reassembly state
    private data class FrameAssembly(
        val frameNumber: Int,
        val totalFragments: Int,
        val isKeyframe: Boolean,
        val timestamp: Long,
        val fragments: Array<ByteArray?>,
        var receivedCount: Int = 0,
        val startTime: Long = System.currentTimeMillis()
    ) {
        fun isComplete(): Boolean = receivedCount == totalFragments

        fun assemble(): ByteArray? {
            if (!isComplete()) return null
            // Calculate total size
            var totalSize = 0
            for (frag in fragments) {
                totalSize += frag?.size ?: return null
            }
            // Combine fragments
            val result = ByteArray(totalSize)
            var offset = 0
            for (frag in fragments) {
                frag?.let {
                    System.arraycopy(it, 0, result, offset, it.size)
                    offset += it.size
                }
            }
            return result
        }
    }

    private val pendingFrames = ConcurrentHashMap<Int, FrameAssembly>()
    private var lastCompletedFrame = -1

    // Stats
    @Volatile var packetsReceived: Long = 0
        private set
    @Volatile var framesReceived: Long = 0
        private set
    @Volatile var framesDropped: Long = 0
        private set

    // Callbacks
    var onVideoFrame: ((nalData: ByteArray, frameNumber: Int, isKeyframe: Boolean, timestamp: Long) -> Unit)? = null
    var onPacketLoss: ((expectedFrame: Int, receivedFrame: Int) -> Unit)? = null

    /**
     * Start listening for UDP video packets.
     */
    fun start(): Boolean {
        return try {
            socket = DatagramSocket(port)
            socket?.soTimeout = 0  // No timeout, we handle blocking in coroutine

            receiveJob = scope.launch {
                receiveLoop()
            }

            cleanupJob = scope.launch {
                cleanupLoop()
            }

            Log.i(TAG, "UDP video receiver started on port $port")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start UDP receiver: ${e.message}")
            false
        }
    }

    /**
     * Stop receiving.
     */
    fun stop() {
        receiveJob?.cancel()
        cleanupJob?.cancel()
        receiveJob = null
        cleanupJob = null

        try {
            socket?.close()
        } catch (e: Exception) {
            // Ignore
        }
        socket = null

        pendingFrames.clear()
        Log.i(TAG, "UDP video receiver stopped")
    }

    private suspend fun receiveLoop() {
        val buffer = ByteArray(MAX_PACKET_SIZE)
        val packet = DatagramPacket(buffer, buffer.size)

        while (coroutineContext.isActive) {
            try {
                socket?.receive(packet) ?: break

                packetsReceived++
                processPacket(buffer, packet.length)
            } catch (e: Exception) {
                if (coroutineContext.isActive) {
                    Log.w(TAG, "Receive error: ${e.message}")
                }
            }
        }
    }

    private fun processPacket(data: ByteArray, length: Int) {
        if (length < HEADER_SIZE) {
            Log.w(TAG, "Packet too small: $length bytes")
            return
        }

        // Parse header
        val packetType = data[0]
        if (packetType != PACKET_TYPE_VIDEO) {
            Log.w(TAG, "Unknown packet type: $packetType")
            return
        }

        val buffer = ByteBuffer.wrap(data)

        // Skip packet type
        buffer.position(1)

        val frameNumber = buffer.int
        val fragmentIndex = buffer.short.toInt() and 0xFFFF
        val totalFragments = buffer.short.toInt() and 0xFFFF
        val flags = buffer.get()
        val isKeyframe = (flags.toInt() and 0x01) != 0
        val timestamp = buffer.long

        // Extract fragment data
        val fragmentSize = length - HEADER_SIZE
        val fragmentData = ByteArray(fragmentSize)
        System.arraycopy(data, HEADER_SIZE, fragmentData, 0, fragmentSize)

        // Check for packet loss (gap in frame numbers)
        if (lastCompletedFrame >= 0 && frameNumber > lastCompletedFrame + 1) {
            // We missed some frames
            val missedFrames = frameNumber - lastCompletedFrame - 1
            framesDropped += missedFrames
            onPacketLoss?.invoke(lastCompletedFrame + 1, frameNumber)
        }

        // Get or create frame assembly
        val assembly = pendingFrames.getOrPut(frameNumber) {
            FrameAssembly(
                frameNumber = frameNumber,
                totalFragments = totalFragments,
                isKeyframe = isKeyframe,
                timestamp = timestamp,
                fragments = arrayOfNulls(totalFragments)
            )
        }

        // Validate fragment
        if (fragmentIndex >= totalFragments || fragmentIndex >= assembly.fragments.size) {
            Log.w(TAG, "Invalid fragment index: $fragmentIndex / $totalFragments")
            return
        }

        // Store fragment if not already received
        if (assembly.fragments[fragmentIndex] == null) {
            assembly.fragments[fragmentIndex] = fragmentData
            assembly.receivedCount++
        }

        // Check if frame is complete
        if (assembly.isComplete()) {
            assembly.assemble()?.let { nalData ->
                framesReceived++
                lastCompletedFrame = frameNumber
                pendingFrames.remove(frameNumber)

                // Remove any older pending frames (they're too late)
                pendingFrames.keys.filter { it < frameNumber }.forEach {
                    pendingFrames.remove(it)
                    framesDropped++
                }

                // Deliver frame
                onVideoFrame?.invoke(nalData, frameNumber, assembly.isKeyframe, assembly.timestamp)
            }
        }
    }

    private suspend fun cleanupLoop() {
        while (coroutineContext.isActive) {
            delay(50)  // Check every 50ms

            val now = System.currentTimeMillis()
            val expiredFrames = pendingFrames.entries.filter {
                now - it.value.startTime > FRAME_TIMEOUT_MS
            }

            for ((frameNum, _) in expiredFrames) {
                pendingFrames.remove(frameNum)
                framesDropped++
                Log.d(TAG, "Dropped incomplete frame $frameNum (timeout)")
            }
        }
    }

    /**
     * Get stats string for debugging.
     */
    fun getStats(): String {
        return "UDP Video: pkts=$packetsReceived, frames=$framesReceived, dropped=$framesDropped"
    }
}
