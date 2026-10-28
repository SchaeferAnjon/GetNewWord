// ImageEncoder.swift
// GetNewWord
//
// 图片编码工具，用于将 NSImage 转换为 Base64 编码格式

import Foundation
import AppKit

class ImageEncoder {

    /// 将 NSImage 转换为 Base64 Data URL（data:image/png;base64,...）
    /// - Parameter image: 源图片
    /// - Returns: Base64 Data URL 字符串，转换失败时返回 nil
    static func toBase64DataURL(_ image: NSImage) -> String? {
        guard let data = image.pngData() else { return nil }
        let base64 = data.base64EncodedString()
        return "data:image/png;base64,\(base64)"
    }

    /// 发给模型用的压缩版：长边限制 + JPEG。
    /// Retina 2x PNG 动辄 300–700KB，压成 ≤1600px 的 JPEG 后一般只有 60–150KB，上传和图片 token 都省。
    static func toCompressedDataURL(_ image: NSImage, maxDimension: CGFloat = 1200, quality: CGFloat = 0.8) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1.0, maxDimension / max(w, h))
        let targetW = Int(w * scale), targetH = Int(h * scale)

        let finalCG: CGImage
        if scale < 1.0, let ctx = CGContext(
            data: nil, width: targetW, height: targetH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
            finalCG = ctx.makeImage() ?? cg
        } else {
            finalCG = cg
        }

        let rep = NSBitmapImageRep(cgImage: finalCG)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return nil }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    /// 将 NSImage 转换为纯 Base64 字符串（不含 Data URL 前缀）
    /// - Parameter image: 源图片
    /// - Returns: Base64 编码字符串，转换失败时返回 nil
    static func toBase64String(_ image: NSImage) -> String? {
        guard let data = image.pngData() else { return nil }
        return data.base64EncodedString()
    }

    /// 将 NSImage 压缩为 JPEG 数据
    /// - Parameters:
    ///   - image: 源图片
    ///   - quality: JPEG 压缩质量，范围 0.0–1.0，默认 0.8
    /// - Returns: JPEG 数据，转换失败时返回 nil
    static func compressToJPEG(_ image: NSImage, quality: CGFloat = 0.8) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        let clampedQuality = max(0.0, min(1.0, quality))
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: clampedQuality])
    }

    /// 将 NSImage 保存到指定文件路径
    /// - Parameters:
    ///   - image: 源图片
    ///   - path: 目标文件路径（PNG 格式）
    /// - Returns: 是否保存成功
    static func saveImage(_ image: NSImage, to path: String) -> Bool {
        guard let data = image.pngData() else { return false }
        let url = URL(fileURLWithPath: path)
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - NSImage PNG 转换扩展

private extension NSImage {
    /// 将 NSImage 转换为 PNG Data
    func pngData() -> Data? {
        guard let tiffRepresentation = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
