// CloudRealtime.swift
// GetNewWord
//
// Supabase Realtime（Phoenix 协议，手写 WebSocket）：订阅 schema getnewword 四张表的变更，
// 另一台设备一改就通知 CloudSyncService 立刻拉一次，不用等每分钟的兜底轮询。
// 只当「有变化」的信号用，数据仍走 CloudSyncService 的增量拉取；RLS 保证只收到自己账号的行。

import Foundation

@MainActor
final class CloudRealtime {
    /// 收到变更（含本机自己推送的回声，拉取时按内容哈希跳过）
    var onChange: (@MainActor () -> Void)?

    private let topic = "realtime:getnewword-sync"
    private let tables = ["categories", "words", "contexts", "snippets"]
    private var task: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var wanted = false
    private var connecting = false
    private var ref = 0
    private var sentToken: String?
    private var backoff: Double = 2

    func start() {
        wanted = true
        guard task == nil, !connecting, reconnectTask == nil else { return }
        connect()
    }

    func stop() {
        wanted = false
        reconnectTask?.cancel(); reconnectTask = nil
        teardown()
    }

    private func connect() {
        guard wanted, SupabaseAuth.shared.session != nil else { return }
        connecting = true
        Task { @MainActor in
            defer { connecting = false }
            guard let token = try? await SupabaseAuth.shared.validAccessToken() else { scheduleReconnect(); return }
            var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("realtime/v1/websocket"), resolvingAgainstBaseURL: false)!
            comps.scheme = "wss"
            comps.queryItems = [URLQueryItem(name: "apikey", value: SupabaseConfig.anonKey),
                                URLQueryItem(name: "vsn", value: "1.0.0")]
            let t = URLSession.shared.webSocketTask(with: comps.url!)
            task = t
            t.resume()
            receiver = Task { @MainActor in await self.receiveLoop(t) }

            let changes = tables.map { ["event": "*", "schema": SupabaseConfig.schema, "table": $0] }
            send(t, event: "phx_join", payload: [
                "config": ["broadcast": ["self": false], "presence": ["key": ""],
                           "postgres_changes": changes, "private": false],
                "access_token": token,
            ])
            sentToken = token

            heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(25))
                    guard !Task.isCancelled, self.task === t else { return }
                    self.send(t, topic: "phoenix", event: "heartbeat", payload: [:])
                    // access token 过期前会被刷新：换了就告诉 Realtime，否则一小时后频道被踢
                    if let fresh = try? await SupabaseAuth.shared.validAccessToken(), fresh != self.sentToken {
                        self.send(t, event: "access_token", payload: ["access_token": fresh])
                        self.sentToken = fresh
                    }
                }
            }
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) async {
        while true {
            do {
                let message = try await t.receive()
                guard case .string(let text) = message,
                      let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let event = obj["event"] as? String else { continue }
                let payload = obj["payload"] as? [String: Any]
                switch event {
                case "postgres_changes":
                    onChange?()
                case "phx_reply":
                    if obj["topic"] as? String == topic {
                        if payload?["status"] as? String == "ok" {
                            backoff = 2
                            AppLog.log("[Realtime] subscribed")
                        } else {
                            AppLog.log("[Realtime] ✗ join: \(text.prefix(300))")
                        }
                    }
                case "system":
                    if payload?["status"] as? String == "error" { AppLog.log("[Realtime] ✗ system: \(text.prefix(300))") }
                case "phx_error", "phx_close":
                    AppLog.log("[Realtime] channel \(event)")
                    throw URLError(.networkConnectionLost)
                default:
                    break
                }
            } catch {
                guard task === t else { return }
                AppLog.log("[Realtime] disconnected: \(error.localizedDescription)")
                teardown()
                scheduleReconnect()
                return
            }
        }
    }

    private func send(_ t: URLSessionWebSocketTask, topic: String? = nil, event: String, payload: [String: Any]) {
        ref += 1
        let msg: [String: Any] = ["topic": topic ?? self.topic, "event": event, "payload": payload,
                                  "ref": String(ref), "join_ref": "1"]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        let text = String(decoding: data, as: UTF8.self)
        Task { try? await t.send(.string(text)) }
    }

    private func teardown() {
        heartbeat?.cancel(); heartbeat = nil
        receiver?.cancel(); receiver = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        sentToken = nil
    }

    private func scheduleReconnect() {
        guard wanted, reconnectTask == nil else { return }
        let delay = backoff
        backoff = min(backoff * 2, 60)
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            reconnectTask = nil
            guard !Task.isCancelled else { return }
            // 断线期间可能漏了变更：重连前先补拉一次
            onChange?()
            connect()
        }
    }
}
