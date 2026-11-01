import AppKit

enum Tool: Int, CaseIterable {
    case pointer
    case rect
    case ellipse
    case arrow
    case line
    case pen
    case text
    case counter
    case highlight
    case blur
    case spotlight

    var symbol: String {
        switch self {
        case .pointer: return "cursorarrow"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .pen: return "scribble"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .highlight: return "highlighter"
        case .blur: return "squareshape.split.3x3"
        case .spotlight: return "flashlight.off.fill"
        }
    }

    var help: String {
        switch self {
        case .pointer: return "选择与移动"
        case .rect: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .line: return "直线"
        case .pen: return "自由笔"
        case .text: return "文字"
        case .counter: return "序号"
        case .highlight: return "高亮"
        case .blur: return "马赛克"
        case .spotlight: return "聚光"
        }
    }
}

/// 值类型标注对象，撤销栈直接做数组快照。
struct Annotation {
    var tool: Tool
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text: String = ""
    var number: Int = 0
    var color: NSColor
    var lineWidth: CGFloat
    var fontSize: CGFloat

    var bounds: CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    var isEmpty: Bool {
        if tool == .pen { return points.count < 2 }
        if tool == .text { return text.isEmpty }
        return bounds.width < 2 && bounds.height < 2
    }

    /// 命中测试，用于选择工具。
    func hitTest(_ point: CGPoint) -> Bool {
        let tolerance: CGFloat = 6
        switch tool {
        case .pen:
            for index in 1..<max(points.count, 1) {
                if distance(from: points[index - 1], to: points[index]) <= lineWidth + tolerance,
                   distanceToSegment(point, points[index - 1], points[index]) <= lineWidth + tolerance {
                    return true
                }
            }
            return false
        case .text:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .line, .arrow:
            return distanceToSegment(point, start, end) <= lineWidth + tolerance
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    mutating func translate(by delta: CGSize) {
        start.x += delta.width
        start.y += delta.height
        end.x += delta.width
        end.y += delta.height
        points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
    }

    private func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared < 0.0001 { return distance(from: p, to: a) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        return distance(from: p, to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

/// 画笔渲染器。屏幕绘制和导出共用同一套代码，坐标系为画布点坐标。
enum Renderer {
    /// 背景类效果（聚光、马赛克）始终画在标注之下，避免后添加的效果把已有标注一起压暗。
    private static let backgroundTools: Set<Tool> = [.spotlight, .blur]

    static func draw(
        _ annotations: [Annotation],
        in ctx: CGContext,
        canvasSize: CGSize,
        pixelated: CGImage?
    ) {
        for annotation in annotations where backgroundTools.contains(annotation.tool) {
            draw(annotation, in: ctx, canvasSize: canvasSize, pixelated: pixelated)
        }
        for annotation in annotations where !backgroundTools.contains(annotation.tool) {
            draw(annotation, in: ctx, canvasSize: canvasSize, pixelated: pixelated)
        }
    }

    static func draw(
        _ annotation: Annotation,
        in ctx: CGContext,
        canvasSize: CGSize,
        pixelated: CGImage?
    ) {
        let color = annotation.color
        let width = annotation.lineWidth

        ctx.saveGState()
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cgColor)

        switch annotation.tool {
        case .pointer:
            break

        case .rect:
            ctx.stroke(annotation.bounds)

        case .ellipse:
            ctx.strokeEllipse(in: annotation.bounds)

        case .line:
            ctx.move(to: annotation.start)
            ctx.addLine(to: annotation.end)
            ctx.strokePath()

        case .arrow:
            drawArrow(ctx, from: annotation.start, to: annotation.end, color: color, width: width)

        case .pen:
            guard annotation.points.count > 1 else { break }
            ctx.move(to: annotation.points[0])
            for point in annotation.points.dropFirst() {
                ctx.addLine(to: point)
            }
            ctx.strokePath()

        case .highlight:
            ctx.setFillColor(color.withAlphaComponent(0.32).cgColor)
            ctx.fill(annotation.bounds)

        case .counter:
            drawCounter(ctx, annotation: annotation)

        case .text:
            drawText(ctx, annotation: annotation)

        case .blur:
            if let pixelated {
                ctx.clip(to: annotation.bounds)
                ctx.draw(pixelated, in: CGRect(origin: .zero, size: canvasSize))
            }

        case .spotlight:
            let path = CGMutablePath()
            path.addRect(CGRect(origin: .zero, size: canvasSize))
            path.addEllipse(in: annotation.bounds)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.58).cgColor)
            ctx.fillPath(using: .evenOdd)
        }

        ctx.restoreGState()
    }

    private static func drawArrow(_ ctx: CGContext, from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length
        let uy = dy / length
        let headLength = min(max(width * 4.5, 13), length * 0.6)
        let headWidth = headLength * 0.72
        let base = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)

        ctx.move(to: from)
        ctx.addLine(to: base)
        ctx.strokePath()

        let head = CGMutablePath()
        head.move(to: to)
        head.addLine(to: CGPoint(x: base.x - uy * headWidth / 2, y: base.y + ux * headWidth / 2))
        head.addLine(to: CGPoint(x: base.x + uy * headWidth / 2, y: base.y - ux * headWidth / 2))
        head.closeSubpath()
        ctx.addPath(head)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    private static func drawCounter(_ ctx: CGContext, annotation: Annotation) {
        let diameter = max(annotation.lineWidth * 7, 24)
        let center = CGPoint(
            x: annotation.start.x + diameter / 2,
            y: annotation.start.y - diameter / 2
        )
        let circle = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        ctx.setFillColor(annotation.color.cgColor)
        ctx.fillEllipse(in: circle)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: diameter * 0.62, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: "\(annotation.number)", attributes: attributes)
        let size = string.size()
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        withGraphicsContext(ctx) { string.draw(at: origin) }
    }

    private static func drawText(_ ctx: CGContext, annotation: Annotation) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: annotation.fontSize, weight: .semibold),
            .foregroundColor: annotation.color
        ]
        let string = NSAttributedString(string: annotation.text, attributes: attributes)
        let size = string.size()
        let origin = CGPoint(x: annotation.start.x, y: annotation.start.y - size.height)
        withGraphicsContext(ctx) { string.draw(at: origin) }
    }

    private static func withGraphicsContext(_ ctx: CGContext, body: () -> Void) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body()
        NSGraphicsContext.current = previous
    }

    /// 生成马赛克底图，供 blur 工具裁剪使用。
    static func makePixelated(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(max(6, input.extent.width / 110), forKey: kCIInputScaleKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }
}
