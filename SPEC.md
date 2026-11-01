# Shottr 功能规格（黑盒观察整理）

来源：本机 Shottr 1.9.3 的公开元数据（Info.plist）、用户配置默认值与界面行为观察。
不包含任何反编译、二进制分析或资源提取。目的仅为撰写一份独立的开源等效实现提供行为依据。

## 1. 应用形态

| 项 | 观察结果 |
| --- | --- |
| Bundle ID | `cc.ffitch.shottr` |
| 最低系统 | macOS 12 |
| 形态 | 菜单栏常驻（NSStatusItem），无常驻 Dock 窗口 |
| URL Scheme | `shottr://` |
| 可打开文件类型 | png / jpeg / gif |
| 快捷键库 | 开源库 `KeyboardShortcuts`（sindresorhus） |

## 2. 截图模式

| 模式 | 内部键 | 说明 |
| --- | --- | --- |
| 区域截图 | `areaCaptureMode` | 默认进入 `editor`，即截图后直接进编辑器 |
| 全屏截图 | — | 当前显示器整屏 |
| 滚动截图 | `everScrollingCapture` | 自动滚动 + 拼接长图 |
| 重开选区 | `reopen` | 复用上一次的选区位置 |

滚动截图参数：`scrollingSpeed`（默认 2）、`scrollingMax`（默认 20000 像素）、`scrollingManualEnabled`、`scrollingReverseAutoscroll`、`scrollingCustomGrabber`。

吸附与光标：`snappingMode=2`（对象/窗口吸附）、`captureCursor=auto`、`areaCustomGrabber`。

## 3. 编辑器对象模型（从配置键反推）

| 对象 | 相关键 | 特性 |
| --- | --- | --- |
| 矩形 | `Shottr.ObjRectangle: handdrawn` | 支持手绘风 |
| 椭圆 | `Shottr.ObjOval: handdrawn` | 支持手绘风 |
| 聚光/遮罩 | `Shottr.ObjSpotlight: shape, size` | 形状默认 `oval`，可调尺寸 |
| 文字 | `Shottr.ObjText: size, style, pointerPresent` | 带指向箭头、多种字号与样式 |
| 序号 | `Shottr.ObjCounter: counterAngle` | 自动递增编号徽章，角度可调 |
| 自由笔 | — | 与"手绘"开关联动 |
| 模糊/马赛克 | — | 界面可见 |

画布能力：`expandableCanvas`（可扩展画布留白）、`headlessTextRendering`。

## 4. 输出与后处理

| 能力 | 键 | 默认 |
| --- | --- | --- |
| 截图后行为 | `afterGrabShow / afterGrabCopy / afterGrabSave` | 显示 |
| 保存格式 | `saveFormat` | Auto |
| 默认目录 | `defaultFolder` | 桌面 |
| 缩放保存 | `downscaleOnSave` | 开 |
| 真实像素 | `realPixels` | 关 |
| 缩略图关闭 | `thumbnailClosing` | 手动 |
| 上传 | `uploadMode`、`uploadS3Bucket` | 关闭 / 支持 S3 |

Esc 行为：`copyOnEsc=1`、`saveOnEsc=0`。

## 5. 取色与对比度

`colorFormat=HEX`、`contrastType=wcag2`。取色器除 HEX/RGB 外还给出 WCAG2 对比度判定。

## 6. OCR

`primaryOCRLang=zh-Hans`、`ocrRemoveBreaks`（默认关，保留换行）。系统能力来自 Vision 框架。

## 7. 外观与窗口

`alwaysOnTop`、`preferLargeWindow`、`thumbnailClosing`、贴图窗口（`Pin.storyboardc`）、预览窗口（`Preview.storyboardc`）、设置窗口（`Preferences.storyboardc`）。默认标注色 `#FA3C63`，美化背景支持纯色 / 渐变（`customBackdropColor`、`customGradFrom/To`）。

## 8. 快捷键默认值（用户自定义过，Carbon 修饰位）

| 动作 | Carbon | 等价按键 |
| --- | --- | --- |
| 区域 | 12 + 256 | ⌘S |
| 全屏 | 12 + 2048 | ⌥S |
| OCR | 12 + 4096 | ⌃S |
| 重开选区 | 12 + 2560 | ⌥⇧S |
| 滚动截图 | 12 + 768 | ⌘⇧S |

## 9. 开源复刻的取舍

0.1 版覆盖核心闭环：区域/全屏截图、标注编辑器（矩形、椭圆、箭头、直线、自由笔、文字、序号、高亮、模糊、聚光）、撤销重做、复制、保存、贴图、OCR、取色、全局快捷键、状态栏菜单。

后续迭代：滚动截图、窗口吸附与窗口截图、S3 上传、背景美化、WCAG 对比度、自定义快捷键、历史记录。
