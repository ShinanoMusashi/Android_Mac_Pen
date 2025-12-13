package com.example.tabletpen.ui

import android.content.Context
import android.content.SharedPreferences
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.*
import android.widget.FrameLayout
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import androidx.navigation.fragment.findNavController
import com.example.tabletpen.PenData
import com.example.tabletpen.R
import com.example.tabletpen.databinding.FragmentMirrorBinding
import com.example.tabletpen.mirror.MirrorClient
import com.example.tabletpen.mirror.VideoDecoder
import com.example.tabletpen.protocol.AppMode
import com.example.tabletpen.protocol.VideoConfig
import com.example.tabletpen.protocol.VideoFrame
import kotlinx.coroutines.launch

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
        // Load saved IP address
        val savedIp = prefs.getString("ip_address", "192.168.1.")
        binding.ipAddressInput.setText(savedIp)

        // Client callbacks
        mirrorClient.onConnectionChanged = { connected ->
            activity?.runOnUiThread {
                updateConnectionUI(connected)
                if (connected) {
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

    private fun setupPenInput() {
        // Handle touch/pen events on the video container
        binding.videoContainer.setOnTouchListener { _, event ->
            handlePenEvent(event)
            true
        }

        // Also handle hover events
        binding.videoContainer.setOnHoverListener { _, event ->
            handlePenEvent(event)
            true
        }
    }

    private fun handlePenEvent(event: MotionEvent) {
        if (!mirrorClient.isConnected) return

        val sv = surfaceView ?: return

        // Get the actual video surface bounds (accounting for letterboxing)
        val surfaceWidth = sv.width.toFloat()
        val surfaceHeight = sv.height.toFloat()

        if (surfaceWidth <= 0 || surfaceHeight <= 0) return

        // Calculate the touch position relative to the surface
        // The SurfaceView is centered in the container, so we need to account for offset
        val containerWidth = binding.videoContainer.width.toFloat()
        val containerHeight = binding.videoContainer.height.toFloat()

        val offsetX = (containerWidth - surfaceWidth) / 2
        val offsetY = (containerHeight - surfaceHeight) / 2

        val relativeX = event.x - offsetX
        val relativeY = event.y - offsetY

        // Normalize coordinates to 0.0 - 1.0 (relative to video surface)
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
        val ip = binding.ipAddressInput.text.toString().trim()
        val port = binding.portInput.text.toString().toIntOrNull() ?: 9876

        if (ip.isEmpty()) {
            Toast.makeText(requireContext(), "Please enter IP address", Toast.LENGTH_SHORT).show()
            return
        }

        // Save IP for next time
        prefs.edit().putString("ip_address", ip).apply()

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
        videoDecoder?.decode(frame.nalData, frame.timestamp, frame.isKeyframe)
    }

    private fun initializeDecoder(config: VideoConfig) {
        // Release existing decoder
        videoDecoder?.release()

        val sv = surfaceView ?: return
        val surface = sv.holder.surface ?: return

        val decoder = VideoDecoder()
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
        _binding = null
    }
}
