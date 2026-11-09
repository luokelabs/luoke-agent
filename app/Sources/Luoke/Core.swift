import AppKit
import Foundation
import IOKit

/// 核心是 Python 子进程（DESIGN §1）：用主控的 Python 只读地起（-B -E -s），带 --parent-pid，壳没了它自己退出；
/// agent.sock 只认这个壳（--parent-pid 的那个进程）。
/// 意外退出就隔一会儿再起，间隔逐次加长。
final class CoreProcess {
    private let config: Config
    private var process: Process?
    private var quitting = false
    private var backoff: TimeInterval = 2
    private var startedAt = Date()
    var onState: ((String?) -> Void)?   // nil 正常；否则一句话

    init(config: Config) { self.config = config }

    func start() {
        // 借主控的 Python 时每次都重新找：主控换了版本、改了名，路径会变
        guard let python = config.pythonFromHub ? (Config.hubPython() ?? config.python) : config.python else { return }
        var args = ["-B", "-E", "-s", "-m", "luoke_agent", "serve", "--home", config.home, "--memory", config.memory,
                    "--parent-pid", String(getpid())]
        if let hub = config.hub { args += ["--hub", hub] }
        for t in config.tools { args += ["--tool", t] }
        if config.memoryApp { args.append("--memory-app") }
        if config.dev { args.append("--dev") }     // 开发版：命令行的 feed、tap 也连得上（agent.sock 平时只认这个壳）
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: config.coreDir)   // -m 从这里找 luoke_agent 和 vendor/
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "PYTHONDONTWRITEBYTECODE": "1",
                         "LUOKE_AGENT_PYTHON": python]   // 核心盯着它：主控换了版本就退出重起
        p.standardOutput = FileHandle.nullDevice
        p.standardError = logHandle()           // 核心只往标准错误写元数据
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.exited(proc.terminationStatus) }
        }
        do {
            try p.run()
            process = p
            startedAt = Date()
            onState?(nil)
        } catch {
            onState?("螺壳的核心起不来。")
            retry()
        }
    }

    private func exited(_ status: Int32) {
        process = nil
        if quitting { return }
        if status == 75 {                       // 核心见主控的 Python 换了版本，自己退出要求重起：马上用新的那份起
            backoff = 2
            start()
            return
        }
        if Date().timeIntervalSince(startedAt) >= 60 { backoff = 2 }   // 稳定跑过一阵才停的，不是起不来：不接着上次的等待
        onState?("螺壳的核心停了，正在重新启动…")
        retry()
    }

    private func retry() {
        let wait = backoff
        backoff = min(backoff * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, !self.quitting, self.process == nil else { return }
            self.start()
        }
    }

    func stop() {
        quitting = true
        guard let p = process, p.isRunning else { return }
        p.terminate()                           // 只停自己起的这个进程
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning, Date() < deadline { usleep(50_000) }
    }

    private func logHandle() -> FileHandle {
        let dir = (config.home as NSString).appendingPathComponent("logs")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = (dir as NSString).appendingPathComponent("core.log")
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return FileHandle.nullDevice }
        h.seekToEndOfFile()
        return h
    }
}

/// 用户在不在 Mac 前：空闲多久（IOHIDSystem 的 HIDIdleTime）、锁屏、屏幕睡着。
final class Presence {
    private(set) var locked = false
    private(set) var asleep = false
    var onChange: (() -> Void)?

    init() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true; self?.onChange?()
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false; self?.onChange?()
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true; self?.onChange?()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false; self?.onChange?()
        }
    }

    var idleSeconds: Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue(), let ns = (prop as? NSNumber)?.uint64Value else { return 0 }
        return Double(ns) / 1_000_000_000
    }

    var body: Data {
        (try? JSONSerialization.data(withJSONObject: ["idle": idleSeconds, "locked": locked, "asleep": asleep])) ?? Data()
    }
}
