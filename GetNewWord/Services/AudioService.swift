// AudioService.swift
// GetNewWord
//
// 发音服务：
// 1. 优先用真人词典发音（有道 dictvoice，MP3，免费无 key，国内可用），下载后缓存到
//    ~/Library/Application Support/GetNewWord/audio/，同一个词只下一次；Anki 同步也直接用这份 mp3。
// 2. 拿不到（短语、离线、冷门词）时回退到系统 TTS，并显式挑一个该语言的真实语音
//    （之前 AVSpeechSynthesisVoice(language:) 拿不到就静默用默认英文声，德语念得像英语）。

import Foundation
import AVFoundation

final class AudioService: NSObject, @unchecked Sendable {
    static let shared = AudioService()

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var generateCompletion: (() -> Void)?
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - 朗读

    /// 朗读单词：先真人发音（缓存/下载），失败再 TTS
    @MainActor
    func speak(_ text: String, language: Language) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 已缓存 → 直接播
        if let cached = cachedAudioURL(for: trimmed, language: language) {
            play(url: cached)
            return
        }

        // 下载（通常 <1s）；有道没有就用 TTS 生成本地文件（同样缓存，德语等全覆盖），实在不行才现场 TTS
        Task { @MainActor in
            if let path = await generateAudioFile(for: trimmed, language: language) {
                play(url: URL(fileURLWithPath: path))
            } else {
                speakWithTTS(trimmed, language: language)
            }
        }
    }

    /// 兼容旧接口：按 BCP-47 代码朗读（仅 TTS）
    @MainActor
    func speak(_ text: String, languageCode: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice(for: languageCode)
        utterance.rate = 0.45
        synthesizer.speak(utterance)
    }

    @MainActor
    private func speakWithTTS(_ text: String, language: Language) {
        speak(text, languageCode: languageCode(for: language))
    }

    @MainActor
    private func play(url: URL) {
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            AppLog.log("[Audio] play failed \(url.lastPathComponent): \(error)")
        }
    }

    // MARK: - 真人发音（有道）

    /// 有道词典发音接口：英语 type=2 美音 / 1 英音；其他语言用 le=de/fr/ja/ko…
    private func pronunciationURL(for text: String, language: Language) -> URL? {
        guard let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        switch language {
        case .english: return URL(string: "https://dict.youdao.com/dictvoice?audio=\(q)&type=2")
        case .german:  return URL(string: "https://dict.youdao.com/dictvoice?audio=\(q)&le=de")
        case .french:  return URL(string: "https://dict.youdao.com/dictvoice?audio=\(q)&le=fr")
        case .spanish: return URL(string: "https://dict.youdao.com/dictvoice?audio=\(q)&le=es")
        case .japanese: return URL(string: "https://dict.youdao.com/dictvoice?audio=\(q)&le=jap")
        case .korean:  return URL(string: "https://dict.youdao.com/dictvoice?audio=\(q)&le=ko")
        case .chinese: return URL(string: "https://dict.youdao.com/dictvoice?audio=\(q)&le=zh")
        case .other:   return nil
        }
    }

    /// 缓存文件路径（不检查存在性）
    private func audioFileURL(for text: String, language: Language) -> URL {
        let safe = text.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
        return audioDirectoryURL().appendingPathComponent("\(safe)_\(language.rawValue).mp3")
    }

    /// 已缓存的发音文件：先真人 mp3，再 TTS aiff；无效文件（0 音频数据）当场删除等待重新生成
    func cachedAudioURL(for text: String, language: Language) -> URL? {
        let mp3 = audioFileURL(for: text, language: language)
        if isValidAudioFile(mp3) { return mp3 }
        let safe = text.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
        let aiff = audioDirectoryURL().appendingPathComponent("\(safe)_\(languageCode(for: language)).aiff")
        if isValidAudioFile(aiff) { return aiff }
        return nil
    }

    /// 音频文件是否有效（存在且有 >0.1s 的音频数据）；无效则删掉
    private func isValidAudioFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if url.pathExtension == "mp3" {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               (attrs[.size] as? Int ?? 0) > 500 { return true }
        } else if let f = try? AVAudioFile(forReading: url), f.length > 1600 {
            return true
        }
        try? FileManager.default.removeItem(at: url)
        AppLog.log("[Audio] removed invalid audio file \(url.lastPathComponent)")
        return false
    }

    /// 下载真人发音并缓存；四级链路：有道 → 维基词典真人录音 → Google TTS → nil（调用方回退本地 TTS）
    func downloadPronunciation(for text: String, language: Language) async -> URL? {
        let dir = audioDirectoryURL()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = audioFileURL(for: text, language: language)

        // 单词：有道是真人录音，优先；短语：有道是合成音，垫底（真人短语录音全网免费源没有）
        let isPhrase = text.contains(" ")
        if !isPhrase, let u = pronunciationURL(for: text, language: language),
           await downloadAudio(from: u, to: local, label: text) { return local }
        if let u = await commonsPronunciationURL(for: text, language: language),
           await downloadAudio(from: u, to: local, label: text) { return local }
        if let u = await commonsSearchPronunciationURL(for: text, language: language),
           await downloadAudio(from: u, to: local, label: text) { return local }
        if let u = googleTTSURL(for: text, language: language),
           await downloadAudio(from: u, to: local, label: text) { return local }
        if isPhrase, let u = pronunciationURL(for: text, language: language),
           await downloadAudio(from: u, to: local, label: text) { return local }
        return nil
    }

    /// Commons 全文搜索真人录音（兜住大小写变体、En-us-、Lingua Libre 母语录音等）
    private func commonsSearchPronunciationURL(for text: String, language: Language) async -> URL? {
        let accepted: [String]
        switch language {
        case .german: accepted = ["de-", "ll-q188 "]
        case .english: accepted = ["en-us-", "en-uk-", "en-au-", "en-", "ll-q1860 "]
        case .french: accepted = ["fr-", "ll-q150 "]
        case .spanish: accepted = ["es-", "ll-q1321 "]
        default: return nil
        }
        var comps = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        comps.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "list", value: "search"), .init(name: "srnamespace", value: "6"),
            .init(name: "srlimit", value: "8"),
            .init(name: "srsearch", value: "intitle:\"\(text)\" filetype:audio")
        ]
        guard let api = comps.url,
              let (data, _) = try? await session.data(from: api),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let results = query["search"] as? [[String: Any]] else { return nil }
        let needle = "-\(text.lowercased())."
        guard let title = results.compactMap({ $0["title"] as? String }).first(where: { t in
            let lower = t.lowercased()
            guard lower.contains(needle) else { return false }   // 词形必须完全一致（排除变位/复数）
            let name = lower.replacingOccurrences(of: "file:", with: "")
            return accepted.contains { name.hasPrefix($0) || name.contains($0) }
        }) else { return nil }
        // 拿原始地址 → mp3 转码地址
        var infoComps = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        infoComps.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url"),
            .init(name: "titles", value: title)
        ]
        guard let infoAPI = infoComps.url,
              let (d2, _) = try? await session.data(from: infoAPI),
              let j2 = try? JSONSerialization.jsonObject(with: d2) as? [String: Any],
              let q2 = j2["query"] as? [String: Any],
              let pages = q2["pages"] as? [String: Any],
              let page = pages.values.first as? [String: Any],
              let infos = page["imageinfo"] as? [[String: Any]],
              let urlStr = infos.first?["url"] as? String,
              let clean = urlStr.components(separatedBy: "?").first else { return nil }
        let filename = (clean as NSString).lastPathComponent
        return URL(string: clean.replacingOccurrences(of: "/commons/", with: "/commons/transcoded/") + "/\(filename).mp3")
    }

    /// 维基词典真人录音（Wikimedia Commons，母语者；德语覆盖极好）→ mp3 转码地址
    private func commonsPronunciationURL(for text: String, language: Language) async -> URL? {
        let prefix: String
        switch language {
        case .german: prefix = "De"
        case .french: prefix = "Fr"
        case .spanish: prefix = "Es"
        case .english: prefix = "En-us"
        default: return nil
        }
        guard let q = "File:\(prefix)-\(text).ogg".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let api = URL(string: "https://commons.wikimedia.org/w/api.php?action=query&format=json&prop=imageinfo&iiprop=url&titles=\(q)") else { return nil }
        guard let (data, _) = try? await session.data(from: api),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any],
              let page = pages.values.first as? [String: Any],
              let infos = page["imageinfo"] as? [[String: Any]],
              let urlStr = infos.first?["url"] as? String,
              let clean = urlStr.components(separatedBy: "?").first else { return nil }
        // ogg → mp3 转码：…/commons/X/YZ/f.ogg → …/commons/transcoded/X/YZ/f.ogg/f.ogg.mp3
        let filename = (clean as NSString).lastPathComponent
        return URL(string: clean.replacingOccurrences(of: "/commons/", with: "/commons/transcoded/") + "/\(filename).mp3")
    }

    /// Google TTS 免费口（全语言在线兜底，音质好于本地紧凑语音）
    private func googleTTSURL(for text: String, language: Language) -> URL? {
        guard language != .other,
              let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let tl = language == .chinese ? "zh-CN" : language.rawValue
        return URL(string: "https://translate.google.com/translate_tts?ie=UTF-8&q=\(q)&tl=\(tl)&client=tw-ob")
    }

    private func downloadAudio(from remote: URL, to local: URL, label: String) async -> Bool {
        do {
            var req = URLRequest(url: remote)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  (http.mimeType ?? "").contains("audio"), data.count > 500 else {
                AppLog.log("[Audio] \(remote.host ?? "?") no audio for '\(label)' (\((response as? HTTPURLResponse)?.statusCode ?? -1))")
                return false
            }
            try data.write(to: local)
            AppLog.log("[Audio] cached '\(label)' \(data.count / 1024)KB ← \(remote.host ?? "")")
            return true
        } catch {
            AppLog.log("[Audio] download failed '\(label)' from \(remote.host ?? ""): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 生成音频文件（Anki 同步用）

    /// 返回可用于 Anki 的本地音频路径：优先真人发音 mp3，否则用 TTS 写成 aiff
    @MainActor
    func generateAudioFile(for text: String, language: Language) async -> String? {
        if let cached = cachedAudioURL(for: text, language: language) { return cached.path }
        if let downloaded = await downloadPronunciation(for: text, language: language) { return downloaded.path }
        return await generateTTSFile(for: text, language: language)
    }

    @MainActor
    private func generateTTSFile(for text: String, language: Language) async -> String? {
        let langCode = languageCode(for: language)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice(for: langCode)
        utterance.rate = 0.45

        let audioDir = audioDirectoryURL()
        let fm = FileManager.default
        try? fm.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let filename = "\(text.replacingOccurrences(of: " ", with: "_"))_\(langCode).aiff"
        let fileURL = audioDir.appendingPathComponent(filename)
        if isValidAudioFile(fileURL) { return fileURL.path }   // 已有有效文件直接用；无效的已被删掉

        // AVAudioFile 必须显式释放才会把数据段长度写进文件头——否则得到 0 秒的"空壳"aiff（Schutzstreifen 事故）
        final class FileBox { var file: AVAudioFile? }
        let box = FileBox()
        let success: Bool = await withCheckedContinuation { continuation in
            var hasResumed = false

            self.generateCompletion = {
                guard !hasResumed else { return }
                hasResumed = true
                box.file = nil                        // 收尾写盘
                continuation.resume(returning: true)
            }

            synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer, pcmBuffer.frameLength > 0 else { return }
                if box.file == nil {
                    box.file = try? AVAudioFile(forWriting: fileURL, settings: pcmBuffer.format.settings)
                }
                try? box.file?.write(from: pcmBuffer)
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !hasResumed else { return }
                hasResumed = true
                box.file = nil
                self.generateCompletion = nil
                continuation.resume(returning: false)
            }
        }
        self.generateCompletion = nil
        return (success && isValidAudioFile(fileURL)) ? fileURL.path : nil
    }

    // MARK: - 辅助

    /// 挑该语言下最好的系统语音：premium > enhanced > default；没有就退回同语言任意声音
    private func bestVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(languageCode.prefix(2)).lowercased()
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(prefix)
        }
        let exact = candidates.filter { $0.language.caseInsensitiveCompare(languageCode) == .orderedSame }
        let pool = exact.isEmpty ? candidates : exact
        return pool.max { a, b in a.quality.rawValue < b.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: languageCode)
    }

    private func languageCode(for language: Language) -> String {
        switch language {
        case .german: return "de-DE"
        case .english: return "en-US"
        case .chinese: return "zh-CN"
        case .french: return "fr-FR"
        case .spanish: return "es-ES"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .other: return "en-US"
        }
    }

    private func audioDirectoryURL() -> URL {
        AppVariant.supportDirectory.appendingPathComponent("audio")
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AudioService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        generateCompletion?()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        generateCompletion?()
    }
}
