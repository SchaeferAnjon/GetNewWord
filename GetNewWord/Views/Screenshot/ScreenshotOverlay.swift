// ScreenshotOverlay.swift
// GetNewWord
//
// 截图覆盖层：全屏半透明遮罩 + 拖拽框选区域
// 矩形内显示原始屏幕内容（清晰），矩形外保持半透明黑色

import AppKit
import SwiftUI

// MARK: - OverlayWindow

/// 使用 nonactivatingPanel：能成为 key window 接收 ESC，
/// 但**不会激活应用**（否则主窗口会被一起带到前台，用户只想要小浮窗）
final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - ScreenshotOverlayController

@MainActor
class ScreenshotOverlayController {
    private var overlayWindows: [NSWindow] = []
    private var onCapture: (@Sendable (NSImage?, NSImage?) -> Void)?

    /// 显示截图覆盖层
    /// - Parameters:
    ///   - screenImages: 每个屏幕对应的截图 [(screen, image)]
    ///   - completion: 截图完成回调，选中区域图片或 nil（取消）
    func showOverlay(screenImages: [(screen: NSScreen, image: NSImage)], completion: @escaping @Sendable (NSImage?, NSImage?) -> Void) {
        self.onCapture = completion

        // 为每个屏幕创建覆盖窗口，使用对应屏幕的截图
        for (screen, image) in screenImages {
            let frame = screen.frame

            let window = OverlayWindow(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.level = .screenSaver
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            // 覆盖层视图的大小与屏幕 frame 一致（points）
            // 但截图 image 的大小是像素尺寸，需要在 draw 中处理缩放
            let overlayView = ScreenshotOverlayView(
                frame: NSRect(origin: .zero, size: frame.size),
                screenImage: image,
                screenFrame: frame,
                controller: self
            )
            window.contentView = overlayView
            window.backgroundColor = .clear

            window.orderFrontRegardless()
            overlayWindows.append(window)

            // 让第一个窗口成为 key window 以接收键盘事件（ESC 取消）
            if screen == NSScreen.screens.first {
                // 不调用 NSApp.activate：nonactivatingPanel 可直接成为 key window
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(overlayView)
            }
        }
    }

    /// 完成截图并关闭覆盖层
    func finishWithImage(_ image: NSImage?, selection: NSImage? = nil) {
        dismiss()
        onCapture?(image, selection)
        onCapture = nil
    }

    /// 关闭覆盖层
    func dismiss() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }
}

// MARK: - ScreenshotOverlayView

/// 自定义 NSView，处理鼠标拖拽框选和绘制
class ScreenshotOverlayView: NSView {
    private var screenImage: NSImage?
    private var screenFrame: NSRect
    private var startPoint: NSPoint?
    private var currentRect: NSRect?
    private var isDragging = false
    private weak var controller: ScreenshotOverlayController?

    // 半透明遮罩颜色
    private let overlayColor = NSColor.black.withAlphaComponent(0.35)

