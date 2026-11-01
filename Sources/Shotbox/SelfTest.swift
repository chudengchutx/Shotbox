import AppKit

/// 非交互自测：不依赖屏幕录制权限，直接验证标注渲染与 PNG 导出链路。
/// 用法：Shotbox --selftest /tmp/out.png
enum SelfTest {
    @MainActor
    static func run(outputPath: String) -> Int32 {
        _ = NSApplication.shared

        guard let base = makeBaseImage() else {
            print("SELFTEST FAIL 无法生成基准图")
            return 1
        }

        // 基准图 600x400 像素，按 2 倍缩放即 300x200 点
        let canvas = CanvasView(image: base, scale: 2)
        canvas.strokeColor = NSColor(srgbRed: 0xFA / 255, green: 0x3C / 255, blue: 0x63 / 255, alpha: 1)
        canvas.lineWidth = 4
        canvas.fontSize = 22

        canvas.annotations = [
            Annotation(
                tool: .rect,
                start: CGPoint(x: 20, y: 150),
                end: CGPoint(x: 140, y: 190),
                color: canvas.strokeColor,
                lineWidth: 4,
                fontSize: 22
            ),
            Annotation(
                tool: .ellipse,
                start: CGPoint(x: 160, y: 150),
                end: CGPoint(x: 250, y: 190),
                color: .systemBlue,
                lineWidth: 4,
                fontSize: 22
            ),
            Annotation(
                tool: .arrow,
                start: CGPoint(x: 30, y: 60),
                end: CGPoint(x: 140, y: 120),
                color: .systemGreen,
                lineWidth: 4,
                fontSize: 22
            ),
            Annotation(
                tool: .text,
                start: CGPoint(x: 160, y: 120),
                end: CGPoint(x: 290, y: 90),
                text: "Shotbox 标注",
                color: .white,
                lineWidth: 4,
                fontSize: 22
            ),
            Annotation(
                tool: .counter,
                start: CGPoint(x: 20, y: 40),
                end: CGPoint(x: 44, y: 16),
                number: 1,
                color: canvas.strokeColor,
                lineWidth: 4,
                fontSize: 22
            ),
            Annotation(
                tool: .highlight,
                start: CGPoint(x: 160, y: 20),
                end: CGPoint(x: 290, y: 60),
                color: .systemYellow,
                lineWidth: 4,
                fontSize: 22
            ),
            Annotation(
                tool: .spotlight,
                start: CGPoint(x: 210, y: 130),
                end: CGPoint(x: 290, y: 70),
                color: .black,
                lineWidth: 4,
                fontSize: 22
            )
        ]

        guard let rendered = canvas.renderedImage() else {
            print("SELFTEST FAIL 渲染失败")
            return 1
        }

        guard rendered.width == base.width, rendered.height == base.height else {
            print("SELFTEST FAIL 导出尺寸不符 \(rendered.width)x\(rendered.height) != \(base.width)x\(base.height)")
            return 1
        }

        do {
            let data = try ImageExporter.pngData(from: rendered)
            let url = URL(fileURLWithPath: outputPath)
            try data.write(to: url)
            print("SELFTEST OK \(outputPath) \(rendered.width)x\(rendered.height) \(data.count) bytes")
        } catch {
            print("SELFTEST FAIL \(error.localizedDescription)")
            return 1
        }

        // 顺便验证取色能读到基准图像素
        if let color = canvas.colorAtViewPoint(CGPoint(x: 10, y: 100)) {
            print("SELFTEST COLOR \(color.hexString)")
        } else {
            print("SELFTEST FAIL 取色失败")
            return 1
        }

        return 0
    }

    static func makeBaseImage() -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: 600,
            height: 400,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))

        for index in 0..<6 {
            let color = NSColor(hue: CGFloat(index) / 6, saturation: 0.5, brightness: 0.9, alpha: 1)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: CGFloat(index) * 100, y: 0, width: 100, height: 40))
        }

        let text = NSAttributedString(
            string: "1920 × 1080  capture fixture",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor(white: 0.85, alpha: 1)
            ]
        )
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(at: CGPoint(x: 20, y: 340))
        NSGraphicsContext.current = previous

        return ctx.makeImage()
    }
}
