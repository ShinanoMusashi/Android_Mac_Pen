package com.example.tabletpen.mirror

import com.example.tabletpen.PenData
import com.example.tabletpen.protocol.MessageType
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer

/**
 * UDP sender for low-latency pen data.
 * Runs alongside TCP for video, providing faster pen input path.
 *
 * UDP advantages for pen data:
 * - No ACK waiting (fire-and-forget)
 * - No retransmission delays
 * - Lower overhead (~28 bytes vs ~40 bytes for TCP)
 * - If packet is lost, next one has newer position anyway
 */
class UDPPenSender {
    private var socket: DatagramSocket? = null
    private var targetAddress: InetAddress? = null
    private var targetPort: Int = 9877

    private var sendJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // Channel for outgoing pen data (CONFLATED = keep only latest)
    private val sendChannel = Channel<PenData>(Channel.CONFLATED)

    @Volatile
    var isConnected = false
        private set

    /**
     * Connect to the Mac server's UDP port.
     * Note: UDP is connectionless, this just sets up the target address.
     */
    fun connect(host: String, port: Int = 9877): Boolean {
        return try {
            targetAddress = InetAddress.getByName(host)
            targetPort = port
            socket = DatagramSocket()
            isConnected = true
            startSendLoop()
            android.util.Log.i("UDPPenSender", "UDP sender ready: $host:$port")
            true
        } catch (e: Exception) {
            android.util.Log.e("UDPPenSender", "Failed to setup UDP: ${e.message}")
            false
        }
    }

    /**
     * Disconnect and cleanup.
     */
    fun disconnect() {
        isConnected = false
        sendJob?.cancel()
        sendJob = null

        try {
            socket?.close()
        } catch (e: Exception) {
            // Ignore
        }
        socket = null
        targetAddress = null
    }

    /**
     * Send pen data via UDP.
     * Uses fire-and-forget semantics - if channel is full, latest data replaces old.
     */
    fun sendPenData(penData: PenData) {
        if (!isConnected) return
        sendChannel.trySend(penData)
    }

    private fun startSendLoop() {
        sendJob = scope.launch {
            try {
                for (penData in sendChannel) {
                    if (!isConnected) break
                    sendPacket(penData)
                }
            } catch (e: Exception) {
                if (isConnected) {
                    android.util.Log.e("UDPPenSender", "Send error: ${e.message}")
                }
            }
        }
    }

    private fun sendPacket(penData: PenData) {
        val socket = socket ?: return
        val address = targetAddress ?: return

        // Encode pen data in same format as TCP binary protocol
        // [Type: 1 byte][Length: 4 bytes BE][Payload: variable]
        val payload = penData.serialize().toByteArray(Charsets.UTF_8)
        val packet = ByteBuffer.allocate(5 + payload.size)

        packet.put(MessageType.PEN_DATA.value)
        packet.putInt(payload.size)
        packet.put(payload)

        val data = packet.array()
        val datagramPacket = DatagramPacket(data, data.size, address, targetPort)

        try {
            socket.send(datagramPacket)
        } catch (e: Exception) {
            // UDP send errors are usually transient, don't disconnect
            android.util.Log.w("UDPPenSender", "UDP send failed: ${e.message}")
        }
    }

    /**
     * Release resources.
     */
    fun release() {
        disconnect()
        scope.cancel()
    }
}
