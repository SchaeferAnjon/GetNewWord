// 语境图（ContextImage.make）：选区往外扩多少、红框画在哪、框外压暗。坐标是左上角原点的像素，画图时要翻转

import AppKit
import CoreGraphics
import Testing
@testable import GetNewWord

/// 纯白的「整屏截图」
private func whiteScreen(width: Int, height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// 按左上角原点读像素
private struct Pixels {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ image: NSImage) {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        width = cg.width
        height = cg.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        bytes = buffer
    }

    func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    func isRed(_ x: Int, _ y: Int) -> Bool { let p = rgb(x, y); return p.r > 240 && p.g < 60 && p.b < 60 }
    func isWhite(_ x: Int, _ y: Int) -> Bool { let p = rgb(x, y); return p.r > 250 && p.g > 250 && p.b > 250 }
    /// 白色压暗 12% ≈ 224
    func isDimmed(_ x: Int, _ y: Int) -> Bool { let p = rgb(x, y); return (215...232).contains(p.r) && p.r == p.g && p.g == p.b }
}

struct ContextImageTests {
    /// Retina 屏（2 像素/point）上框了一个靠上的小词：左右各扩 520pt、上下 120pt，碰到屏幕边就截住
    @Test func smallSelectionNearTop() throws {
        let screen = whiteScreen(width: 2000, height: 1200)
        let selection = CGRect(x: 1000, y: 100, width: 100, height: 40)
        let (context, crop) = try #require(ContextImage.make(from: screen, sourceRect: selection, scaleX: 2, scaleY: 2, isSmallSelection: true))

        let cropped = try #require(crop)
        #expect(cropped.size == NSSize(width: 100, height: 40))

        // 横向 1000 ± 1040 超出两边 → 整屏宽；纵向 100 - 240 截到 0，下边到 100 + 40 + 240 = 380
        let px = Pixels(context)
        #expect(px.width == 2000)
        #expect(px.height == 380)

        // 红框：选区往外 3pt（6 像素）。上边在 y = 100 - 6 = 94，左边在 x = 1000 - 6 = 994
        #expect(px.isRed(1050, 94))
        #expect(px.isRed(1050, 146))
        #expect(px.isRed(994, 120))
        #expect(px.isRed(1106, 120))
        // 翻转没弄反：图的下半部分对称的位置上没有红框
        #expect(!px.isRed(1050, 380 - 1 - 94))
        // 框里保持原样，框外压暗
        #expect(px.isWhite(1050, 120))
        #expect(px.isDimmed(100, 300))
        #expect(px.isDimmed(1050, 20))
        #expect(px.isDimmed(1050, 200))
    }

    /// 选区已经很大（一整段）：只扩 40pt × 30pt
    @Test func largeSelectionPadsLittle() throws {
        let screen = whiteScreen(width: 1440, height: 900)
        let selection = CGRect(x: 300, y: 300, width: 600, height: 200)
        let (context, _) = try #require(ContextImage.make(from: screen, sourceRect: selection, scaleX: 1, scaleY: 1, isSmallSelection: false))
        let px = Pixels(context)
        #expect(px.width == 600 + 2 * 40)
        #expect(px.height == 200 + 2 * 30)
        // 红框外扩 3 像素，线宽 4：上边在 y = 30 - 3 = 27
        #expect(px.isRed(340, 27))
        #expect(px.isRed(37, 100))
        #expect(px.isWhite(340, 130))
        #expect(px.isDimmed(5, 5))
    }

    /// 选区贴着屏幕右下角：扩出去的部分截掉，红框还在选区上
    @Test func selectionAtBottomRightCorner() throws {
        let screen = whiteScreen(width: 1000, height: 800)
        let selection = CGRect(x: 900, y: 760, width: 100, height: 40)
        let (context, crop) = try #require(ContextImage.make(from: screen, sourceRect: selection, scaleX: 1, scaleY: 1, isSmallSelection: true))
        #expect(crop?.size == NSSize(width: 100, height: 40))
        let px = Pixels(context)
        // 左边扩到 900 - 520 = 380，右边、下边截在屏幕边上
        #expect(px.width == 1000 - 380)
        #expect(px.height == 800 - (760 - 120))
        // 选区在语境图里的位置：x 900 - 380 = 520，y 760 - 640 = 120；上边红线在 y = 117
        #expect(px.isRed(570, 117))
        #expect(px.isWhite(570, 140))
        #expect(px.isDimmed(100, 60))
    }
}
