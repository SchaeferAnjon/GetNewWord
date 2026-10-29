// HotkeyRecorderView.swift
// GetNewWord
//
// 快捷键录制控件：点击后按下组合键即录入，存到 UserDefaults（keyCode + modifiers），
// HotkeyManager 监听变化后重新注册 Carbon 热键。

import SwiftUI
import AppKit
import Carbon.HIToolbox

/// 快捷键再多按的那一个修饰键：截图取词这一次只查不存，指词查词这一次和「加入词库」开关反着来。
/// 默认 ⌥；⌥ 不好按的可以换成 ⇧ ⌃ ⌘，或者关掉不要这一组
enum ExtraModifier: String, CaseIterable, Identifiable, Sendable {
    case option, shift, control, command, off

    static let `default` = ExtraModifier.option
    var id: String { rawValue }

    /// NSEvent.ModifierFlags 的位；关掉时没有
    var flag: UInt32? {
        switch self {
        case .option: return UInt32(NSEvent.ModifierFlags.option.rawValue)
        case .shift: return UInt32(NSEvent.ModifierFlags.shift.rawValue)
        case .control: return UInt32(NSEvent.ModifierFlags.control.rawValue)
        case .command: return UInt32(NSEvent.ModifierFlags.command.rawValue)
        case .off: return nil
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .shift: return "⇧"
        case .control: return "⌃"
        case .command: return "⌘"
        case .off: return ""
        }
    }

    /// 键帽下面的小字：键名
    var keyName: String {
        switch self {
        case .option: return "Option"
        case .shift: return "Shift"
        case .control: return "Control"
        case .command: return "Command"
        case .off: return String(localized: "不用")
        }
    }
}

/// 一组可录制的全局快捷键（UserDefaults 里 keyCode + modifiers 两个键，再加一个「多按的那个键」）
struct HotkeyPrefs: Sendable {
    let keyCodeKey: String
    let modifiersKey: String
    let extraKey: String
    let defaultKeyCode: UInt32
    let defaultModifiers: UInt32

    /// 截图取词：默认 ⌘⇧A
    static let screenshot = HotkeyPrefs(
        keyCodeKey: "hotkeyKeyCode", modifiersKey: "hotkeyModifiers", extraKey: "hotkeyExtraModifier",
        defaultKeyCode: UInt32(kVK_ANSI_A),
        defaultModifiers: UInt32(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue)
    )
    /// 指词取词（直接取鼠标下的词，不用框选）：默认 ⌃⌘A
    static let hover = HotkeyPrefs(
        keyCodeKey: "hoverHotkeyKeyCode", modifiersKey: "hoverHotkeyModifiers", extraKey: "hoverHotkeyExtraModifier",
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

    /// 多按的那个键（没设过就是 ⌥）
    var extra: ExtraModifier {
        UserDefaults.standard.string(forKey: extraKey).flatMap(ExtraModifier.init(rawValue:)) ?? .default
    }
    func saveExtra(_ e: ExtraModifier) {
        UserDefaults.standard.set(e.rawValue, forKey: extraKey)
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
    }

    /// 组合键再加那个键后的修饰键；关掉了、或组合键里本来就有这个键时没有这一组
    static func extraModifiers(base: UInt32, extra: ExtraModifier) -> UInt32? {
        guard let flag = extra.flag, base & flag == 0 else { return nil }
        return base | flag
    }
    var extraModifiers: UInt32? { Self.extraModifiers(base: modifiers, extra: extra) }

    /// 多按一个键那一组的显示串（如 ⌥⇧⌘A），没有这一组时是 nil
    var extraDisplayString: String? { extraModifiers.map { Self.display(keyCode: keyCode, modifiers: $0) } }

    var combo: HotkeyCombo { HotkeyCombo(keyCode: keyCode, modifiers: modifiers) }
    var extraCombo: HotkeyCombo? { extraModifiers.map { HotkeyCombo(keyCode: keyCode, modifiers: $0) } }

    /// 截图取词 / 指词查词
    var title: String { keyCodeKey == Self.hover.keyCodeKey ? String(localized: "指词查词") : String(localized: "截图取词") }
    /// 另一组快捷键
    var other: HotkeyPrefs { keyCodeKey == Self.hover.keyCodeKey ? .screenshot : .hover }

    /// 多按一个键那一组撞上了另一组的组合键（或另一组多按的那组）：撞了就不注册，设置里标出来
    static func extraClashes(_ extra: HotkeyCombo?, otherBase: HotkeyCombo, otherExtra: HotkeyCombo?) -> Bool {
        guard let extra else { return false }
        return extra == otherBase || extra == otherExtra
    }
    var extraClashes: Bool { Self.extraClashes(extraCombo, otherBase: other.combo, otherExtra: other.extraCombo) }

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
            UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
            UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
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

/// 一个全局组合键：主键 + 修饰键（NSEvent.ModifierFlags 的位）
struct HotkeyCombo: Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
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

/// 设置页里选「多按的那个键」：⌥ ⇧ ⌃ ⌘ 四个键帽和「不用」，画法同上面的大键帽；组合键里已经有的键点不了。
/// 下面一行小字说现在多按以后是哪一组，和另一组撞了用橙色标出来
struct ExtraModifierPicker: View {
    let prefs: HotkeyPrefs
    @State private var extra: ExtraModifier
    /// 组合键在上面改了（HotkeyKeyCaps 录了新的），这里跟着重算
    @State private var revision = 0

    init(prefs: HotkeyPrefs) {
        self.prefs = prefs
        _extra = State(initialValue: prefs.extra)
    }

    var body: some View {
        let _ = revision
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(ExtraModifier.allCases) { e in cap(e) }
            }
            Text(status)
                .font(.system(size: 11.5))
                .foregroundStyle(prefs.extraClashes ? Theme.warn : Theme.text3)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hotkeyChanged)) { _ in
            extra = prefs.extra
            revision += 1
        }
    }

    private func cap(_ e: ExtraModifier) -> some View {
        let selected = extra == e
        let taken = e.flag.map { prefs.modifiers & $0 != 0 } ?? false
        return Button {
            extra = e
            prefs.saveExtra(e)
        } label: {
            Group {
                if e == .off { Text("不用").font(.system(size: 12, weight: .medium)) }
                else { Text(e.symbol).font(.system(size: 15, weight: .medium)) }
            }
            .foregroundStyle(selected ? Theme.accent : Theme.text)
            .frame(minWidth: 30, minHeight: 30)
            .padding(.horizontal, e == .off ? 8 : 0)
            .background(selected ? Theme.accentSoft.opacity(0.5) : Theme.elevated, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Theme.accent : Theme.borderStrong, lineWidth: selected ? 1.5 : 0.5))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(taken && !selected)
        .opacity(taken ? 0.35 : 1)
        .help(taken ? String(localized: "组合键里已经有 \(e.symbol)") : e.keyName)
        .accessibilityLabel(e == .off ? String(localized: "不用") : e.keyName)
    }

    private var status: String {
        if extra == .off { return String(localized: "不用多按的这一组") }
        guard let combo = prefs.extraDisplayString else { return String(localized: "组合键里已经有 \(extra.symbol)，换一个键") }
        if prefs.extraClashes {
            return String(localized: "和「\(prefs.other.title)」的 \(combo) 撞了，这一组不会生效")
        }
        return String(localized: "现在是 \(combo)")
    }
}
