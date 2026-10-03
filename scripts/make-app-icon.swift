#!/usr/bin/env swift
// Generates the RiepilogoIliad app icon into
// RiepilogoIliad/Assets.xcassets/AppIcon.appiconset (PNGs + Contents.json).
//
// Design: "SIM + anello dati" — a white SIM card inside a tri-colour data ring
// (green / yellow / red, echoing the app's usage bar) on a violet squircle.
//
// Usage (from the repo root):  swift scripts/make-app-icon.swift
// or:                          make icon

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct IconSpec {
    let name: String
    let px: Int
}

let specs: [IconSpec] = [
    .init(name: "icon_16x16", px: 16),
    .init(name: "icon_16x16@2x", px: 32),
    .init(name: "icon_32x32", px: 32),
    .init(name: "icon_32x32@2x", px: 64),
    .init(name: "icon_128x128", px: 128),
    .init(name: "icon_128x128@2x", px: 256),
    .init(name: "icon_256x256", px: 256),
    .init(name: "icon_256x256@2x", px: 512),
    .init(name: "icon_512x512", px: 512),
    .init(name: "icon_512x512@2x", px: 1024),
]

func render(px: Int) -> CGImage {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // macOS icon grid: content ≈ 80.5% of the canvas, Big Sur corner curvature.
    let margin = s * 0.0977
    let content = s - margin * 2
    let radius = content * 0.2237
    let bgRect = CGRect(x: margin, y: margin, width: content, height: content)

    // Violet squircle background with a soft top gloss.
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let top = CGColor(srgbRed: 0.38, green: 0.33, blue: 0.96, alpha: 1)
    let bottom = CGColor(srgbRed: 0.47, green: 0.15, blue: 0.76, alpha: 1)
    let bgGradient = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: bgRect.minX, y: bgRect.maxY),
        end: CGPoint(x: bgRect.maxX, y: bgRect.minY),
        options: []
    )
    let gloss = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gloss,
        start: CGPoint(x: bgRect.midX, y: bgRect.maxY),
        end: CGPoint(x: bgRect.midX, y: bgRect.midY),
        options: []
    )
    ctx.restoreGState()

    let center = CGPoint(x: bgRect.midX, y: bgRect.midY)

    // Data ring: three arcs, clockwise from the top (angles in degrees,
    // clockwise from 12 o'clock): green 0–150, yellow 160–250, red 260–300.
    let ringRadius = content * 0.40
    let ringWidth = max(content * 0.085, 1.0)
    let ringColors: [(CGFloat, CGFloat, CGColor)] = [
        (0, 150, CGColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)),
        (160, 250, CGColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1)),
        (260, 300, CGColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1)),
    ]
    ctx.setLineWidth(ringWidth)
    ctx.setLineCap(.round)
    for (from, to, color) in ringColors {
        ctx.setStrokeColor(color)
        ctx.addArc(
            center: center, radius: ringRadius,
            startAngle: (90 - from) * .pi / 180,
            endAngle: (90 - to) * .pi / 180,
            clockwise: true
        )
        ctx.strokePath()
    }

    // SIM card: white rounded rect with a chamfered top-right corner.
    let cardW = content * 0.35
    let cardH = content * 0.48
    let x0 = center.x - cardW / 2
    let y0 = center.y - cardH / 2
    let corner = cardW * 0.15
    let chamfer = cardW * 0.36

    let card = CGMutablePath()
    card.move(to: CGPoint(x: x0 + corner, y: y0))
    card.addLine(to: CGPoint(x: x0 + cardW - corner, y: y0))
    card.addArc(
        center: CGPoint(x: x0 + cardW - corner, y: y0 + corner),
        radius: corner, startAngle: -.pi / 2, endAngle: 0, clockwise: false
    )
    card.addLine(to: CGPoint(x: x0 + cardW, y: y0 + cardH - chamfer))
    card.addLine(to: CGPoint(x: x0 + cardW - chamfer, y: y0 + cardH))
    card.addLine(to: CGPoint(x: x0 + corner, y: y0 + cardH))
    card.addArc(
        center: CGPoint(x: x0 + corner, y: y0 + cardH - corner),
        radius: corner, startAngle: .pi / 2, endAngle: .pi, clockwise: false
    )
    card.addLine(to: CGPoint(x: x0, y: y0 + corner))
    card.addArc(
        center: CGPoint(x: x0 + corner, y: y0 + corner),
        radius: corner, startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false
    )
    card.closeSubpath()

    ctx.saveGState()
    if px >= 64 {
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.010),
            blur: s * 0.030,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30)
        )
    }
    ctx.setFillColor(CGColor(srgbRed: 0.99, green: 0.99, blue: 1.0, alpha: 1))
    ctx.addPath(card)
    ctx.fillPath()
    ctx.restoreGState()

    // Contact chip (skipped when it would be sub-pixel noise).
    if px >= 32 {
        let chipW = cardW * 0.52
        let chipH = cardH * 0.28
        let chipRect = CGRect(
            x: center.x - chipW / 2,
            y: center.y - chipH / 2,
            width: chipW, height: chipH
        )
        let chipPath = CGPath(
            roundedRect: chipRect,
            cornerWidth: chipW * 0.12, cornerHeight: chipW * 0.12, transform: nil
        )
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.68, blue: 0.22, alpha: 1))
        ctx.addPath(chipPath)
        ctx.fillPath()

        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55))
        ctx.setLineWidth(max(chipW * 0.045, 0.6))
        for i in 1...2 {
            let x = chipRect.minX + chipW * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: chipRect.minY + chipH * 0.18))
            ctx.addLine(to: CGPoint(x: x, y: chipRect.maxY - chipH * 0.18))
            ctx.strokePath()
        }
    }

    return ctx.makeImage()!
}

func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Failed to encode PNG")
    }
    return data as Data
}

// MARK: - Output

let fm = FileManager.default
let catalogURL = URL(fileURLWithPath: "RiepilogoIliad/Assets.xcassets")
let iconSetURL = catalogURL.appendingPathComponent("AppIcon.appiconset")

try fm.createDirectory(at: iconSetURL, withIntermediateDirectories: true)

let catalogContents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try catalogContents.write(
    to: catalogURL.appendingPathComponent("Contents.json"),
    atomically: true, encoding: .utf8
)

let appIconContents = """
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16", "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16", "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32", "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32", "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try appIconContents.write(
    to: iconSetURL.appendingPathComponent("Contents.json"),
    atomically: true, encoding: .utf8
)

for spec in specs {
    let image = render(px: spec.px)
    let url = iconSetURL.appendingPathComponent("\(spec.name).png")
    try pngData(image).write(to: url)
    print("wrote \(url.path) (\(spec.px)×\(spec.px))")
}
print("App icon generated.")
