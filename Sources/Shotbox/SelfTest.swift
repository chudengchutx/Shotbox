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

        if !verifyStitching() {
            return 1
        }

        return 0
    }

    /// 用合成页面模拟逐帧滚动，验证拼接结果与原页面逐像素一致。
    @MainActor
    private static func verifyStitching() -> Bool {
        let pageWidth = 800
        let pageHeight = 3000
        let viewport = 800
        let step = 240

        guard let page = makeScrollPage(width: pageWidth, height: pageHeight) else {
            print("SELFTEST STITCH FAIL 无法生成页面")
            return false
        }

        let stitcher = ScrollStitcher(maxHeight: 20000)
        guard let first = page.cropping(to: CGRect(x: 0, y: 0, width: pageWidth, height: viewport)) else {
            print("SELFTEST STITCH FAIL 裁切首帧失败")
            return false
        }
        stitcher.seed(first)

        var offset = 0
        var frames = 1
        while offset + viewport < pageHeight {
            offset = min(offset + step, pageHeight - viewport)
            guard let frame = page.cropping(to: CGRect(x: 0, y: offset, width: pageWidth, height: viewport)) else { break }
            _ = stitcher.append(frame)
            frames += 1
            if stitcher.isFull { break }
        }

        guard stitcher.height == pageHeight else {
            print("SELFTEST STITCH FAIL 高度 \(stitcher.height) != \(pageHeight)（\(frames) 帧）")
            return false
        }

        guard let expected = ScrollStitcher.topDownRGBA(page),
              let stitched = stitcher.makeImage(),
              let actual = ScrollStitcher.topDownRGBA(stitched) else {
            print("SELFTEST STITCH FAIL 无法读取像素")
            return false
        }

        let stride = pageWidth * 4
        for row in Swift.stride(from: 0, to: pageHeight, by: 97) {
            let start = row * stride
            let end = start + stride
            if expected.data[start..<end] != actual.data[start..<end] {
                print("SELFTEST STITCH FAIL 第 \(row) 行内容不一致")
                return false
            }
        }

        print("SELFTEST STITCH OK \(frames) 帧 -> \(pageWidth)x\(stitcher.height)")
        return true
    }

    /// 生成一张每行颜色都不同的“网页”，用于拼接验证。
    @MainActor
    private static func makeScrollPage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for row in 0..<height {
            // 把行号编码进像素，保证每一行都唯一，便于验证拼接是否错位
            let red = CGFloat(row & 0xFF) / 255
            let green = CGFloat((row >> 8) & 0xFF) / 255
            let color = NSColor(srgbRed: red, green: green, blue: 0.35, alpha: 1)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: CGFloat(height - row - 1), width: CGFloat(width), height: 1))
        }

        for offset in Swift.stride(from: 0, to: height, by: 200) {
            let text = NSAttributedString(
                string: "offset \(offset)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .bold),
                    .foregroundColor: NSColor.white
                ]
            )
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text.draw(at: CGPoint(x: 40, y: CGFloat(height - offset - 40)))
            NSGraphicsContext.current = previous
        }

        return ctx.makeImage()
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
