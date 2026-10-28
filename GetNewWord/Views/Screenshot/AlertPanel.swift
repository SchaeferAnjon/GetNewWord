// AlertPanel.swift
// GetNewWord
//
// 欧陆词典式浮动错误弹窗：截图分析失败时，在鼠标位置附近弹出一个
// 不抢占焦点的小浮层（NSPanel），8 秒后自动消失。
// 解决主窗口在后台/被遮挡时用户看不到任何错误反馈的问题。

import AppKit
import SwiftUI

// MARK: - "分析中" 浮窗控制器

/// 框选完成后立即在鼠标附近显示"正在分析…"小浮窗，让用户知道 AI 正在工作；
/// 结果面板或错误浮窗出现时由调用方 dismiss。
@MainActor
class LoadingPanelController {
    static let shared = LoadingPanelController()

    private var panel: NSPanel?
    private init() {}

    func show() {
        dismiss()

        let panelSize = NSSize(width: 240, height: 64)
        let content = NSHostingView(rootView: LoadingPanelView())
        content.sizingOptions = []
        content.frame = NSRect(origin: .zero, size: panelSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        if let screen {
            let x = min(max(mouseLocation.x + 16, screen.frame.minX + 10), screen.frame.maxX - panelSize.width - 10)
            let y = min(max(mouseLocation.y - panelSize.height - 16, screen.frame.minY + 10), screen.frame.maxY - panelSize.height - 10)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct LoadingPanelView: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在分析…").font(.headline)
                Text("AI 识别中，通常 5–15 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(width: 240, height: 64)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderStrong, lineWidth: 0.5))
        .appAppearance()
    }
}

// MARK: - 报错：分清是哪种问题，给能直接解决的按钮（design/panels「报错文案」）

enum LookupFailure {
    case noKey, badKey, timeout, network(String), noWord
    /// 余额不足、额度用完、请求太密（402 / 429）
    case quota
    /// 模型名不对（404 / 模型不存在），带当前模型名
    case model(String)
    /// 回复没写完就停了（finish_reason=length）
    case truncated
    /// 回了，但不是约定的 JSON
    case unreadable
    /// 没归类的服务商报错，带它的原话
    case service(String)
    case other(String)

    static func from(_ error: Error) -> LookupFailure {
        switch error {
        case ZhipuServiceError.apiKeyNotConfigured: return .noKey
        case ZhipuServiceError.unauthorized: return .badKey
        case ZhipuServiceError.quotaExceeded: return .quota
        case ZhipuServiceError.modelNotFound: return .model(APIProvider.current.model)
        case ZhipuServiceError.truncated: return .truncated
        case ZhipuServiceError.responseParsingFailed, ZhipuServiceError.invalidResponse, ZhipuServiceError.emptyResponse: return .unreadable
        case ZhipuServiceError.apiError(let message): return .service(message)
        case ZhipuServiceError.networkError(let e as URLError) where e.code == .timedOut: return .timeout
        case ZhipuServiceError.networkError(let e): return .network(e.localizedDescription)
        default: return .other(error.localizedDescription)
        }
    }

    /// 要用户处理的报错不自己消失；只有「没认出词」5 秒后淡出
    var autoDismiss: Bool { if case .noWord = self { return true } else { return false } }

    var badge: String {
        switch self {
        case .noKey: return "key.fill"
        case .badKey: return "key.slash"
        case .timeout: return "clock.fill"
        case .network: return "wifi.slash"
        case .noWord: return "text.viewfinder"
        case .quota: return "creditcard"
        case .model: return "questionmark"
        case .truncated: return "scissors"
        case .unreadable: return "curlybraces"
        case .service, .other: return "exclamationmark"
        }
    }

    func title(_ ai: String) -> String {
        switch self {
        case .noKey: return String(localized: "还没填 \(ai) 的 Key")
        case .badKey: return String(localized: "\(ai) 不认这个 Key")
        case .timeout: return String(localized: "\(ai) 迟迟没回应")
        case .network: return String(localized: "连不上 \(ai)")
        case .noWord: return String(localized: "指针下没认出单词")
        case .quota: return String(localized: "\(ai) 的额度用完了")
        case .model: return String(localized: "\(ai) 找不到这个模型")
        case .truncated: return String(localized: "\(ai) 的回复被截断了")
        case .unreadable: return String(localized: "\(ai) 回的内容读不懂")
        case .service: return String(localized: "\(ai) 这次报错了")
        case .other: return String(localized: "这次没讲成")
        }
    }

    var detail: String {
        switch self {
        case .noKey: return String(localized: "讲解要用你自己的 AI Key。在「设置 › AI 服务」填好，就能接着查词。")
        case .badKey: return String(localized: "可能复制少了几位，或者在官网删掉了。到「设置 › AI 服务」重新粘贴，会自动验证。")
        case .timeout: return String(localized: "已经自动重试过。可能是网络不稳，也可能是它正忙；可以再按一次，或换一家 AI。")
        case .network(let m): return String(localized: "检查一下网络，再按一次快捷键。（\(m)）")
        case .noWord: return String(localized: "把指针停在单词正中间再按 \(HotkeyPrefs.hover.displayString)；字太小就用 \(HotkeyPrefs.screenshot.displayString) 框住它。")
        case .quota: return String(localized: "可能是余额不够，或者短时间里查得太多。到它的后台充值，或者先换一家 AI。")
        case .model(let m): return String(localized: "模型名「\(m)」可能写错了，或者这家已经不提供它。到「设置 › AI 服务」换一个模型。")
        case .truncated: return String(localized: "这次讲得太长，没写完就停了。再按一次，或者框小一点；老是这样就换一家 AI。")
        case .unreadable: return String(localized: "它没按约定的格式回答。再按一次一般就好；老是这样就换个模型，或换一家 AI。")
        case .service(let m): return String(localized: "再按一次试试，老是这样就换一家 AI。它的原话：\(m)")
        case .other(let m): return m
        }
    }
}

@MainActor
class ErrorPanelController {
    static let shared = ErrorPanelController()

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    private var clickMonitor: Any?

    private init() {}

    /// 在鼠标附近（刚取词的地方）显示报错
    func show(_ failure: LookupFailure) {
        dismiss()
        let provider = APIProvider.current
        let panelSize = NSSize(width: 380, height: failure.hasActions ? 166 : 112)
        let view = ErrorPanelView(failure: failure, provider: provider,
                                  onDismiss: { [weak self] in self?.dismiss() },
                                  onHover: { [weak self] inside in self?.pauseAutoDismiss(inside, failure) })
        let content = NSHostingView(rootView: view)
        content.sizingOptions = []
        content.frame = NSRect(origin: .zero, size: panelSize)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.contentView = content
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            let x = min(max(mouse.x + 16, vf.minX + 10), vf.maxX - panelSize.width - 10)
            let y = min(max(mouse.y - panelSize.height - 16, vf.minY + 10), vf.maxY - panelSize.height - 10)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        // 点别处就关（和查词面板一样）；要处理的报错不靠计时消失
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in ErrorPanelController.shared.dismiss() }
        }
        if failure.autoDismiss { scheduleDismiss() }
    }

    /// 兼容只有一句话的旧调用
    func show(message: String) { show(.other(message)) }

    private func scheduleDismiss() {
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// 鼠标放上去就停住计时，移开再重新计
    private func pauseAutoDismiss(_ inside: Bool, _ failure: LookupFailure) {
        guard failure.autoDismiss else { return }
        dismissWorkItem?.cancel()
        if !inside { scheduleDismiss() }
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }
}

struct ErrorPanelView: View {
    let failure: LookupFailure
    let provider: APIProvider
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if case .noWord = failure {
                        Image(nsImage: NSApp.applicationIconImage).resizable()
                    } else {
                        ProviderLogo(provider: provider, size: 22)
                            .frame(width: 34, height: 34)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(width: 34, height: 34)
                Image(systemName: failure.badge)
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Theme.warn, in: Circle())
                    .overlay(Circle().stroke(Theme.elevated, lineWidth: 1.5))
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.title(provider.displayName)).font(.system(size: 14, weight: .semibold))
                Text(failure.detail).font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)   // 英文、德文常要四行
                Spacer(minLength: 6)
                buttons
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text2)
                    .frame(width: 20, height: 20).background(Theme.selected, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 380, height: failure.hasActions ? 166 : 112, alignment: .topLeading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderStrong, lineWidth: 0.5))
        .onHover(perform: onHover)
        .appAppearance()
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            switch failure {
            case .noKey, .badKey:
                Button(failure.isNoKey ? "去填 Key" : "去换 Key") { onDismiss(); SettingsOpener.open(.ai) }
                    .buttonStyle(PrimaryButtonStyle())
                if let url = provider.keyPage {
                    Button("怎么拿 Key") { NSWorkspace.shared.open(url) }.buttonStyle(SecondaryButtonStyle())
                }
            case .quota:
                Button("换一家 AI") { onDismiss(); SettingsOpener.open(.ai) }.buttonStyle(PrimaryButtonStyle())
                if let url = provider.keyPage {
                    Button("打开它的后台") { NSWorkspace.shared.open(url) }.buttonStyle(SecondaryButtonStyle())
                }
            case .model:
                Button("去改模型") { onDismiss(); SettingsOpener.open(.ai) }.buttonStyle(PrimaryButtonStyle())
            case .timeout, .network, .truncated, .unreadable, .service:
                Button("换一家 AI") { onDismiss(); SettingsOpener.open(.ai) }.buttonStyle(SecondaryButtonStyle())
            case .noWord, .other:
                EmptyView()
            }
        }
    }
}

private extension LookupFailure {
    var isNoKey: Bool { if case .noKey = self { return true } else { return false } }
    /// 有没有解决按钮：没有就把面板收矮
    var hasActions: Bool {
        switch self {
        case .noKey, .badKey, .timeout, .network, .quota, .model, .truncated, .unreadable, .service: return true
        case .noWord, .other: return false
        }
    }
}
