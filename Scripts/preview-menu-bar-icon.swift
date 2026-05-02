#!/usr/bin/env swift
// Renders the SolarLight menu bar icon to .build/menu-bar-icon-preview.png
// at 16x scale for visual review. Mirrors the path code in MenuBarIcon.swift.
import AppKit
import Foundation

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let rootURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let buildURL = rootURL.appendingPathComponent(".build")
try? FileManager.default.createDirectory(at: buildURL, withIntermediateDirectories: true)

let scale: CGFloat = 16
let canvas = NSSize(width: 18, height: 18)
let pixelW = Int(canvas.width * scale)
let pixelH = Int(canvas.height * scale)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil,
    width: pixelW,
    height: pixelH,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

context.setFillColor(NSColor(white: 0.94, alpha: 1.0).cgColor)
context.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

context.scaleBy(x: scale, y: scale)

let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsContext

NSColor.black.setStroke()
NSColor.black.setFill()

let lensCenter = NSPoint(x: 7.4, y: 10.6)
let lensRadius: CGFloat = 5.0
let lensStroke: CGFloat = 1.6
let handleAngle: CGFloat = -.pi / 4
let handleStart = NSPoint(
    x: lensCenter.x + cos(handleAngle) * lensRadius,
    y: lensCenter.y + sin(handleAngle) * lensRadius
)
let handleEnd = NSPoint(
    x: lensCenter.x + cos(handleAngle) * (lensRadius + 4.4),
    y: lensCenter.y + sin(handleAngle) * (lensRadius + 4.4)
)

func handleClipShape(from start: NSPoint, to end: NSPoint, width: CGFloat) -> NSBezierPath {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = sqrt(dx * dx + dy * dy)
    let nx = -dy / length
    let ny = dx / length
    let half = width / 2
    let p1 = NSPoint(x: start.x + nx * half, y: start.y + ny * half)
    let p2 = NSPoint(x: end.x + nx * half, y: end.y + ny * half)
    let p4 = NSPoint(x: start.x - nx * half, y: start.y - ny * half)
    let path = NSBezierPath()
    path.move(to: p1)
    path.line(to: p2)
    path.appendArc(withCenter: end, radius: half,
                   startAngle: atan2(ny, nx) * 180 / .pi,
                   endAngle: atan2(-ny, -nx) * 180 / .pi,
                   clockwise: true)
    path.line(to: p4)
    path.appendArc(withCenter: start, radius: half,
                   startAngle: atan2(-ny, -nx) * 180 / .pi,
                   endAngle: atan2(ny, nx) * 180 / .pi,
                   clockwise: true)
    path.close()
    return path
}

// Orbit (with even-odd clip excluding lens interior + handle).
do {
    context.saveGState()
    let clip = NSBezierPath(rect: NSRect(origin: .zero, size: canvas))
    clip.windingRule = .evenOdd
    let lensInterior = NSBezierPath(ovalIn: NSRect(
        x: lensCenter.x - (lensRadius - 0.4),
        y: lensCenter.y - (lensRadius - 0.4),
        width: (lensRadius - 0.4) * 2,
        height: (lensRadius - 0.4) * 2
    ))
    clip.append(lensInterior)
    clip.append(handleClipShape(from: handleStart, to: handleEnd, width: 3.4))
    clip.addClip()

    let center = NSPoint(x: canvas.width / 2, y: canvas.height / 2)
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: .pi / 6)
    context.translateBy(x: -center.x, y: -center.y)

    let orbitRect = NSRect(x: center.x - 8.8, y: center.y - 2.6, width: 17.6, height: 5.2)
    let orbit = NSBezierPath(ovalIn: orbitRect)
    orbit.lineWidth = 1.05
    orbit.stroke()
    context.restoreGState()
}

let lens = NSBezierPath(ovalIn: NSRect(
    x: lensCenter.x - lensRadius,
    y: lensCenter.y - lensRadius,
    width: lensRadius * 2,
    height: lensRadius * 2
))
lens.lineWidth = lensStroke
lens.stroke()

let handle = NSBezierPath()
handle.move(to: handleStart)
handle.line(to: handleEnd)
handle.lineCapStyle = .round
handle.lineWidth = 2.0
handle.stroke()

do {
    let path = NSBezierPath()
    let points = 4
    let total = points * 2
    let outer: CGFloat = 3.1
    let inner: CGFloat = 0.8
    for i in 0..<total {
        let radius = i.isMultiple(of: 2) ? outer : inner
        let theta = -CGFloat.pi / 2 + CGFloat(i) * (.pi / CGFloat(points))
        let p = NSPoint(
            x: lensCenter.x + cos(theta) * radius,
            y: lensCenter.y + sin(theta) * radius
        )
        if i == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    path.close()
    path.fill()
}

NSGraphicsContext.restoreGraphicsState()

let cgImage = context.makeImage()!
let bitmap = NSBitmapImageRep(cgImage: cgImage)
let png = bitmap.representation(using: .png, properties: [:])!
let outURL = buildURL.appendingPathComponent("menu-bar-icon-preview.png")
try png.write(to: outURL)
print(outURL.path)
