// 匿名报到：只在同意后发、一天一次、发的内容只有这几项，失败不算报过；开发版不发，除非设了 GETNEWWORD_API

import Foundation
import Testing
@testable import GetNewWord

@MainActor
struct UsagePingTests {
    /// 记下发出去的请求，按 status 回话
    final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
        var status = 204
        var error: Error?
    }

    private func makePing(dir: URL, endpoint: URL? = URL(string: "http://127.0.0.1:9/v1/ping"), consent: @escaping () -> Bool = { true },
                          day: @escaping () -> Date = Date.init, recorder: Recorder) -> UsagePing {
        UsagePing(file: dir.appendingPathComponent("usage-ping.json"), endpoint: endpoint, enabled: consent, now: day) { request in
            recorder.requests.append(request)
            if let error = recorder.error { throw error }
            return recorder.status
        }
    }

    @Test func sendsOnlyTheAgreedFieldsOncePerDay() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = Recorder()
        let ping = makePing(dir: dir, recorder: recorder)
        // 装好后第一次启动就有随机编号（没有地址的那份只记编号，不开定时）
        makePing(dir: dir, endpoint: nil, recorder: recorder).start()
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: ping.file)) as? [String: Any]
        let id = try #require(saved?["id"] as? String)
        #expect(UUID(uuidString: id) != nil)

        #expect(await ping.tick() == .sent)
        #expect(await ping.tick() == .done)
        #expect(recorder.requests.count == 1)

        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://127.0.0.1:9/v1/ping")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 10)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(Set(body.keys) == ["id", "version", "platform", "arch", "plan", "lang", "product"])
        #expect(body["id"] == id)
        #expect(body["platform"] == "darwin")
        #expect(["arm64", "x64"].contains(body["arch"]))
        #expect(["member", "own"].contains(body["plan"]))
        #expect(["zh", "en", "de"].contains(body["lang"]))
        #expect(body["product"] == "getnewword")
        #expect(body["version"] == Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    @Test func nothingWithoutConsent() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = Recorder()
        #expect(await makePing(dir: dir, consent: { false }, recorder: recorder).tick() == .off)
        #expect(recorder.requests.isEmpty)
    }

    /// 断网、服务器报错都不算今天报过，下次再试；第二天还报，编号不变
    @Test func failureRetriesAndNextDaySendsAgain() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = Recorder()
        var today = Date(timeIntervalSince1970: 1_790_000_000)
        let ping = makePing(dir: dir, day: { today }, recorder: recorder)

        recorder.error = URLError(.timedOut)
        #expect(await ping.tick() == .failed)
        recorder.error = nil
        recorder.status = 500
        #expect(await ping.tick() == .failed)
        recorder.status = 204
        #expect(await ping.tick() == .sent)
        today = today.addingTimeInterval(86_400)
        #expect(await ping.tick() == .sent)
        #expect(recorder.requests.count == 4)
        let ids = try recorder.requests.map { try JSONDecoder().decode(UsagePing.Body.self, from: $0.httpBody ?? Data()).id }
        #expect(Set(ids).count == 1)
    }

    @Test func endpoint() {
        #expect(UsagePing.endpoint(environment: [:], isDev: false)?.absoluteString == "https://api.us-cloud.uk/v1/ping")
        #expect(UsagePing.endpoint(environment: [:], isDev: true) == nil)
        #expect(UsagePing.endpoint(environment: ["GETNEWWORD_API": "http://127.0.0.1:8790/"], isDev: true)?.absoluteString
                == "http://127.0.0.1:8790/v1/ping")
    }

    /// 跑测试的这个进程（开发版）自己不报：没设 GETNEWWORD_API 时 shared 没有地址
    @Test func testsAndDevBuildsDontReport() {
        if ProcessInfo.processInfo.environment["GETNEWWORD_API"] == nil {
            #expect(UsagePing.shared.endpoint == nil)
        }
    }
}
