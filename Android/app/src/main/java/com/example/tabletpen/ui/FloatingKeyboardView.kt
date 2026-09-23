package com.example.tabletpen.ui

import android.annotation.SuppressLint
import android.content.Context
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.example.tabletpen.protocol.MacKeyCodes
import kotlin.math.max

/**
 * A draggable, resizable on-screen keyboard that floats over the mirror.
 * Character keys emit [onText] (sent as TEXT_INPUT); Backspace/Enter emit [onKey]
 * (macOS keycodes). It does not resize or move the mirror underneath it.
 */
@SuppressLint("ClickableViewAccessibility", "SetTextI18n")
class FloatingKeyboardView(context: Context) : FrameLayout(context) {

    var onText: ((String) -> Unit)? = null
    var onKey: ((Int) -> Unit)? = null
    var onClose: (() -> Unit)? = null

    private var shifted = false
    private var symbols = false
    private val rowsContainer: LinearLayout

    private fun dp(v: Int) = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics
    )

    private data class Key(val label: String, val weight: Float = 1f, val onTap: () -> Unit)

    init {
        setBackgroundColor(0xE61A1A1A.toInt())

        val column = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        }
        addView(column)

        // Header: drag handle + close button
        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10).toInt(), dp(4).toInt(), dp(6).toInt(), dp(4).toInt())
        }
        val title = TextView(context).apply {
            text = "⌨  drag"
            setTextColor(0xFFAAAAAA.toInt())
            textSize = 12f
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val close = Button(context).apply {
            text = "✕"
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 12f
            setBackgroundColor(0x00000000)
            setPadding(0, 0, 0, 0)
            minWidth = dp(36).toInt()
            minimumWidth = dp(36).toInt()
            setOnClickListener { onClose?.invoke() }
        }
        header.addView(title)
        header.addView(close)
        column.addView(header)
        enableDrag(header)
        enableDrag(title)

        rowsContainer = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f)
        }
        column.addView(rowsContainer)

        buildKeys()

        // Resize handle (bottom-right corner)
        val handle = View(context).apply { setBackgroundColor(0xFF666666.toInt()) }
        addView(handle, LayoutParams(dp(20).toInt(), dp(20).toInt(), Gravity.BOTTOM or Gravity.END))
        enableResize(handle)
    }

    private fun charKey(s: String) = Key(s) { onText?.invoke(s) }

    private fun letterKey(c: Char): Key {
        val ch = if (shifted) c.uppercaseChar() else c
        return Key(ch.toString()) { onText?.invoke(ch.toString()) }
    }

    private fun letterPage(): List<List<Key>> = listOf(
        "1234567890".map { charKey(it.toString()) },
        "qwertyuiop".map { letterKey(it) },
        "asdfghjkl".map { letterKey(it) },
        buildList {
            add(Key(if (shifted) "⇧" else "⇪", 1.5f) { shifted = !shifted; buildKeys() })
            addAll("zxcvbnm".map { letterKey(it) })
            add(Key("⌫", 1.5f) { onKey?.invoke(MacKeyCodes.DELETE) })
        },
        listOf(
            Key("?123", 1.5f) { symbols = true; buildKeys() },
            charKey(","),
            Key("space", 4f) { onText?.invoke(" ") },
            charKey("."),
            Key("⏎", 1.5f) { onKey?.invoke(MacKeyCodes.RETURN) }
        )
    )

    private fun symbolPage(): List<List<Key>> = listOf(
        "1234567890".map { charKey(it.toString()) },
        "!@#$%^&*()".map { charKey(it.toString()) },
        "-_=+[]{}\\|".map { charKey(it.toString()) },
        buildList {
            addAll(";:'\",.?/".map { charKey(it.toString()) })
            add(Key("⌫", 1.5f) { onKey?.invoke(MacKeyCodes.DELETE) })
        },
        listOf(
            Key("ABC", 1.5f) { symbols = false; buildKeys() },
            charKey("~"),
            Key("space", 4f) { onText?.invoke(" ") },
            charKey("`"),
            Key("⏎", 1.5f) { onKey?.invoke(MacKeyCodes.RETURN) }
        )
    )

    private fun buildKeys() {
        rowsContainer.removeAllViews()
        val rows = if (symbols) symbolPage() else letterPage()
        for (row in rows) {
            val rowView = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f)
            }
            for (key in row) rowView.addView(makeButton(key))
            rowsContainer.addView(rowView)
        }
    }

    private fun makeButton(key: Key): Button {
        return Button(context).apply {
            text = key.label
            isAllCaps = false
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 15f
            setBackgroundColor(0xFF333333.toInt())
            setPadding(0, 0, 0, 0)
            val lp = LinearLayout.LayoutParams(0, LayoutParams.MATCH_PARENT, key.weight)
            lp.setMargins(dp(2).toInt(), dp(2).toInt(), dp(2).toInt(), dp(2).toInt())
            layoutParams = lp
            setOnClickListener { key.onTap() }
        }
    }

    private fun enableDrag(handle: View) {
        var startX = 0f; var startY = 0f; var origTx = 0f; var origTy = 0f
        handle.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = e.rawX; startY = e.rawY; origTx = translationX; origTy = translationY; true
                }
                MotionEvent.ACTION_MOVE -> {
                    translationX = origTx + (e.rawX - startX)
                    translationY = origTy + (e.rawY - startY)
                    true
                }
                else -> false
            }
        }
    }

    private fun enableResize(handle: View) {
        var startX = 0f; var startY = 0f; var origW = 0; var origH = 0
        handle.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = e.rawX; startY = e.rawY; origW = width; origH = height; true
                }
                MotionEvent.ACTION_MOVE -> {
                    val lp = layoutParams
                    lp.width = max(dp(280).toInt(), origW + (e.rawX - startX).toInt())
                    lp.height = max(dp(150).toInt(), origH + (e.rawY - startY).toInt())
                    layoutParams = lp
                    true
                }
                else -> false
            }
        }
    }
}
