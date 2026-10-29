// PerfProbe.swift
// GetNewWord
//
// 开发版的滚动打点，只编进 Debug 版：GNW_PERF=1 启动后，每一段滚动（滚轮停 0.8 秒算一段）在 app.log 里记一行，
// 量查词面板、设置窗口、主窗口滑起来顺不顺：
//   帧数和掉帧（按屏幕刷新率算）、最长的一帧、主线程最长连续忙多久、滚轮事件从发生到被处理等了多久。
// 帧靠屏幕的 CADisplayLink 回调数：主线程被占住时回调会迟到，迟到的那几帧就是用户看到的卡。

#if DEBUG
import AppKit
import QuartzCore

@MainActor
final class PerfProbe: NSObject {
    static let shared = PerfProbe()

    static func startIfRequested() {
        guard ProcessInfo.processInfo.environment["GNW_PERF"] != nil else { return }
        shared.start()
    }

    private var link: CADisplayLink?
    private var monitor: Any?
    private var observer: CFRunLoopObserver?

    private var active = false
    private var window = ""
    private var startedAt: CFTimeInterval = 0
    private var lastScroll: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var period: CFTimeInterval = 1.0 / 60
    private var frames = 0
    private var dropped = 0
    private var worstFrame: CFTimeInterval = 0
    private var busySince: CFTimeInterval = 0
    private var worstBusy: CFTimeInterval = 0
    private var busyTotal: CFTimeInterval = 0
    private var events = 0
    private var lagTotal: CFTimeInterval = 0
    private static let tail: CFTimeInterval = 0.25
    private var worstLag: CFTimeInterval = 0

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            self?.scrolled(e)
            return e
        }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.runLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        AppLog.log("[Perf] probe on")
    }

    private func scrolled(_ e: NSEvent) {
        let now = CACurrentMediaTime()
        if !active { begin(e, now: now) }
        lastScroll = now
        events += 1
        let lag = now - e.timestamp
        lagTotal += lag
        worstLag = max(worstLag, lag)
    }

    private func begin(_ e: NSEvent, now: CFTimeInterval) {
        active = true
        let w = e.window
        window = "\(w.map { String(describing: type(of: $0)) } ?? "?") \(Int(w?.frame.width ?? 0))x\(Int(w?.frame.height ?? 0))"
        startedAt = now
        lastFrame = 0
        frames = 0; dropped = 0; worstFrame = 0
        worstBusy = 0; busyTotal = 0
        events = 0; lagTotal = 0; worstLag = 0
        if link == nil {
            let screen = w?.screen ?? NSScreen.main
            link = screen?.displayLink(target: self, selector: #selector(tick(_:)))
            link?.add(to: .main, forMode: .common)
        }
        link?.isPaused = false
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard active else { return }
        period = max(1.0 / 240, l.targetTimestamp - l.timestamp)
        let inSession = CACurrentMediaTime() - lastScroll < Self.tail
        if lastFrame > 0, inSession {
            let dt = l.timestamp - lastFrame
            worstFrame = max(worstFrame, dt)
            let missed = Int((dt / period).rounded()) - 1
            if missed > 0 { dropped += missed }
        }
        lastFrame = l.timestamp
        if inSession { frames += 1 }
        if CACurrentMediaTime() - lastScroll > 0.8 { finish() }
    }

    private func runLoop(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
            busySince = now
        } else if busySince > 0 {
            let busy = now - busySince
            busySince = 0
            guard active, now - lastScroll < Self.tail else { return }
            worstBusy = max(worstBusy, busy)
            busyTotal += busy
        }
    }

    private func finish() {
        active = false
        link?.isPaused = true
        let secs = max(0.001, lastScroll - startedAt)
        // 帧、掉帧、主线程忙都只算滚动中和最后一个事件之后的 0.25 秒（滚动收尾的动画），之后空等的不算
        let elapsed = secs + Self.tail
        let hz = Int((1 / period).rounded())
        func ms(_ t: CFTimeInterval) -> String { String(format: "%.1f", t * 1000) }
        AppLog.log("[Perf] scroll \(window) · \(String(format: "%.1f", secs))s · events \(events) · frames \(frames) @\(hz)Hz"
                   + " · dropped \(dropped) (\(String(format: "%.1f", Double(dropped) / elapsed))/s) · worst frame \(ms(worstFrame))ms"
                   + " · main busy max \(ms(worstBusy))ms, \(Int(busyTotal / elapsed * 100))%"
                   + " · event lag avg \(ms(lagTotal / Double(max(1, events))))ms max \(ms(worstLag))ms")
    }
}
#endif
