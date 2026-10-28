// SettingsIllustrations.swift
// GetNewWord
//
// 设置页和欢迎页顶上的示意图：画出这一页的设置管的是什么。
// 动画用 .task 里的循环推进 phase，视图消失时随 task 取消停下；尺寸固定，不让布局跳。

import SwiftUI
import AppKit

// MARK: - 示例句：一句德语，按翻译语言给释义和整句译文

enum DemoSentence {
    static let word = "Nachhaltigkeit"

    static func meaning(_ t: TargetLanguage) -> String {
        switch t {
        case .zhHans: return "可持续性"
        case .zhHant: return "永續性"
        case .en: return "sustainability"
        case .de: return "Fähigkeit, dauerhaft ohne Schaden zu bestehen"
        case .fr: return "durabilité"
        case .es: return "sostenibilidad"
        case .ja: return "持続可能性"
        case .ko: return "지속 가능성"
        }
    }

    static func translation(_ t: TargetLanguage) -> String {
        switch t {
        case .zhHans: return "研究表明，供应链的可持续性明显提高了。"
        case .zhHant: return "研究顯示，供應鏈的永續性明顯提升了。"
        case .en: return "The study shows supply chains have become noticeably more sustainable."
        case .de: return "Die Studie belegt: Lieferketten sind heute deutlich nachhaltiger."
        case .fr: return "L'étude montre que la durabilité des chaînes d'approvisionnement a nettement progressé."
        case .es: return "El estudio muestra que la sostenibilidad de las cadenas de suministro ha aumentado claramente."
        case .ja: return "研究によると、サプライチェーンの持続可能性は大きく高まっている。"
        case .ko: return "연구에 따르면 공급망의 지속 가능성이 크게 높아졌다."
        }
    }
}

/// 白底小卡片里的原句，目标词可加框或高亮。分行写死，框才能正好套在词上
private struct SentenceCard: View {
    var boxed = false
    var highlighted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("Die Studie zeigt, dass die ")
                Text(DemoSentence.word)
                    .foregroundStyle(highlighted || boxed ? Theme.text : Theme.text2)
                    .padding(.horizontal, 2)
                    .background(highlighted ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 3))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                            .padding(-2)
                            .opacity(boxed ? 1 : 0)
                    }
            }
            Text("der Lieferketten deutlich")
            Text("zugenommen hat.")
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.text2)
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
    }
}

/// 查词弹窗
struct LookupPopup: View {
    let target: TargetLanguage
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(DemoSentence.word).font(.system(size: 13, weight: .semibold))
                Text("die · 名词").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            Text(DemoSentence.meaning(target)).font(.system(size: 12.5)).foregroundStyle(Theme.accent)
            if !compact {
                Text(DemoSentence.translation(target))
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 210, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
    }
}

// MARK: - 翻译语言：选哪种，弹窗就换成哪种

struct TranslateIllustration: View {
    let target: TargetLanguage
    var body: some View {
        Stage(height: 150) {
            HStack(alignment: .center, spacing: -16) {
                SentenceCard(highlighted: true).offset(y: -12)
                LookupPopup(target: target)
                    .id(target)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                    .offset(y: 16)
            }
            .animation(.easeOut(duration: 0.25), value: target)
        }
    }
}

// MARK: - 截图取词：框住词 → 弹出讲解，循环

struct CaptureIllustration: View {
    let target: TargetLanguage
    @State private var phase = 0   // 0 只有句子，1 框住，2 弹出讲解

    var body: some View {
        Stage(height: 150) {
            HStack(spacing: -16) {
                SentenceCard(boxed: phase >= 1).offset(y: -14)
                LookupPopup(target: target)
                    .opacity(phase >= 2 ? 1 : 0)
                    .offset(y: phase >= 2 ? 18 : 26)
            }
        }
        .task {
            while !Task.isCancelled {
                for (p, wait) in [(0, 0.9), (1, 0.8), (2, 2.4)] {
                    withAnimation(.easeOut(duration: 0.3)) { phase = p }
                    try? await Task.sleep(for: .seconds(wait))
                }
            }
        }
    }
}

// MARK: - 指词查词：视频字幕上，鼠标停到词上 → 弹出释义，空格照常控制视频

struct PointIllustration: View {
    let target: TargetLanguage
    @State private var phase = 0   // 0 鼠标在远处，1 停在词上，2 弹出

    var body: some View {
        Stage(height: 130) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.09))
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: "pause.fill").font(.system(size: 9))
                        Text("12:41").font(.system(size: 10.5).monospacedDigit())
                        Spacer()
                    }
                    .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    HStack(spacing: 0) {
                        Text("…dass die ")
                        Text("Lieferketten")
                            .padding(.horizontal, 3)
                            .background(phase >= 1 ? Theme.accent.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 3))
                        Text(" wachsen")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                }
                .padding(12)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .offset(x: phase >= 1 ? 6 : 120, y: phase >= 1 ? 44 : 10)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Lieferkette").font(.system(size: 12.5, weight: .semibold))
                        Text("die").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                    Text(Self.meaning(target)).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    Text("空格照常控制视频").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .offset(x: 120, y: -14)
                .opacity(phase >= 2 ? 1 : 0)
            }
            .frame(width: 440)
            .padding(.vertical, 10)
        }
        .task {
            while !Task.isCancelled {
                for (p, wait) in [(0, 0.9), (1, 0.7), (2, 2.4)] {
                    withAnimation(.easeInOut(duration: 0.4)) { phase = p }
                    try? await Task.sleep(for: .seconds(wait))
                }
            }
        }
    }

    static func meaning(_ t: TargetLanguage) -> String {
        switch t {
        case .zhHans: return "供应链"
        case .zhHant: return "供應鏈"
        case .en: return "supply chain"
        case .de: return "Kette von Lieferanten bis zum Kunden"
        case .fr: return "chaîne d'approvisionnement"
        case .es: return "cadena de suministro"
        case .ja: return "サプライチェーン"
        case .ko: return "공급망"
        }
    }
}

