// Renders the MacDroid app icon: white laptop+iphone symbol on an indigo
// gradient rounded square. Usage: swift make-icon.swift /path/out.png
import AppKit

let outputPath = CommandLine.arguments[1]
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.42, green: 0.36, blue: 0.95, alpha: 1),
    ending: NSColor(calibratedRed: 0.17, green: 0.11, blue: 0.52, alpha: 1)
)!
gradient.draw(in: path, angle: -90)

if let symbol = NSImage(systemSymbolName: "laptopcomputer.and.iphone", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .medium)
    if let sized = symbol.withSymbolConfiguration(config) {
        let tinted = NSImage(size: sized.size, flipped: false) { drawRect in
            sized.draw(in: drawRect)
            NSColor.white.set()
            drawRect.fill(using: .sourceAtop)
            return true
        }
        let aspect = sized.size.height / sized.size.width
        let width: CGFloat = 560
        let height = width * aspect
        tinted.draw(in: NSRect(
            x: (size - width) / 2, y: (size - height) / 2,
            width: width, height: height
        ))
    }
}

image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outputPath))
print("icon written to \(outputPath)")
