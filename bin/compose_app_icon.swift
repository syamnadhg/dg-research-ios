#!/usr/bin/env swift
//
// Composite the Apple mark onto the app icon, top-left.
//
// ⚠ Why a Swift script rather than a line of `sips`. This device is the *iOS* backend, and the
// owner wants the tile to say so at a glance — the web app and the phone otherwise carry an
// identical telescope. The badge has to be the real Apple glyph, and the only place that glyph
// legally and reliably exists on this machine is SF Symbols (`apple.logo`), reachable through
// AppKit. `sips` cannot composite at all, and nothing else on this box can rasterise a vector.
//
// Usage: compose_app_icon.swift <base.png> <out.png>
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: compose_app_icon.swift <base.png> <out.png>\n".data(using: .utf8)!)
    exit(2)
}

guard let base = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

let side = max(base.size.width, base.size.height)
let canvas = NSImage(size: NSSize(width: side, height: side))

canvas.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
base.draw(in: NSRect(x: 0, y: 0, width: side, height: side))

// ⚠ BLENDED, not badged. The first version drew a hard near-black disc with a white glyph, and at
// 60pt it read as a sticker someone had stuck on top of the artwork — the one thing an app icon
// must not look like. The fix is to stop treating it as a badge: no disc, and the glyph painted in
// the mark's OWN palette, so it sits in the picture rather than on it.
//
// `#6366f1` is lifted straight from `favicon.svg` — it is the `tgLegFade` indigo the telescope's
// legs already use. Reusing an existing colour is what makes the addition look authored.
let badgeSide = side * 0.30
let inset = side * 0.055
// AppKit's origin is BOTTOM-left, so "top-left" is y = side - inset - badgeSide.
let badgeRect = NSRect(
    x: inset, y: side - inset - badgeSide, width: badgeSide, height: badgeSide
)

// A soft halo in the same violet the SVG's own nebula gradients use, at the same sort of opacity
// (the file's `tgNebUL` stop is 0.12). Enough to seat the glyph on the white field; not enough to
// read as a shape of its own.
let haloColor = NSColor(calibratedRed: 0.545, green: 0.361, blue: 0.965, alpha: 1)
for step in stride(from: 5, through: 1, by: -1) {
    let grow = badgeSide * 0.10 * CGFloat(step)
    haloColor.withAlphaComponent(0.030).setFill()
    NSBezierPath(ovalIn: badgeRect.insetBy(dx: -grow, dy: -grow)).fill()
}

guard let symbol = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "iOS") else {
    FileHandle.standardError.write("SF Symbol apple.logo unavailable\n".data(using: .utf8)!)
    exit(1)
}
let glyphColor = NSColor(calibratedRed: 0.388, green: 0.400, blue: 0.945, alpha: 1)  // #6366f1
let tinted = symbol.withSymbolConfiguration(
    NSImage.SymbolConfiguration(pointSize: badgeSide * 0.62, weight: .medium)
        .applying(.init(paletteColors: [glyphColor]))
) ?? symbol

// Centred in the disc by its own aspect ratio, not by assuming it is square — the Apple glyph is
// taller than it is wide, and centring a square would sit it low.
let glyphHeight = badgeSide * 0.58
let glyphWidth = glyphHeight * (tinted.size.width / max(tinted.size.height, 1))
tinted.draw(
    in: NSRect(
        x: badgeRect.midX - glyphWidth / 2,
        y: badgeRect.midY - glyphHeight / 2,
        width: glyphWidth,
        height: glyphHeight
    ),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)
canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: args[2]))
