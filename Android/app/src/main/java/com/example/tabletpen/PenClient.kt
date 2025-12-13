package com.example.tabletpen

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.consumeEach
import java.io.BufferedWriter
import java.io.OutputStreamWriter
import java.net.Socket

/**
 * Network client that sends pen data to the Mac server.
 */
class PenClient {

    private var socket: Socket? = null
    private var writer: BufferedWriter? = null
    private var sendJob: Job? = null
    private val dataChannel = Channel<PenData>(Channel.CONFLATED) // Only keep latest data

    var onConnectionChanged: ((Boolean) -> Unit)? = null
    var onError: ((String) -> Unit)? = null

    val isConnected: Boolean
        get() = socket?.isConnected == true && socket?.isClosed == false

    /**
     * Connect to the Mac server.
     */
    suspend fun connect(host: String, port: Int): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                disconnect()

                socket = Socket(host, port).apply {
                    tcpNoDelay = true  // Disable Nagle's algorithm for lower latency
                    soTimeout = 5000
                }
                writer = BufferedWriter(OutputStreamWriter(socket!!.getOutputStream()))

                // Start send loop
                startSendLoop()

                withContext(Dispatchers.Main) {
                    onConnectionChanged?.invoke(true)
                }
                true
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    onError?.invoke("Connection failed: ${e.message}")
                    onConnectionChanged?.invoke(false)
                }
                false
            }
        }
    }

    /**
     * Disconnect from the server.
     */
    fun disconnect() {
        sendJob?.cancel()
        sendJob = null

        try {
            writer?.close()
            socket?.close()
        } catch (e: Exception) {
            // Ignore close errors
        }

        writer = null
        socket = null
        onConnectionChanged?.invoke(false)
    }

    /**
     * Queue pen data to be sent.
     */
    fun sendPenData(data: PenData) {
        dataChannel.trySend(data)
    }

    private fun startSendLoop() {
        sendJob = CoroutineScope(Dispatchers.IO).launch {
            try {
                dataChannel.consumeEach { data ->
                    try {
                        writer?.apply {
                            write(data.serialize())
                            flush()
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            onError?.invoke("Send error: ${e.message}")
                            disconnect()
                        }
                        return@consumeEach
                    }
                }
            } catch (e: CancellationException) {
                // Normal cancellation
            }
        }
    }
}
