#!/usr/bin/env swift
// ChargeSurf app icon: a white battery whose charge is a green sea, with a navy sailboat on the swell.
// Drawn with CoreGraphics so it can be rebuilt without design tools. Flat art, no text, custom shapes.
// Usage: swift docs/icon/generate-icon.swift <outdir>
//   writes art-1024.png (full-bleed square) and icon-1024.png (macOS rounded shape, 824 px body).
// docs/icon/make-icon.sh turns icon-1024.png into resources/ChargeSurf.icns.

import AppKit
import CoreGraphics
import QuartzCore

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let cs = CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                         CGFloat(hex & 0xFF) / 255, a])!
}

// Palette: sea teal to navy (as in the README images), white, Apple green for the charge.
let skyTop: UInt32 = 0x1E8FB3, skyBottom: UInt32 = 0x0B2545
let white: UInt32 = 0xFFFFFF, navy: UInt32 = 0x0B2545, navyLight: UInt32 = 0x1E5F86
let seaTop: UInt32 = 0x5BE07A, seaBottom: UInt32 = 0x1FA84A

func makeContext() -> CGContext {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    return ctx
}

func roundRect(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat) {
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
}

// Sea surface: a sine swell across the battery, with a crest under the boat.
struct Sea {
    var level: CGFloat = 0.40, amp: CGFloat = 22, periods: CGFloat = 2.25, crestAt: CGFloat = 0.45
    var phase: CGFloat { 0.25 - periods * crestAt }
}

func surfaceY(_ x: CGFloat, _ inner: CGRect, _ sea: Sea) -> CGFloat {
    let x0 = inner.minX - 10, x1 = inner.maxX + 10, t = (x - x0) / (x1 - x0)
    return inner.minY + inner.height * sea.level + sea.amp * sin((t * sea.periods + sea.phase) * 2 * .pi)
}

