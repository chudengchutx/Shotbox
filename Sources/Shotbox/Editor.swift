import AppKit

@MainActor
final class CanvasView: NSView {
    let baseImage: CGImage
    let imageScale: CGFloat

    var annotations: [Annotation] = []
    var tool: Tool = .rect
    var strokeColor: NSColor = NSColor(srgbRed: 0xFA / 255, green: 0x3C / 255, blue: 0x63 / 255, alpha: 1)
    var lineWidth: CGFloat = 3
    var fontSize: CGFloat = 20

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var current: Annotation?
    private var dragOrigin: CGPoint?
    private var movingIndex: Int?
    private var moveAnchor: CGPoint?
    private var selectedIndex: Int?
    private(set) var counterValue = 1
    private lazy var pixelated: CGImage? = Renderer.makePixelated(baseImage)

    var onChange: (() -> Void)?

    init(image: CGImage, scale: CGFloat) {
        self.baseImage = image
        self.imageScale = scale
        let pointSize = CGSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        super.init(frame: CGRect(origin: .zero, size: pointSize))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: 历史

    func pushHistory() {
        undoStack.append(annotations)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
        onChange?()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = last
        selectedIndex = nil
        needsDisplay = true
        onChange?()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selectedIndex = nil
        needsDisplay = true
        onChange?()
    }

    func deleteSelected() {
        guard let index = selectedIndex, annotations.indices.contains(index) else { return }
        pushHistory()
        annotations.remove(at: index)
        selectedIndex = nil
        needsDisplay = true
    }

    // MARK: 导出

    func renderedImage() -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let sx = CGFloat(width) / max(bounds.width, 1)
        let sy = CGFloat(height) / max(bounds.height, 1)
        ctx.scaleBy(x: sx, y: sy)
        Renderer.draw(annotations, in: ctx, canvasSize: bounds.size, pixelated: pixelated)
        return ctx.makeImage()
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(baseImage, in: bounds)
        Renderer.draw(annotations, in: ctx, canvasSize: bounds.size, pixelated: pixelated)
        if let current {
            Renderer.draw(current, in: ctx, canvasSize: bounds.size, pixelated: pixelated)
        }
        if let index = selectedIndex, annotations.indices.contains(index) {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(annotations[index].bounds.insetBy(dx: -4, dy: -4))
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }

    // MARK: 交互

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if tool == .pointer {
            if let index = annotations.lastIndex(where: { $0.hitTest(point) }) {
                selectedIndex = index
                movingIndex = index
                moveAnchor = point
            } else {
                selectedIndex = nil
                movingIndex = nil
            }
            needsDisplay = true
            return
        }

        if tool == .text {
            promptText(at: point)
            return
        }

        selectedIndex = nil
        dragOrigin = point
        var annotation = Annotation(
            tool: tool,
            start: point,
            end: point,
            color: strokeColor,
            lineWidth: lineWidth,
            fontSize: fontSize
        )
        if tool == .counter {
            annotation.number = counterValue
        }
        if tool == .pen {
            annotation.points = [point]
        }
        current = annotation
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if tool == .pointer {
            if let index = movingIndex, annotations.indices.contains(index), let anchor = moveAnchor {
                let delta = CGSize(width: point.x - anchor.x, height: point.y - anchor.y)
                annotations[index].translate(by: delta)
                moveAnchor = point
                needsDisplay = true
            }
            return
        }

        guard var annotation = current else { return }
        if tool == .pen {
            annotation.points.append(point)
        }
        annotation.end = point
        current = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if tool == .pointer {
            if movingIndex != nil {
                pushHistory()
            }
            movingIndex = nil
            moveAnchor = nil
            return
        }

        guard let annotation = current else { return }
        current = nil
        dragOrigin = nil
        guard !annotation.isEmpty else {
            needsDisplay = true
            return
        }
        pushHistory()
        annotations.append(annotation)
        if annotation.tool == .counter { counterValue += 1 }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            deleteSelected()
        default:
            super.keyDown(with: event)
        }
    }

    private func promptText(at point: CGPoint) {
        let alert = NSAlert()
        alert.messageText = "添加文字"
        alert.informativeText = "输入要标注的文字内容。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.font = NSFont.systemFont(ofSize: 14)
        alert.accessoryView = field
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pushHistory()
        var annotation = Annotation(
            tool: .text,
            start: point,
            end: point,
            text: text,
            color: strokeColor,
            lineWidth: lineWidth,
            fontSize: fontSize
        )
        annotation.end = CGPoint(x: point.x + 120, y: point.y - fontSize)
        annotations.append(annotation)
        needsDisplay = true
    }

    // MARK: 取色

    func colorAtViewPoint(_ point: CGPoint) -> NSColor? {
        let px = Int(point.x * imageScale)
        let py = Int((bounds.height - point.y) * imageScale)
        guard px >= 0, py >= 0, px < baseImage.width, py < baseImage.height else { return nil }
        guard let cropped = baseImage.cropping(to: CGRect(x: px, y: py, width: 1, height: 1)) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(
            srgbRed: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }
}