    /// 尺寸标签字体属性：只创建一次复用。draw() 高频重建字典时如果 fontd 恰好返回失效字体，
    /// CoreText 会抛 NSException 直接闪退（2026-09-02 17:01 崩溃报告，ScreenshotOverlayView.draw → ApplyFont）
    private static let sizeLabelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white
    ]

    init(frame: NSRect, screenImage: NSImage, screenFrame: NSRect, controller: ScreenshotOverlayController) {
        self.screenImage = screenImage
        self.screenFrame = screenFrame
        self.controller = controller
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        startPoint = location
        currentRect = NSRect(origin: location, size: .zero)
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let location = convert(event.locationInWindow, from: nil)

        let x = min(start.x, location.x)
        let y = min(start.y, location.y)
        let w = abs(location.x - start.x)
        let h = abs(location.y - start.y)

        currentRect = NSRect(x: x, y: y, width: w, height: h)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = currentRect, rect.width > 5, rect.height > 5 else {
            // 点击太小，取消
            controller?.finishWithImage(nil)
            return
        }

        isDragging = false

        // 从屏幕截图中裁剪选区
        if let screenImage = screenImage,
           let cropped = cropImage(screenImage, toRect: rect) {
            controller?.finishWithImage(cropped.0, selection: cropped.1)
        } else {
            controller?.finishWithImage(nil)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // 右键取消
        controller?.finishWithImage(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            cancelOperation(nil)
        }
    }

    /// 结果面板开着时 Esc 被它的全局热键截走，由它转到这里
    override func cancelOperation(_ sender: Any?) {
        controller?.finishWithImage(nil)
    }

    // 确保视图可以成为第一响应者以接收键盘事件
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let viewWidth = bounds.width
        let viewHeight = bounds.height

        // 1. 先绘制全屏屏幕截图作为底层
        if let image = screenImage {
            image.draw(in: bounds)
        } else {
            // 没有截图时用灰色填充
            NSColor.darkGray.setFill()
            bounds.fill()
        }

        // 2. 在整个视图上绘制半透明黑色遮罩
        overlayColor.setFill()
        bounds.fill()

        // 3. 如果有选区，在选区内重新绘制原始截图（清晰显示）
        if let rect = currentRect, rect.width > 1, rect.height > 1, let image = screenImage {
            // 计算视图坐标到图片像素坐标的缩放比例
            let imagePixelWidth = image.size.width
            let imagePixelHeight = image.size.height
            let scaleX = imagePixelWidth / viewWidth
            let scaleY = imagePixelHeight / viewHeight

            // 将视图坐标（points，原点在左下角）转换为图片像素坐标（原点在左上角）
            // CGImage.cropping(to:) 使用左上角原点，需要 Y 轴翻转
            let srcX = rect.origin.x * scaleX
            let srcY = (viewHeight - rect.origin.y - rect.height) * scaleY
            let srcW = rect.width * scaleX
            let srcH = rect.height * scaleY

            let sourceRect = CGRect(x: srcX, y: srcY, width: srcW, height: srcH)

            // 裁剪图片并在选区绘制
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let croppedCG = cgImage.cropping(to: sourceRect) {
                let croppedNS = NSImage(cgImage: croppedCG, size: rect.size)

                NSGraphicsContext.saveGraphicsState()

                // 绘制清晰的截图区域（覆盖遮罩）
                croppedNS.draw(in: rect)

                // 绘制选区白色边框
                let borderPath = NSBezierPath(rect: rect)
                borderPath.lineWidth = 1.5
                NSColor.white.setStroke()
                borderPath.stroke()

                // 绘制选区尺寸提示
                let sizeText = "\(Int(rect.width)) × \(Int(rect.height))"
                let attrs = Self.sizeLabelAttrs
                let textSize = sizeText.size(withAttributes: attrs)
                let textX = rect.origin.x + (rect.width - textSize.width) / 2
                let textY = rect.origin.y + rect.height + 6
                let textRect = NSRect(x: textX, y: textY, width: textSize.width, height: textSize.height)

                // 文字背景
                let bgRect = textRect.insetBy(dx: -4, dy: -2)
                let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3)
                NSColor.black.withAlphaComponent(0.6).setFill()
                bgPath.fill()

                sizeText.draw(in: textRect, withAttributes: attrs)

                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    // MARK: - Image Cropping

    private func cropImage(_ image: NSImage, toRect rect: NSRect) -> (NSImage, NSImage?)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let imagePixelWidth = CGFloat(cgImage.width)
        let imagePixelHeight = CGFloat(cgImage.height)
        let viewWidth = bounds.width
        let viewHeight = bounds.height

        // 计算视图坐标（points）到图片像素坐标的缩放比例
        let scaleX = imagePixelWidth / viewWidth
        let scaleY = imagePixelHeight / viewHeight

        // 将视图坐标（原点在左下角）转换为图片像素坐标（原点在左上角）
        // CGImage.cropping(to:) 使用左上角原点，需要 Y 轴翻转
        let srcX = rect.origin.x * scaleX
        let srcY = (viewHeight - rect.origin.y - rect.height) * scaleY
        let srcW = rect.width * scaleX
        let srcH = rect.height * scaleY

        let sourceRect = CGRect(x: srcX, y: srcY, width: srcW, height: srcH)
        return ContextImage.make(
            from: cgImage, sourceRect: sourceRect, scaleX: scaleX, scaleY: scaleY,
            isSmallSelection: rect.width < 400 || rect.height < 120
        )
    }
}
