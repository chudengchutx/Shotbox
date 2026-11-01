import AppKit
import Vision

// MARK: - 导出

enum ImageExporter {
    static func pngData(from image: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Shotbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败"])
        }
        return data
    }

    static func copyToPasteboard(image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }
}

// MARK: - OCR

enum TextRecognizer {
    static func recognize(image: CGImage, languages: [String] = ["zh-Hans", "en-US"]) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = true
            if #available(macOS 13.0, *) {
                request.revision = VNRecognizeTextRequestRevision3
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}

// MARK: - 屏幕录制权限

enum ScreenPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func request() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 贴图窗口

final class PinContentView: NSView {
    let image: CGImage

    init(image: CGImage, frame: CGRect) {
        self.image = image
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)
    }
}

@MainActor
final class PinWindow: NSWindow {
    private static var open: [PinWindow] = []

    static func show(image: CGImage, scale: CGFloat) {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let natural = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let maxSize = CGSize(width: visible.width * 0.7, height: visible.height * 0.7)
        let ratio = min(1, min(maxSize.width / natural.width, maxSize.height / natural.height))
        let size = CGSize(width: natural.width * ratio, height: natural.height * ratio)

        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        let window = PinWindow(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.02)
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = PinContentView(image: image, frame: CGRect(origin: .zero, size: size))
        window.orderFrontRegardless()
        open.append(window)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.keyCode == 13 {
            close()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            close()
            return
        }
        super.mouseDown(with: event)
    }

    override func close() {
        PinWindow.open.removeAll { $0 === self }
        super.close()
    }
}
