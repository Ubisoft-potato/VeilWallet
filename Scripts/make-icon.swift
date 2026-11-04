import AppKit
import Foundation
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
        NSColor(calibratedRed: 0.055, green: 0.06, blue: 0.085, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 964, height: 964), xRadius: 208, yRadius: 208).fill()
        let shield = NSBezierPath()
        shield.move(to: NSPoint(x: 512, y: 820))
        shield.line(to: NSPoint(x: 760, y: 730))
        shield.line(to: NSPoint(x: 746, y: 480))
        shield.curve(to: NSPoint(x: 512, y: 215), controlPoint1: NSPoint(x: 730, y: 350), controlPoint2: NSPoint(x: 605, y: 255))
        shield.curve(to: NSPoint(x: 278, y: 480), controlPoint1: NSPoint(x: 419, y: 255), controlPoint2: NSPoint(x: 294, y: 350))
        shield.line(to: NSPoint(x: 264, y: 730)); shield.close()
        NSColor(calibratedRed: 0.72, green: 0.67, blue: 1, alpha: 1).setStroke()
        shield.lineWidth = 32; shield.stroke()
        ctx.saveGState(); shield.addClip()
        NSColor(calibratedRed: 0.72, green: 0.67, blue: 1, alpha: 1).setFill()
        NSRect(x: 512, y: 150, width: 350, height: 750).fill()
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
