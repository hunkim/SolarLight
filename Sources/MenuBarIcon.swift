import AppKit

enum MenuBarIcon {
    /// 18×18 template image for the status item: an orbit ring crossing a
    /// magnifying glass with a 4-point sparkle in the lens — a compact echo
    /// of the SolarLight app icon.
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(in: size)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SolarLight"
        return image
    }

    private static func draw(in size: NSSize) {
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let lensCenter = NSPoint(x: 7.4, y: 10.6)
        let lensRadius: CGFloat = 5.0
        let lensStroke: CGFloat = 1.6
        let handleAngle: CGFloat = -.pi / 4
        let handleEnd = NSPoint(
            x: lensCenter.x + cos(handleAngle) * (lensRadius + 4.4),
            y: lensCenter.y + sin(handleAngle) * (lensRadius + 4.4)
        )

        drawOrbit(canvas: size, lensCenter: lensCenter, lensRadius: lensRadius, handleEnd: handleEnd)
        drawLens(center: lensCenter, radius: lensRadius, stroke: lensStroke)
        drawHandle(lensCenter: lensCenter, lensRadius: lensRadius)
        sparkle(center: lensCenter, outer: 3.1, inner: 0.8).fill()
    }

    /// Tilted orbit ring crossing the canvas. The portions overlapping the
    /// lens interior and the handle are clipped out so the ring reads as
    /// passing *behind* both.
    private static func drawOrbit(canvas: NSSize, lensCenter: NSPoint, lensRadius: CGFloat, handleEnd: NSPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()

        // Even-odd clip: full canvas, minus the lens interior, minus a stroke
        // along the handle so the orbit doesn't cross over the handle.
        let clip = NSBezierPath(rect: NSRect(origin: .zero, size: canvas))
        clip.windingRule = .evenOdd

        let lensInterior = NSBezierPath(ovalIn: NSRect(
            x: lensCenter.x - (lensRadius - 0.4),
            y: lensCenter.y - (lensRadius - 0.4),
            width: (lensRadius - 0.4) * 2,
            height: (lensRadius - 0.4) * 2
        ))
        clip.append(lensInterior)

        // Approximate the handle stroke as a stadium-shaped clip cutout.
        let handleClipPath = handleClipShape(
            from: NSPoint(
                x: lensCenter.x + cos(-.pi / 4) * lensRadius,
                y: lensCenter.y + sin(-.pi / 4) * lensRadius
            ),
            to: handleEnd,
            width: 3.4
        )
        clip.append(handleClipPath)
        clip.addClip()

        // Tilted ellipse: drawn axis-aligned then rotated about canvas center.
        // +30° gives lower-left → upper-right slope, matching the SolarLight icon.
        let center = NSPoint(x: canvas.width / 2, y: canvas.height / 2)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: .pi / 6)
        context.translateBy(x: -center.x, y: -center.y)

        let orbitRect = NSRect(
            x: center.x - 8.8,
            y: center.y - 2.6,
            width: 17.6,
            height: 5.2
        )
        let orbit = NSBezierPath(ovalIn: orbitRect)
        orbit.lineWidth = 1.05
        orbit.stroke()

        context.restoreGState()
    }

    /// Stadium (rounded-rect along a vector) shape used to mask the orbit out
    /// of the magnifying-glass handle.
    private static func handleClipShape(from start: NSPoint, to end: NSPoint, width: CGFloat) -> NSBezierPath {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return NSBezierPath() }
        let nx = -dy / length
        let ny = dx / length
        let half = width / 2

        let p1 = NSPoint(x: start.x + nx * half, y: start.y + ny * half)
        let p2 = NSPoint(x: end.x + nx * half, y: end.y + ny * half)
        let p4 = NSPoint(x: start.x - nx * half, y: start.y - ny * half)

        let path = NSBezierPath()
        path.move(to: p1)
        path.line(to: p2)
        // End cap: half-circle around `end`.
        path.appendArc(
            withCenter: end,
            radius: half,
            startAngle: atan2(ny, nx) * 180 / .pi,
            endAngle: atan2(-ny, -nx) * 180 / .pi,
            clockwise: true
        )
        path.line(to: p4)
        // Start cap: half-circle around `start`.
        path.appendArc(
            withCenter: start,
            radius: half,
            startAngle: atan2(-ny, -nx) * 180 / .pi,
            endAngle: atan2(ny, nx) * 180 / .pi,
            clockwise: true
        )
        path.close()
        return path
    }

    private static func drawLens(center: NSPoint, radius: CGFloat, stroke: CGFloat) {
        let lens = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        lens.lineWidth = stroke
        lens.stroke()
    }

    private static func drawHandle(lensCenter: NSPoint, lensRadius: CGFloat) {
        let angle: CGFloat = -.pi / 4
        let start = NSPoint(
            x: lensCenter.x + cos(angle) * lensRadius,
            y: lensCenter.y + sin(angle) * lensRadius
        )
        let end = NSPoint(
            x: lensCenter.x + cos(angle) * (lensRadius + 4.4),
            y: lensCenter.y + sin(angle) * (lensRadius + 4.4)
        )
        let handle = NSBezierPath()
        handle.move(to: start)
        handle.line(to: end)
        handle.lineCapStyle = .round
        handle.lineWidth = 2.0
        handle.stroke()
    }

    private static func sparkle(center: NSPoint, outer: CGFloat, inner: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let points = 4
        let total = points * 2
        for i in 0..<total {
            let radius = i.isMultiple(of: 2) ? outer : inner
            let theta = -CGFloat.pi / 2 + CGFloat(i) * (.pi / CGFloat(points))
            let p = NSPoint(
                x: center.x + cos(theta) * radius,
                y: center.y + sin(theta) * radius
            )
            if i == 0 {
                path.move(to: p)
            } else {
                path.line(to: p)
            }
        }
        path.close()
        return path
    }
}
