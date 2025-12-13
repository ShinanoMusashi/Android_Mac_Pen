package com.example.tabletpen

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View

/**
 * Custom view that captures all pen input including hover, pressure, tilt, and button state.
 */
class PenInputView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    // Callback for pen data
    var onPenData: ((PenData) -> Unit)? = null

    // Visual feedback
    private var currentX = 0f
    private var currentY = 0f
    private var currentPressure = 0f
    private var isActive = false
    private var isHovering = false
    private var buttonPressed = false

    // Paint for visual feedback
    private val cursorPaint = Paint().apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeWidth = 2f
        isAntiAlias = true
    }

    private val pressurePaint = Paint().apply {
        color = Color.parseColor("#BB86FC")
        style = Paint.Style.FILL
        isAntiAlias = true
    }

    private val hoverPaint = Paint().apply {
        color = Color.parseColor("#66BB86FC")
        style = Paint.Style.STROKE
        strokeWidth = 2f
        isAntiAlias = true
    }

    private val textPaint = Paint().apply {
        color = Color.WHITE
        textSize = 40f
        isAntiAlias = true
    }

    private val gridPaint = Paint().apply {
        color = Color.parseColor("#333333")
        style = Paint.Style.STROKE
        strokeWidth = 1f
    }

    init {
        // Enable hover events
        isHovered = false
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        // Draw grid for reference
        drawGrid(canvas)

        // Draw instructions when idle
        if (!isActive && !isHovering) {
            val text = "Move pen here"
            val textWidth = textPaint.measureText(text)
            canvas.drawText(text, (width - textWidth) / 2, height / 2f, textPaint)
        }

        // Draw cursor feedback
        if (isActive || isHovering) {
            val screenX = currentX * width
            val screenY = currentY * height

            if (isHovering && !isActive) {
                // Hovering - draw circle outline
                canvas.drawCircle(screenX, screenY, 30f, hoverPaint)
                canvas.drawCircle(screenX, screenY, 5f, pressurePaint)
            } else if (isActive) {
                // Touching - draw filled circle based on pressure
                val radius = 20f + (currentPressure * 40f)
                canvas.drawCircle(screenX, screenY, radius, pressurePaint)
                canvas.drawCircle(screenX, screenY, radius, cursorPaint)
            }

            // Draw crosshairs
            cursorPaint.alpha = 100
            canvas.drawLine(screenX - 50, screenY, screenX - 10, screenY, cursorPaint)
            canvas.drawLine(screenX + 10, screenY, screenX + 50, screenY, cursorPaint)
            canvas.drawLine(screenX, screenY - 50, screenX, screenY - 10, cursorPaint)
            canvas.drawLine(screenX, screenY + 10, screenX, screenY + 50, cursorPaint)
            cursorPaint.alpha = 255

            // Draw debug info
            drawDebugInfo(canvas, screenX, screenY)
        }
    }

    private fun drawGrid(canvas: Canvas) {
        val stepX = width / 10f
        val stepY = height / 10f

        for (i in 1..9) {
            canvas.drawLine(stepX * i, 0f, stepX * i, height.toFloat(), gridPaint)
            canvas.drawLine(0f, stepY * i, width.toFloat(), stepY * i, gridPaint)
        }
    }

    private fun drawDebugInfo(canvas: Canvas, screenX: Float, screenY: Float) {
        val info = buildString {
            append("X: %.2f  Y: %.2f\n".format(currentX, currentY))
            append("Pressure: %.2f\n".format(currentPressure))
            append(if (isHovering) "HOVER  " else "")
            append(if (isActive) "TOUCH  " else "")
            append(if (buttonPressed) "BUTTON" else "")
        }

        var yPos = 60f
        textPaint.textSize = 32f
        for (line in info.split("\n")) {
            canvas.drawText(line, 20f, yPos, textPaint)
            yPos += 40f
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        processPenEvent(event)
        return true
    }

    override fun onHoverEvent(event: MotionEvent): Boolean {
        processPenEvent(event)
        return true
    }

    private fun processPenEvent(event: MotionEvent) {
        // Normalize coordinates to 0.0 - 1.0 range
        val normalizedX = (event.x / width).coerceIn(0f, 1f)
        val normalizedY = (event.y / height).coerceIn(0f, 1f)

        // Get pressure (0.0 when hovering, 0.0-1.0 when touching)
        val pressure = when (event.action) {
            MotionEvent.ACTION_HOVER_ENTER,
            MotionEvent.ACTION_HOVER_MOVE,
            MotionEvent.ACTION_HOVER_EXIT -> 0f
            else -> event.pressure.coerceIn(0f, 1f)
        }

        // Check if pen button is pressed (usually BUTTON_STYLUS_PRIMARY)
        val button = (event.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY) != 0 ||
                     (event.buttonState and MotionEvent.BUTTON_SECONDARY) != 0

        // Get tilt (orientation) if available
        val tiltX = if (event.device?.motionRanges?.any { it.axis == MotionEvent.AXIS_TILT } == true) {
            Math.sin(event.getAxisValue(MotionEvent.AXIS_ORIENTATION).toDouble()).toFloat()
        } else 0f

        val tiltY = if (event.device?.motionRanges?.any { it.axis == MotionEvent.AXIS_TILT } == true) {
            Math.cos(event.getAxisValue(MotionEvent.AXIS_ORIENTATION).toDouble()).toFloat() *
            event.getAxisValue(MotionEvent.AXIS_TILT)
        } else 0f

        // Determine state
        val hovering = event.action == MotionEvent.ACTION_HOVER_ENTER ||
                       event.action == MotionEvent.ACTION_HOVER_MOVE
        val down = event.action == MotionEvent.ACTION_DOWN ||
                   event.action == MotionEvent.ACTION_MOVE

        // Update local state for drawing
        currentX = normalizedX
        currentY = normalizedY
        currentPressure = pressure
        isHovering = hovering
        isActive = down
        buttonPressed = button

        // Create pen data
        val penData = PenData(
            x = normalizedX,
            y = normalizedY,
            pressure = pressure,
            isHovering = hovering,
            isDown = down,
            buttonPressed = button,
            tiltX = tiltX,
            tiltY = tiltY,
            timestamp = event.eventTime
        )

        // Handle pen up
        if (event.action == MotionEvent.ACTION_UP || event.action == MotionEvent.ACTION_CANCEL) {
            isActive = false
            val upData = penData.copy(isDown = false, pressure = 0f)
            onPenData?.invoke(upData)
        } else if (event.action == MotionEvent.ACTION_HOVER_EXIT) {
            isHovering = false
            val exitData = penData.copy(isHovering = false)
            onPenData?.invoke(exitData)
        } else {
            onPenData?.invoke(penData)
        }

        // Request redraw
        invalidate()
    }

    // Handle historical events for smoother tracking
    private fun processHistoricalEvents(event: MotionEvent) {
        for (i in 0 until event.historySize) {
            val historicalX = (event.getHistoricalX(i) / width).coerceIn(0f, 1f)
            val historicalY = (event.getHistoricalY(i) / height).coerceIn(0f, 1f)
            val historicalPressure = event.getHistoricalPressure(i).coerceIn(0f, 1f)

            val penData = PenData(
                x = historicalX,
                y = historicalY,
                pressure = historicalPressure,
                isHovering = false,
                isDown = true,
                buttonPressed = buttonPressed,
                tiltX = 0f,
                tiltY = 0f,
                timestamp = event.getHistoricalEventTime(i)
            )
            onPenData?.invoke(penData)
        }
    }
}
