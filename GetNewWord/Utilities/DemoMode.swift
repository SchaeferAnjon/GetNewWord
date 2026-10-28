// DemoMode.swift
// GetNewWord
//
// README 截图用的演示模式，只编进 Debug 版（scripts/readme-shots.mjs 用它）。没人操作、锁着屏的 Mac 上也能走一遍
// 真的框选取词：整屏截图换成给定的图片，拖框换成给定的矩形，按快捷键换成启动后依次自动框一遍。
// 后面的本地 OCR、AI 请求、面板、存词库、发音、同步 Anki 都走正常流程。
//   GNW_DEMO=<plan.json>  {"lookups": [{"screen": "/path/screen.png", "select": [x, y, w, h]}, …], "pause": 15}
//                         screen 是整屏大小的图（像素 = 屏幕 point × 缩放），select 按 point 算、左上角原点
//   GNW_DEMO_KEY=<key>    当前 AI 服务商的 Key，只在环境变量里，不写钥匙串

#if DEBUG
import AppKit
import ImageIO
import SwiftData

@MainActor
enum DemoMode {
    private struct Lookup: Decodable {
        let screen: String
        let select: [CGFloat]
    }
    private struct Plan: Decodable {
        let lookups: [Lookup]
        let pause: Double?
    }

    private static let plan: Plan? = {
        guard let path = ProcessInfo.processInfo.environment["GNW_DEMO"] else { return nil }
        do {
            let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard plan.lookups.allSatisfy({ $0.select.count == 4 }) else { fail("select 要写成 [x, y, w, h]") }
            return plan
        } catch {
            fail("读不了 \(path)：\(error)")
        }
    }()

    nonisolated static let key = ProcessInfo.processInfo.environment["GNW_DEMO_KEY"]

    private static var started = false
    /// 正在框的那一个
    private static var current: Lookup?

    /// 主窗口出现后依次框 plan 里的每一个；每框完一个等 pause 秒（补全、发音、Anki 同步都在这段时间里跑完）
    static func start(_ vm: AnalysisViewModel, context: ModelContext) {
        guard let plan, !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            for (i, lookup) in plan.lookups.enumerated() {
                current = lookup
                await vm.triggerAnalysis(modelContext: context, mode: .capture)
                current = nil
                AppLog.log("[Demo] \(i + 1)/\(plan.lookups.count) done")
                try? await Task.sleep(for: .seconds(plan.pause ?? 15))
            }
            AppLog.log("[Demo] all done")
        }
    }

    /// 代替框选，返回和框选一样的 (带红框的语境图, 选区小图)；没在演示就是 nil
    static func capture() -> (NSImage, NSImage?)? {
        guard let lookup = current else { return nil }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: lookup.screen) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("读不了 \(lookup.screen)") }
        let rect = CGRect(x: lookup.select[0], y: lookup.select[1], width: lookup.select[2], height: lookup.select[3])
        let scale = CGFloat(cg.width) / (NSScreen.main?.frame.width ?? CGFloat(cg.width))
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        return ContextImage.make(from: cg, sourceRect: pixels, scaleX: scale, scaleY: scale,
                                 isSmallSelection: rect.width < 400 || rect.height < 120)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("GNW_DEMO: \(message)\n".utf8))
        exit(2)
    }
}
#endif
