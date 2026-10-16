import AppKit

// Native vector artwork, rendered at every macOS icon size during the build.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 204, yRadius: 204)
        NSGradient(starting: NSColor(srgbRed: 0.03, green: 0.30, blue: 0.96, alpha: 1), ending: NSColor(srgbRed: 0.12, green: 0.72, blue: 1, alpha: 1))!.draw(in: tile, angle: 70)
        NSColor.white.setFill()
        let heights: [CGFloat] = [140, 270, 430, 560, 340, 210, 110]
        for (index, height) in heights.enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 252 + CGFloat(index) * 78, y: 512 - height / 2, width: 52, height: height), xRadius: 26, yRadius: 26).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
