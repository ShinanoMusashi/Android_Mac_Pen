package com.example.tabletpen.mirror

import com.example.tabletpen.PenData
import com.example.tabletpen.protocol.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Client for screen mirror mode.
 * Handles bidirectional communication: sends pen data, receives video frames.
 */
class MirrorClient {
    private var socket: Socket? = null
    private var inputStream: DataInputStream? = null
    private var outputStream: DataOutputStream? = null

    private var receiveJob: Job? = null
    private var sendJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // Channel for outgoing messages (CONFLATED = keep only latest pen data)
    private val sendChannel = Channel<OutgoingMessage>(Channel.CONFLATED)

    private sealed class OutgoingMessage {
        data class PenDataMsg(val data: PenData) : OutgoingMessage()
        data class ModeRequestMsg(val mode: AppMode) : OutgoingMessage()
        data class QualityRequestMsg(val bitrateMbps: Int) : OutgoingMessage()
        data class ROIUpdateMsg(val x: Float, val y: Float, val width: Float, val height: Float) : OutgoingMessage()
        data class LogDataMsg(val filename: String, val content: String) : OutgoingMessage()
        object PingMsg : OutgoingMessage()
    }

    @Volatile
    var isConnected = false
        private set

    // Latency measurement
    private var pingJob: Job? = null
    private var lastPingTime = 0L
    @Volatile
    var currentLatency = -1L
        private set

    // Performance stats for timing
    var stats: PerformanceStats? = null

