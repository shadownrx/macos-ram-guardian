import AppKit
import Foundation
import Darwin

struct Configuration: Codable {
    var enabled: Bool
    var idleSeconds: Double
    var criticalIdleSeconds: Double
    var warningSeconds: Double
    var criticalSeconds: Double
    var actionInterval: Double
    var retrySeconds: Double
    var allowedBundles: [String]
}

struct Candidate {
    let pid: pid_t
    let bundle: String
    let idle: Double
    let footprint: UInt64
    let foreground: Bool
    let regular: Bool
}

let protectedBundles: Set<String> = ["com.openai.codex", "com.stablyai.orca",
    "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2",
    "dev.zed.Zed", "com.microsoft.VSCode", "com.apple.finder"]

func eligible(_ c: Candidate, _ config: Configuration, pressure: Int32,
              pressureDuration: Double, cooldown: Double, sinceAttempt: Double) -> Bool {
    guard config.enabled, pressure == 2 || pressure == 4, !c.foreground, c.regular,
          config.allowedBundles.contains(c.bundle), !protectedBundles.contains(c.bundle), cooldown >= config.actionInterval,
          sinceAttempt >= config.retrySeconds else { return false }
    let critical = pressure == 4
    return c.idle >= (critical ? config.criticalIdleSeconds : config.idleSeconds)
        && pressureDuration >= (critical ? config.criticalSeconds : config.warningSeconds)
}

func pressureLevel() -> Int32? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0,
          [1, 2, 4].contains(value) else { return nil }
    return value
}

func footprint(_ pid: pid_t) -> UInt64 {
    var info = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
        }
    }
    return result == 0 ? info.ri_phys_footprint : 0
}

func swapUsed() -> UInt64? {
    var info = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    return sysctlbyname("vm.swapusage", &info, &size, nil, 0) == 0 ? info.xsu_used : nil
}

let configURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
                    ?? "\(NSHomeDirectory())/.local/share/codex-ram-guardian/config.json")
let base = configURL.deletingLastPathComponent()
let statusURL = base.appendingPathComponent("status.json")
let logURL = base.appendingPathComponent("events.jsonl")

func writeJSON(_ value: [String: Any], to url: URL) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        try? data.write(to: url, options: .atomic)
    }
}

func log(_ event: String, _ fields: [String: Any] = [:]) {
    var record = fields
    record["event"] = event
    record["time"] = ISO8601DateFormatter().string(from: Date())
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
       let size = attrs[.size] as? NSNumber, size.intValue > 1_048_576 {
        let previous = base.appendingPathComponent("events.previous.jsonl")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: logURL, to: previous)
    }
    guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
    data.append(10)
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

func selfTest() {
    let config = Configuration(enabled: true, idleSeconds: 1200, criticalIdleSeconds: 300,
        warningSeconds: 90, criticalSeconds: 15, actionInterval: 60, retrySeconds: 1800,
        allowedBundles: ["test.safe"])
    let safe = Candidate(pid: 1, bundle: "test.safe", idle: 1201, footprint: 10,
                         foreground: false, regular: true)
    func decision(_ c: Candidate = safe, pressure: Int32 = 2, duration: Double = 91,
                  cooldown: Double = 61, attempt: Double = 1801) -> Bool {
        eligible(c, config, pressure: pressure, pressureDuration: duration,
                 cooldown: cooldown, sinceAttempt: attempt)
    }
    precondition(decision())
    precondition(!decision(pressure: 1))
    precondition(!decision(pressure: 0))
    precondition(!decision(duration: 89))
    precondition(!decision(cooldown: 59))
    precondition(!decision(attempt: 1799))
    precondition(!decision(Candidate(pid: 1, bundle: "test.safe", idle: 1201,
        footprint: 10, foreground: true, regular: true)))
    precondition(!decision(Candidate(pid: 1, bundle: "test.safe", idle: 1201,
        footprint: 10, foreground: false, regular: false)))
    precondition(!decision(Candidate(pid: 1, bundle: "com.openai.codex", idle: 9000,
        footprint: 10, foreground: false, regular: true)))
    precondition(!decision(Candidate(pid: 1, bundle: "test.safe", idle: 1199,
        footprint: 10, foreground: false, regular: true)))
    let critical = Candidate(pid: 1, bundle: "test.safe", idle: 301, footprint: 10,
        foreground: false, regular: true)
    precondition(decision(critical, pressure: 4, duration: 16))
    precondition(!decision(critical, pressure: 4, duration: 14))
    var off = config; off.enabled = false
    precondition(!eligible(safe, off, pressure: 4, pressureDuration: 100,
        cooldown: 100, sinceAttempt: 9000))
    var permissive = config; permissive.allowedBundles.append("com.openai.codex")
    precondition(!eligible(Candidate(pid: 1, bundle: "com.openai.codex", idle: 9000,
        footprint: 10, foreground: false, regular: true), permissive, pressure: 4,
        pressureDuration: 100, cooldown: 100, sinceAttempt: 9000))
    print("14 policy checks passed")
}

