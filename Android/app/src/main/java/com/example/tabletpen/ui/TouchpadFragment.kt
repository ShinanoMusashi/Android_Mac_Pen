package com.example.tabletpen.ui

import android.content.Context
import android.content.SharedPreferences
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.SeekBar
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import androidx.navigation.fragment.findNavController
import com.example.tabletpen.PenClient
import com.example.tabletpen.R
import com.example.tabletpen.databinding.FragmentTouchpadBinding
import kotlinx.coroutines.launch

class TouchpadFragment : Fragment() {

    private var _binding: FragmentTouchpadBinding? = null
    private val binding get() = _binding!!

    private val penClient = PenClient()
    private lateinit var prefs: SharedPreferences

    // Sensitivity: 0.5 to 5.0, default 1.5
    private var sensitivity = 1.5f

    // Track if disconnect was user-initiated
    private var userInitiatedDisconnect = false

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentTouchpadBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        prefs = requireContext().getSharedPreferences("TabletPen", Context.MODE_PRIVATE)
        loadSettings()

        setupConnectionUI()
        setupSettingsPanel()
        setupPenInput()
        setupBackButtons()
        setupDisconnectOverlay()
    }

    private fun setupBackButtons() {
        binding.backButton.setOnClickListener {
            userInitiatedDisconnect = true
            penClient.disconnect()
            findNavController().navigateUp()
        }
        binding.backButtonExpanded.setOnClickListener {
            userInitiatedDisconnect = true
            penClient.disconnect()
            findNavController().navigateUp()
        }
    }

    private fun setupDisconnectOverlay() {
        binding.overlayBackButton.setOnClickListener {
            userInitiatedDisconnect = true
            penClient.disconnect()
            findNavController().navigateUp()
        }

        binding.overlayReconnectButton.setOnClickListener {
            hideDisconnectOverlay()
            connect()
        }

        // Floating disconnect button
        binding.floatingDisconnectButton.setOnClickListener {
            userInitiatedDisconnect = true
            penClient.disconnect()
            findNavController().navigateUp()
        }
    }

    private fun showDisconnectOverlay() {
        if (_binding == null) return
        binding.disconnectOverlay.visibility = View.VISIBLE
    }

    private fun hideDisconnectOverlay() {
        if (_binding == null) return
        binding.disconnectOverlay.visibility = View.GONE
    }

    private fun loadSettings() {
        sensitivity = prefs.getFloat("sensitivity", 1.5f)
        // Convert sensitivity (0.5-5.0) to seekbar progress (0-100)
        val progress = ((sensitivity - 0.5f) / 4.5f * 100).toInt()
        binding.sensitivitySeekBar.progress = progress
        updateSensitivityDisplay()
    }

    private fun saveSettings() {
        prefs.edit().putFloat("sensitivity", sensitivity).apply()
    }

    private fun setupConnectionUI() {
        // Connection state callbacks
        penClient.onConnectionChanged = { connected ->
            activity?.runOnUiThread {
                updateConnectionUI(connected)
            }
        }

        penClient.onError = { error ->
            activity?.runOnUiThread {
                Toast.makeText(requireContext(), error, Toast.LENGTH_SHORT).show()
            }
        }

        // Connect button
        binding.connectButton.setOnClickListener {
            if (penClient.isConnected) {
                userInitiatedDisconnect = true
                penClient.disconnect()
            } else {
                connect()
            }
        }

        // Expand button - show full connection panel
        binding.expandButton.setOnClickListener {
            showExpandedConnectionPanel()
        }

        // Load saved IP address
        val savedIp = prefs.getString("ip_address", "192.168.1.")
        binding.ipAddressInput.setText(savedIp)

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

    private fun setupSettingsPanel() {
        // Toggle settings panel visibility
        binding.settingsToggle.setOnClickListener {
            val isVisible = binding.settingsPanel.visibility == View.VISIBLE
            binding.settingsPanel.visibility = if (isVisible) View.GONE else View.VISIBLE
            binding.settingsToggle.text = if (isVisible) getString(R.string.settings) else "Hide"
        }

        // Sensitivity slider
        binding.sensitivitySeekBar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                // Map 0-100 to 0.5-5.0
                sensitivity = 0.5f + (progress / 100f) * 4.5f
                updateSensitivityDisplay()
            }

            override fun onStartTrackingTouch(seekBar: SeekBar?) {}

            override fun onStopTrackingTouch(seekBar: SeekBar?) {
                saveSettings()
            }
        })
    }

    private fun updateSensitivityDisplay() {
        binding.sensitivityValue.text = "%.1fx".format(sensitivity)
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
            val success = penClient.connect(ip, port)
            binding.connectButton.isEnabled = true

            if (!success) {
                binding.statusText.text = getString(R.string.status_disconnected)
                binding.statusText.setTextColor(ContextCompat.getColor(requireContext(), R.color.disconnected_red))
            }
        }
    }

    private fun updateConnectionUI(connected: Boolean) {
        if (_binding == null) return

        if (connected) {
            binding.statusText.text = getString(R.string.status_connected)
            binding.statusText.setTextColor(ContextCompat.getColor(requireContext(), R.color.connected_green))
            binding.connectButton.text = getString(R.string.disconnect)

            // Update indicator colors (both expanded and collapsed)
            val greenColor = ContextCompat.getColor(requireContext(), R.color.connected_green)
            (binding.statusIndicator.background as? GradientDrawable)?.setColor(greenColor)
            (binding.collapsedStatusIndicator.background as? GradientDrawable)?.setColor(greenColor)
            binding.collapsedStatusText.text = getString(R.string.status_connected)
            binding.collapsedStatusText.setTextColor(greenColor)

            // Hide disconnect overlay and collapse the connection panel
            hideDisconnectOverlay()
            showCollapsedConnectionBar()

            // Show floating disconnect button
            binding.floatingDisconnectButton.visibility = View.VISIBLE

            // Reset user-initiated flag for next potential disconnect
            userInitiatedDisconnect = false
        } else {
            binding.statusText.text = getString(R.string.status_disconnected)
            binding.statusText.setTextColor(ContextCompat.getColor(requireContext(), R.color.disconnected_red))
            binding.connectButton.text = getString(R.string.connect)

            // Update indicator colors
            val redColor = ContextCompat.getColor(requireContext(), R.color.disconnected_red)
            (binding.statusIndicator.background as? GradientDrawable)?.setColor(redColor)
            (binding.collapsedStatusIndicator.background as? GradientDrawable)?.setColor(redColor)
            binding.collapsedStatusText.text = getString(R.string.status_disconnected)
            binding.collapsedStatusText.setTextColor(redColor)

            // Hide floating disconnect button
            binding.floatingDisconnectButton.visibility = View.GONE

            // Show disconnect overlay if this was unexpected (not user-initiated)
            if (!userInitiatedDisconnect) {
                showDisconnectOverlay()
            } else {
                // Show expanded panel when user disconnected manually
                showExpandedConnectionPanel()
            }
        }
    }

    private fun setupPenInput() {
        binding.penInputView.onPenData = { penData ->
            if (penClient.isConnected) {
                penClient.sendPenData(penData)
            }
        }
    }

    override fun onDestroyView() {
        super.onDestroyView()
        userInitiatedDisconnect = true
        penClient.disconnect()
        _binding = null
    }
}
