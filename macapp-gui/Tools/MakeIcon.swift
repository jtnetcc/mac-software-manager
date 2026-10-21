import AppKit

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else {
    FileHandle.standardError.write("无法创建位图\n".data(using: .utf8)!)
    exit(1)
}

rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 46
let rect = NSRect(
    x: inset, y: inset,
    width: CGFloat(size) - inset * 2,
    height: CGFloat(size) - inset * 2
)
let path = NSBezierPath(roundedRect: rect, xRadius: 212, yRadius: 212)
NSColor(srgbRed: 0.16, green: 0.43, blue: 0.92, alpha: 1).setFill()
path.fill()

let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let target = NSRect(
        x: (CGFloat(size) - s.width) / 2,
        y: (CGFloat(size) - s.height) / 2,
        width: s.width, height: s.height
    )
    symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    exit(1)
}
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try data.write(to: URL(fileURLWithPath: output))
print("icon written: \(output)")
