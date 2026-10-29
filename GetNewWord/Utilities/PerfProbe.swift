// PerfProbe.swift
// GetNewWord
//
// 开发版的卡顿打点，只编进 Debug 版：GNW_PERF=1 启动后在 app.log 里记，量查词面板、设置窗口、主窗口顺不顺：
// - 每一段滚动（滚轮停 0.8 秒算一段）、每一段按键（换词、搜索框打字，停 0.8 秒算一段）记一行：
//   帧数和掉帧（按屏幕刷新率算）、最长的一帧、主线程最长连续忙多久、事件从发生到处理完（含 SwiftUI 重算和提交）等了多久。
// - 主窗口打开：从启动（进程开始）或从收到「开主窗口」到第一帧画出来多久，开窗前后 2 秒里主线程最长忙多久、一共忙多久。
//   测试脚本用分布式通知开关主窗口（com.getnewword.perf.openMain / closeMain），不用模拟点击。
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

    private enum Kind: String { case scroll, keys }

    private var started = false
    private var link: CADisplayLink?
    private var monitor: Any?
    private var observers: [CFRunLoopObserver] = []

    // 一段滚动或按键
    private var active = false
    private var kind = Kind.scroll
    private var window = ""
    private var startedAt: CFTimeInterval = 0
    private var lastInput: CFTimeInterval = 0
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
    /// 还没处理完的按键：事件时间戳，等主线程这一轮忙完（SwiftUI 重算、提交都做完）再算它等了多久
    private var pendingKeys: [CFTimeInterval] = []

    // 主窗口打开
    private var openFrom: CFTimeInterval = 0
    private var openLabel = ""
    private var openFirstFrame: CFTimeInterval = 0
    private var openWorstBusy: CFTimeInterval = 0
    private var openBusyTotal: CFTimeInterval = 0
    private static let openSettle: CFTimeInterval = 2

    private func start() {
        guard !started else { return }   // 主窗口关了再开会再走一次 onAppear
        started = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] e in
            self?.input(e)
            return e
        }
        // 醒来最先记、睡前最后记：SwiftUI 的重算和 Core Animation 的提交都挂在睡前，要算进忙里
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.woke() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        for o in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
            observers.append(o)
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(openMain), name: .init("com.getnewword.perf.openMain"), object: nil)
        dnc.addObserver(self, selector: #selector(closeMain), name: .init("com.getnewword.perf.closeMain"), object: nil)
        AppLog.log("[Perf] probe on")
        busySince = CACurrentMediaTime()   // 现在就在主线程的一轮里（主窗口的 onAppear）
        // 冷启动：从进程开始算到第一帧
        beginOpen(from: CACurrentMediaTime() - Self.processAge(), label: "launch")
    }

    // MARK: - 主窗口打开

    private static func processAge() -> CFTimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let tv = info.kp_proc.p_un.__p_starttime
        let startedAt = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - startedAt
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MainWindowOpener.id) == true && $0.isVisible }
    }

    @objc private func openMain() {
        beginOpen(from: CACurrentMediaTime(), label: "reopen")
        MainWindowOpener.open()
    }

    @objc private func closeMain() {
        mainWindow?.performClose(nil)
    }

    private func beginOpen(from t0: CFTimeInterval, label: String) {
        openFrom = t0
        openLabel = label
        openFirstFrame = 0
        openWorstBusy = 0
        openBusyTotal = 0
    }

    private func openTracked(busy: CFTimeInterval, now: CFTimeInterval) {
        guard openFrom > 0 else { return }
        openWorstBusy = max(openWorstBusy, busy)
        openBusyTotal += busy
        if openFirstFrame == 0 {
            // 主窗口已经在屏幕上、主线程这一轮做完（内容排好、提交出去）= 第一帧
            guard mainWindow != nil else { return }
            openFirstFrame = now
            let from = openFrom
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.openSettle) { [weak self] in
                if self?.openFrom == from { self?.finishOpen() }
            }
        }
    }

    private func finishOpen() {
        func ms(_ t: CFTimeInterval) -> String { String(format: "%.0f", t * 1000) }
        let w = mainWindow
        AppLog.log("[Perf] open main \(openLabel) · first frame \(ms(openFirstFrame - openFrom))ms"
                   + " · main busy max \(ms(openWorstBusy))ms, total \(ms(openBusyTotal))ms until first frame + \(Int(Self.openSettle))s"
                   + " · window \(Int(w?.frame.width ?? 0))x\(Int(w?.frame.height ?? 0))")
        openFrom = 0
    }

    // MARK: - 滚动和按键

    private func input(_ e: NSEvent) {
        let now = CACurrentMediaTime()
        let k: Kind = e.type == .keyDown ? .keys : .scroll
        if active, k != kind { finish() }
        if !active { begin(e, kind: k, now: now) }
        lastInput = now
        events += 1
        if k == .keys {
            pendingKeys.append(e.timestamp)
        } else {
            let lag = now - e.timestamp
            lagTotal += lag
            worstLag = max(worstLag, lag)
        }
    }

    private func begin(_ e: NSEvent, kind k: Kind, now: CFTimeInterval) {
        active = true
        kind = k
        let w = e.window
        window = "\(w.map { String(describing: type(of: $0)) } ?? "?") \(Int(w?.frame.width ?? 0))x\(Int(w?.frame.height ?? 0))"
        startedAt = now
        lastFrame = 0
        frames = 0; dropped = 0; worstFrame = 0
        worstBusy = 0; busyTotal = 0
        events = 0; lagTotal = 0; worstLag = 0
        pendingKeys = []
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
        let inSession = CACurrentMediaTime() - lastInput < Self.tail
        if lastFrame > 0, inSession {
            let dt = l.timestamp - lastFrame
            worstFrame = max(worstFrame, dt)
            let missed = Int((dt / period).rounded()) - 1
            if missed > 0 { dropped += missed }
        }
        lastFrame = l.timestamp
        if inSession { frames += 1 }
        if CACurrentMediaTime() - lastInput > 0.8 { finish() }
    }

    private func woke() {
        busySince = CACurrentMediaTime()
    }

    private func willSleep() {
        let now = CACurrentMediaTime()
        guard busySince > 0 else { return }
        let busy = now - busySince
        busySince = 0
        openTracked(busy: busy, now: now)
        if !pendingKeys.isEmpty {
            for t in pendingKeys {
                let lag = now - t
                lagTotal += lag
                worstLag = max(worstLag, lag)
            }
            pendingKeys = []
        }
        guard active, now - lastInput < Self.tail else { return }
        worstBusy = max(worstBusy, busy)
        busyTotal += busy
    }

    private func finish() {
        active = false
        link?.isPaused = true
        let secs = max(0.001, lastInput - startedAt)
        // 帧、掉帧、主线程忙都只算输入中和最后一个事件之后的 0.25 秒（滚动收尾的动画），之后空等的不算
        let elapsed = secs + Self.tail
        let hz = Int((1 / period).rounded())
        func ms(_ t: CFTimeInterval) -> String { String(format: "%.1f", t * 1000) }
        // 按键记的是从按下到这一轮处理完；滚动记的是滚轮事件从发生到被处理
        let lagName = kind == .keys ? "key done" : "event lag"
        AppLog.log("[Perf] \(kind.rawValue) \(window) · \(String(format: "%.1f", secs))s · events \(events) · frames \(frames) @\(hz)Hz"
                   + " · dropped \(dropped) (\(String(format: "%.1f", Double(dropped) / elapsed))/s) · worst frame \(ms(worstFrame))ms"
                   + " · main busy max \(ms(worstBusy))ms, \(Int(busyTotal / elapsed * 100))%"
                   + " · \(lagName) avg \(ms(lagTotal / Double(max(1, events))))ms max \(ms(worstLag))ms")
    }
}
#endif
