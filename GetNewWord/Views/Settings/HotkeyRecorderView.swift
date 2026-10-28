// HotkeyRecorderView.swift
// GetNewWord
//
// 快捷键录制控件：点击后按下组合键即录入，存到 UserDefaults（keyCode + modifiers），
// HotkeyManager 监听变化后重新注册 Carbon 热键。

import SwiftUI
import AppKit
import Carbon.HIToolbox

/// 一组可录制的全局快捷键（UserDefaults 里 keyCode + modifiers 两个键）
struct HotkeyPrefs: Sendable {
    let keyCodeKey: String
    let modifiersKey: String
    let defaultKeyCode: UInt32
    let defaultModifiers: UInt32

    /// 截图取词：默认 ⌘⇧A
    static let screenshot = HotkeyPrefs(
        keyCodeKey: "hotkeyKeyCode", modifiersKey: "hotkeyModifiers",
        defaultKeyCode: UInt32(kVK_ANSI_A),
        defaultModifiers: UInt32(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue)
    )
    /// 指词取词（直接取鼠标下的词，不用框选）：默认 ⌃⌘A
    static let hover = HotkeyPrefs(
        keyCodeKey: "hoverHotkeyKeyCode", modifiersKey: "hoverHotkeyModifiers",
        defaultKeyCode: UInt32(kVK_ANSI_A),
        defaultModifiers: UInt32(NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.command.rawValue)
    )

    var keyCode: UInt32 {
        let v = UserDefaults.standard.integer(forKey: keyCodeKey)
        return UserDefaults.standard.object(forKey: keyCodeKey) == nil ? defaultKeyCode : UInt32(v)
    }
    var modifiers: UInt32 {
        let v = UserDefaults.standard.integer(forKey: modifiersKey)
        return UserDefaults.standard.object(forKey: modifiersKey) == nil ? defaultModifiers : UInt32(v)
    }
    func save(keyCode: UInt32, modifiers: UInt32) {
        UserDefaults.standard.set(Int(keyCode), forKey: keyCodeKey)
        UserDefaults.standard.set(Int(modifiers), forKey: modifiersKey)
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
    }
    func reset() { save(keyCode: defaultKeyCode, modifiers: defaultModifiers) }

    /// "⌘⇧A" 这样的显示串
    var displayString: String { Self.display(keyCode: keyCode, modifiers: modifiers) }

    static func display(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        let f = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + keyName(keyCode)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        let special: [UInt32: String] = [
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Escape): "⎋",
            UInt32(kVK_Delete): "⌫", UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→"
        ]
        if let n = special[keyCode] { return n }
        // 用当前键盘布局把 keyCode 翻成字符
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buf -> OSStatus in
            UCKeyTranslate(buf.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self),
                           UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("GetNewWord.hotkeyChanged")
}

// MARK: - SwiftUI 控件

struct HotkeyRecorderView: View {
    let prefs: HotkeyPrefs
    @State private var recording = false
    @State private var display: String

    init(prefs: HotkeyPrefs) {
        self.prefs = prefs
        _display = State(initialValue: prefs.displayString)
    }

    var body: some View {
        HStack(spacing: 8) {
            RecorderButton(recording: $recording) { keyCode, mods in
                prefs.save(keyCode: keyCode, modifiers: mods)
                display = prefs.displayString
                recording = false
            }
            .frame(width: 140, height: 26)
            .overlay(
                Text(recording ? String(localized: "按下组合键…") : display)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(recording ? Color.accentColor : .primary)
                    .allowsHitTesting(false)
            )
            Button("重置") {
                prefs.reset()
                display = prefs.displayString
            }
            .controlSize(.small)
        }
    }
}

/// 承接键盘事件的 NSView（点击后成为 first responder，keyDown 即录入）
struct RecorderButton: NSViewRepresentable {
    @Binding var recording: Bool
    /// false：透明地盖在键帽上，外观由 SwiftUI 画
    var drawsBackground = true
    let onRecord: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let v = RecorderNSView()
        v.drawsBackground = drawsBackground
        v.onRecord = onRecord
        v.onRecordingChanged = { recording = $0 }
        return v
    }
    func updateNSView(_ nsView: RecorderNSView, context: Context) {}
}

final class RecorderNSView: NSView {
    var onRecord: ((UInt32, UInt32) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var drawsBackground = true
    private var isRecording = false { didSet { onRecordingChanged?(isRecording); needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); isRecording = true }
    override func resignFirstResponder() -> Bool { isRecording = false; return true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == UInt16(kVK_Escape) { isRecording = false; window?.makeFirstResponder(nil); return }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // 至少要一个修饰键，避免把普通打字键当全局热键
        guard !mods.isEmpty else { NSSound.beep(); return }
        onRecord?(UInt32(event.keyCode), UInt32(mods.rawValue))
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard drawsBackground else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// 设置页里的大键帽：点一下进入录制，按下新组合键立即生效
struct HotkeyKeyCaps: View {
    let prefs: HotkeyPrefs
    @State private var recording = false
    @State private var display: String

    init(prefs: HotkeyPrefs) {
        self.prefs = prefs
        _display = State(initialValue: prefs.displayString)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ZStack {
                if recording {
                    Text("按下组合键…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 150, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else {
                    KeyCaps(combo: display)
                }
            }
            .overlay(RecorderButton(recording: $recording, drawsBackground: false) { keyCode, mods in
                prefs.save(keyCode: keyCode, modifiers: mods)
                display = prefs.displayString
                recording = false
            })
            HStack(spacing: 8) {
                Text(recording ? "Esc 取消" : "点键帽可以改").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                if display != HotkeyPrefs.display(keyCode: prefs.defaultKeyCode, modifiers: prefs.defaultModifiers) {
                    Button("恢复默认") { prefs.reset(); display = prefs.displayString }
                        .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}
