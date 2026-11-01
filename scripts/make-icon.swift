import AppKit

// 生成 Shotbox 的 AppIcon.icns：深色圆角底 + 取景框 + 红色标注点
let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))

image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// 背景：深灰圆角矩形，带一点纵向渐变
let inset: CGFloat = canvas * 0.09
let rect = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let radius: CGFloat = canvas * 0.22
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1).cgColor,
        NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1).cgColor
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: canvas),
    end: CGPoint(x: 0, y: 0),
    options: []
)
ctx.restoreGState()

// 取景框四个角
let frameInset: CGFloat = canvas * 0.26
let frameRect = CGRect(
    x: frameInset,
    y: frameInset,
    width: canvas - frameInset * 2,
    height: canvas - frameInset * 2
)
let armLength: CGFloat = canvas * 0.15
ctx.setStrokeColor(NSColor(white: 0.97, alpha: 1).cgColor)
ctx.setLineWidth(canvas * 0.035)
ctx.setLineCap(.round)

let corners: [(CGPoint, CGFloat, CGFloat)] = [
    (CGPoint(x: frameRect.minX, y: frameRect.minY), 1, 1),
    (CGPoint(x: frameRect.maxX, y: frameRect.minY), -1, 1),
    (CGPoint(x: frameRect.minX, y: frameRect.maxY), 1, -1),
    (CGPoint(x: frameRect.maxX, y: frameRect.maxY), -1, -1)
]
for (origin, dx, dy) in corners {
    ctx.move(to: origin)
    ctx.addLine(to: CGPoint(x: origin.x + armLength * dx, y: origin.y))
    ctx.move(to: origin)
    ctx.addLine(to: CGPoint(x: origin.x, y: origin.y + armLength * dy))
}
ctx.strokePath()

// 中间一道红色标注箭头，点出"标注"这个卖点
let arrowStart = CGPoint(x: canvas * 0.36, y: canvas * 0.38)
let arrowEnd = CGPoint(x: canvas * 0.65, y: canvas * 0.62)
ctx.setStrokeColor(NSColor(srgbRed: 0.98, green: 0.24, blue: 0.39, alpha: 1).cgColor)
ctx.setLineWidth(canvas * 0.045)
ctx.move(to: arrowStart)
ctx.addLine(to: arrowEnd)
ctx.strokePath()

let dx = arrowEnd.x - arrowStart.x
let dy = arrowEnd.y - arrowStart.y
let length = max(hypot(dx, dy), 0.001)
let ux = dx / length, uy = dy / length
let headLength: CGFloat = canvas * 0.11
let headWidth: CGFloat = canvas * 0.085
let base = CGPoint(x: arrowEnd.x - ux * headLength, y: arrowEnd.y - uy * headLength)
ctx.setFillColor(NSColor(srgbRed: 0.98, green: 0.24, blue: 0.39, alpha: 1).cgColor)
let head = CGMutablePath()
head.move(to: arrowEnd)
head.addLine(to: CGPoint(x: base.x - uy * headWidth / 2, y: base.y + ux * headWidth / 2))
head.addLine(to: CGPoint(x: base.x + uy * headWidth / 2, y: base.y - ux * headWidth / 2))
head.closeSubpath()
ctx.addPath(head)
ctx.fillPath()

image.unlockFocus()

// 输出 iconset
let iconsetURL = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { exit(1) }

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        guard let scaled = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()

        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        if let data = scaled.representation(using: .png, properties: [:]) {
            try? data.write(to: iconsetURL.appendingPathComponent(name))
        }
    }
}

print("iconset 已生成: \(iconsetURL.path)")