if CommandLine.arguments.contains("--self-test") { selfTest(); exit(0) }
if CommandLine.arguments.contains("--integration-test") || CommandLine.arguments.contains("--integration-test-refusal") {
    // This test can only request termination of the disposable fixture application.
    let testBundle = "local.codex.ramguardian.testfixture"
    guard let fixture = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == testBundle }) else {
        print("Disposable test fixture is not running"); exit(1)
    }
    guard fixture.terminate() else { print("Quit request was refused"); exit(1) }
    if CommandLine.arguments.contains("--integration-test-refusal") {
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.processIdentifier == fixture.processIdentifier }) else {
            print("Fixture was terminated despite refusing normal quit"); exit(1)
        }
        print("Application refusal was respected; requesting fixture cleanup normally")
        guard fixture.terminate() else { print("Fixture cleanup request failed"); exit(1) }
    }
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        if !NSWorkspace.shared.runningApplications.contains(where: { $0.processIdentifier == fixture.processIdentifier }) {
            print("Normal quit completed for disposable fixture; no force termination used"); exit(0)
        }
    }
    print("Normal quit did not complete"); exit(1)
}
if CommandLine.arguments.contains("--probe") {
    let apps = NSWorkspace.shared.runningApplications.compactMap { app -> [String: Any]? in
        guard let bundle = app.bundleIdentifier else { return nil }
        return ["bundle": bundle, "pid": app.processIdentifier,
                "foreground": app.isActive, "footprintBytes": footprint(app.processIdentifier)]
    }
    let result: [String: Any] = ["pressure": pressureLevel() ?? -1,
        "swapUsedBytes": swapUsed() ?? 0, "apps": apps]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!); exit(0)
}

final class Guardian {
    var lastActive: [pid_t: Double] = [:]
    var lastAttempt: [pid_t: Double] = [:]
    var previousPressure: Int32?
    var pressureSince = Date.timeIntervalSinceReferenceDate
    var lastAction = -Double.greatestFiniteMagnitude
    var wakeGraceUntil = Date.timeIntervalSinceReferenceDate + 120
    var timer: Timer?
    var observers: [NSObjectProtocol] = []
    var pending: [pid_t: String] = [:]
    var lastTelemetry = -Double.greatestFiniteMagnitude

