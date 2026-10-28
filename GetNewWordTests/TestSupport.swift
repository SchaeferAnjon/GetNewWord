// 测试共用：内存里的词库、按名字比较报错种类

import Foundation
import SwiftData
@testable import GetNewWord

/// 和应用同一套模型定义，只放在内存里
@MainActor
func makeLibrary() throws -> ModelContext {
    let schema = Schema([WordEntry.self, WordContext.self, KnowledgeSnippet.self, Category.self])
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    let context = ModelContext(container)
    // ModelContext 不持有 container：存起来，测试期间别被释放
    retainedContainers.append(container)
    return context
}

@MainActor private var retainedContainers: [ModelContainer] = []

/// 枚举的种类名，不带关联值：.network("…") → "network"
func caseName(_ value: Any) -> String {
    String(String(describing: value).prefix { $0 != "(" })
}

/// 测试专用的临时文件夹，用完自己删
func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GetNewWordTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
