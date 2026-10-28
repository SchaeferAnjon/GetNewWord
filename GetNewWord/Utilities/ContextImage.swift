// ContextImage.swift
// GetNewWord
//
// 欧路词典式取词：用户往往只框一个词，单独发给模型没有语境。
// 因此把选区向四周扩展一圈作为上下文一起截取，并在图上用红框标出用户实际圈选的区域，
// Prompt 里告诉模型"只解释红框内的词，红框外是上下文"。
// 框选截图和指词取词共用这一份。

import AppKit

enum ContextImage {
    /// - Parameters:
    ///   - cgImage: 整屏截图
    ///   - sourceRect: 选区（图片像素坐标，左上角原点）
    ///   - scaleX/scaleY: 每个 point 对应的像素数
    ///   - isSmallSelection: 选区越小扩得越多（单词 → 整句/整段），选区本身已经很大时只略微扩展
    /// - Returns: (带红框的语境图, 纯选区小图——本地 OCR 秒查词库用)
    static func make(from cgImage: CGImage, sourceRect: CGRect, scaleX: CGFloat, scaleY: CGFloat, isSmallSelection: Bool) -> (NSImage, NSImage?)? {
        let selectionImage: NSImage? = cgImage.cropping(to: sourceRect.integral).map {
            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
        }

        let padXPoints: CGFloat = isSmallSelection ? 520 : 40
        let padYPoints: CGFloat = isSmallSelection ? 120 : 30
        let contextRect = sourceRect
            .insetBy(dx: -padXPoints * scaleX, dy: -padYPoints * scaleY)
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
            .integral

        guard let contextCG = cgImage.cropping(to: contextRect) else { return nil }

        // 在上下文图上绘制红框（CGContext 原点在左下角，需要把 top-left 像素坐标翻转）
        let w = contextCG.width, h = contextCG.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (NSImage(cgImage: contextCG, size: NSSize(width: w, height: h)), selectionImage)
        }
        ctx.draw(contextCG, in: CGRect(x: 0, y: 0, width: w, height: h))

        let boxX = sourceRect.origin.x - contextRect.origin.x
        let boxYTopLeft = sourceRect.origin.y - contextRect.origin.y
        let boxRect = CGRect(
            x: boxX,
            y: CGFloat(h) - boxYTopLeft - sourceRect.height,
            width: sourceRect.width,
            height: sourceRect.height
        ).insetBy(dx: -3 * scaleX, dy: -3 * scaleY)
        // 框外轻微压暗：给视觉定位弱的模型（DeepSeek）更强的目标信号
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.12))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: max(0, boxRect.minY)))
        ctx.fill(CGRect(x: 0, y: boxRect.maxY, width: CGFloat(w), height: max(0, CGFloat(h) - boxRect.maxY)))
        ctx.fill(CGRect(x: 0, y: boxRect.minY, width: max(0, boxRect.minX), height: boxRect.height))
        ctx.fill(CGRect(x: boxRect.maxX, y: boxRect.minY, width: max(0, CGFloat(w) - boxRect.maxX), height: boxRect.height))
        ctx.setStrokeColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.setLineWidth(max(4, 3 * scaleX))
        ctx.stroke(boxRect)

        guard let annotated = ctx.makeImage() else {
            return (NSImage(cgImage: contextCG, size: NSSize(width: w, height: h)), selectionImage)
        }
        return (NSImage(cgImage: annotated, size: NSSize(width: w, height: h)), selectionImage)
    }
}
