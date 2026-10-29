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

/// 框选查到的词全是老词、语境也一样：状态条写「已在词库里」，不写「已存进」，撤销藏起来
struct SavedNothingNewTests {
    private func check(words: Int, snippets: Int = 0, skipped: Set<Int>, removedWords: Set<Int> = [], removedSnippets: Set<Int> = []) -> Bool {
        AnalysisViewModel.savedNothingNew(wordCount: words, snippetCount: snippets, skipped: skipped,
                                          removedWords: removedWords, removedSnippets: removedSnippets)
    }

    @Test func allOldWords() {
        #expect(check(words: 1, skipped: [0]))
        #expect(check(words: 3, skipped: [0, 1, 2]))
    }

    /// 有一个是新存的、或者还存了知识片段：照旧写「已存进」
    @Test func somethingNewWasSaved() {
        #expect(!check(words: 2, skipped: [0]))
        #expect(!check(words: 1, snippets: 1, skipped: [0]))
        #expect(!check(words: 0, snippets: 1, skipped: []))
    }

    /// 什么都没认出来不算「没新存」（那是「未识别到」）
    @Test func emptyResult() {
        #expect(!check(words: 0, skipped: []))
    }

    /// 新存的那个被单项移除了，剩下的都是老词：也算什么都没新存
    @Test func newOneRemoved() {
        #expect(check(words: 2, skipped: [0], removedWords: [1]))
        #expect(check(words: 1, snippets: 1, skipped: [0], removedSnippets: [0]))
        // 全移除了：没有词可说
        #expect(!check(words: 1, skipped: [0], removedWords: [0]))
    }
}

/// 快速识词（框的那个写法）和主分析的词头算不算同一个词：算的话提前发出的补全留着，不再补一遍、不再念第二遍
@MainActor
struct SameHeadwordTests {
    @Test func inflectedFormsAreTheSameWord() {
        WordMatcher.warmUp()   // 主线程上要等词元模型读完才认不规则变化（App 里启动时在后台读）
        #expect(AnalysisViewModel.isSameHeadword("heat", "heats", language: .english))
        #expect(AnalysisViewModel.isSameHeadword("steam up", "steamed up", language: .english))
        // 变音不算差别：以前 hält 和 halten 算两个词，补全被丢掉重补
        #expect(AnalysisViewModel.isSameHeadword("halten", "hält", language: .german))
        #expect(AnalysisViewModel.isSameHeadword("Haus", "Häuser", language: .german))
        // 不规则变化
        #expect(AnalysisViewModel.isSameHeadword("run", "ran", language: .english))
        #expect(AnalysisViewModel.isSameHeadword("give up", "gave up", language: .english))
    }

    @Test func differentWordsAreNot() {
        #expect(!AnalysisViewModel.isSameHeadword("Britain", "beloved", language: .english))
        #expect(!AnalysisViewModel.isSameHeadword("anhalten", "hält", language: .german))
        #expect(!AnalysisViewModel.isSameHeadword("heat", "wheat", language: .english))
        #expect(!AnalysisViewModel.isSameHeadword("give up", "give", language: .english))
    }
}
