// HotkeyManager.swift
// GetNewWord
//
// 全局快捷键管理器
// 使用 Carbon RegisterEventHotKey API 实现系统级热键注册
// 无需辅助功能权限，任意应用前台时均可触发（最可靠）
//
// 架构说明：
// - Carbon 回调是 C 函数指针（@convention(c)），不能捕获 Swift 上下文
// - 注册时分配递增的 EventHotKeyID.id，handler 存入全局注册表
// - 回调触发时按 id 从注册表查找 handler，派发到主队列执行
// - registry 声明为 nonisolated(unsafe) 绕过 Swift 6 并发检查；
//   写入仅发生在主线程（@MainActor 注册/注销），读取发生在主队列（回调派发），线程安全

import Foundation
import AppKit
import Carbon.HIToolbox

// MARK: - Carbon 热键回调（文件级顶层函数）

/// Carbon 热键按下事件的 C 兼容回调
///
/// 必须是顶层函数（不捕获任何上下文），才能转换为 @convention(c)
/// 传给 InstallEventHandler。handler 通过 HotkeyManager.registry
/// （按 EventHotKeyID.id 索引）查找。
private func carbonHotKeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }

    // 取出热键 ID（kEventParamDirectObject / typeEventHotKeyID）
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return noErr }

    let id = hotKeyID.id
    let pressedAt = GetEventTime(event)

    // 派发到主队列执行，保证 handler 在主线程安全执行
    DispatchQueue.main.async {
        HotkeyManager.lastPressedAt = pressedAt
        HotkeyManager.dispatchHotKey(id: id)
    }

    return noErr
}

