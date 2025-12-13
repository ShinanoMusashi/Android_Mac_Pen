import Foundation

/// Represents pen input data received from the Android tablet.
struct PenData {
    let x: Float           // Normalized X position (0.0 to 1.0)
    let y: Float           // Normalized Y position (0.0 to 1.0)
    let pressure: Float    // Pressure (0.0 to 1.0)
    let isHovering: Bool   // True when pen is near but not touching
    let isDown: Bool       // True when pen is touching screen
    let buttonPressed: Bool // True when pen button is pressed
    let tiltX: Float       // Tilt on X axis
    let tiltY: Float       // Tilt on Y axis
    let timestamp: Int64   // Event timestamp

    /// Parse pen data from the network format.
    /// Format: "x,y,pressure,hovering,down,button,tiltX,tiltY,timestamp"
    static func parse(from string: String) -> PenData? {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        guard parts.count >= 9 else { return nil }

        guard let x = Float(parts[0]),
              let y = Float(parts[1]),
              let pressure = Float(parts[2]),
              let tiltX = Float(parts[6]),
              let tiltY = Float(parts[7]),
              let timestamp = Int64(parts[8]) else {
            return nil
        }

        return PenData(
            x: x,
            y: y,
            pressure: pressure,
            isHovering: parts[3] == "1",
            isDown: parts[4] == "1",
            buttonPressed: parts[5] == "1",
            tiltX: tiltX,
            tiltY: tiltY,
            timestamp: timestamp
        )
    }
}
