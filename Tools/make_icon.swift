// Renders the app icon: four glass panels, each holding a battery that fills from the bottom,
// echoing the slot columns in the app. Usage: swift Tools/make_icon.swift <out-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no bitmap context") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let cg = context.cgContext

// Body: deep blue-violet, lit from the top left.
let margin: CGFloat = 20
let body = NSRect(x: margin, y: margin, width: CGFloat(size) - 2 * margin, height: CGFloat(size) - 2 * margin)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 215, yRadius: 215)
NSGradient(colors: [color(0x3B4FA8), color(0x1B2260), color(0x0C1034)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: bodyPath, angle: -60)

cg.saveGState()
bodyPath.addClip()
// Soft glow in the upper left, like light through glass.
NSGradient(colors: [color(0x7FA6FF, 0.38), color(0x7FA6FF, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(fromCenter: NSPoint(x: 250, y: 860), radius: 0, toCenter: NSPoint(x: 250, y: 860), radius: 620, options: [])
cg.restoreGState()

// Four slots.
struct Slot { var fill: CGFloat; var done: Bool }
let slots = [Slot(fill: 0.46, done: false), Slot(fill: 0.74, done: false), Slot(fill: 1, done: true), Slot(fill: 0.90, done: false)]
let panelW: CGFloat = 188, panelH: CGFloat = 600, gap: CGFloat = 26
let totalW = panelW * 4 + gap * 3
let originX = (CGFloat(size) - totalW) / 2
let originY = (CGFloat(size) - panelH) / 2 - 6

func symbol(_ name: String, pointSize: CGFloat, in rect: NSRect, alpha: CGFloat = 1) {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))) else { return }
    let s = image.size
    image.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
               from: .zero, operation: .sourceOver, fraction: alpha)
}

for (index, slot) in slots.enumerated() {
    let panel = NSRect(x: originX + CGFloat(index) * (panelW + gap), y: originY, width: panelW, height: panelH)
    let panelPath = NSBezierPath(roundedRect: panel, xRadius: 62, yRadius: 62)

    // Glass panel: translucent white with a brighter top edge and a hairline border.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35).cgColor)
    color(0xFFFFFF, 0.13).setFill()
    panelPath.fill()
    cg.restoreGState()
    NSGradient(colors: [color(0xFFFFFF, 0.20), color(0xFFFFFF, 0.04)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: panelPath, angle: -90)
    color(0xFFFFFF, 0.28).setStroke()
    panelPath.lineWidth = 2.5
    panelPath.stroke()

    // Battery: terminal nub + cell.
    let tint = slot.done ? (top: color(0x7BF0A6), bottom: color(0x2FBF68)) : (top: color(0x66B3FF), bottom: color(0x2E6CEA))
    let cell = NSRect(x: panel.midX - 62, y: panel.minY + 40, width: 124, height: 460)
    let nub = NSRect(x: panel.midX - 26, y: cell.maxY + 8, width: 52, height: 15)
    tint.top.withAlphaComponent(0.65).setFill()
    NSBezierPath(roundedRect: nub, xRadius: 7, yRadius: 7).fill()

    let cellPath = NSBezierPath(roundedRect: cell, xRadius: 40, yRadius: 40)
    color(0xFFFFFF, 0.12).setFill()
    cellPath.fill()

    cg.saveGState()
    cellPath.addClip()
    let fillRect = NSRect(x: cell.minX, y: cell.minY, width: cell.width, height: max(cell.height * slot.fill, 40))
    cg.setShadow(offset: .zero, blur: 40, color: tint.top.withAlphaComponent(0.8).cgColor)
    NSGradient(colors: [tint.top, tint.bottom], atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: fillRect, angle: -90)
    cg.restoreGState()
    color(0xFFFFFF, 0.38).setStroke()
    cellPath.lineWidth = 3
    cellPath.stroke()

    // Glyph in the middle of the cell.
    symbol(slot.done ? "checkmark" : "bolt.fill", pointSize: slot.done ? 78 : 84,
           in: NSRect(x: cell.minX, y: cell.midY - 50, width: cell.width, height: 100))
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: "\(outDir)/icon_1024.png"))
print("wrote \(outDir)/icon_1024.png (\(rep.pixelsWide)x\(rep.pixelsHigh))")
