// 快捷键「多按一个键」：默认 ⌥，能换成 ⇧ ⌃ ⌘ 或关掉；组合键里本来就有的键不再加；和另一组撞了不注册

import AppKit
import Testing
@testable import GetNewWord

private let cmd = UInt32(NSEvent.ModifierFlags.command.rawValue)
private let shift = UInt32(NSEvent.ModifierFlags.shift.rawValue)
private let ctrl = UInt32(NSEvent.ModifierFlags.control.rawValue)
private let opt = UInt32(NSEvent.ModifierFlags.option.rawValue)
private let keyA: UInt32 = 0   // kVK_ANSI_A
private let keyS: UInt32 = 1   // kVK_ANSI_S

struct ExtraModifierTests {
    @Test func defaultIsOption() {
        #expect(ExtraModifier.default == .option)
        #expect(ExtraModifier.allCases == [.option, .shift, .control, .command, .off])
        #expect(ExtraModifier.allCases.map(\.symbol) == ["⌥", "⇧", "⌃", "⌘", ""])
        #expect(ExtraModifier.off.flag == nil)
    }

    /// 默认的 ⌘⇧A 再按 ⌥ → ⌥⇧⌘A；换成 ⌃ → ⌃⇧⌘A
    @Test func addsTheChosenKey() {
        #expect(HotkeyPrefs.extraModifiers(base: cmd | shift, extra: .option) == cmd | shift | opt)
        #expect(HotkeyPrefs.extraModifiers(base: cmd | shift, extra: .control) == cmd | shift | ctrl)
        #expect(HotkeyPrefs.display(keyCode: keyA, modifiers: cmd | shift | ctrl) == "⌃⇧⌘A")
    }

    /// 组合键里已经有这个键（⌘⇧A 选 ⇧）、或选了「不用」：没有这一组
    @Test func noExtraWhenTakenOrOff() {
        #expect(HotkeyPrefs.extraModifiers(base: cmd | shift, extra: .shift) == nil)
        #expect(HotkeyPrefs.extraModifiers(base: cmd | shift, extra: .command) == nil)
        #expect(HotkeyPrefs.extraModifiers(base: cmd | shift, extra: .off) == nil)
    }

    /// 截图取词改成 ⌘A、多按 ⌃ → ⌃⌘A，正好是指词查词的默认组合：撞了
    @Test func clashWithOtherBase() {
        let extra = HotkeyCombo(keyCode: keyA, modifiers: cmd | ctrl)
        #expect(HotkeyPrefs.extraClashes(extra, otherBase: HotkeyCombo(keyCode: keyA, modifiers: ctrl | cmd), otherExtra: nil))
    }

    /// 截图 ⌘⇧A + ⌃ 和指词 ⌃⌘A + ⇧ 都是 ⌃⇧⌘A：两组多按的撞了
    @Test func clashBetweenExtras() {
        let shot = HotkeyCombo(keyCode: keyA, modifiers: cmd | shift | ctrl)
        let hoverExtra = HotkeyCombo(keyCode: keyA, modifiers: ctrl | cmd | shift)
        #expect(HotkeyPrefs.extraClashes(shot, otherBase: HotkeyCombo(keyCode: keyA, modifiers: ctrl | cmd), otherExtra: hoverExtra))
    }

    /// 默认两组（⌥⇧⌘A、⌃⌥⌘A）不撞；主键不同也不撞；没有这一组就谈不上撞
    @Test func defaultsDoNotClash() {
        let shotExtra = HotkeyCombo(keyCode: keyA, modifiers: cmd | shift | opt)
        let hoverBase = HotkeyCombo(keyCode: keyA, modifiers: ctrl | cmd)
        let hoverExtra = HotkeyCombo(keyCode: keyA, modifiers: ctrl | cmd | opt)
        #expect(!HotkeyPrefs.extraClashes(shotExtra, otherBase: hoverBase, otherExtra: hoverExtra))
        #expect(!HotkeyPrefs.extraClashes(HotkeyCombo(keyCode: keyS, modifiers: ctrl | cmd), otherBase: hoverBase, otherExtra: nil))
        #expect(!HotkeyPrefs.extraClashes(nil, otherBase: hoverBase, otherExtra: hoverExtra))
    }
}

/// 读写设置（测试宿主自己的 UserDefaults，不是开发版的），一条一条来，跑完还原
@Suite(.serialized) @MainActor
struct HotkeyPrefsStorageTests {
    private let keys = ["hotkeyKeyCode", "hotkeyModifiers", "hotkeyExtraModifier",
                        "hoverHotkeyKeyCode", "hoverHotkeyModifiers", "hoverHotkeyExtraModifier"]

    private func withCleanDefaults(_ body: () throws -> Void) rethrows {
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { UserDefaults.standard.set(v, forKey: k) } }
        try body()
    }

    /// 没设过：⌥，和 1.2.0 一样是 ⌥⇧⌘A / ⌃⌥⌘A
    @Test func unsetMeansOption() {
        withCleanDefaults {
            #expect(HotkeyPrefs.screenshot.extra == .option)
            #expect(HotkeyPrefs.hover.extra == .option)
            #expect(HotkeyPrefs.screenshot.extraDisplayString == "⌥⇧⌘A")
            #expect(HotkeyPrefs.hover.extraDisplayString == "⌃⌥⌘A")
            #expect(!HotkeyPrefs.screenshot.extraClashes)
            #expect(!HotkeyPrefs.hover.extraClashes)
        }
    }

    /// 两组各存各的；存的时候发 hotkeyChanged，HotkeyManager 收到就重新注册
    @Test func savedPerShortcutAndNotifies() {
        withCleanDefaults {
            var notified = 0
            let token = NotificationCenter.default.addObserver(forName: .hotkeyChanged, object: nil, queue: nil) { _ in notified += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            HotkeyPrefs.screenshot.saveExtra(.control)
            HotkeyPrefs.hover.saveExtra(.off)
            #expect(notified == 2)
            #expect(UserDefaults.standard.string(forKey: "hotkeyExtraModifier") == "control")
            #expect(HotkeyPrefs.screenshot.extraDisplayString == "⌃⇧⌘A")
            #expect(HotkeyPrefs.hover.extra == .off)
            #expect(HotkeyPrefs.hover.extraDisplayString == nil)
        }
    }

    /// 截图选 ⌃、指词选 ⇧：都成了 ⌃⇧⌘A，两边都标撞了（都不注册）
    @Test func bothExtrasClash() {
        withCleanDefaults {
            HotkeyPrefs.screenshot.saveExtra(.control)
            HotkeyPrefs.hover.saveExtra(.shift)
            #expect(HotkeyPrefs.screenshot.extraClashes)
            #expect(HotkeyPrefs.hover.extraClashes)
            #expect(HotkeyPrefs.screenshot.other.title == HotkeyPrefs.hover.title)
        }
    }

    /// 存了不认识的值（比如以后的版本写的）按默认 ⌥ 处理
    @Test func unknownValueFallsBack() {
        withCleanDefaults {
            UserDefaults.standard.set("hyper", forKey: "hotkeyExtraModifier")
            #expect(HotkeyPrefs.screenshot.extra == .option)
        }
    }
}
