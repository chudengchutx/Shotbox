import AppKit

/// 滚动长截图的拼接器。
///
/// 每一帧都与已拼接结果的尾部做逐行哈希匹配，找到最大的重叠高度，
/// 只把重叠部分之后的新行追加进去。相比逐像素 SAD，行哈希在 20000 像素的长图上仍然够快。
final class ScrollStitcher {
    struct Frame {
        let data: [UInt8]
        let width: Int
        let height: Int
    }

    private(set) var width = 0
    private(set) var height = 0
    private var buffer: [UInt8] = []
    private let maxHeight: Int

    init(maxHeight: Int = 20000) {
        self.maxHeight = maxHeight
    }

    var isFull: Bool { height >= maxHeight }
    var isEmpty: Bool { height == 0 }

    /// 用第一帧初始化。
    @discardableResult
    func seed(_ image: CGImage) -> Bool {
        guard let frame = Self.topDownRGBA(image) else { return false }
        width = frame.width
        height = frame.height
        buffer = frame.data
        buffer.reserveCapacity(frame.width * frame.height * 4 * 2)
        return true
    }

    /// 追加一帧。返回新增行数；0 表示画面没变化；-1 表示无法匹配，该帧应丢弃。
    ///
    /// 匹配时不是简单取最大重叠：纯白段落、重复背景会让大量候选同时成立，
    /// 取最大会让每帧只追加几行。这里在完整匹配的候选里选纹理最丰富的那个。
    func append(_ image: CGImage) -> Int {
        guard let frame = Self.topDownRGBA(image),
              frame.width == width,
              height > 0,
              frame.height > 1 else { return -1 }

        let frameHeight = frame.height
        let frameHashes = (0..<frameHeight).map { rowHash(frame.data, row: $0) }
        let tailCount = min(frameHeight, height)
        let tailHashes = (0..<tailCount).map { rowHash(buffer, row: height - tailCount + $0) }

        // 前缀去重数量，用来衡量某段内容的纹理度
        var distinctPrefix = [Int](repeating: 0, count: frameHeight + 1)
        var seen = Set<UInt64>()
        seen.reserveCapacity(frameHeight)
        for index in 0..<frameHeight {
            seen.insert(frameHashes[index])
            distinctPrefix[index + 1] = seen.count
        }

        let minimumOverlap = min(12, tailCount)
        var bestCandidate = 0
        var bestScore = 0.0

        for candidate in stride(from: tailCount, through: minimumOverlap, by: -1) {
            let offset = tailCount - candidate
            var isMatch = true
            for index in 0..<candidate where tailHashes[offset + index] != frameHashes[index] {
                isMatch = false
                break
            }
            guard isMatch else { continue }

            let score = Double(distinctPrefix[candidate]) / Double(candidate)
            if score > bestScore {
                bestScore = score
                bestCandidate = candidate
            }
            if score >= 0.95 { break }   // 纹理充分，不可能有更好的匹配
        }

        guard bestCandidate > 0, bestScore >= 0.12 else { return -1 }

        let addedRows = frameHeight - bestCandidate
        guard addedRows > 0 else { return 0 }

        let rowsToAppend = min(addedRows, maxHeight - height)
        guard rowsToAppend > 0 else { return 0 }

        let start = bestCandidate * width * 4
        let end = (bestCandidate + rowsToAppend) * width * 4
        buffer.append(contentsOf: frame.data[start..<end])
        height += rowsToAppend
        return rowsToAppend
    }

    func makeImage() -> CGImage? {
        guard width > 0, height > 0, buffer.count >= width * height * 4 else { return nil }
        let bytes = Data(buffer[0..<(width * height * 4)])
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: 像素

    /// 转成行 0 在顶部（top-down）、RGBA8 的像素缓冲。
    ///
    /// CGBitmapContext 的内存布局里行 0 就是图像顶部（Quartz 只把绘图坐标原点放在左下），
    /// 所以直接使用 draw 后的缓冲即可，不需要额外翻转。
    static func topDownRGBA(_ image: CGImage) -> Frame? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        return Frame(data: data, width: width, height: height)
    }

