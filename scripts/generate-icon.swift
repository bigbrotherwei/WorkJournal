import AppKit

// Vector master rendered at every native icon size; no external assets required.
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for (name, size) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
    NSGradient(starting: NSColor(red: 0.08, green: 0.31, blue: 0.29, alpha: 1), ending: NSColor(red: 0.29, green: 0.64, blue: 0.53, alpha: 1))!.draw(in: tile, angle: 55)
    ctx.saveGState(); tile.addClip()
    NSColor.white.withAlphaComponent(0.12).setFill()
    NSBezierPath(ovalIn: NSRect(x: 560, y: 600, width: 470, height: 470)).fill()
    ctx.restoreGState()
    NSColor(calibratedWhite: 1, alpha: 0.96).setFill()
    NSBezierPath(roundedRect: NSRect(x: 242, y: 216, width: 484, height: 600), xRadius: 64, yRadius: 64).fill()
    NSColor(red: 0.72, green: 0.85, blue: 0.79, alpha: 1).setFill()
    for (y,w) in [(650,260),(548,260),(446,168)] {
        NSBezierPath(roundedRect: NSRect(x: 316, y: y, width: w, height: 24), xRadius: 12, yRadius: 12).fill()
    }
    ctx.saveGState(); ctx.translateBy(x: 580, y: 270); ctx.rotate(by: -.pi/4)
    NSColor(red: 0.94, green: 0.71, blue: 0.35, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: -42, y: 0, width: 84, height: 390), xRadius: 22, yRadius: 22).fill()
    NSColor(red: 0.15, green: 0.36, blue: 0.31, alpha: 1).setFill()
    let tip = NSBezierPath();tip.move(to: NSPoint(x: -42,y: 0));tip.line(to: NSPoint(x: 42,y: 0));tip.line(to: NSPoint(x: 0,y: -70));tip.close();tip.fill()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent("icon_\(name).png"))
}
