import AppKit
import ScreenCaptureKit

/// 一张显示器的原始截图。image 为像素尺寸，frame 为该屏在全局坐标中的点尺寸。
struct ScreenShot {
    let image: CGImage
    let scale: CGFloat
    let frame: CGRect
    let displayID: CGDirectDisplayID

    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    /// 以视图坐标（左下原点、点单位）裁切出像素图。
    func crop(viewRect: CGRect) -> CGImage? {
        let clipped = viewRect.intersection(CGRect(origin: .zero, size: pointSize))
        guard clipped.width > 1, clipped.height > 1 else { return nil }
        let pixelRect = CGRect(
            x: clipped.origin.x * scale,
            y: (pointSize.height - clipped.maxY) * scale,
            width: clipped.width * scale,
            height: clipped.height * scale
        ).integral
        return image.cropping(to: pixelRect)
    }
}

enum Capturer {
    static func captureAllScreens() async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [ScreenShot] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // SCDisplay 的宽高可能是点尺寸，按屏幕缩放因子显式取像素，避免 Retina 下只剩 1x
            let pixelWidth = Int((screen.frame.width * screen.backingScaleFactor).rounded())
            let pixelHeight = Int((screen.frame.height * screen.backingScaleFactor).rounded())
            config.width = max(pixelWidth, display.width)
            config.height = max(pixelHeight, display.height)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.captureResolution = .best
            config.scalesToFit = false

            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let scale = CGFloat(image.width) / max(screen.frame.width, 1)
                shots.append(ScreenShot(image: image, scale: scale, frame: screen.frame, displayID: displayID))
            } catch {
                NSLog("Shotbox: 抓屏失败 \(displayID) \(error.localizedDescription)")
            }
        }
        return shots
    }
}

/// 复用同一 filter 连续抓取固定区域的多帧，供滚动长截图使用。
final class RegionCapturer {
    private let filter: SCContentFilter
    private let sourceRect: CGRect
    private let pixelWidth: Int
    private let pixelHeight: Int

    init(shot: ScreenShot, rect: CGRect) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == shot.displayID }) else {
            throw NSError(domain: "Shotbox", code: 10, userInfo: [NSLocalizedDescriptionKey: "找不到对应显示器"])
        }
        self.filter = SCContentFilter(display: display, excludingWindows: [])
        // sourceRect 相对显示器左上角，入参 rect 相对屏幕左下角
        self.sourceRect = CGRect(
            x: rect.minX,
            y: shot.frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        self.pixelWidth = max(Int((rect.width * shot.scale).rounded()), 1)
        self.pixelHeight = max(Int((rect.height * shot.scale).rounded()), 1)
    }

    func capture() async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = pixelWidth
        config.height = pixelHeight
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// 选区阶段：每个显示器一个覆盖窗口，抓图作为背景，拖动框选。
@MainActor
final class SelectionController {
    private var shots: [ScreenShot] = []
    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var monitor: Any?
    private var finished = false

    var onSelection: ((ScreenShot, CGRect) -> Void)?
    var onCancel: (() -> Void)?

    init(shots: [ScreenShot]) {
        self.shots = shots
    }

    func begin() {
        NSApp.activate(ignoringOtherApps: true)
        for shot in shots {
            let view = OverlayView(shot: shot)
            view.onConfirm = { [weak self] rect in
                self?.finish(shot: shot, rect: rect)
            }
            view.onCancel = { [weak self] in
                self?.cancel()
            }
            let window = OverlayWindow(shot: shot)
            window.contentView = view
            window.setFrame(shot.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }
        if let first = windows.first {
            first.makeKey()
            first.makeFirstResponder(views.first)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                self.cancel()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 { // Return / Enter / Space
                if let active = self.views.first(where: { $0.hasSelection }) {
                    active.confirm()
                    return nil
                }
            }
            return event
        }
        NSCursor.crosshair.set()
    }

    private func finish(shot: ScreenShot, rect: CGRect) {
        guard !finished else { return }
        finished = true
        cleanup()
        onSelection?(shot, rect)
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        cleanup()
        onCancel?()
    }

    private func cleanup() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
    }
}

final class OverlayWindow: NSWindow {
    init(shot: ScreenShot) {
        super.init(
            contentRect: shot.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayView: NSView {
    private let shot: ScreenShot
    private var selection: CGRect?
    private var dragOrigin: CGPoint?

    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    var hasSelection: Bool {
        guard let selection else { return false }
        return selection.width > 2 && selection.height > 2
    }

    init(shot: ScreenShot) {
        self.shot = shot
        super.init(frame: CGRect(origin: .zero, size: shot.pointSize))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func confirm() {
        guard let selection, selection.width > 2, selection.height > 2 else { return }
        onConfirm?(selection)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(shot.image, in: bounds)

        let shade = CGMutablePath()
        shade.addRect(bounds)
        if let selection { shade.addRect(selection) }
        ctx.addPath(shade)
        ctx.setFillColor(NSColor.black.withAlphaComponent(hasSelection ? 0.42 : 0.26).cgColor)
        ctx.fillPath(using: .evenOdd)

        guard let selection, hasSelection else { return }

        ctx.setStrokeColor(NSColor(srgbRed: 0.39, green: 0.63, blue: 1.0, alpha: 1).cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(selection)

        let handle: CGFloat = 8
        ctx.setFillColor(NSColor.white.cgColor)
        for point in [
            CGPoint(x: selection.minX, y: selection.minY),
            CGPoint(x: selection.maxX, y: selection.minY),
            CGPoint(x: selection.minX, y: selection.maxY),
            CGPoint(x: selection.maxX, y: selection.maxY)
        ] {
            ctx.fill(CGRect(x: point.x - handle / 2, y: point.y - handle / 2, width: handle, height: handle))
        }

        let pixels = "\(Int(selection.width * shot.scale)) × \(Int(selection.height * shot.scale))"
        drawLabel(pixels + "    Enter 确认 · Esc 取消", below: selection)
    }

    private func drawLabel(_ text: String, below rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var origin = CGPoint(x: rect.minX, y: rect.minY - size.height - 10)
        if origin.y < 8 { origin.y = rect.maxY + 10 }
        let box = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        string.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, hasSelection {
            confirm()
            return
        }
        window?.makeFirstResponder(self)
        dragOrigin = point
        selection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(origin.x, point.x),
            y: min(origin.y, point.y),
            width: abs(point.x - origin.x),
            height: abs(point.y - origin.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if !hasSelection {
            onCancel?()
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76, 49: confirm()
        default: super.keyDown(with: event)
        }
    }
}
