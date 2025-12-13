import AppKit
import CoreGraphics

/// A window that displays pressure-sensitive drawing from the tablet.
class DrawingWindow: NSWindow {
    private let drawingView: DrawingView

    init() {
        drawingView = DrawingView()

        super.init(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        self.title = "Tablet Drawing Canvas"
        self.contentView = drawingView
        self.minSize = NSSize(width: 400, height: 300)
        self.backgroundColor = .white
    }

    /// Add a stroke point with pressure.
    func addPoint(_ point: CGPoint, pressure: Float, isNewStroke: Bool) {
        drawingView.addPoint(point, pressure: pressure, isNewStroke: isNewStroke)
    }

    /// Clear the canvas.
    func clear() {
        drawingView.clear()
    }
}

/// Custom view that renders pressure-sensitive strokes.
class DrawingView: NSView {
    private var strokes: [[StrokePoint]] = []
    private var currentStroke: [StrokePoint] = []

    struct StrokePoint {
        let point: CGPoint
        let pressure: Float
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func addPoint(_ point: CGPoint, pressure: Float, isNewStroke: Bool) {
        if isNewStroke && !currentStroke.isEmpty {
            strokes.append(currentStroke)
            currentStroke = []
        }

        // Convert point to view coordinates
        let viewPoint = CGPoint(
            x: point.x * bounds.width,
            y: point.y * bounds.height
        )

        currentStroke.append(StrokePoint(point: viewPoint, pressure: pressure))
        needsDisplay = true
    }

    func finishStroke() {
        if !currentStroke.isEmpty {
            strokes.append(currentStroke)
            currentStroke = []
        }
    }

    func clear() {
        strokes.removeAll()
        currentStroke.removeAll()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Fill background
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)

        // Draw all completed strokes
        for stroke in strokes {
            drawStroke(stroke, in: context)
        }

        // Draw current stroke
        drawStroke(currentStroke, in: context)
    }

    private func drawStroke(_ stroke: [StrokePoint], in context: CGContext) {
        guard stroke.count >= 2 else { return }

        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for i in 1..<stroke.count {
            let prev = stroke[i - 1]
            let curr = stroke[i]

            // Line width based on pressure (2 to 20 points)
            let width = 2.0 + CGFloat(curr.pressure) * 18.0

            context.setLineWidth(width)
            context.beginPath()
            context.move(to: prev.point)
            context.addLine(to: curr.point)
            context.strokePath()
        }
    }
}
