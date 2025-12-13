package com.example.tabletpen.ui

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment
import androidx.navigation.fragment.findNavController
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.example.tabletpen.R
import com.example.tabletpen.databinding.FragmentHomeBinding
import com.example.tabletpen.databinding.ItemModeBinding

class HomeFragment : Fragment() {

    private var _binding: FragmentHomeBinding? = null
    private val binding get() = _binding!!

    data class ModeItem(
        val id: String,
        val title: String,
        val description: String,
        val iconRes: Int
    )

    private val modes = listOf(
        ModeItem(
            id = "touchpad",
            title = "",  // Will be set from resources
            description = "",
            iconRes = android.R.drawable.ic_menu_compass
        ),
        ModeItem(
            id = "mirror",
            title = "",
            description = "",
            iconRes = android.R.drawable.ic_menu_gallery
        )
    )

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentHomeBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        // Build modes list with string resources
        val modesList = listOf(
            ModeItem(
                id = "touchpad",
                title = getString(R.string.mode_touchpad_title),
                description = getString(R.string.mode_touchpad_desc),
                iconRes = android.R.drawable.ic_menu_compass
            ),
            ModeItem(
                id = "mirror",
                title = getString(R.string.mode_mirror_title),
                description = getString(R.string.mode_mirror_desc),
                iconRes = android.R.drawable.ic_menu_gallery
            )
        )

        binding.modeList.layoutManager = LinearLayoutManager(requireContext())
        binding.modeList.adapter = ModeAdapter(modesList) { mode ->
            when (mode.id) {
                "touchpad" -> findNavController().navigate(R.id.action_home_to_touchpad)
                "mirror" -> findNavController().navigate(R.id.action_home_to_mirror)
            }
        }
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }

    // RecyclerView Adapter
    inner class ModeAdapter(
        private val modes: List<ModeItem>,
        private val onClick: (ModeItem) -> Unit
    ) : RecyclerView.Adapter<ModeAdapter.ModeViewHolder>() {

        inner class ModeViewHolder(val binding: ItemModeBinding) : RecyclerView.ViewHolder(binding.root)

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ModeViewHolder {
            val binding = ItemModeBinding.inflate(
                LayoutInflater.from(parent.context),
                parent,
                false
            )
            return ModeViewHolder(binding)
        }

        override fun onBindViewHolder(holder: ModeViewHolder, position: Int) {
            val mode = modes[position]
            holder.binding.apply {
                modeTitle.text = mode.title
                modeDescription.text = mode.description
                modeIcon.setImageResource(mode.iconRes)
                root.setOnClickListener { onClick(mode) }
            }
        }

        override fun getItemCount() = modes.size
    }
}
