package com.example.tabletpen

/**
 * Data class representing pen input state.
 * This gets serialized and sent to the Mac.
 */
data class PenData(
    val x: Float,           // Normalized X position (0.0 to 1.0)
    val y: Float,           // Normalized Y position (0.0 to 1.0)
    val pressure: Float,    // Pressure (0.0 to 1.0), 0 when hovering
    val isHovering: Boolean,// True when pen is near but not touching
    val isDown: Boolean,    // True when pen is touching screen
    val buttonPressed: Boolean, // True when pen button is pressed
    val tiltX: Float,       // Tilt on X axis (-1.0 to 1.0)
    val tiltY: Float,       // Tilt on Y axis (-1.0 to 1.0)
    val timestamp: Long     // Event timestamp
) {
    /**
     * Serialize to a simple string format for network transmission.
     * Format: "x,y,pressure,hovering,down,button,tiltX,tiltY,timestamp"
     */
    fun serialize(): String {
        return buildString {
            append("%.5f".format(x))
            append(",")
            append("%.5f".format(y))
            append(",")
            append("%.4f".format(pressure))
            append(",")
            append(if (isHovering) "1" else "0")
            append(",")
            append(if (isDown) "1" else "0")
            append(",")
            append(if (buttonPressed) "1" else "0")
            append(",")
            append("%.4f".format(tiltX))
            append(",")
            append("%.4f".format(tiltY))
            append(",")
            append(timestamp)
            append("\n")
        }
    }

    companion object {
        /**
         * Deserialize from string format.
         */
        fun deserialize(data: String): PenData? {
            return try {
                val parts = data.trim().split(",")
                if (parts.size >= 9) {
                    PenData(
                        x = parts[0].toFloat(),
                        y = parts[1].toFloat(),
                        pressure = parts[2].toFloat(),
                        isHovering = parts[3] == "1",
                        isDown = parts[4] == "1",
                        buttonPressed = parts[5] == "1",
                        tiltX = parts[6].toFloat(),
                        tiltY = parts[7].toFloat(),
                        timestamp = parts[8].toLong()
                    )
                } else null
            } catch (e: Exception) {
                null
            }
        }
    }
}