    func start() {
        log("started", ["pid": getpid(), "version": 1])
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.lastActive[app.processIdentifier] = Date.timeIntervalSinceReferenceDate
            }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let now = Date.timeIntervalSinceReferenceDate
            self.pressureSince = now
            self.wakeGraceUntil = now + 120
            self.previousPressure = nil
            log("wake", ["graceSeconds": 120])
        })
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func tick() {
        let now = Date.timeIntervalSinceReferenceDate
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(Configuration.self, from: data),
              config.idleSeconds >= 300, config.criticalIdleSeconds >= 60,
              config.actionInterval >= 30, config.retrySeconds >= 300 else {
            log("invalid_configuration"); return
        }
        let apps = NSWorkspace.shared.runningApplications
        let currentPIDs = Set(apps.map { $0.processIdentifier })
        for (pid, bundle) in pending where !currentPIDs.contains(pid) {
            log("quit_completed", ["bundle": bundle, "pid": pid]); pending.removeValue(forKey: pid)
        }
        lastActive = lastActive.filter { currentPIDs.contains($0.key) }
        lastAttempt = lastAttempt.filter { currentPIDs.contains($0.key) }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in apps {
            let pid = app.processIdentifier
            if lastActive[pid] == nil || app.isActive || pid == frontmostPID { lastActive[pid] = now }
        }
        guard let pressure = pressureLevel() else {
            writeJSON(["time": ISO8601DateFormatter().string(from: Date()),
                       "error": "memory_pressure_unavailable", "enabled": config.enabled], to: statusURL)
            return
        }
        if previousPressure != pressure {
            pressureSince = now; previousPressure = pressure
            log("pressure_changed", ["pressure": pressure, "swapUsedBytes": swapUsed() ?? 0])
        }
        let monitored = apps.filter { config.allowedBundles.contains($0.bundleIdentifier ?? "") }
        let rows: [[String: Any]] = monitored.map { app in
            ["bundle": app.bundleIdentifier ?? "", "pid": app.processIdentifier,
             "idleSeconds": Int(now - (lastActive[app.processIdentifier] ?? now)),
             "foreground": app.isActive || app.processIdentifier == frontmostPID,
             "footprintBytes": footprint(app.processIdentifier)]
        }
        writeJSON(["time": ISO8601DateFormatter().string(from: Date()), "pid": getpid(),
            "enabled": config.enabled, "pressure": pressure,
            "pressureSeconds": Int(now - pressureSince), "swapUsedBytes": swapUsed() ?? 0,
            "monitoredApps": rows, "wakeGraceSeconds": max(0, Int(wakeGraceUntil - now))], to: statusURL)
        if now - lastTelemetry >= 60 {
            log("sample", ["pressure": pressure, "swapUsedBytes": swapUsed() ?? 0, "apps": rows])
            lastTelemetry = now
        }
        guard now >= wakeGraceUntil else { return }
        let candidates = monitored.filter { app in
            let pid = app.processIdentifier
            let candidate = Candidate(pid: pid, bundle: app.bundleIdentifier ?? "",
                idle: now - (lastActive[pid] ?? now), footprint: footprint(pid),
                foreground: app.isActive || pid == frontmostPID, regular: app.activationPolicy == .regular
                    || app.bundleIdentifier == "app.cotypist.Cotypist"
                    || app.bundleIdentifier == "com.facmartoni.DepotBar")
            return eligible(candidate, config, pressure: pressure,
                pressureDuration: now - pressureSince, cooldown: now - lastAction,
                sinceAttempt: now - (lastAttempt[pid] ?? -Double.greatestFiniteMagnitude))
        }.sorted { footprint($0.processIdentifier) > footprint($1.processIdentifier) }
        guard let app = candidates.first, !app.isTerminated, !app.isActive,
              app.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let pid = app.processIdentifier
        lastAttempt[pid] = now; lastAction = now
        let bundle = app.bundleIdentifier ?? ""
        let bytes = footprint(pid)
        let accepted = app.terminate()
        log("quit_requested", ["bundle": bundle, "pid": pid, "accepted": accepted,
            "footprintBytes": bytes, "pressure": pressure,
            "idleSeconds": Int(now - (lastActive[pid] ?? now))])
        if accepted { pending[pid] = bundle }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let guardian = Guardian()
guardian.start()
app.run()
