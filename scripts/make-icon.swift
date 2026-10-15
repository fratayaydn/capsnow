// Draws the CapsNow app icon: a Caps Lock key with its arrow and a lit green indicator, on a dark rounded square.
// Usage: swift scripts/make-icon.swift <project-dir>
// Writes Resources/AppIcon.icns and .build/AppIcon-preview.png.
import AppKit

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [UInt32], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors.map { color($0) } as CFArray, locations: locations)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Drawn on a 1024 canvas, origin bottom-left.
func drawIcon(_ ctx: CGContext) {
    let body = roundedRect(CGRect(x: 100, y: 100, width: 824, height: 824), 185)

    // Background: dark graphite with a green tint, lighter in the middle.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([0x253129, 0x141C17, 0x080C0A], [0, 0.55, 1]),
                           start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    ctx.drawRadialGradient(CGGradient(colorsSpace: sRGB, colors: [color(0x34C759, 0.16), color(0x34C759, 0)] as CFArray,
                                      locations: [0, 1])!,
                           startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 440, options: [])
    ctx.restoreGState()

    // Keycap: a square key with a soft shadow and a slightly lighter top face.
    let cap = CGRect(x: 232, y: 232, width: 560, height: 560)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.55))
    ctx.addPath(roundedRect(cap, 96))
    ctx.setFillColor(color(0x24272C))
    ctx.fillPath()
    ctx.restoreGState()
    let face = cap.insetBy(dx: 40, dy: 40).offsetBy(dx: 0, dy: 14)
    ctx.saveGState()
    ctx.addPath(roundedRect(face, 72))
    ctx.clip()
    ctx.drawLinearGradient(gradient([0x474B53, 0x33363C], [0, 1]),
                           start: CGPoint(x: 0, y: face.maxY), end: CGPoint(x: 0, y: face.minY), options: [])
    ctx.restoreGState()

    // Caps Lock symbol: an outlined arrow pointing up, over a bar.
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 512, y: 668))
    arrow.addLine(to: CGPoint(x: 650, y: 524))
    arrow.addLine(to: CGPoint(x: 578, y: 524))
    arrow.addLine(to: CGPoint(x: 578, y: 428))
    arrow.addLine(to: CGPoint(x: 446, y: 428))
    arrow.addLine(to: CGPoint(x: 446, y: 524))
    arrow.addLine(to: CGPoint(x: 374, y: 524))
    arrow.closeSubpath()
    ctx.addPath(arrow)
    ctx.setStrokeColor(color(0xF2F4F6))
    ctx.setLineWidth(26)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.addPath(roundedRect(CGRect(x: 433, y: 346, width: 158, height: 34), 12))
    ctx.setFillColor(color(0xF2F4F6))
    ctx.fillPath()

    // The indicator: lit, glowing green.
    let led = CGRect(x: 318 - 24, y: 706 - 24, width: 48, height: 48)
    ctx.saveGState()
    for (blur, alpha) in [(70.0, 0.9), (30.0, 1.0)] as [(CGFloat, CGFloat)] {
        ctx.setShadow(offset: .zero, blur: blur, color: color(0x4CF07A, alpha))
        ctx.addEllipse(in: led)
        ctx.setFillColor(color(0x5CF58A))
        ctx.fillPath()
    }
    ctx.restoreGState()
    ctx.addEllipse(in: led.insetBy(dx: 10, dy: 10).offsetBy(dx: -4, dy: 6))
    ctx.setFillColor(color(0xE6FFEC, 0.85))
    ctx.fillPath()
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    drawIcon(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

let build = "\(root)/.build"
let iconset = "\(build)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    writePNG(render(size), "\(iconset)/icon_\(size)x\(size).png")
    writePNG(render(size * 2), "\(iconset)/icon_\(size)x\(size)@2x.png")
}
writePNG(render(1024), "\(build)/AppIcon-preview.png")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "\(root)/Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