// MARK: - HotkeyManager

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    typealias HotkeyHandler = @Sendable () -> Void

    /// 热键签名 'GNWD'（GetNewWord），用于标识本应用注册的热键
    private static let hotKeySignature: UInt32 = 0x474E5744  // 'GNWD'

    // MARK: 全局注册表（供 C 回调查找 handler）

    /// Carbon 回调无法捕获上下文，按 EventHotKeyID.id → handler 索引
    ///
    /// nonisolated(unsafe) 绕过 Swift 6 隔离检查：
    /// 写入仅发生在主线程（@MainActor 的注册/注销方法），
    /// 读取仅发生在主队列（carbonHotKeyCallback 派发的回调），无数据竞争
    nonisolated(unsafe) private static var registry: [UInt32: @Sendable () -> Void] = [:]

    /// 最近一次热键按下的时刻（开机以来的秒数，和 CACurrentMediaTime 同一个钟）：开发版打点从按下那一刻算
    nonisolated(unsafe) static var lastPressedAt: TimeInterval = 0

    /// 由 Carbon 回调（经主队列派发）调用：查找并执行对应热键的 handler
    nonisolated static func dispatchHotKey(id: UInt32) {
        guard let handler = registry[id] else { return }
        handler()
    }

    // MARK: 内部状态

    /// 已注册热键的记录（identifier → Carbon 热键引用）
    private struct HotkeyEntry {
        let id: UInt32
        let ref: EventHotKeyRef
    }

    private var entries: [String: HotkeyEntry] = [:]
    /// 已安装的 Carbon 键盘事件处理器（安装一次，全局复用）
    private var eventHandlerRef: EventHandlerRef?
    /// 下一个分配的热键 ID（从 1 递增）
    private var nextHotKeyID: UInt32 = 1

    private init() {
        installEventHandlerIfNeeded()
    }

    // MARK: - 注册/注销

    /// 注册全局快捷键（系统级热键，无需辅助功能权限）
    /// - Parameters:
    ///   - identifier: 唯一标识符
    ///   - keyCode: 虚拟键码（如 kVK_ANSI_A = 0x00）
    ///   - modifiers: 修饰键，接受 NSEvent.ModifierFlags 组合的 rawValue
    ///                （如 NSEvent.ModifierFlags.command.rawValue | .shift.rawValue），
    ///                也可直接传 Carbon 修饰键常量，内部均会统一转换
    ///   - handler: 快捷键触发回调（在主队列执行）
    func register(identifier: String, keyCode: UInt32, modifiers: UInt32, handler: @escaping HotkeyHandler) {
        // 同 identifier 重复注册：先注销旧热键，避免泄漏与重复触发
        unregister(identifier: identifier)

        installEventHandlerIfNeeded()

        let id = nextHotKeyID
        nextHotKeyID += 1

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            Self.carbonModifiers(from: modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            NSLog("HotkeyManager: 注册热键 '\(identifier)' 失败 (keyCode=\(keyCode), modifiers=0x\(String(modifiers, radix: 16)), status=\(status))")
            return
        }

        entries[identifier] = HotkeyEntry(id: id, ref: ref)
        Self.registry[id] = handler
    }

    /// 注销全局快捷键
    func unregister(identifier: String) {
        guard let entry = entries.removeValue(forKey: identifier) else { return }
        UnregisterEventHotKey(entry.ref)
        Self.registry.removeValue(forKey: entry.id)
    }

    /// 注销所有快捷键
    func unregisterAll() {
        for entry in entries.values {
            UnregisterEventHotKey(entry.ref)
            Self.registry.removeValue(forKey: entry.id)
        }
        entries.removeAll()
        // 保留已安装的事件处理器，后续再次注册热键时可直接复用
    }

    // MARK: - 默认快捷键

    /// 注册截图取词（默认 ⌘⇧A）和指词查词（默认 ⌃⌘A）两组快捷键，各自再多按一个键（默认 ⌥，设置里能换或关掉）
    /// - Parameters:
    ///   - screenshotHandler: 截图取词并自动保存
    ///   - lookupHandler: 截图 + 多按的键：快速查词，只看释义不入库
    ///   - hoverHandler: 指词查词，存不存按设置开关（默认只查）
    ///   - hoverOptionHandler: 指词 + 多按的键：和开关相反
    func registerDefaultHotkeys(
        screenshotHandler: @escaping HotkeyHandler, lookupHandler: @escaping HotkeyHandler,
        hoverHandler: @escaping HotkeyHandler, hoverOptionHandler: @escaping HotkeyHandler
    ) {
        // 用户在设置里录制的组合键；设置变更后由 MainView 重新调用本方法
        registerPair(prefs: .screenshot, identifier: "screenshot", handler: screenshotHandler, extraHandler: lookupHandler)
        registerPair(prefs: .hover, identifier: "hover", handler: hoverHandler, extraHandler: hoverOptionHandler)
        func extra(_ p: HotkeyPrefs) -> String {
            guard let s = p.extraDisplayString else { return "no extra" }
            return p.extraClashes ? "\(s) clashes, not registered" : s
        }
        AppLog.log("[Hotkey] registered \(HotkeyPrefs.screenshot.displayString) 截图取词（+\(extra(.screenshot)) 只查）, \(HotkeyPrefs.hover.displayString) 指词查词（+\(extra(.hover)) 与入库开关相反）")
    }

    /// 组合键本身 → handler；再多按一个键 → extraHandler。关掉了、组合键里本来就有这个键、或和另一组撞了时不注册
    private func registerPair(prefs: HotkeyPrefs, identifier: String, handler: @escaping HotkeyHandler, extraHandler: @escaping HotkeyHandler) {
        register(identifier: identifier, keyCode: prefs.keyCode, modifiers: prefs.modifiers, handler: handler)
        if let mods = prefs.extraModifiers, !prefs.extraClashes {
            register(identifier: identifier + "-extra", keyCode: prefs.keyCode, modifiers: mods, handler: extraHandler)
        } else {
            unregister(identifier: identifier + "-extra")
        }
    }

    // MARK: - Carbon 事件处理器安装

    /// 确保 Carbon 热键事件处理器已安装（只安装一次）
    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: EventClass(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // 顶层函数 carbonHotKeyCallback 不捕获上下文，可转换为 @convention(c)
        let callback: EventHandlerUPP = carbonHotKeyCallback
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &handlerRef
        )

        if status == noErr {
            eventHandlerRef = handlerRef
        } else {
            NSLog("HotkeyManager: InstallEventHandler 失败 (status=\(status))")
        }
    }

    // MARK: - 修饰键转换

    /// 将 NSEvent.ModifierFlags 风格（或 Carbon 风格）的修饰键位掩码转换为 Carbon 修饰键
    ///
    /// NSEvent:  command=0x10000  shift=0x20000  option=0x80000  control=0x40000
    /// Carbon:   cmdKey=0x0100    shiftKey=0x0200 optionKey=0x0800 controlKey=0x1000
    /// 两套常量位值不同，必须显式转换
    private static func carbonModifiers(from modifiers: UInt32) -> UInt32 {
        var carbon: UInt32 = 0

        // NSEvent.ModifierFlags 风格
        if modifiers & UInt32(NSEvent.ModifierFlags.command.rawValue) != 0 { carbon |= UInt32(cmdKey) }
        if modifiers & UInt32(NSEvent.ModifierFlags.shift.rawValue) != 0 { carbon |= UInt32(shiftKey) }
        if modifiers & UInt32(NSEvent.ModifierFlags.option.rawValue) != 0 { carbon |= UInt32(optionKey) }
        if modifiers & UInt32(NSEvent.ModifierFlags.control.rawValue) != 0 { carbon |= UInt32(controlKey) }

        // Carbon 风格（调用者直接传 Carbon 常量时也能正确处理）
        if modifiers & UInt32(cmdKey) != 0 { carbon |= UInt32(cmdKey) }
        if modifiers & UInt32(shiftKey) != 0 { carbon |= UInt32(shiftKey) }
        if modifiers & UInt32(optionKey) != 0 { carbon |= UInt32(optionKey) }
        if modifiers & UInt32(controlKey) != 0 { carbon |= UInt32(controlKey) }

        return carbon
    }
}
