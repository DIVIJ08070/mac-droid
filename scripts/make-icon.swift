// Renders the Bifrost app icon: a rainbow-gradient bridge arc spanning two nodes
// (the two devices) on a dark rounded square. Usage: swift make-icon.swift out.png
import AppKit

let outputPath = CommandLine.arguments[1]
// "foreground" mode: transparent background, design shrunk into the center so
// Android's adaptive-icon mask doesn't clip it.
let foregroundMode = CommandLine.arguments.contains("foreground")
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// ── Background: dark rounded square with a subtle vertical gradient ──
if !foregroundMode {
    let inset: CGFloat = 96
    let bgRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 200, cornerHeight: 200, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bgGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.13, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.07, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()
}

// In foreground mode, scale the design down about the icon centre so Android's
// adaptive mask doesn't clip it (safe zone ≈ inner two-thirds).
if foregroundMode {
    let s: CGFloat = 0.74
    ctx.translateBy(x: size / 2, y: size * 0.52)
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: -size / 2, y: -size * 0.50)
}

// ── The bridge: an arc from the left node to the right node, bulging up ──
let left = CGPoint(x: size * 0.30, y: size * 0.40)
let right = CGPoint(x: size * 0.70, y: size * 0.40)
let arc = CGMutablePath()
arc.move(to: left)
arc.addCurve(
    to: right,
    control1: CGPoint(x: size * 0.40, y: size * 0.80),
    control2: CGPoint(x: size * 0.60, y: size * 0.80)
)
let lineWidth: CGFloat = 62
let stroked = arc.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 0)

ctx.saveGState()
ctx.addPath(stroked)
ctx.clip()
// Bifrost spectrum — a refined rainbow, warm on the left to cool on the right.
let spectrum = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.42, alpha: 1).cgColor, // coral
        NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.36, alpha: 1).cgColor, // amber
        NSColor(calibratedRed: 0.55, green: 0.90, blue: 0.55, alpha: 1).cgColor, // green
        NSColor(calibratedRed: 0.40, green: 0.78, blue: 1.00, alpha: 1).cgColor, // sky
        NSColor(calibratedRed: 0.62, green: 0.55, blue: 1.00, alpha: 1).cgColor, // violet
    ] as CFArray,
    locations: [0, 0.28, 0.5, 0.74, 1]
)!
ctx.drawLinearGradient(spectrum, start: left, end: right, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// ── The two nodes (devices) at the ends of the bridge ──
func node(_ p: CGPoint, _ color: NSColor) {
    let r: CGFloat = 46
    ctx.setFillColor(NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.13, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: p.x - r - 8, y: p.y - r - 8, width: (r + 8) * 2, height: (r + 8) * 2))
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
}
node(left, NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.42, alpha: 1))
node(right, NSColor(calibratedRed: 0.62, green: 0.55, blue: 1.00, alpha: 1))

image.unlockFocus()
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outputPath))
print("icon written to \(outputPath)")
