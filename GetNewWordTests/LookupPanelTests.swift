// 查词面板：默认是经典卡片（1.1.7 那版，带截图），它记的大小能接上 1.1.x 存的；截图先缩小再显示

import AppKit
import Testing
@testable import GetNewWord

struct LookupPanelStyleTests {
    @Test func classicIsDefaultAndListedFirst() {
        #expect(LookupPanelStyle.allCases.first == .classic)
        #expect(LookupPanelStyle(rawValue: "") == nil)
        // 1.2.0 存过的值还认得
        #expect(LookupPanelStyle(rawValue: "tag") == .tag)
        #expect(LookupPanelStyle(rawValue: "lecture") == .lecture)
    }

    /// 经典卡片和讲义卡的按钮在顶上状态条里，浮签放在底栏
    @Test func statusBarStyles() {
        #expect(LookupPanelStyle.classic.hasStatusBar)
        #expect(LookupPanelStyle.lecture.hasStatusBar)
        #expect(!LookupPanelStyle.tag.hasStatusBar)
        #expect(!LookupPanelStyle.tagExpanded.hasStatusBar)
    }

    /// 和 1.1.7 一样 520 宽、最高 780
    @Test func classicSize() {
        #expect(LookupPanelStyle.classic.panelSize(expanded: true) == NSSize(width: 520, height: 780))
    }
}

@MainActor
struct PanelSizeMemoryTests {
    private func defaults() throws -> UserDefaults {
        let name = "GetNewWordTests.panelSize.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        d.removePersistentDomain(forName: name)
        return d
    }

    /// 从 1.1.x 升上来：经典卡片没记过大小时用 1.1.x 存的那个
    @Test func classicFallsBackToLegacySize() throws {
        let d = try defaults()
        d.set(NSStringFromSize(NSSize(width: 610, height: 700)), forKey: AnalysisResultWindowController.legacySizeKey)
        #expect(AnalysisResultWindowController.savedSize(.classic, defaults: d) == NSSize(width: 610, height: 700))
        // 讲义卡不接 1.1.x 的
        #expect(AnalysisResultWindowController.savedSize(.lecture, defaults: d) == nil)
        // 经典卡片自己记过就用自己的
        d.set(NSStringFromSize(NSSize(width: 540, height: 720)), forKey: "resultPanelSize.classic")
        #expect(AnalysisResultWindowController.savedSize(.classic, defaults: d) == NSSize(width: 540, height: 720))
    }

    /// 收起的浮签每次都用默认小尺寸；存坏了的值不用
    @Test func tagAndBrokenValues() throws {
        let d = try defaults()
        d.set(NSStringFromSize(NSSize(width: 500, height: 500)), forKey: "resultPanelSize.tag")
        #expect(AnalysisResultWindowController.savedSize(.tag, defaults: d) == nil)
        d.set("garbage", forKey: "resultPanelSize.lecture")
        #expect(AnalysisResultWindowController.savedSize(.lecture, defaults: d) == nil)
    }
}

@MainActor
struct ScreenshotThumbnailTests {
    private func image(width: Int, height: Int) -> NSImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: width, height: height))
    }

    private func pixels(_ i: NSImage) -> (Int, Int) {
        let cg = i.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return (cg.width, cg.height)
    }

    /// Retina 整屏宽的语境图（3024×600）：缩到 1800 宽以内，宽高比不变
    @Test func shrinksWideContextImage() throws {
        let thumb = try #require(ScreenshotThumbnail.downscale(image(width: 3024, height: 600)))
        let (w, h) = pixels(thumb)
        #expect(w == 1800)
        #expect(h == 357)
        #expect(abs(thumb.size.width / thumb.size.height - 3024.0 / 600.0) < 0.02)
    }

    /// 很高的图按高度缩（最高 360 像素）
    @Test func shrinksTallImage() throws {
        let thumb = try #require(ScreenshotThumbnail.downscale(image(width: 800, height: 1200)))
        let (w, h) = pixels(thumb)
        #expect(h == 360)
        #expect(w == 240)
    }

    /// 本来就不大的原样用；同一张图第二次直接拿缓存
    @Test func smallImageUntouchedAndCached() {
        let small = image(width: 600, height: 200)
        #expect(ScreenshotThumbnail.downscale(small) === small)
        let big = image(width: 3000, height: 800)
        let first = ScreenshotThumbnail.make(big)
        #expect(ScreenshotThumbnail.make(big) === first)
        #expect(first !== big)
    }
}
