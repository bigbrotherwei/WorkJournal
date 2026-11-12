import AppKit

// Editable vector master. Render each native size independently for crisp Dock/Finder icons.
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
for (name, size) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 210, yRadius: 210)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x4D386C, alpha: 0.18).cgColor)
    color(0x9D84CA).setFill(); tile.fill()
    ctx.restoreGState()
    NSGradient(starting: color(0x7960AC), ending: color(0xC2ADE9))!.draw(in: tile, angle: 65)
    ctx.saveGState(); tile.addClip()
    color(0xFFFFFF, alpha: 0.09).setFill()
    NSBezierPath(ovalIn: NSRect(x: 340, y: 650, width: 780, height: 500)).fill()
    ctx.restoreGState()
    color(0xFFFFFF, alpha: 0.3).setStroke(); tile.lineWidth = 2; tile.stroke()

    // Layered paper, generous rounded corners, and three readable lines.
    rounded(NSRect(x: 260, y: 193, width: 500, height: 628), radius: 78, fill: color(0xD9D6F3))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -9), blur: 20, color: color(0x4C396D, alpha: 0.13).cgColor)
    rounded(NSRect(x: 226, y: 223, width: 500, height: 628), radius: 78, fill: color(0xFFFDFC))
    ctx.restoreGState()
    rounded(NSRect(x: 300, y: 710, width: 130, height: 35), radius: 17.5, fill: color(0xAC96D2))
    for (y, width) in [(605, 270), (509, 270), (413, 178)] {
        rounded(NSRect(x: 300, y: y, width: width, height: 26), radius: 13, fill: color(0xD9CFEA))
    }

    // Warm, rounded pencil gives the mark a friendly focal point.
    ctx.saveGState(); ctx.translateBy(x: 605, y: 292); ctx.rotate(by: -.pi / 4)
    ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 12, color: color(0x493461, alpha: 0.2).cgColor)
    rounded(NSRect(x: -47, y: 0, width: 94, height: 364), radius: 28, fill: color(0xEBC397))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    rounded(NSRect(x: -47, y: 315, width: 94, height: 81), radius: 28, fill: color(0x7960AC))
    rounded(NSRect(x: -32, y: 50, width: 14, height: 245), radius: 7, fill: color(0xFFF6E6, alpha: 0.7))
    color(0xFFF3DF).setFill()
    let tip = NSBezierPath(); tip.move(to: NSPoint(x: -47, y: 14)); tip.line(to: NSPoint(x: 47, y: 14)); tip.line(to: NSPoint(x: 0, y: -65)); tip.close(); tip.fill()
    color(0x66517F).setFill()
    let graphite = NSBezierPath(); graphite.move(to: NSPoint(x: -18, y: -34)); graphite.line(to: NSPoint(x: 18, y: -34)); graphite.line(to: NSPoint(x: 0, y: -65)); graphite.close(); graphite.fill()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent("icon_\(name).png"))
}
