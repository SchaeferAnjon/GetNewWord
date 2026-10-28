// 测试本身不能碰开发版的数据：数据目录在临时文件夹，bundle id 和开发版不同（make test）

import Foundation
import Testing
@testable import GetNewWord

struct TestIsolationTests {
    @Test func dataGoesToTemporaryFolder() {
        #expect(AppVariant.isUnitTesting)
        let support = AppVariant.supportDirectory.standardizedFileURL.path
        #expect(support.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
        #expect(!support.contains("Application Support"))
    }

    @Test func notTheInstalledApp() {
        #expect(AppVariant.isDev)
        #expect(AppVariant.bundleID != "com.getnewword.app")
    }
}
