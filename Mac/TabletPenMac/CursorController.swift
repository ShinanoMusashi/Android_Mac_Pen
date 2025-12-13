import Foundation
import CoreGraphics
import AppKit

/// Controls the Mac cursor based on pen input data.
/// Uses relative positioning like a trackpad.
class CursorController {
    private var lastButtonState = false
    private var isMouseDown = false

    // For relative movement tracking
    private var lastPenX: Float?
    private var lastPenY: Float?
    private var isPenActive = false  // Track if pen is currently in use

    // Movement smoothing - accumulated small movements
    private var accumulatedDeltaX: Float = 0
    private var accumulatedDeltaY: Float = 0

    /// Dead zone threshold for movement (normalized coordinates)
    /// Movements smaller than this are accumulated until they exceed the threshold
    /// This prevents jittery cursor when holding the pen still
    var movementDeadZone: Float = 0.002  // ~0.2% of tablet surface

    /// Pressure threshold for registering a "click" (0.0 to 1.0)
    /// Pen must exceed this pressure to trigger mouse down
    /// This allows light touches without clicking
    var pressureThreshold: Float = 0.25  // 25% pressure required

    /// Sensitivity multiplier (higher = faster cursor movement)
    /// Range: 0.5 (slow) to 5.0 (fast), default 1.5
    var sensitivity: Float = 1.5

    /// Screen dimensions for calculating movement.
    var screenBounds: CGRect {
        return NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    /// Get current cursor position.
    private var currentCursorPosition: CGPoint {
        return NSEvent.mouseLocation
    }

    /// Process pen data and move/click cursor accordingly.
    func processPenData(_ data: PenData) {
        // Check if pen just started touching or hovering (new stroke)
        let penJustActivated = (data.isDown || data.isHovering) && !isPenActive

        // Update active state
        let wasActive = isPenActive
        isPenActive = data.isDown || data.isHovering

        // If pen just lifted completely, reset tracking
        if !isPenActive && wasActive {
            lastPenX = nil
            lastPenY = nil
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0

            // Handle mouse up if needed
            if isMouseDown {
                let pos = flippedCursorPosition()
                mouseUp(at: pos, isRightClick: lastButtonState)
                isMouseDown = false
            }
            lastButtonState = data.buttonPressed
            return
        }

        // If pen just activated, just store position (don't move yet)
        if penJustActivated {
            lastPenX = data.x
            lastPenY = data.y
            lastButtonState = data.buttonPressed
            return
        }

        // Calculate relative movement if we have a previous position
        if let prevX = lastPenX, let prevY = lastPenY {
            let deltaX = data.x - prevX
            let deltaY = data.y - prevY

            // Accumulate small movements
            accumulatedDeltaX += deltaX
            accumulatedDeltaY += deltaY

            // Only move if accumulated movement exceeds dead zone threshold
            // This prevents jittery cursor when holding pen still
            let totalDelta = sqrt(accumulatedDeltaX * accumulatedDeltaX + accumulatedDeltaY * accumulatedDeltaY)

            if totalDelta > movementDeadZone {
                // Scale delta by sensitivity and screen size
                // Using screen width as base for consistent feel
                let baseScale = Float(screenBounds.width) * sensitivity
                let moveX = CGFloat(accumulatedDeltaX * baseScale)
                let moveY = CGFloat(accumulatedDeltaY * baseScale)

                // Reset accumulated delta after applying
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0

                // Get current cursor position and apply delta
                let currentPos = currentCursorPosition
                // Note: macOS screen Y is from bottom, but we want natural movement
                let newX = currentPos.x + moveX
                let newY = currentPos.y - moveY  // Subtract because pen Y is inverted

                // Clamp to screen bounds
                let clampedX = max(0, min(newX, screenBounds.width))
                let clampedY = max(0, min(newY, screenBounds.height))

                let flippedPos = CGPoint(x: clampedX, y: screenBounds.height - clampedY)

                // Move cursor
                moveCursor(to: flippedPos)

                // Handle dragging
                if isMouseDown {
                    mouseDrag(to: flippedPos)
                }
            }
        }

        // Store current position for next frame
        lastPenX = data.x
        lastPenY = data.y

        // Get current cursor position for click events
        let cursorPos = flippedCursorPosition()

        // Determine if pressure exceeds threshold for clicking
        let pressureExceedsThreshold = data.pressure >= pressureThreshold

        // Handle pen down/up for clicking based on pressure threshold
        // Mouse down only when pressure exceeds threshold (not just touching)
        if data.isDown && pressureExceedsThreshold && !isMouseDown {
            // Pressure exceeded threshold - mouse down
            mouseDown(at: cursorPos, isRightClick: data.buttonPressed)
            isMouseDown = true
        } else if (!data.isDown || !pressureExceedsThreshold) && isMouseDown {
            // Pen lifted or pressure dropped below threshold - mouse up
            mouseUp(at: cursorPos, isRightClick: lastButtonState)
            isMouseDown = false
        }

        // Handle button press for right-click (when hovering, not touching)
        if data.buttonPressed && !lastButtonState && !data.isDown {
            // Button just pressed while hovering - right click
            rightClick(at: cursorPos)
        }

        lastButtonState = data.buttonPressed
    }

    /// Get cursor position in CoreGraphics coordinates (flipped Y).
    private func flippedCursorPosition() -> CGPoint {
        let pos = currentCursorPosition
        return CGPoint(x: pos.x, y: screenBounds.height - pos.y)
    }

    /// Move the cursor to a point.
    private func moveCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Re-associate mouse with cursor to prevent drift
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Simulate mouse down.
    private func mouseDown(at point: CGPoint, isRightClick: Bool) {
        let eventType: CGEventType = isRightClick ? .rightMouseDown : .leftMouseDown
        let mouseButton: CGMouseButton = isRightClick ? .right : .left

        if let event = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: point, mouseButton: mouseButton) {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Simulate mouse up.
    private func mouseUp(at point: CGPoint, isRightClick: Bool) {
        let eventType: CGEventType = isRightClick ? .rightMouseUp : .leftMouseUp
        let mouseButton: CGMouseButton = isRightClick ? .right : .left

        if let event = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: point, mouseButton: mouseButton) {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Simulate mouse drag.
    private func mouseDrag(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Simulate right click.
    private func rightClick(at point: CGPoint) {
        mouseDown(at: point, isRightClick: true)
        mouseUp(at: point, isRightClick: true)
    }

    /// Reset tracking state (call when switching modes).
    func reset() {
        lastPenX = nil
        lastPenY = nil
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        isPenActive = false
        isMouseDown = false
    }
}