// MARK: - 三个节点连成一条路：AI 怎么走、Anki 连没连上、两台 Mac 同步

struct NodeBadge: View {
    enum Icon { case app, symbol(String), provider(APIProvider), image(NSImage) }
    let icon: Icon
    let label: String
    var dimmed = false
    var width: CGFloat = 86

    var body: some View {
        VStack(spacing: 6) {
            Group {
                switch icon {
                case .app:
                    Image(nsImage: NSApp.applicationIconImage).resizable()
                case .symbol(let name):
                    Image(systemName: name).font(.system(size: 15)).foregroundStyle(Theme.text2)
                        .frame(width: 32, height: 32)
                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 0.5))
                case .provider(let p):
                    ProviderLogo(provider: p, size: 22)
                        .frame(width: 32, height: 32)
                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 0.5))
                case .image(let img):
                    Image(nsImage: img).resizable()
                }
            }
            .frame(width: 34, height: 34)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1).minimumScaleFactor(0.8)
        }
        .opacity(dimmed ? 0.45 : 1)
        .frame(width: width)
    }
}

/// 两点之间的连线：连上是实线并有小点流过，没连上是虚线
struct FlowLine: View {
    var active: Bool
    var width: CGFloat = 60
    @State private var t: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            if active {
                Rectangle().fill(Theme.accent.opacity(0.5)).frame(height: 1.5)
                Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(x: t * (width - 5))
            } else {
                Line().stroke(Theme.borderStrong, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])).frame(height: 1.5)
            }
        }
        .frame(width: width, height: 6)
        .padding(.bottom, 18)
        .onAppear {
            guard active else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { t = 1 }
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path(); p.move(to: CGPoint(x: 0, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); return p
        }
    }
}

struct AIRouteIllustration: View {
    let provider: APIProvider
    var body: some View {
        HStack(spacing: 0) {
            NodeBadge(icon: .app, label: "GetNewWord", width: 60)
            FlowLine(active: true, width: 16)
            NodeBadge(icon: .symbol("key"), label: String(localized: "你的 Key"), width: 60)
            FlowLine(active: true, width: 16)
            NodeBadge(icon: .provider(provider), label: provider.displayName, width: 60)
        }
    }
}

struct AnkiLinkIllustration: View {
    let connected: Bool
    var body: some View {
        Stage(height: 130) {
            VStack(spacing: 10) {
                HStack(spacing: 0) {
                    NodeBadge(icon: .app, label: "GetNewWord")
                    FlowLine(active: connected, width: 50)
                    HStack(spacing: 5) {
                        Circle().fill(connected ? Theme.ok : Theme.warn).frame(width: 6, height: 6)
                        Text("AnkiConnect").font(.system(size: 11))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.elevated, in: Capsule())
                    .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 0.5))
                    .padding(.bottom, 18)
                    FlowLine(active: connected, width: 50)
                    NodeBadge(icon: Self.ankiIcon.map { .image($0) } ?? .symbol("rectangle.stack"), label: "Anki")
                }
                Text(connected ? "已连上 · 查过的词会自动做成卡片" : "还没连上 · Anki 没打开，或没装插件")
                    .font(.system(size: 12))
                    .foregroundStyle(connected ? Theme.ok : Theme.warn)
            }
            .id(connected)
        }
    }

    /// 装了 Anki 就用它自己的图标
    static var ankiIcon: NSImage? {
        AnkiInstaller.shared.ankiApp.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

struct PermissionIllustration: View {
    let granted: Bool
    @State private var on = false

    var body: some View {
        Stage(height: 130) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                        Circle().fill($0).frame(width: 8, height: 8)
                    }
                    Text("系统设置 › 隐私与安全性").font(.system(size: 11)).foregroundStyle(Theme.text3).padding(.leading, 6)
                }
                .padding(10)
                Hairline()
                VStack(alignment: .leading, spacing: 8) {
                    Text("录屏与系统录音").font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 8) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 18, height: 18)
                        Text(AppVariant.isDev ? "GetNewWord Dev" : "GetNewWord").font(.system(size: 12))
                        Spacer()
                        Toggle("", isOn: .constant(on)).toggleStyle(.square).labelsHidden().allowsHitTesting(false)
                    }
                    .padding(8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(10)
            }
            .frame(width: 320)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
        .task(id: granted) {
            // 已授权就一直开着；没授权就演示「去这里打开它」
            if granted { on = true; return }
            while !Task.isCancelled {
                on = false
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation { on = true }
                try? await Task.sleep(for: .seconds(1.8))
            }
        }
    }
}

struct SyncIllustration: View {
    let active: Bool
    var body: some View {
        Stage(height: 100) {
            HStack(spacing: 0) {
                NodeBadge(icon: .symbol("laptopcomputer"), label: String(localized: "这台 Mac"))
                FlowLine(active: active, width: 70)
                Image(systemName: "cloud").font(.system(size: 14)).foregroundStyle(Theme.text2)
                    .frame(width: 32, height: 32).background(Theme.elevated, in: Circle())
                    .overlay(Circle().stroke(Theme.border, lineWidth: 0.5))
                    .padding(.bottom, 18)
                FlowLine(active: active, width: 70)
                NodeBadge(icon: .symbol("laptopcomputer"), label: String(localized: "另一台"), dimmed: !active)
            }
        }
    }
}
