#!/usr/bin/env swift
// Draws the Ginkgo app icon (1024×1024 PNG) with Core Graphics, so the icon is reproducible from source.
// Usage: swift scripts/make-icon.swift <output.png>
//
// A single golden ginkgo leaf on warm paper. The leaf's two lobes read as an open book; the leaf itself is
// the bookmark East Asian readers used to tuck between pages to keep silverfish away.

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Work in a top-left origin, y-down space like the design sketch.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// Paper background.
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0xFBF6EC), rgb(0xEFE4CF)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size), options: [])

// Leaf, tilted a little like a bookmark dropped on a page.
ctx.saveGState()
ctx.translateBy(x: 512, y: 560)
ctx.rotate(by: -12 * .pi / 180)
ctx.translateBy(x: -512, y: -560)

let base = CGPoint(x: 512, y: 700)
let leaf = CGMutablePath()
leaf.move(to: base)
// Left side: nearly straight, the fan opening wide.
leaf.addCurve(to: CGPoint(x: 160, y: 418), control1: CGPoint(x: 430, y: 640), control2: CGPoint(x: 236, y: 500))
// Left lobe: a broad, flat arc.
leaf.addCurve(to: CGPoint(x: 352, y: 246), control1: CGPoint(x: 136, y: 330), control2: CGPoint(x: 236, y: 252))
// Shallow notch splitting the two lobes.
leaf.addCurve(to: CGPoint(x: 512, y: 292), control1: CGPoint(x: 432, y: 242), control2: CGPoint(x: 492, y: 258))
leaf.addCurve(to: CGPoint(x: 672, y: 246), control1: CGPoint(x: 532, y: 258), control2: CGPoint(x: 592, y: 242))
leaf.addCurve(to: CGPoint(x: 864, y: 418), control1: CGPoint(x: 788, y: 252), control2: CGPoint(x: 888, y: 330))
leaf.addCurve(to: base, control1: CGPoint(x: 788, y: 500), control2: CGPoint(x: 594, y: 640))
leaf.closeSubpath()

// Stem.
let stem = CGMutablePath()
stem.move(to: CGPoint(x: 512, y: 690))
stem.addQuadCurve(to: CGPoint(x: 492, y: 850), control: CGPoint(x: 518, y: 780))

// Soft shadow on the paper.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: rgb(0x6B4A12, 0.28))
ctx.addPath(leaf)
ctx.setFillColor(rgb(0xE0A62E))
ctx.fillPath()
ctx.addPath(stem)
ctx.setStrokeColor(rgb(0xB9801C))
ctx.setLineWidth(16)
ctx.setLineCap(.round)
ctx.strokePath()
ctx.restoreGState()

// Leaf body: golden gradient from the tip edge down to the base.
ctx.saveGState()
ctx.addPath(leaf)
ctx.clip()
let gold = CGGradient(colorsSpace: cs, colors: [rgb(0xF7CF5C), rgb(0xE9AE34), rgb(0xC98A1E)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gold, start: CGPoint(x: 512, y: 240), end: base, options: [.drawsAfterEndLocation])

// Fan veins radiating from the base.
ctx.setStrokeColor(rgb(0xFFF4D6, 0.38))
ctx.setLineWidth(3.2)
ctx.setLineCap(.round)
let veins = 17
for i in 0..<veins {
    let t = CGFloat(i) / CGFloat(veins - 1)
    let angle = (-162 + t * 144) * .pi / 180  // spread across the fan
    let end = CGPoint(x: base.x + cos(angle) * 560, y: base.y + sin(angle) * 560)
    ctx.move(to: base)
    ctx.addLine(to: end)
}
ctx.strokePath()

// A faint highlight along the upper edge.
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 210), end: CGPoint(x: 512, y: 440), options: [])
ctx.restoreGState()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
