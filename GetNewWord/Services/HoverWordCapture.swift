// HoverWordCapture.swift
// GetNewWord
//
// 指词查词：不用框选，按快捷键时取鼠标下的那个词。
// 截鼠标所在的屏幕（不含本 App 自己的窗口，钉住的面板盖在词上也不碍事），
// 对光标附近一小块做本地 OCR，按每个词的包围盒找出光标压着的词，
// 再当成用户框了这个词，交给和框选同一套红框语境图（ContextImage）。
// 附近几行的文字一并带回：查词走纯文字请求，不再让模型看图找词。

import AppKit
import NaturalLanguage
import ScreenCaptureKit
@preconcurrency import Vision

enum HoverWordCapture {
    /// 图在后台线程生成后只读不改，跨线程交回主线程是安全的
    struct Shot: @unchecked Sendable {
        let word: String
        /// 光标附近几行屏幕文字（按行从上到下）
        let context: String
        /// en / de / fr / es
        let language: String
        let image: NSImage
    }

    struct Word: Sendable {
        let text: String
        /// 像素坐标，左上角原点
        let rect: CGRect
    }

    /// OCR 范围：光标左右各 450pt、上下各 70pt（够拿到目标词所在的整句）
    private static let ocrHalfWidth: CGFloat = 450
    private static let ocrHalfHeight: CGFloat = 70
    /// 光标落在字母间隙或词边上时，离它这么近（pt）的词也算
    private static let tolerance: CGFloat = 6

    /// 主线程只读鼠标和屏幕参数，截屏、OCR、画红框都在后台做：主线程忙着重绘时不用排队
    @MainActor
    static func capture() async -> Shot? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        return await process(mouse: mouse, frame: screen.frame, backingScale: screen.backingScaleFactor, displayID: displayID)
    }

    private static func process(mouse: NSPoint, frame: NSRect, backingScale: CGFloat, displayID: CGDirectDisplayID) async -> Shot? {
        guard let screenCG = await captureExcludingOwnWindows(displayID: displayID, pixelSize: CGSize(
            width: frame.width * backingScale, height: frame.height * backingScale
        )) else { return nil }
        let scale = CGFloat(screenCG.width) / frame.width
        let cursor = CGPoint(x: (mouse.x - frame.minX) * scale, y: (frame.maxY - mouse.y) * scale)

        let ocrRect = CGRect(
            x: cursor.x - ocrHalfWidth * scale, y: cursor.y - ocrHalfHeight * scale,
            width: 2 * ocrHalfWidth * scale, height: 2 * ocrHalfHeight * scale
        ).intersection(CGRect(x: 0, y: 0, width: screenCG.width, height: screenCG.height)).integral
        guard let ocrCG = screenCG.cropping(to: ocrRect) else { return nil }

        let (words, lines) = await recognizeText(in: ocrCG)
        let local = CGPoint(x: cursor.x - ocrRect.minX, y: cursor.y - ocrRect.minY)
        guard let hit = pick(words, at: local, tolerance: tolerance * scale) else {
            AppLog.log("[Hover] no word at cursor (\(words.count) words nearby)")
            return nil
        }
        let wordRect = hit.rect.offsetBy(dx: ocrRect.minX, dy: ocrRect.minY)
        guard let (image, _) = ContextImage.make(
            from: screenCG, sourceRect: wordRect, scaleX: scale, scaleY: scale, isSmallSelection: true
        ) else { return nil }
        let context = readingOrder(lines).joined(separator: "\n")
        let lang = language(of: context)
        return Shot(word: hit.text, context: context, language: lang, image: image)
    }

    /// 整块图里的文字，按行从上到下（框选取词读框内和语境用）
    static func recognizeLines(in cg: CGImage) async -> [String] {
        readingOrder(await recognizeText(in: cg).lines)
    }

    private static func readingOrder(_ lines: [Word]) -> [String] {
        lines.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }.map(\.text)
    }

    /// Vision 第一次识别要加载模型（约 0.4s），App 启动时先跑一次空图
    static func warmUp() {
        guard let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let blank = ctx.makeImage() else { return }
        Task.detached(priority: .utility) { _ = await recognizeText(in: blank) }
    }

    static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .german, .french, .spanish]
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "en"
    }

    /// 光标压着的词；都没压着时取容差内最近的
    static func pick(_ words: [Word], at point: CGPoint, tolerance: CGFloat) -> Word? {
        if let hit = words.first(where: { $0.rect.contains(point) }) { return hit }
        return words
            .map { ($0, distance(from: point, to: $0.rect)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    private static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 逐词识别（.accurate 才给得出单个词的包围盒，.fast 只有整行），同时带回整行文字
    private static func recognizeText(in cg: CGImage) async -> (words: [Word], lines: [Word]) {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        // Vision 归一化坐标是左下原点
        func pixelRect(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
        }
        return await withCheckedContinuation { cont in
            let request = VNRecognizeTextRequest { req, _ in
                var words: [Word] = []
                var lines: [Word] = []
                for obs in (req.results as? [VNRecognizedTextObservation]) ?? [] {
                    guard let candidate = obs.topCandidates(1).first else { continue }
                    let s = candidate.string
                    lines.append(Word(text: s, rect: pixelRect(obs.boundingBox)))
                    s.enumerateSubstrings(in: s.startIndex..., options: .byWords) { sub, range, _, _ in
                        guard let sub, sub.contains(where: \.isLetter),
                              let box = try? candidate.boundingBox(for: range)?.boundingBox else { return }
                        words.append(Word(text: sub, rect: pixelRect(box)))
                    }
                }
                cont.resume(returning: (words, lines))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            // 带上中文：框选的知识片段可能是中文，只给拉丁语系会读成乱码字母
            request.recognitionLanguages = ["en-US", "de-DE", "fr-FR", "es-ES", "zh-Hans"]
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) } catch { cont.resume(returning: ([], [])) }
            }
        }
    }

    /// 截整块屏幕，去掉本 App 的窗口（结果面板、悬浮球）
    private static func captureExcludingOwnWindows(displayID: CGDirectDisplayID, pixelSize: CGSize) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let pid = ProcessInfo.processInfo.processIdentifier
            let filter = SCContentFilter(
                display: display,
                excludingApplications: content.applications.filter { $0.processID == pid },
                exceptingWindows: []
            )
            let config = SCStreamConfiguration()
            config.width = Int(pixelSize.width)
            config.height = Int(pixelSize.height)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            AppLog.log("[Hover] screen capture failed: \(error.localizedDescription)")
            return nil
        }
    }
}
