#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Renders the SolarLight DMG background at 1x and 2x.
// Output: Assets/dmg-background.png (540x380) and Assets/dmg-background@2x.png (1080x760).
//
// Layout matches the icon positions set by Scripts/package-dmg.sh:
//   SolarLight.app icon center -> (140, 180)
//   Applications  icon center -> (400, 180)
// Coordinates here are in points with origin top-left (Finder convention).

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let rootURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let assetsURL = rootURL.appendingPathComponent("Assets")

let baseSize = CGSize(width: 540, height: 380)

func render(scale: CGFloat) -> Data {
    let pixelWidth = Int(baseSize.width * scale)
    let pixelHeight = Int(baseSize.height * scale)

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Failed to create CGContext")
    }

    context.scaleBy(x: scale, y: scale)

    // Top-left origin coordinate system to match Finder.
    context.translateBy(x: 0, y: baseSize.height)
    context.scaleBy(x: 1, y: -1)

    let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext

    drawBackground(size: baseSize)
    drawHeadline(size: baseSize)
    drawArrow(size: baseSize)
    drawFootnote(size: baseSize)

    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = context.makeImage() else {
        fatalError("Failed to make CGImage")
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    bitmap.size = baseSize
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG")
    }
    return png
}

func drawBackground(size: CGSize) {
    // Soft top-to-bottom gradient: near-white with a faint blue wash.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.984, green: 0.988, blue: 0.996, alpha: 1.0),
        NSColor(calibratedRed: 0.929, green: 0.949, blue: 0.984, alpha: 1.0)
    ])!
    gradient.draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Subtle radial highlight behind the app icon.
    let highlightCenter = NSPoint(x: 140, y: 180)
    let highlight = NSGradient(colors: [
        NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.85),
        NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.0)
    ])!
    highlight.draw(
        fromCenter: highlightCenter, radius: 0,
        toCenter: highlightCenter, radius: 130,
        options: []
    )
}

func drawHeadline(size: CGSize) {
    let title = "Install SolarLight"
    let subtitle = "Drag the SolarLight icon onto the Applications folder."

    let titleStyle = NSMutableParagraphStyle()
    titleStyle.alignment = .center
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
        .foregroundColor: NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.20, alpha: 1.0),
        .paragraphStyle: titleStyle,
        .kern: 0.2
    ]
    let titleSize = (title as NSString).size(withAttributes: titleAttrs)
    let titleRect = NSRect(
        x: (size.width - titleSize.width) / 2,
        y: 38,
        width: titleSize.width,
        height: titleSize.height
    )
    (title as NSString).draw(in: titleRect, withAttributes: titleAttrs)

    let subtitleStyle = NSMutableParagraphStyle()
    subtitleStyle.alignment = .center
    let subtitleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(calibratedRed: 0.32, green: 0.36, blue: 0.45, alpha: 1.0),
        .paragraphStyle: subtitleStyle
    ]
    let subtitleSize = (subtitle as NSString).size(withAttributes: subtitleAttrs)
    let subtitleRect = NSRect(
        x: (size.width - subtitleSize.width) / 2,
        y: titleRect.maxY + 6,
        width: subtitleSize.width,
        height: subtitleSize.height
    )
    (subtitle as NSString).draw(in: subtitleRect, withAttributes: subtitleAttrs)
}

func drawArrow(size: CGSize) {
    // Arrow drawn between the two icon centers (140, 180) and (400, 180).
    // Icons are ~96pt wide so leave breathing room around them.
    let startX: CGFloat = 210
    let endX: CGFloat = 330
    let midY: CGFloat = 180

    let shaftHeight: CGFloat = 8
    let headWidth: CGFloat = 26
    let headHeight: CGFloat = 28

    let shaftRect = NSRect(
        x: startX,
        y: midY - shaftHeight / 2,
        width: endX - startX - headWidth + 6,
        height: shaftHeight
    )

    let path = NSBezierPath()
    path.move(to: NSPoint(x: shaftRect.minX, y: shaftRect.minY))
    path.line(to: NSPoint(x: shaftRect.maxX, y: shaftRect.minY))
    path.line(to: NSPoint(x: shaftRect.maxX, y: midY - headHeight / 2))
    path.line(to: NSPoint(x: endX, y: midY))
    path.line(to: NSPoint(x: shaftRect.maxX, y: midY + headHeight / 2))
    path.line(to: NSPoint(x: shaftRect.maxX, y: shaftRect.maxY))
    path.line(to: NSPoint(x: shaftRect.minX, y: shaftRect.maxY))
    path.close()

    NSColor(calibratedRed: 0.18, green: 0.32, blue: 0.62, alpha: 0.85).setFill()
    path.fill()
}

func drawFootnote(size: CGSize) {
    let text = "On first launch, macOS may ask you to confirm opening an app from the internet."

    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor(calibratedRed: 0.42, green: 0.46, blue: 0.55, alpha: 1.0),
        .paragraphStyle: style
    ]
    let textSize = (text as NSString).size(withAttributes: attrs)
    let rect = NSRect(
        x: (size.width - textSize.width) / 2,
        y: size.height - textSize.height - 22,
        width: textSize.width,
        height: textSize.height
    )
    (text as NSString).draw(in: rect, withAttributes: attrs)
}

let outputs: [(name: String, scale: CGFloat)] = [
    ("dmg-background.png", 1),
    ("dmg-background@2x.png", 2)
]

for output in outputs {
    let data = render(scale: output.scale)
    let url = assetsURL.appendingPathComponent(output.name)
    try data.write(to: url)
    print("Wrote \(url.path) (\(data.count) bytes)")
}
