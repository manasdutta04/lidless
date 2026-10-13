import AppKit

/// The menu bar icon: the Lidless mark (an open laptop seen side-on, forming
/// an "L"), drawn in code as a template image so it follows the menu bar's
/// light/dark appearance.
///
/// Idle: the mark alone. Awake: the mark with two signal arcs pulsing out of
/// the open laptop in turn.
enum MenuBarGlyph {
    static let size = NSSize(width: 20, height: 16)

    /// `phase` in 0..<1 drives the animation; nil draws the static frame.
    static func image(active: Bool, phase: Double?) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(active: active, phase: phase)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? "Lidless: awake" : "Lidless: normal sleep"
        return image
    }

    // Geometry taken from the app icon: a steep lid meeting a flat base.
    private static let lidTop = NSPoint(x: 2.6, y: 14.2)
    private static let hinge = NSPoint(x: 6.0, y: 2.6)
    private static let baseEnd = NSPoint(x: 18.2, y: 2.6)

    private static func draw(active: Bool, phase: Double?) {
        let mark = NSBezierPath()
        mark.move(to: lidTop)
        mark.line(to: hinge)
        mark.line(to: baseEnd)
        mark.lineWidth = 2.1
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        NSColor.black.setStroke()
        mark.stroke()

        guard active else { return }

        // Arcs radiate from inside the open laptop, toward its upper right.
        let origin = NSPoint(x: hinge.x + 1.6, y: hinge.y + 1.8)
        let t = CGFloat(phase ?? 0.35)
        for (i, radius) in [CGFloat(5.0), CGFloat(8.6)].enumerated() {
            let alpha: CGFloat
            if phase == nil {
                alpha = 1
            } else {
                // Each arc fades in and out, the outer one a third of a cycle later.
                var local = (t - CGFloat(i) * 0.33).truncatingRemainder(dividingBy: 1)
                if local < 0 { local += 1 }
                alpha = 0.25 + 0.75 * max(0, sin(local * .pi))
            }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: origin, radius: radius, startAngle: 12, endAngle: 68)
            arc.lineWidth = 1.5
            arc.lineCapStyle = .round
            NSColor.black.withAlphaComponent(alpha).setStroke()
            arc.stroke()
        }
    }
}