    private func rowHash(_ data: [UInt8], row: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let base = row * width * 4
        var x = 0
        while x < width {
            let index = base + x * 4
            hash = (hash ^ UInt64(data[index])) &* 0x0000_0100_0000_01b3
            hash = (hash ^ UInt64(data[index + 1])) &* 0x0000_0100_0000_01b3
            hash = (hash ^ UInt64(data[index + 2])) &* 0x0000_0100_0000_01b3
            x += 3
        }
        return hash
    }
}

/// 滚动截图过程中的提示条。
final class ScrollHUDWindow: NSWindow {
    private let label = NSTextField(labelWithString: "")

    init(near globalRect: CGRect) {
        let width: CGFloat = 340
        let height: CGFloat = 34
        let screen = NSScreen.screens.first { $0.frame.intersects(globalRect) }?.visibleFrame
        // 选区贴底部时提示条放到选区上方，避免掉出屏幕
        var originY = globalRect.minY - height - 12
        if let screen, originY < screen.minY + 8 {
            originY = globalRect.maxY + 12
        }
        var originX = globalRect.midX - width / 2
        if let screen {
            originX = min(max(originX, screen.minX + 8), screen.maxX - width - 8)
            originY = min(originY, screen.maxY - height - 8)
        }
        let origin = CGPoint(x: originX, y: originY)
        super.init(
            contentRect: CGRect(origin: origin, size: CGSize(width: width, height: height)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9

        label.frame = CGRect(x: 12, y: 8, width: width - 24, height: 18)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.textColor = .white
        background.addSubview(label)
        contentView = background
    }

    func update(_ text: String) {
        label.stringValue = text
    }
}

/// 滚动截图会话：反复抓取选区，边滚边拼，停止滚动后自动收尾。
@MainActor
final class ScrollCaptureSession {
    private let shot: ScreenShot
    private let rect: CGRect
    private let idleLimit = 6          // 6 帧无新增即视为滚动结束（约 1.5 秒）
    private let interval: TimeInterval = 0.25

    private var stitcher = ScrollStitcher()
    private var capturer: RegionCapturer?
    private var timer: Timer?
    private var hud: ScrollHUDWindow?
    private var idleCount = 0
    private var busy = false
    private var finished = false

    var onFinish: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?

    init(shot: ScreenShot, rect: CGRect) {
        self.shot = shot
        self.rect = rect
    }

    func start() {
        Task { @MainActor in
            do {
                let capturer = try await RegionCapturer(shot: shot, rect: rect)
                self.capturer = capturer

                let globalRect = CGRect(
                    x: shot.frame.minX + rect.minX,
                    y: shot.frame.minY + rect.minY,
                    width: rect.width,
                    height: rect.height
                )
                let hud = ScrollHUDWindow(near: globalRect)
                hud.update("在选区内向下滚动，停止滚动自动完成")
                hud.orderFrontRegardless()
                self.hud = hud

                tick()
                let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            } catch {
                self.cancel()
            }
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        teardown()
        onCancel?()
    }

    private func tick() {
        guard !finished, !busy, let capturer else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let frame = try await capturer.capture()
                self.handle(frame)
            } catch {
                self.idleCount += 1
                if self.idleCount >= self.idleLimit { self.finish() }
            }
        }
    }

    private func handle(_ frame: CGImage) {
        guard !finished else { return }

        if stitcher.isEmpty {
            stitcher.seed(frame)
            hud?.update("已拼接 \(stitcher.height) px · 继续向下滚动")
            return
        }

        let added = stitcher.append(frame)
        switch added {
        case let rows where rows > 0:
            idleCount = 0
            hud?.update("已拼接 \(stitcher.height) px · 停止滚动即完成")
            if stitcher.isFull { finish() }
        case 0:
            idleCount += 1
            if idleCount == idleLimit / 2 {
                hud?.update("已拼接 \(stitcher.height) px · 准备收尾…")
            }
            if idleCount >= idleLimit { finish() }
        default:
            // 无法匹配（内容在动画或已滚过头），丢弃该帧
            idleCount += 1
            if idleCount >= idleLimit { finish() }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        teardown()
        if let image = stitcher.makeImage() {
            onFinish?(image)
        } else {
            onCancel?()
        }
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        hud?.orderOut(nil)
        hud = nil
    }
}
