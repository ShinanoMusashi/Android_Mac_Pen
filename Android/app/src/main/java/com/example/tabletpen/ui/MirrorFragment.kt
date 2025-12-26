package com.example.tabletpen.ui

import android.content.Context
import android.content.SharedPreferences
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.view.*
import android.widget.FrameLayout
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import androidx.navigation.fragment.findNavController
import com.example.tabletpen.PenData
import com.example.tabletpen.R
import com.example.tabletpen.databinding.FragmentMirrorBinding
import com.example.tabletpen.mirror.MirrorClient
import com.example.tabletpen.mirror.PerformanceStats
import com.example.tabletpen.mirror.VideoDecoder
import com.example.tabletpen.protocol.AppMode
import com.example.tabletpen.protocol.VideoConfig
import com.example.tabletpen.protocol.VideoFrame
import kotlinx.coroutines.launch
import kotlin.math.abs

class MirrorFragment : Fragment(), SurfaceHolder.Callback {

    private var _binding: FragmentMirrorBinding? = null
    private val binding get() = _binding!!

    private lateinit var prefs: SharedPreferences

    private val mirrorClient = MirrorClient()
    private var videoDecoder: VideoDecoder? = null
    private var surfaceView: SurfaceView? = null

    private var videoConfig: VideoConfig? = null
    private var surfaceReady = false

    // For aspect ratio calculation
    private var videoWidth = 0
    private var videoHeight = 0

    // Stats display
    private var statsVisible = false
    private var performanceStats: PerformanceStats? = null
    private var isLogging = false
    private var isPipelineLogging = false

    // Toolbox state
    private var toolboxVisible = false
    private var cursorModeEnabled = true
    private var topBarHidden = false

    // Pinch-to-zoom and pan state
    private var currentZoom = 1.0f
    private var panX = 0f
    private var panY = 0f
    private val minZoom = 0.5f
    private val maxZoom = 5.0f
    private var scaleGestureDetector: ScaleGestureDetector? = null
    private var lastTouchX = 0f
    private var lastTouchY = 0f
    private var isPanning = false
    private var activePointerId = MotionEvent.INVALID_POINTER_ID

    // ROI update throttling
    private var lastROIUpdateTime = 0L
    private var lastROIX = 0f
    private var lastROIY = 0f
    private var lastROIWidth = 1f
    private var lastROIHeight = 1f

    // USB/ADB connection mode
    private var useUsbConnection = false

    // Immersive mode
    private var isImmersive = false

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentMirrorBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        prefs = requireContext().getSharedPreferences("TabletPen", Context.MODE_PRIVATE)