@MainActor
final class EditorWindowController: NSWindowController {
    private let canvas: CanvasView
    private var toolButtons: [NSButton] = []
    private var monitor: Any?
    private var colorWell: NSColorWell?
    private var widthSlider: NSSlider?
    private var toolbarStack: NSStackView?
    private var toolbarScroll: NSScrollView?

    var onClose: (() -> Void)?

    init(image: CGImage, scale: CGFloat) {
        let canvas = CanvasView(image: image, scale: scale)
        self.canvas = canvas

        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let pointSize = canvas.bounds.size
        let toolbarHeight: CGFloat = 46
        let width = min(max(pointSize.width + 2, 480), visible.width * 0.86)
        let height = min(pointSize.height + toolbarHeight + 28, visible.height * 0.86)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shotbox 编辑器"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        buildUI()
        window.delegate = self
        installKeyMonitor()
        onClose = nil
        // 首次布局完成后按实际可用宽度重算工具栏
        DispatchQueue.main.async { [weak self] in self?.layoutToolbar() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = NSColor(white: 0.13, alpha: 1)
        scroll.drawsBackground = true
        scroll.documentView = canvas

        let toolbar = NSStackView()
        toolbar.translatesAutoresizingMaskIntoConstraints = true
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        toolbarStack = toolbar

        for tool in Tool.allCases {
            let button = NSButton()
            button.bezelStyle = .texturedRounded
            button.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.help)
            button.toolTip = tool.help
            button.tag = tool.rawValue
            button.target = self
            button.action = #selector(selectTool(_:))
            button.setButtonType(.pushOnPushOff)
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            toolButtons.append(button)
            toolbar.addArrangedSubview(button)
        }
        toolButtons.first?.state = .on

        toolbar.addArrangedSubview(makeSeparator())
        toolbar.addArrangedSubview(makeLabel("颜色"))

        let well = NSColorWell(frame: .zero)
        well.color = canvas.strokeColor
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.widthAnchor.constraint(equalToConstant: 40).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        colorWell = well
        toolbar.addArrangedSubview(well)

        toolbar.addArrangedSubview(makeLabel("粗细"))
        let slider = NSSlider(value: 3, minValue: 1, maxValue: 16, target: self, action: #selector(widthChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        slider.controlSize = .small
        widthSlider = slider
        toolbar.addArrangedSubview(slider)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)

        for (title, symbol, action) in [
            ("撤销", "arrow.uturn.backward", #selector(doUndo)),
            ("重做", "arrow.uturn.forward", #selector(doRedo)),
            ("取色", "eyedropper", #selector(pickColor)),
            ("识别", "text.viewfinder", #selector(doOCR)),
            ("贴图", "pin", #selector(doPin)),
            ("保存", "square.and.arrow.down", #selector(doSave)),
            ("复制", "doc.on.doc", #selector(copyAndClose))
        ] as [(String, String, Selector)] {
            let button = NSButton()
            button.bezelStyle = .texturedRounded
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.title = ""
            button.toolTip = title
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            toolbar.addArrangedSubview(button)
        }

        content.addSubview(scroll)

        // 工具栏放在横向可滚动容器里，按钮总宽度不会再撑大窗口
        let toolbarScroll = NSScrollView()
        toolbarScroll.translatesAutoresizingMaskIntoConstraints = false
        toolbarScroll.hasHorizontalScroller = true
        toolbarScroll.hasVerticalScroller = false
        toolbarScroll.autohidesScrollers = true
        toolbarScroll.scrollerStyle = .overlay
        toolbarScroll.borderType = .noBorder
        toolbarScroll.drawsBackground = true
        toolbarScroll.backgroundColor = NSColor.windowBackgroundColor
        toolbarScroll.documentView = toolbar
        self.toolbarScroll = toolbarScroll
        content.addSubview(toolbarScroll)

        NSLayoutConstraint.activate([
            toolbarScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbarScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbarScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            toolbarScroll.heightAnchor.constraint(equalToConstant: 46),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: toolbarScroll.topAnchor)
        ])

        layoutToolbar()
    }

    /// 按内容固有宽度布局工具栏，超出部分由横向滚动承担。
    private func layoutToolbar() {
        guard let toolbarStack, let toolbarScroll else { return }
        let height = max(toolbarScroll.contentSize.height, 46)
        let fitting = toolbarStack.fittingSize.width
        let width = max(fitting, toolbarScroll.contentSize.width)
        toolbarStack.frame = CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow else { return event }
            let command = event.modifierFlags.contains(.command)
            if command, let key = event.charactersIgnoringModifiers?.lowercased() {
                switch key {
                case "c": self.copyAndClose(); return nil
                case "s": self.doSave(); return nil
                case "p": self.doPin(); return nil
                case "e": self.doOCR(); return nil
                case "z":
                    if event.modifierFlags.contains(.shift) { self.canvas.redo() } else { self.canvas.undo() }
                    return nil
                default: break
                }
            }
            switch event.keyCode {
            case 36, 76: self.copyAndClose(); return nil
            case 53: self.closeEditor(); return nil
            case 51, 117: self.canvas.deleteSelected(); return nil
            default: return event
            }
        }
    }

    // MARK: 动作

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = Tool(rawValue: sender.tag) else { return }
        canvas.tool = tool
        for button in toolButtons {
            button.state = button == sender ? .on : .off
        }
        window?.makeFirstResponder(canvas)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.strokeColor = sender.color
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        canvas.lineWidth = CGFloat(sender.doubleValue)
    }

    @objc private func doUndo() { canvas.undo() }
    @objc private func doRedo() { canvas.redo() }

    @objc private func pickColor() {
        let point = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        guard let color = canvas.colorAtViewPoint(point) else { return }
        let hex = color.hexString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        colorWell?.color = color
        canvas.strokeColor = color
        window?.title = "已复制颜色 \(hex)"
    }

    @objc private func doOCR() {
        guard let image = canvas.renderedImage() else { return }
        window?.title = "识别中…"
        Task { @MainActor in
            let text = await TextRecognizer.recognize(image: image)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.window?.title = text.isEmpty ? "未识别到文字" : "已复制 \(text.count) 个字符"
        }
    }

    @objc private func doPin() {
        guard let image = canvas.renderedImage() else { return }
        PinWindow.show(image: image, scale: canvas.imageScale)
    }

    @objc private func doSave() {
        guard let image = canvas.renderedImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Screenshot \(Self.timestamp()).png"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ImageExporter.pngData(from: image).write(to: url)
            window?.title = "已保存 \(url.lastPathComponent)"
        } catch {
            presentError("保存失败", error.localizedDescription)
        }
    }

    @objc func copyAndClose() {
        guard let image = canvas.renderedImage() else { return }
        ImageExporter.copyToPasteboard(image: image)
        closeEditor()
    }

    func closeEditor() {
        window?.close()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }

    private func presentError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

extension EditorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        onClose?()
    }

    func windowDidResize(_ notification: Notification) {
        layoutToolbar()
    }
}

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