    // Callbacks
    var onVideoConfig: ((VideoConfig) -> Unit)? = null
    var onVideoFrame: ((VideoFrame) -> Unit)? = null
    var onConnectionChanged: ((Boolean) -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    var onModeAck: ((AppMode) -> Unit)? = null
    var onLatencyUpdate: ((Long) -> Unit)? = null

    /**
     * Connect to the Mac server.
     */
    suspend fun connect(host: String, port: Int): Boolean = withContext(Dispatchers.IO) {
        try {
            disconnect()

            val newSocket = Socket()
            newSocket.tcpNoDelay = true
            newSocket.soTimeout = 0 // No read timeout (we handle blocking reads)
            newSocket.connect(InetSocketAddress(host, port), 5000)

            socket = newSocket
            inputStream = DataInputStream(newSocket.getInputStream())
            outputStream = DataOutputStream(newSocket.getOutputStream())
            isConnected = true

            // Start receive and send loops
            startReceiveLoop()
            startSendLoop()
            startPingLoop()

            withContext(Dispatchers.Main) {
                onConnectionChanged?.invoke(true)
            }

            true
        } catch (e: Exception) {
            e.printStackTrace()
            withContext(Dispatchers.Main) {
                onError?.invoke("Connection failed: ${e.message}")
            }
            false
        }
    }

    /**
     * Disconnect from the server.
     */
    fun disconnect() {
        isConnected = false

        pingJob?.cancel()
        pingJob = null
        receiveJob?.cancel()
        receiveJob = null
        sendJob?.cancel()
        sendJob = null

        try {
            socket?.close()
        } catch (e: Exception) {
            // Ignore
        }

        socket = null
        inputStream = null
        outputStream = null
        currentLatency = -1

        onConnectionChanged?.invoke(false)
    }

    /**
     * Request screen mirror mode from server.
     */
    fun requestMirrorMode() {
        sendModeRequest(AppMode.SCREEN_MIRROR)
    }

    /**
     * Request touchpad mode from server.
     */
    fun requestTouchpadMode() {
        sendModeRequest(AppMode.TOUCHPAD)
    }

    /**
     * Request quality settings from server.
     * @param bitrateMbps Desired bitrate in Mbps (e.g., 35 for WiFi, 50 for USB)
     */
    fun requestQuality(bitrateMbps: Int) {
        if (!isConnected) return
        scope.launch {
            sendChannel.send(OutgoingMessage.QualityRequestMsg(bitrateMbps))
        }
    }

    /**
     * Update region of interest for zoomed streaming.
     * All values are normalized (0.0 to 1.0) relative to screen size.
     * @param x Left position (0.0 = left edge)
     * @param y Top position (0.0 = top edge)
     * @param width Width of region (1.0 = full width)
     * @param height Height of region (1.0 = full height)
     */
    fun updateROI(x: Float, y: Float, width: Float, height: Float) {
        if (!isConnected) return
        sendChannel.trySend(OutgoingMessage.ROIUpdateMsg(x, y, width, height))
    }

    /**
     * Send log data to Mac for saving.
     */
    fun sendLogData(filename: String, content: String) {
        if (!isConnected) return
        scope.launch {
            sendChannel.send(OutgoingMessage.LogDataMsg(filename, content))
        }
    }

    private fun sendModeRequest(mode: AppMode) {
        if (!isConnected) return
        scope.launch {
            sendChannel.send(OutgoingMessage.ModeRequestMsg(mode))
        }
    }

    /**
     * Send pen data to the server.
     */
    fun sendPenData(penData: PenData) {
        if (!isConnected) return
        // Use trySend to avoid blocking - if channel is full, latest data replaces old
        sendChannel.trySend(OutgoingMessage.PenDataMsg(penData))
    }

    private fun startPingLoop() {
        pingJob = scope.launch {
            while (isActive && isConnected) {
                delay(1000) // Send ping every second
                if (isConnected) {
                    sendChannel.trySend(OutgoingMessage.PingMsg)
                }
            }
        }
    }

    private fun startSendLoop() {
        sendJob = scope.launch {
            try {
                for (message in sendChannel) {
                    if (!isConnected) break
                    val output = outputStream ?: break

                    when (message) {
                        is OutgoingMessage.PenDataMsg -> {
                            ProtocolCodec.writePenData(output, message.data.serialize())
                        }
                        is OutgoingMessage.ModeRequestMsg -> {
                            ProtocolCodec.writeModeRequest(output, message.mode)
                        }
                        is OutgoingMessage.QualityRequestMsg -> {
                            ProtocolCodec.writeQualityRequest(output, message.bitrateMbps)
                        }
                        is OutgoingMessage.ROIUpdateMsg -> {
                            ProtocolCodec.writeROIUpdate(output, message.x, message.y, message.width, message.height)
                        }
                        is OutgoingMessage.LogDataMsg -> {
                            ProtocolCodec.writeLogData(output, message.filename, message.content)
                        }
                        is OutgoingMessage.PingMsg -> {
                            lastPingTime = System.currentTimeMillis()
                            ProtocolCodec.writePing(output)
                        }
                    }
                }
            } catch (e: Exception) {
                if (isConnected) {
                    handleDisconnect("Send error: ${e.message}")
                }
            }
        }
    }

    private fun startReceiveLoop() {
        receiveJob = scope.launch {
            try {
                while (isActive && isConnected) {
                    val input = inputStream ?: break
                    val message = ProtocolCodec.readMessage(input) ?: break

                    handleMessage(message)
                }
            } catch (e: Exception) {
                if (isActive) {
                    handleDisconnect("Receive error: ${e.message}")
                }
            }
        }
    }

    private suspend fun handleMessage(message: ProtocolMessage) {
        when (message.type) {
            MessageType.VIDEO_CONFIG -> {
                ProtocolCodec.parseVideoConfig(message.payload)?.let { config ->
                    withContext(Dispatchers.Main) {
                        onVideoConfig?.invoke(config)
                    }
                }
            }

            MessageType.VIDEO_FRAME -> {
                ProtocolCodec.parseVideoFrame(message.payload)?.let { frame ->
                    // Timing: record network receive
                    stats?.onNetworkReceive(frame.frameNumber, frame.nalData.size, frame.isKeyframe)

                    // Don't switch to Main thread for frames (performance)
                    onVideoFrame?.invoke(frame)
                }
            }

            MessageType.MODE_ACK -> {
                val mode = if (message.payload.isNotEmpty()) {
                    AppMode.fromValue(message.payload[0]) ?: AppMode.TOUCHPAD
                } else {
                    AppMode.TOUCHPAD
                }
                withContext(Dispatchers.Main) {
                    onModeAck?.invoke(mode)
                }
            }

            MessageType.PONG -> {
                // Calculate round-trip latency
                if (lastPingTime > 0) {
                    currentLatency = System.currentTimeMillis() - lastPingTime
                    withContext(Dispatchers.Main) {
                        onLatencyUpdate?.invoke(currentLatency)
                    }
                }
            }

            else -> {
                // Unknown message type
            }
        }
    }

    private fun handleDisconnect(reason: String) {
        if (isConnected) {
            isConnected = false
            scope.launch(Dispatchers.Main) {
                onError?.invoke(reason)
                onConnectionChanged?.invoke(false)
            }
        }
    }

    /**
     * Clean up resources.
     */
    fun release() {
        disconnect()
        scope.cancel()
    }
}