        setupBackButtons()
        setupConnectionUI()
        setupVideoSurface()
        setupPenInput()
        setupStatsOverlay()
        setupToolbox()
        setupGestures()
        setupImmersiveMode()
    }

    private fun setupBackButtons() {
        val backAction = {
            mirrorClient.requestTouchpadMode()
            mirrorClient.disconnect()
            findNavController().navigateUp()
        }
        binding.backButton.setOnClickListener { backAction() }
        binding.backButtonCollapsed.setOnClickListener { backAction() }
    }

    private fun setupConnectionUI() {
        // Load saved settings
        val savedIp = prefs.getString("ip_address", "192.168.1.")
        useUsbConnection = prefs.getBoolean("use_usb", false)
        binding.ipAddressInput.setText(savedIp)
        updateUsbToggleUI()

        // USB toggle button
        binding.usbToggle.setOnClickListener {
            useUsbConnection = !useUsbConnection
            prefs.edit().putBoolean("use_usb", useUsbConnection).apply()
            updateUsbToggleUI()
        }

        // Client callbacks
        mirrorClient.onConnectionChanged = { connected ->
            activity?.runOnUiThread {
                updateConnectionUI(connected)
                if (connected) {
                    // Send quality request based on connection type
                    val bitrateMbps = if (useUsbConnection) 50 else 35
                    mirrorClient.requestQuality(bitrateMbps)
                    // Request mirror mode after connection
                    mirrorClient.requestMirrorMode()
                }
            }
        }

        mirrorClient.onError = { error ->
            activity?.runOnUiThread {
                Toast.makeText(requireContext(), error, Toast.LENGTH_SHORT).show()
            }
        }

        mirrorClient.onVideoConfig = { config ->
            activity?.runOnUiThread {
                handleVideoConfig(config)
            }
        }

        mirrorClient.onVideoFrame = { frame ->
            handleVideoFrame(frame)
        }

        mirrorClient.onModeAck = { mode ->
            activity?.runOnUiThread {
                if (mode == AppMode.SCREEN_MIRROR) {
                    binding.placeholderText.text = "Waiting for video stream..."
                }
            }
        }

        // Connect button
        binding.connectButton.setOnClickListener {
            if (mirrorClient.isConnected) {
                mirrorClient.requestTouchpadMode()
                mirrorClient.disconnect()
            } else {
                connect()
            }
        }

        // Expand button
        binding.expandButton.setOnClickListener {
            showExpandedConnectionPanel()
        }

        updateConnectionUI(false)
    }

    private fun showExpandedConnectionPanel() {
        binding.collapsedBar.visibility = View.GONE
        binding.connectionPanel.visibility = View.VISIBLE
        binding.statusText.visibility = View.VISIBLE
    }

    private fun showCollapsedConnectionBar() {
        binding.connectionPanel.visibility = View.GONE
        binding.statusText.visibility = View.GONE
        binding.collapsedBar.visibility = View.VISIBLE
    }

    private fun setupVideoSurface() {
        // Add SurfaceView to the container
        val sv = SurfaceView(requireContext())
        sv.layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
            Gravity.CENTER
        )
        sv.holder.addCallback(this)
        surfaceView = sv

        // Insert at index 0 so placeholder text is on top
        binding.videoContainer.addView(sv, 0)
    }

    private fun setupStatsOverlay() {
        // Initialize performance stats
        performanceStats = PerformanceStats(context)

        // Wire up stats to client for network receive timing
        mirrorClient.stats = performanceStats

        // Stats toggle button
        binding.statsToggleButton.setOnClickListener {
            statsVisible = !statsVisible
            binding.statsOverlay.visibility = if (statsVisible) View.VISIBLE else View.GONE
            binding.statsToggleButton.text = if (statsVisible) "Hide Stats" else getString(R.string.stats)
        }

        // Log toggle button
        binding.logToggleButton.setOnClickListener {
            isLogging = !isLogging
            if (isLogging) {
                performanceStats?.startLogging()
                binding.logToggleButton.text = "Stop Log"
                Toast.makeText(context, "Logging started", Toast.LENGTH_SHORT).show()
            } else {
                performanceStats?.stopLogging()
                binding.logToggleButton.text = "Start Log"
                Toast.makeText(context, "Log saved to app files", Toast.LENGTH_SHORT).show()
            }
        }

        // Network latency callback (ping RTT)
        mirrorClient.onLatencyUpdate = { latency ->
            activity?.runOnUiThread {
                updateNetworkLatencyDisplay(latency)
            }
        }
    }

    private fun setupToolbox() {
        // Toolbox toggle (FAB button)
        binding.toolboxToggle.setOnClickListener {
            toolboxVisible = !toolboxVisible
            binding.toolbox.visibility = if (toolboxVisible) View.VISIBLE else View.GONE
        }

        // Cursor mode (pen controls cursor)
        binding.toolCursor.setOnClickListener {
            cursorModeEnabled = true
            updateToolModeButtons()
        }

        // View only mode (no cursor control)
        binding.toolViewOnly.setOnClickListener {
            cursorModeEnabled = false
            updateToolModeButtons()
        }

        // Zoom controls - now just for quick zoom, pinch-to-zoom is primary
        binding.toolZoomIn.setOnClickListener {
            currentZoom = (currentZoom * 1.25f).coerceAtMost(maxZoom)
            applyTransform()
        }

        binding.toolZoomOut.setOnClickListener {
            currentZoom = (currentZoom / 1.25f).coerceAtLeast(minZoom)
            applyTransform()
        }

        // Long press to reset zoom/pan
        binding.toolZoomOut.setOnLongClickListener {
            resetTransform()
            Toast.makeText(context, "Reset zoom", Toast.LENGTH_SHORT).show()
            true
        }

        // Stats toggle
        binding.toolStats.setOnClickListener {
            statsVisible = !statsVisible
            binding.statsOverlay.visibility = if (statsVisible) View.VISIBLE else View.GONE
            updateToolButtonState(binding.toolStats, statsVisible)
        }

        // Log toggle
        binding.toolLog.setOnClickListener {
            isLogging = !isLogging
            if (isLogging) {
                performanceStats?.startLogging()
                Toast.makeText(context, "Logging started", Toast.LENGTH_SHORT).show()
            } else {
                performanceStats?.stopLogging()
                Toast.makeText(context, "Log saved", Toast.LENGTH_SHORT).show()
            }
            updateToolButtonState(binding.toolLog, isLogging)
        }

        // Pipeline log toggle
        binding.toolPipelineLog.setOnClickListener {
            isPipelineLogging = !isPipelineLogging
            if (isPipelineLogging) {
                performanceStats?.startPipelineLogging()
                Toast.makeText(context, "Pipeline logging started", Toast.LENGTH_SHORT).show()
            } else {
                performanceStats?.stopPipelineLogging()
                Toast.makeText(context, "Pipeline log saved", Toast.LENGTH_SHORT).show()
            }
            updateToolButtonState(binding.toolPipelineLog, isPipelineLogging)
        }

        // Hide/show top bar
        binding.toolHideBar.setOnClickListener {
            topBarHidden = !topBarHidden
            if (topBarHidden) {
                binding.collapsedBar.visibility = View.GONE
                binding.connectionPanel.visibility = View.GONE
                binding.statusText.visibility = View.GONE
            } else {
                if (mirrorClient.isConnected) {
                    binding.collapsedBar.visibility = View.VISIBLE
                } else {
                    binding.connectionPanel.visibility = View.VISIBLE
                    binding.statusText.visibility = View.VISIBLE
                }
            }
            updateToolButtonState(binding.toolHideBar, topBarHidden)
        }

        // Fullscreen toggle
        binding.toolFullscreen.setOnClickListener {
            if (isImmersive) {
                exitImmersiveMode()
            } else {
                enterImmersiveMode()
            }
            updateToolButtonState(binding.toolFullscreen, isImmersive)
        }

        // Make toolbox draggable via drag handle
        setupToolboxDrag()
    }

    private fun setupToolboxDrag() {
        var initialX = 0f
        var initialY = 0f
        var initialTouchX = 0f
        var initialTouchY = 0f

        binding.toolboxDragHandle.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    initialX = binding.toolbox.x
                    initialY = binding.toolbox.y
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    binding.toolbox.x = initialX + (event.rawX - initialTouchX)
                    binding.toolbox.y = initialY + (event.rawY - initialTouchY)
                    true
                }
                else -> false
            }
        }
    }

    private fun updateToolModeButtons() {
        if (cursorModeEnabled) {
            binding.toolCursor.setBackgroundResource(R.drawable.tool_button_selected)
            binding.toolViewOnly.setBackgroundResource(R.drawable.tool_button_normal)
            binding.toolCursor.imageTintList = android.content.res.ColorStateList.valueOf(0xFFFFFFFF.toInt())
            binding.toolViewOnly.imageTintList = android.content.res.ColorStateList.valueOf(0xFFAAAAAA.toInt())
        } else {
            binding.toolCursor.setBackgroundResource(R.drawable.tool_button_normal)
            binding.toolViewOnly.setBackgroundResource(R.drawable.tool_button_selected)
            binding.toolCursor.imageTintList = android.content.res.ColorStateList.valueOf(0xFFAAAAAA.toInt())
            binding.toolViewOnly.imageTintList = android.content.res.ColorStateList.valueOf(0xFFFFFFFF.toInt())
        }
    }

    private fun updateToolButtonState(button: android.widget.ImageButton, active: Boolean) {
        if (active) {
            button.setBackgroundResource(R.drawable.tool_button_selected)
        } else {
            button.setBackgroundResource(R.drawable.tool_button_normal)
        }
    }

    private fun applyTransform() {
        binding.zoomLevel.text = "${(currentZoom * 100).toInt()}%"
        surfaceView?.let { sv ->
            sv.scaleX = currentZoom
            sv.scaleY = currentZoom
            sv.translationX = panX
            sv.translationY = panY
        }

        // Send ROI update to Mac for zoomed streaming
        updateROI()
    }

    /**
     * Calculate and send the visible region of interest to the Mac.
     * When zoomed in, this tells Mac to only stream the visible portion at full resolution.
     */
    private fun updateROI() {
        if (!mirrorClient.isConnected) return

        val sv = surfaceView ?: return
        val svWidth = sv.width.toFloat()
        val svHeight = sv.height.toFloat()
        if (svWidth <= 0 || svHeight <= 0) return

        // Calculate visible region in normalized coordinates (0.0 to 1.0)
        // When zoomed in, visible area is smaller
        val visibleWidth = (1.0f / currentZoom).coerceIn(0.1f, 1f)
        val visibleHeight = (1.0f / currentZoom).coerceIn(0.1f, 1f)

        // Calculate center offset from pan (pan is in pixels, convert to normalized)
        // At zoom 1.0, pan has no effect on visible region
        // At zoom 2.0, pan of svWidth/2 means we're showing second half
        val centerOffsetX = -panX / (svWidth * currentZoom)
        val centerOffsetY = -panY / (svHeight * currentZoom)

        // Calculate top-left corner of visible region
        // Center is at 0.5, 0.5 when no pan
        var roiX = 0.5f - visibleWidth / 2 + centerOffsetX
        var roiY = 0.5f - visibleHeight / 2 + centerOffsetY

        // Clamp to valid range (ensure we don't go negative or exceed bounds)
        val maxX = (1f - visibleWidth).coerceAtLeast(0f)
        val maxY = (1f - visibleHeight).coerceAtLeast(0f)
        roiX = roiX.coerceIn(0f, maxX)
        roiY = roiY.coerceIn(0f, maxY)

        // Throttle updates to max 10 per second, and only send if changed significantly
        val now = System.currentTimeMillis()
        val timeSinceLastUpdate = now - lastROIUpdateTime
        val roiChanged = kotlin.math.abs(roiX - lastROIX) > 0.01f ||
                        kotlin.math.abs(roiY - lastROIY) > 0.01f ||
                        kotlin.math.abs(visibleWidth - lastROIWidth) > 0.01f ||
                        kotlin.math.abs(visibleHeight - lastROIHeight) > 0.01f

        if (timeSinceLastUpdate < 100 && !roiChanged) {
            return  // Skip this update
        }

        lastROIUpdateTime = now
        lastROIX = roiX
        lastROIY = roiY
        lastROIWidth = visibleWidth
        lastROIHeight = visibleHeight

        // Only send ROI if zoomed in significantly (>120%)
        if (currentZoom > 1.2f) {
            mirrorClient.updateROI(roiX, roiY, visibleWidth, visibleHeight)
        } else {
            // Reset to full screen
            mirrorClient.updateROI(0f, 0f, 1f, 1f)
        }
    }

    private fun resetTransform() {
        currentZoom = 1.0f
        panX = 0f
        panY = 0f
        applyTransform()
    }

    private fun setupGestures() {
        // Scale gesture detector for pinch-to-zoom
        scaleGestureDetector = ScaleGestureDetector(requireContext(), object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: ScaleGestureDetector): Boolean {
                currentZoom *= detector.scaleFactor
                currentZoom = currentZoom.coerceIn(minZoom, maxZoom)
                applyTransform()
                return true
            }
        })

        // Touch listener for pan and zoom gestures on video container
        binding.videoContainer.setOnTouchListener { _, event ->
            // Let scale detector handle pinch gestures
            scaleGestureDetector?.onTouchEvent(event)

            // Handle pan with two fingers
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    activePointerId = event.getPointerId(0)
                    lastTouchX = event.x
                    lastTouchY = event.y
                    isPanning = false
                }
                MotionEvent.ACTION_POINTER_DOWN -> {
                    // Second finger down - start panning
                    if (event.pointerCount == 2) {
                        isPanning = true
                        // Use midpoint of two fingers
                        lastTouchX = (event.getX(0) + event.getX(1)) / 2
                        lastTouchY = (event.getY(0) + event.getY(1)) / 2
                    }
                }
                MotionEvent.ACTION_MOVE -> {
                    if (event.pointerCount == 2 && isPanning) {
                        // Two-finger pan
                        val midX = (event.getX(0) + event.getX(1)) / 2
                        val midY = (event.getY(0) + event.getY(1)) / 2
                        panX += midX - lastTouchX
                        panY += midY - lastTouchY
                        lastTouchX = midX
                        lastTouchY = midY
                        applyTransform()
                    } else if (event.pointerCount == 1 && cursorModeEnabled && !isPanning) {
                        // Single finger - send pen data (cursor control)
                        handlePenEvent(event)
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    isPanning = false
                    activePointerId = MotionEvent.INVALID_POINTER_ID
                }
                MotionEvent.ACTION_POINTER_UP -> {
                    isPanning = false
                }
            }

            // For single touch, also handle pen events
            if (event.pointerCount == 1 && !isPanning && cursorModeEnabled) {
                if (event.actionMasked == MotionEvent.ACTION_DOWN ||
                    event.actionMasked == MotionEvent.ACTION_UP) {
                    handlePenEvent(event)
                }
            }
            true
        }
    }

    private fun setupImmersiveMode() {
        // Prepare for edge-to-edge display
        activity?.window?.let { window ->
            WindowCompat.setDecorFitsSystemWindows(window, false)
        }
    }

    private fun enterImmersiveMode() {
        isImmersive = true
        activity?.window?.let { window ->
            val controller = WindowCompat.getInsetsController(window, window.decorView)
            // Set behavior FIRST before hiding
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            // Hide both status bar and navigation bar
            controller.hide(WindowInsetsCompat.Type.systemBars())

            // Also use legacy flags for broader compatibility
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            )
        }
    }

    private fun exitImmersiveMode() {
        isImmersive = false
        activity?.window?.let { window ->
            val controller = WindowCompat.getInsetsController(window, window.decorView)
            controller.show(WindowInsetsCompat.Type.systemBars())

            // Clear legacy flags
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
        }
    }

    private fun updateUsbToggleUI() {
        if (useUsbConnection) {
            binding.usbToggle.text = "USB"
            binding.usbToggle.setBackgroundColor(ContextCompat.getColor(requireContext(), R.color.purple_500))
            binding.usbToggle.setTextColor(ContextCompat.getColor(requireContext(), android.R.color.white))
            binding.ipInputLayout.visibility = View.GONE
        } else {
            binding.usbToggle.text = "WiFi"
            binding.usbToggle.setBackgroundColor(ContextCompat.getColor(requireContext(), android.R.color.transparent))
            binding.usbToggle.setTextColor(ContextCompat.getColor(requireContext(), R.color.purple_200))
            binding.ipInputLayout.visibility = View.VISIBLE
        }
    }

    private fun updateNetworkLatencyDisplay(latency: Long) {
        if (_binding == null) return
        binding.statsNetwork.text = "Net RTT: ${latency}ms"
    }

    private fun updateStatsDisplay(stats: PerformanceStats) {
        if (_binding == null) return
        activity?.runOnUiThread {
            // FPS with color coding
            val fpsColor = when {
                stats.currentFps >= 55 -> "#00FF00"
                stats.currentFps >= 30 -> "#FFFF00"
                else -> "#FF0000"
            }
            binding.statsFps.text = "FPS: %.1f".format(stats.currentFps)
            binding.statsFps.setTextColor(android.graphics.Color.parseColor(fpsColor))

            // 1% low and 5% low
            val lowColor = when {
                stats.fivePercentLow >= 30 -> "#00FF00"
                stats.fivePercentLow >= 20 -> "#FFFF00"
                else -> "#FF0000"
            }
            binding.statsLowFps.text = "1%%: %.1f | 5%%: %.1f".format(stats.onePercentLow, stats.fivePercentLow)
            binding.statsLowFps.setTextColor(android.graphics.Color.parseColor(lowColor))

            // Latency (end-to-end from frame timestamp)
            val latencyColor = when {
                stats.avgLatency < 100 -> "#00FF00"
                stats.avgLatency < 200 -> "#FFFF00"
                else -> "#FF0000"
            }
            binding.statsLatency.text = "E2E: ${stats.avgLatency}ms (max: ${stats.maxLatency}ms)"
            binding.statsLatency.setTextColor(android.graphics.Color.parseColor(latencyColor))

            // Frame time
            binding.statsFrameTime.text = "Frame: %.1fms".format(stats.avgFrameTime)

            // Queue and dropped
            binding.statsQueue.text = "Queue: ${stats.queueDepth} | Drop: ${stats.totalFramesDropped}"

            // Keyframe info
            val kfInterval = if (stats.keyframeInterval > 0) "${stats.keyframeInterval}ms" else "--"
            binding.statsKeyframe.text = "KF: ${stats.keyframeCount} @ $kfInterval"

            // Decoder info
            videoDecoder?.let { decoder ->
                val hwIndicator = if (decoder.isHardwareDecoder) "HW" else "SW"
                // Shorten decoder name for display
                val shortName = decoder.decoderName
                    .replace("OMX.", "")
                    .replace("c2.", "")
                    .replace(".avc.decoder", "")
                    .replace(".decoder.avc", "")
                    .take(20)
                binding.statsDecoder.text = "Dec: $hwIndicator $shortName"
                binding.statsDecoder.setTextColor(
                    if (decoder.isHardwareDecoder) 0xFF00FF00.toInt() else 0xFFFF0000.toInt()
                )
            }

            // Pipeline timing
            binding.statsPipeline.text = "Net→Q: %.1f | Q: %.1f | Dec: %.1f | Rnd: %.1f".format(
                stats.avgNetworkToQueue,
                stats.avgQueueWait,
                stats.avgDecodeTime,
                stats.avgDecodeToRender
            )
            binding.statsPipelineTotal.text = "Total Android: %.1f ms".format(stats.avgTotalPipeline)

            // Color code pipeline total based on target latency
            val pipelineColor = when {
                stats.avgTotalPipeline <= 17 -> 0xFF00FF00.toInt()  // Green - excellent
                stats.avgTotalPipeline <= 25 -> 0xFF88FF00.toInt()  // Yellow-green - good
                stats.avgTotalPipeline <= 50 -> 0xFFFFFF00.toInt()  // Yellow - acceptable
                else -> 0xFFFF0000.toInt()  // Red - too slow
            }
            binding.statsPipelineTotal.setTextColor(pipelineColor)
        }
    }

    private fun setupPenInput() {
        // Touch is now handled in setupGestures()
        // Only set up hover events here for pen hovering
        binding.videoContainer.setOnHoverListener { _, event ->
            if (cursorModeEnabled && !isPanning) {
                handlePenEvent(event)
            }
            true
        }
    }

    private fun handlePenEvent(event: MotionEvent) {
        if (!mirrorClient.isConnected) return
        if (!cursorModeEnabled) return  // View-only mode

        val sv = surfaceView ?: return

        // Get the actual video surface bounds
        val surfaceWidth = sv.width.toFloat()
        val surfaceHeight = sv.height.toFloat()

        if (surfaceWidth <= 0 || surfaceHeight <= 0) return

        // Calculate the touch position relative to the container
        val containerWidth = binding.videoContainer.width.toFloat()
        val containerHeight = binding.videoContainer.height.toFloat()

        // Account for zoom and pan transformations
        // The surface is centered, then scaled, then translated
        val scaledWidth = surfaceWidth * currentZoom
        val scaledHeight = surfaceHeight * currentZoom

        // Center position of surface in container
        val centerX = containerWidth / 2 + panX
        val centerY = containerHeight / 2 + panY

        // Surface bounds after transformation
        val surfaceLeft = centerX - scaledWidth / 2
        val surfaceTop = centerY - scaledHeight / 2

        // Touch position relative to the transformed surface
        val relativeX = (event.x - surfaceLeft) / currentZoom
        val relativeY = (event.y - surfaceTop) / currentZoom

        // Normalize coordinates to 0.0 - 1.0 (relative to video surface)
        // These are ABSOLUTE positions on the screen
        val normalizedX = (relativeX / surfaceWidth).coerceIn(0f, 1f)
        val normalizedY = (relativeY / surfaceHeight).coerceIn(0f, 1f)

        // Get pressure
        val pressure = when (event.action) {
            MotionEvent.ACTION_HOVER_ENTER,
            MotionEvent.ACTION_HOVER_MOVE,
            MotionEvent.ACTION_HOVER_EXIT -> 0f
            else -> event.pressure.coerceIn(0f, 1f)
        }

        // Check pen button
        val buttonPressed = (event.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY) != 0 ||
                (event.buttonState and MotionEvent.BUTTON_SECONDARY) != 0

        // Determine state
        val isHovering = event.action == MotionEvent.ACTION_HOVER_ENTER ||
                event.action == MotionEvent.ACTION_HOVER_MOVE
        val isDown = event.action == MotionEvent.ACTION_DOWN ||
                event.action == MotionEvent.ACTION_MOVE

        val penData = PenData(
            x = normalizedX,
            y = normalizedY,
            pressure = pressure,
            isHovering = isHovering,
            isDown = isDown,
            buttonPressed = buttonPressed,
            tiltX = 0f,
            tiltY = 0f,
            timestamp = event.eventTime
        )

        mirrorClient.sendPenData(penData)
    }

    private fun connect() {
        // Use localhost for USB, otherwise use entered IP
        val ip = if (useUsbConnection) {
            "127.0.0.1"  // ADB forwards localhost to Mac
        } else {
            binding.ipAddressInput.text.toString().trim()
        }
        val port = binding.portInput.text.toString().toIntOrNull() ?: 9876

        if (!useUsbConnection && ip.isEmpty()) {
            Toast.makeText(requireContext(), "Please enter IP address", Toast.LENGTH_SHORT).show()
            return
        }

        // Save IP for next time (only for WiFi mode)
        if (!useUsbConnection) {
            prefs.edit().putString("ip_address", ip).apply()
        }

        binding.statusText.text = getString(R.string.status_connecting)
        binding.statusText.setTextColor(ContextCompat.getColor(requireContext(), R.color.teal_200))
        binding.connectButton.isEnabled = false

        viewLifecycleOwner.lifecycleScope.launch {
            val success = mirrorClient.connect(ip, port)
            binding.connectButton.isEnabled = true

            if (!success) {
                binding.statusText.text = getString(R.string.status_disconnected)
                binding.statusText.setTextColor(ContextCompat.getColor(requireContext(), R.color.disconnected_red))
            }
        }
    }

    private fun handleVideoConfig(config: VideoConfig) {
        videoConfig = config
        videoWidth = config.width
        videoHeight = config.height
        binding.placeholderText.text = "Video: ${config.width}x${config.height} @ ${config.fps}fps"

        // Update stats overlay
        binding.statsResolution.text = "Resolution: ${config.width}x${config.height}"
        val bitrateMbps = config.bitrate / 1_000_000f
        binding.statsBitrate.text = "Bitrate: %.1f Mbps".format(bitrateMbps)

        // Update surface size for proper aspect ratio
        updateSurfaceSize()

        // Initialize decoder if surface is ready
        if (surfaceReady) {
            initializeDecoder(config)
        }
    }

    private fun updateSurfaceSize() {
        val sv = surfaceView ?: return
        if (videoWidth <= 0 || videoHeight <= 0) return

        val containerWidth = binding.videoContainer.width
        val containerHeight = binding.videoContainer.height

        if (containerWidth <= 0 || containerHeight <= 0) return

        // Calculate size that fits within container while maintaining aspect ratio
        val videoAspect = videoWidth.toFloat() / videoHeight
        val containerAspect = containerWidth.toFloat() / containerHeight

        val (newWidth, newHeight) = if (videoAspect > containerAspect) {
            // Video is wider - fit to width
            containerWidth to (containerWidth / videoAspect).toInt()
        } else {
            // Video is taller - fit to height
            (containerHeight * videoAspect).toInt() to containerHeight
        }

        // Update SurfaceView layout with centered gravity
        sv.layoutParams = FrameLayout.LayoutParams(newWidth, newHeight, Gravity.CENTER)
        sv.requestLayout()
    }

    private fun handleVideoFrame(frame: VideoFrame) {
        videoDecoder?.decode(frame.nalData, frame.timestamp, frame.isKeyframe, frame.frameNumber)
    }

    private fun initializeDecoder(config: VideoConfig) {
        // Release existing decoder
        videoDecoder?.release()

        val sv = surfaceView ?: return
        val surface = sv.holder.surface ?: return

        // Reset and configure performance stats
        performanceStats?.reset()
        performanceStats?.sourceWidth = config.width
        performanceStats?.sourceHeight = config.height

        val decoder = VideoDecoder()
        decoder.stats = performanceStats
        decoder.onStatsUpdate = { _, _ ->
            performanceStats?.let { updateStatsDisplay(it) }
        }

        if (decoder.initialize(surface, config.width, config.height)) {
            videoDecoder = decoder
            binding.placeholderText.visibility = View.GONE
        } else {
            Toast.makeText(requireContext(), "Failed to initialize video decoder", Toast.LENGTH_SHORT).show()
        }
    }

    private fun updateConnectionUI(connected: Boolean) {
        if (_binding == null) return

        if (connected) {
            binding.statusText.text = getString(R.string.status_connected)
            binding.statusText.setTextColor(ContextCompat.getColor(requireContext(), R.color.connected_green))
            binding.connectButton.text = getString(R.string.disconnect)

            val greenColor = ContextCompat.getColor(requireContext(), R.color.connected_green)
            (binding.statusIndicator.background as? GradientDrawable)?.setColor(greenColor)
            (binding.collapsedStatusIndicator.background as? GradientDrawable)?.setColor(greenColor)
            binding.collapsedStatusText.text = getString(R.string.status_connected)
            binding.collapsedStatusText.setTextColor(greenColor)

            // Show toolbox toggle when connected
            binding.toolboxToggle.visibility = View.VISIBLE

            // Show collapsed bar when connected
            showCollapsedConnectionBar()
        } else {
            binding.statusText.text = getString(R.string.status_disconnected)
            binding.statusText.setTextColor(ContextCompat.getColor(requireContext(), R.color.disconnected_red))
            binding.connectButton.text = getString(R.string.connect)

            val redColor = ContextCompat.getColor(requireContext(), R.color.disconnected_red)
            (binding.statusIndicator.background as? GradientDrawable)?.setColor(redColor)
            (binding.collapsedStatusIndicator.background as? GradientDrawable)?.setColor(redColor)
            binding.collapsedStatusText.text = getString(R.string.status_disconnected)
            binding.collapsedStatusText.setTextColor(redColor)

            binding.placeholderText.visibility = View.VISIBLE
            binding.placeholderText.text = getString(R.string.mirror_placeholder)

            // Hide stats overlay, toolbox, and buttons when disconnected
            binding.statsOverlay.visibility = View.GONE
            binding.toolbox.visibility = View.GONE
            binding.toolboxToggle.visibility = View.GONE
            statsVisible = false
            toolboxVisible = false

            // Reset zoom and pan
            resetTransform()

            // Show expanded panel when disconnected
            showExpandedConnectionPanel()

            // Release decoder
            videoDecoder?.release()
            videoDecoder = null
            videoConfig = null
        }
    }

    // SurfaceHolder.Callback
    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceReady = true

        // Initialize decoder if we have config
        videoConfig?.let { config ->
            initializeDecoder(config)
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        // Surface size changed, update aspect ratio
        updateSurfaceSize()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
        videoDecoder?.release()
        videoDecoder = null
    }

    override fun onDestroyView() {
        super.onDestroyView()
        mirrorClient.requestTouchpadMode()
        mirrorClient.release()
        videoDecoder?.release()
        performanceStats?.stopLogging()
        performanceStats?.stopPipelineLogging()
        performanceStats = null
        _binding = null
    }
}
