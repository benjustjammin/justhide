//
//  make-icon.swift
//  JustHide
//
//  Draws the app icon and writes AppIcon.icns.
//
//  Run: swift tools/make-icon.swift Resources
//
//  The motif is the thing the app does: a menu bar strip with a chevron and a
//  few icons to its right, the ones that stay. Drawn rather than shipped as
//  artwork so it can be regenerated and tweaked without a binary asset.
//

import AppKit

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"

/// macOS app icons sit in a rounded square with a margin around it, roughly
/// 10% on each side, or they look oversized next to system icons.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let scale = size / 1024
        let inset = 100 * scale
        let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let corner = 185 * scale

        // Body: a deep blue-to-indigo gradient, in the register of the system icons.
        let shape = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)
        NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.32, blue: 0.72, alpha: 1),
                   ending: NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.38, alpha: 1))?
            .draw(in: shape, angle: -90)

        // A subtle top highlight, which is what stops a flat gradient looking dead.
        let highlight = NSBezierPath(roundedRect: body.insetBy(dx: 0, dy: 0), xRadius: corner, yRadius: corner)
        highlight.setClip()
        NSGradient(starting: NSColor(white: 1, alpha: 0.22),
                   ending: NSColor(white: 1, alpha: 0))?
            .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

        // The menu bar strip. Deliberately chunky: at small sizes a thin bar
        // disappears, and the point of the icon is to read as a menu bar.
        let barHeight = 230 * scale
        let barRect = NSRect(x: body.minX + 55 * scale,
                             y: body.midY - barHeight / 2,
                             width: body.width - 110 * scale,
                             height: barHeight)
        NSColor(white: 1, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

        // The chevron, left of centre: what you click.
        let chevron = NSBezierPath()
        chevron.lineWidth = 30 * scale
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        // Smaller than the icons beside it: in a real bar the chevron is the
        // smallest thing there, not the biggest.
        let chevronX = barRect.minX + 115 * scale
        let chevronReach = 34 * scale
        chevron.move(to: NSPoint(x: chevronX + chevronReach, y: barRect.midY + chevronReach))
        chevron.line(to: NSPoint(x: chevronX - chevronReach * 0.2, y: barRect.midY))
        chevron.line(to: NSPoint(x: chevronX + chevronReach, y: barRect.midY - chevronReach))
        NSColor(calibratedRed: 0.13, green: 0.18, blue: 0.45, alpha: 1).setStroke()
        chevron.stroke()

        // Three icons to its right: the ones that stay visible. Sized like real
        // menu bar glyphs relative to the bar, not like punctuation.
        // Spacing chosen so the last icon sits inside the bar with a margin to
        // spare: bar width is body.width - 110, and an earlier attempt clipped
        // the third one clean off the end.
        let dotRadius = 52 * scale
        let firstDot = chevronX + 195 * scale
        let dotGap = 150 * scale
        for index in 0..<3 {
            let centre = NSPoint(x: firstDot + CGFloat(index) * dotGap, y: barRect.midY)
            let dot = NSBezierPath(ovalIn: NSRect(x: centre.x - dotRadius, y: centre.y - dotRadius,
                                                  width: dotRadius * 2, height: dotRadius * 2))
            NSColor(calibratedRed: 0.13, green: 0.18, blue: 0.45, alpha: index == 0 ? 1 : 0.55).setFill()
            dot.fill()
        }
        return true
    }
    return image
}

// An .iconset needs these, at 1x and 2x.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let iconset = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    let image = drawIcon(size: variant.pixels)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("failed to render \(variant.name)")
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

print("wrote \(iconset.path)")
