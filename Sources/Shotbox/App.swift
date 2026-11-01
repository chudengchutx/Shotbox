import AppKit
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private var selection: SelectionController?
    private var editor: EditorWindowController?
    private var lastShots: [ScreenShot] = []
    private var lastArea: (displayID: CGDirectDisplayID, rect: CGRect)?
    private var scrollSession: ScrollCaptureSession?
    private var permissionItem: NSMenuItem?

    /// 菜单栏常驻应用启动时不弹窗，权限状态直接写在菜单里，避免抢焦点。
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHotKeys()
        requestPermissionOnLaunchIfNeeded()

        // 开发/验收用：不抢焦点地打开一个带示例标注的编辑器窗口
        if CommandLine.arguments.contains("--editor-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let image = SelfTest.makeBaseImage() else { return }
                self.openEditor(image: image, scale: 2, activate: false)
            }
        }

        // 命令行验收抓屏链路：Shotbox --capture-test /tmp/shot.png
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--capture-test") {
            let path = CommandLine.arguments.count > flagIndex + 1
                ? CommandLine.arguments[flagIndex + 1]
                : "/tmp/shotbox-capture.png"
            Task { @MainActor in
                guard ScreenPermission.isGranted else {
                    print("CAPTURE FAIL permission_denied")
                    exit(2)
                }
                do {
                    let shots = try await Capturer.captureAllScreens()
                    guard let first = shots.first else {
                        print("CAPTURE FAIL no_displays")
                        exit(3)
                    }
                    try ImageExporter.pngData(from: first.image).write(to: URL(fileURLWithPath: path))
                    print("CAPTURE OK \(path) \(first.image.width)x\(first.image.height) scale=\(first.scale)")
                } catch {
                    print("CAPTURE FAIL \(error.localizedDescription)")
                }
                exit(0)
            }
        }
    }

    /// 首次启动主动请求一次屏幕录制权限，避免用户去设置里翻。
    private func requestPermissionOnLaunchIfNeeded() {
        guard !ScreenPermission.isGranted else { return }
        let key = "didRequestScreenPermission"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        ScreenPermission.request()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let permissionItem else { return }
        if ScreenPermission.isGranted {
            permissionItem.title = "屏幕录制权限：已授权"
            permissionItem.action = nil
        } else {
            permissionItem.title = "⚠️ 屏幕录制权限未授予（点此修复）"
            permissionItem.action = #selector(showPermission)
        }
    }

    // MARK: 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Shotbox")
            button.image?.isTemplate = true
            button.toolTip = "Shotbox · 截图标注"
        }

        let menu = NSMenu()

        menu.addItem(item("区域截图", #selector(captureArea), "⌘⇧2"))
        menu.addItem(item("全屏截图", #selector(captureFullScreen), "⌥⌘3"))
        menu.addItem(item("滚动长截图", #selector(captureScrolling), "⌃⇧2"))
        menu.addItem(item("重开上次选区", #selector(reopenLastArea), "⌥⇧2"))
        menu.addItem(.separator())
        menu.addItem(item("从剪贴板识别文字", #selector(ocrFromPasteboard), "⌃⌘2"))
        menu.addItem(item("从剪贴板打开图片", #selector(openFromPasteboard), ""))
        menu.addItem(.separator())
        let permission = item("屏幕录制权限…", #selector(showPermission), "")
        permissionItem = permission
        menu.addItem(permission)
        menu.delegate = self
        menu.addItem(item("打开截图保存目录", #selector(openDesktop), ""))
        menu.addItem(.separator())
        menu.addItem(item("退出 Shotbox", #selector(quit), "q"))

        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector?, _ shortcut: String) -> NSMenuItem {
        let item = NSMenuItem(title: shortcut.isEmpty ? title : "\(title)    \(shortcut)", action: action, keyEquivalent: "")
        item.target = if action == nil { nil } else { self }
        return item
    }

    private func setupHotKeys() {
        // 19 = 数字 2，20 = 数字 3
        hotKeys.append(HotKey.register(keyCode: 19, modifiers: HotKey.cmd | HotKey.shift) { [weak self] in
            self?.captureArea()
        })
        hotKeys.append(HotKey.register(keyCode: 20, modifiers: HotKey.cmd | HotKey.option) { [weak self] in
            self?.captureFullScreen()
        })
        hotKeys.append(HotKey.register(keyCode: 19, modifiers: HotKey.cmd | HotKey.control) { [weak self] in
            self?.ocrFromPasteboard()
        })
        hotKeys.append(HotKey.register(keyCode: 19, modifiers: HotKey.control | HotKey.shift) { [weak self] in
            self?.captureScrolling()
        })
        hotKeys.append(HotKey.register(keyCode: 19, modifiers: HotKey.option | HotKey.shift) { [weak self] in
            self?.reopenLastArea()
        })
    }

    // MARK: 截图

    @objc private func captureArea() {
        guard ensurePermission() else { return }
        guard selection == nil else { return }
        Task { @MainActor in
            do {
                let shots = try await Capturer.captureAllScreens()
                guard !shots.isEmpty else {
                    self.notify("截图失败", "没有获取到显示器画面。请确认屏幕录制权限后重启 Shotbox。")
                    return
                }
                self.lastShots = shots
                let controller = SelectionController(shots: shots)
                self.selection = controller
                controller.onSelection = { [weak self] shot, rect in
                    guard let self else { return }
                    self.selection = nil
                    self.lastArea = (shot.displayID, rect)
                    guard let cropped = shot.crop(viewRect: rect) else { return }
                    self.openEditor(image: cropped, scale: shot.scale)
                }
                controller.onCancel = { [weak self] in
                    self?.selection = nil
                }
                controller.begin()
            } catch {
                self.notify("截图失败", error.localizedDescription + "\n请检查屏幕录制权限。")
            }
        }
    }

    @objc private func captureFullScreen() {
        guard ensurePermission() else { return }
        Task { @MainActor in
            do {
                let shots = try await Capturer.captureAllScreens()
                guard let main = shots.first else {
                    self.notify("截图失败", "没有获取到显示器画面。")
                    return
                }
                self.lastShots = shots
                self.openEditor(image: main.image, scale: main.scale)
            } catch {
                self.notify("截图失败", error.localizedDescription)
            }
        }
    }

    @objc private func captureScrolling() {
        guard ensurePermission() else { return }
        guard selection == nil, scrollSession == nil else { return }
        Task { @MainActor in
            do {
                let shots = try await Capturer.captureAllScreens()
                guard !shots.isEmpty else {
                    self.notify("截图失败", "没有获取到显示器画面。")
                    return
                }
                self.lastShots = shots
                let controller = SelectionController(shots: shots)
                self.selection = controller
                controller.onSelection = { [weak self] shot, rect in
                    guard let self else { return }
                    self.selection = nil
                    self.startScrolling(shot: shot, rect: rect)
                }
                controller.onCancel = { [weak self] in
                    self?.selection = nil
                }
                controller.begin()
            } catch {
                self.notify("截图失败", error.localizedDescription)
            }
        }
    }

    private func startScrolling(shot: ScreenShot, rect: CGRect) {
        let session = ScrollCaptureSession(shot: shot, rect: rect)
        scrollSession = session
        session.onFinish = { [weak self] image in
            guard let self else { return }
            self.scrollSession = nil
            self.lastArea = (shot.displayID, rect)
            self.openEditor(image: image, scale: shot.scale)
        }
        session.onCancel = { [weak self] in
            self?.scrollSession = nil
        }
        session.start()
    }

    @objc private func reopenLastArea() {        guard let area = lastArea else {
            notify("没有历史选区", "先做一次区域截图，之后可以用它重开。")
            return
        }
        guard ensurePermission() else { return }
        Task { @MainActor in
            do {
                let shots = try await Capturer.captureAllScreens()
                guard let shot = shots.first(where: { $0.displayID == area.displayID }) ?? shots.first else {
                    self.notify("截图失败", "没有获取到显示器画面。")
                    return
                }
                guard let cropped = shot.crop(viewRect: area.rect) else {
                    self.notify("无法重开选区", "上次的选区超出了当前屏幕范围。")
                    return
                }
                self.lastShots = shots
                self.openEditor(image: cropped, scale: shot.scale)
            } catch {
                self.notify("截图失败", error.localizedDescription)
            }
        }
    }

    private func openEditor(image: CGImage, scale: CGFloat, activate: Bool = true) {
        editor?.close()
        let controller = EditorWindowController(image: image, scale: scale)
        controller.onClose = { [weak self] in
            self?.editor = nil
        }
        editor = controller
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
            controller.window?.orderFrontRegardless()
        }
    }

    // MARK: 剪贴板

    @objc private func ocrFromPasteboard() {
        let pasteboard = NSPasteboard.general
        guard
            let objects = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
            let image = objects.first,
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            notify("剪贴板里没有图片", "先复制一张图片，再用这个命令识别文字。")
            return
        }
        Task { @MainActor in
            let text = await TextRecognizer.recognize(image: cgImage)
            guard !text.isEmpty else {
                self.notify("未识别到文字", "换一张文字更清晰的图片试试。")
                return
            }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            self.notify("已复制识别结果", "共 \(text.count) 个字符。")
        }
    }

    @objc private func openFromPasteboard() {
        let pasteboard = NSPasteboard.general
        guard
            let objects = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
            let image = objects.first,
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            notify("剪贴板里没有图片", "先复制一张图片。")
            return
        }
        openEditor(image: cgImage, scale: 2)
    }

    // MARK: 其他

    @objc private func showPermission() {
        if ScreenPermission.isGranted {
            notify("屏幕录制权限已开启", "可以直接使用区域截图。")
        } else {
            ScreenPermission.openSettings()
        }
    }

    @objc private func openDesktop() {
        if let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func ensurePermission() -> Bool {
        if ScreenPermission.isGranted { return true }
        ScreenPermission.request()
        notify(
            "需要屏幕录制权限",
            "已发送授权请求。请在「系统设置 → 隐私与安全性 → 屏幕录制」勾选 Shotbox，然后退出并重新打开。"
        )
        return false
    }

    private func notify(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