func seaPath(_ inner: CGRect, _ sea: Sea) -> CGPath {
    let p = CGMutablePath(), x0 = inner.minX - 10, x1 = inner.maxX + 10
    for i in 0...160 {
        let x = x0 + (x1 - x0) * CGFloat(i) / 160
        let pt = CGPoint(x: x, y: surfaceY(x, inner, sea))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.addLine(to: CGPoint(x: x1, y: inner.minY - 10)); p.addLine(to: CGPoint(x: x0, y: inner.minY - 10))
    p.closeSubpath()
    return p
}

/// Sailboat with its deck at (cx, deckY): hull, mainsail and jib. s = scale.
func sailboat(_ ctx: CGContext, cx: CGFloat, deckY: CGFloat, s: CGFloat) {
    let hw = 300 * s, hh = 70 * s
    let h = CGMutablePath()
    h.move(to: CGPoint(x: cx - hw / 2, y: deckY)); h.addLine(to: CGPoint(x: cx + hw / 2, y: deckY))
    h.addCurve(to: CGPoint(x: cx + hw * 0.22, y: deckY - hh), control1: CGPoint(x: cx + hw * 0.46, y: deckY - hh * 0.5), control2: CGPoint(x: cx + hw * 0.36, y: deckY - hh))
    h.addLine(to: CGPoint(x: cx - hw * 0.26, y: deckY - hh))
    h.addCurve(to: CGPoint(x: cx - hw / 2, y: deckY), control1: CGPoint(x: cx - hw * 0.40, y: deckY - hh), control2: CGPoint(x: cx - hw * 0.47, y: deckY - hh * 0.45))
    h.closeSubpath()
    ctx.addPath(h); ctx.setFillColor(rgb(navy)); ctx.fillPath()
    let mastX = cx - 10 * s, gap = 18 * s
    let m = CGMutablePath()
    m.move(to: CGPoint(x: mastX, y: deckY + 400 * s))
    m.addCurve(to: CGPoint(x: mastX, y: deckY + gap), control1: CGPoint(x: mastX, y: deckY + 300 * s), control2: CGPoint(x: mastX, y: deckY + 120 * s))
    m.addLine(to: CGPoint(x: mastX + 215 * s, y: deckY + gap))
    m.addCurve(to: CGPoint(x: mastX, y: deckY + 400 * s), control1: CGPoint(x: mastX + 170 * s, y: deckY + 150 * s), control2: CGPoint(x: mastX + 90 * s, y: deckY + 300 * s))
    m.closeSubpath()
    ctx.addPath(m); ctx.setFillColor(rgb(navy)); ctx.fillPath()
    let j = CGMutablePath()
    j.move(to: CGPoint(x: mastX - gap, y: deckY + 330 * s)); j.addLine(to: CGPoint(x: mastX - gap, y: deckY + gap))
    j.addLine(to: CGPoint(x: mastX - 150 * s, y: deckY + gap))
    j.addCurve(to: CGPoint(x: mastX - gap, y: deckY + 330 * s), control1: CGPoint(x: mastX - 110 * s, y: deckY + 120 * s), control2: CGPoint(x: mastX - 60 * s, y: deckY + 240 * s))
    j.closeSubpath()
    ctx.addPath(j); ctx.setFillColor(rgb(navyLight)); ctx.fillPath()
}

/// Full-bleed square art.
func art() -> CGImage {
    let ctx = makeContext()
    let g = CGGradient(colorsSpace: cs, colors: [rgb(skyTop), rgb(skyBottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: size * 0.3, y: size), end: CGPoint(x: size * 0.7, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Battery: solid white body and terminal.
    let body = CGRect(x: 118, y: 282, width: 724, height: 460)
    roundRect(ctx, CGRect(x: 842, y: 432, width: 64, height: 160), 26); ctx.setFillColor(rgb(white)); ctx.fillPath()
    roundRect(ctx, body, 84); ctx.fillPath()
    // Charge sea inside.
    let inner = body.insetBy(dx: 30, dy: 30), sea = Sea()
    ctx.saveGState()
    roundRect(ctx, inner, 50); ctx.clip()
    ctx.addPath(seaPath(inner, sea)); ctx.clip()
    let level = inner.minY + inner.height * sea.level
    let sg = CGGradient(colorsSpace: cs, colors: [rgb(seaTop), rgb(seaBottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sg, start: CGPoint(x: 0, y: level + sea.amp), end: CGPoint(x: 0, y: inner.minY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    // Boat on the crest, tilted a little with the swell.
    let s: CGFloat = 0.46, bx = inner.minX + inner.width * sea.crestAt
    let tilt = atan((surfaceY(bx + 1, inner, sea) - surfaceY(bx - 1, inner, sea)) / 2) * 0.6
    ctx.saveGState()
    ctx.translateBy(x: bx, y: surfaceY(bx, inner, sea)); ctx.rotate(by: tilt)
    sailboat(ctx, cx: 0, deckY: 50 * s, s: s)
    ctx.restoreGState()
    return ctx.makeImage()!
}

/// macOS app icon: the art inside the standard rounded shape (824 px body, continuous corners), transparent margin.
func appIcon(_ artwork: CGImage) -> CGImage {
    let body: CGFloat = 824, off = (size - body) / 2
    let mask = CALayer()
    mask.frame = CGRect(x: 0, y: 0, width: body, height: body)
    mask.cornerRadius = body * 0.225; mask.cornerCurve = .continuous
    mask.backgroundColor = rgb(white); mask.masksToBounds = true
    let mctx = makeContext()
    mctx.translateBy(x: off, y: off)
    mask.render(in: mctx)
    let maskImage = mctx.makeImage()!
    let ctx = makeContext()
    ctx.clip(to: CGRect(x: 0, y: 0, width: size, height: size), mask: maskImage)
    ctx.draw(artwork, in: CGRect(x: off, y: off, width: body, height: body))
    return ctx.makeImage()!
}

func save(_ img: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    print("wrote \(out)/\(name)")
}

try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let a = art()
save(a, "art-1024.png")
save(appIcon(a), "icon-1024.png")
