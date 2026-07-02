// Generates the app icon (original artwork: car silhouette + diagnostic
// pulse trace on a rounded-square gradient). Usage:
//   swift make-icon.swift <output-dir>   -> writes AppIcon.icns
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// Background: dark slate rounded square (macOS Big Sur+ squircle-ish inset)
let inset: CGFloat = size * 0.08
let bgRect = CGRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: size*0.18, cornerHeight: size*0.18, transform: nil)
ctx.addPath(bgPath)
ctx.clip()
let colors = [NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.22, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.16, green: 0.24, blue: 0.38, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Car silhouette (simple primitives: body, cabin, wheels)
let car = NSColor(calibratedWhite: 0.92, alpha: 1)
car.setFill()
let bodyY = size * 0.30
let body = CGPath(roundedRect: CGRect(x: size*0.18, y: bodyY, width: size*0.64, height: size*0.13),
                  cornerWidth: size*0.04, cornerHeight: size*0.04, transform: nil)
ctx.addPath(body); ctx.fillPath()
let cabin = CGMutablePath()
cabin.move(to: CGPoint(x: size*0.30, y: bodyY + size*0.12))
cabin.addLine(to: CGPoint(x: size*0.38, y: bodyY + size*0.24))
cabin.addLine(to: CGPoint(x: size*0.62, y: bodyY + size*0.24))
cabin.addLine(to: CGPoint(x: size*0.72, y: bodyY + size*0.12))
cabin.closeSubpath()
ctx.addPath(cabin); ctx.fillPath()
ctx.setBlendMode(.clear)   // punch out wheel wells
for x in [size*0.32, size*0.68] {
    ctx.fillEllipse(in: CGRect(x: x - size*0.075, y: bodyY - size*0.055, width: size*0.15, height: size*0.15))
}
ctx.setBlendMode(.normal)
for x in [size*0.32, size*0.68] {   // wheels
    car.setFill()
    ctx.fillEllipse(in: CGRect(x: x - size*0.055, y: bodyY - size*0.035, width: size*0.11, height: size*0.11))
}

// Diagnostic pulse trace (ECG-style) across the lower third, accent green
let pulse = NSColor(calibratedRed: 0.22, green: 0.85, blue: 0.49, alpha: 1)
pulse.setStroke()
ctx.setLineWidth(size * 0.030)
ctx.setLineJoin(.round); ctx.setLineCap(.round)
let py = size * 0.625
let p = CGMutablePath()
p.move(to: CGPoint(x: size*0.16, y: py))
p.addLine(to: CGPoint(x: size*0.38, y: py))
p.addLine(to: CGPoint(x: size*0.45, y: py + size*0.10))
p.addLine(to: CGPoint(x: size*0.53, y: py - size*0.13))
p.addLine(to: CGPoint(x: size*0.60, y: py + size*0.05))
p.addLine(to: CGPoint(x: size*0.64, y: py))
p.addLine(to: CGPoint(x: size*0.84, y: py))
ctx.addPath(p); ctx.strokePath()

image.unlockFocus()

// Emit iconset and compile to icns
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    let names = px == 1024 ? ["icon_512x512@2x.png"]
              : px == 64   ? ["icon_32x32@2x.png"]
              : ["icon_\(px)x\(px).png", px > 16 ? "icon_\(px/2)x\(px/2)@2x.png" : ""]
    for n in names where !n.isEmpty {
        try! png.write(to: URL(fileURLWithPath: "\(iconset)/\(n)"))
    }
}
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AppIcon.icns"]
task.launch(); task.waitUntilExit()
print("AppIcon.icns written, exit \(task.terminationStatus)")
