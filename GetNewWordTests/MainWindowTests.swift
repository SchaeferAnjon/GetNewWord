// 主窗口：关掉后应用不退出，留在菜单栏（快捷键照常查词，菜单栏「打开主窗口」再打开）

import AppKit
import Testing
@testable import GetNewWord

@MainActor
struct MainWindowTests {
    @Test func closingLastWindowKeepsAppRunning() {
        #expect(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)
    }
}
