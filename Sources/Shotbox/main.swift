import AppKit

// 非交互自测入口，用于 CI 或命令行验证渲染/导出链路
if let flagIndex = CommandLine.arguments.firstIndex(of: "--selftest") {
    let outputPath = CommandLine.arguments.count > flagIndex + 1
        ? CommandLine.arguments[flagIndex + 1]
        : "/tmp/shotbox-selftest.png"
    let code = MainActor.assumeIsolated { SelfTest.run(outputPath: outputPath) }
    exit(code)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let appDelegate = AppDelegate()
    app.delegate = appDelegate
    // 常规策略：在 Dock 里保留入口，避免菜单栏图标被挤掉时找不到 app
    app.setActivationPolicy(.regular)
    app.run()
}
