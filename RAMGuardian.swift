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
    var killProcesses: Bool?
    var pylanceLimitMB: Double?
    var notify: Bool?
    var minFootprintMB: [String: Double]?
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
    if let minMB = config.minFootprintMB?[c.bundle], Double(c.footprint) < minMB * 1_048_576 { return false }
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

func childPIDs(_ pid: pid_t) -> [pid_t] {
    var children = [pid_t](repeating: 0, count: 4096)
    let count = children.withUnsafeMutableBytes {
        proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
    }
    guard count > 0 else { return [] }
    return Array(children.prefix(min(Int(count), children.count))).filter { $0 > 0 }
}

// Used only to rank applications; termination still targets the regular app.
// Shared allocations can appear in several footprints, so this is an estimate.
func treeFootprint(_ root: pid_t, children: (pid_t) -> [pid_t] = childPIDs,
                   measure: (pid_t) -> UInt64 = footprint) -> UInt64 {
    var pending = [root], visited = Set<pid_t>(), total: UInt64 = 0
    while let pid = pending.popLast(), visited.count < 8192 {
        guard visited.insert(pid).inserted else { continue }
        let sum = total.addingReportingOverflow(measure(pid))
        total = sum.overflow ? UInt64.max : sum.partialValue
        pending.append(contentsOf: children(pid))
    }
    return total
}

struct ProcInfo {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let start: UInt64
    let name: String
    let args: String
}

// Dev tooling that is safe to stop once its parent (terminal, agent, editor) is gone.
let devExecutables: Set<String> = ["node", "uv", "bun", "deno", "esbuild", "next-server"]
let devMarkers = ["pytest", "uvicorn", "next dev", "next-server", "next/dist", "vite",
                  "turbopack", "manage.py", "celery", "esbuild", "vitest", "jest", "tsserver"]

func isDevProcess(_ p: ProcInfo, home: String) -> Bool {
    let name = p.name.lowercased()
    guard name.hasPrefix("python") || devExecutables.contains(name) else { return false }
    return devMarkers.contains { p.args.contains($0) } || p.args.contains("\(home)/code/")
}

// Returns why a process should be stopped, or nil. Never targets other users,
// launchd-managed jobs or processes younger than two minutes.
func killReason(_ p: ProcInfo, footprint: UInt64, launchdPIDs: Set<pid_t>, me: uid_t,
                now: UInt64, pylanceLimit: UInt64, home: String) -> String? {
    guard p.uid == me, p.pid > 1, p.pid != getpid(), !launchdPIDs.contains(p.pid) else { return nil }
    if p.args.contains("vscode-pylance") && p.args.contains("server.bundle.js") && footprint >= pylanceLimit {
        return "pylance"
    }
    if p.ppid == 1, now >= p.start + 120, isDevProcess(p, home: home) { return "orphan" }
    return nil
}

func processArgs(_ pid: pid_t) -> String {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return "" }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return "" }
    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    var i = 4
    while i < size && buffer[i] != 0 { i += 1 }  // executable path
    while i < size && buffer[i] == 0 { i += 1 }
    var args: [String] = []
    while args.count < argc && i < size {
        let begin = i
        while i < size && buffer[i] != 0 { i += 1 }
        args.append(String(decoding: buffer[begin..<i], as: UTF8.self))
        i += 1
    }
    return args.joined(separator: " ")
}

func processInfo(_ pid: pid_t) -> ProcInfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    var path = [CChar](repeating: 0, count: 4096)
    let name = proc_pidpath(pid, &path, UInt32(path.count)) > 0
        ? URL(fileURLWithPath: String(cString: path)).lastPathComponent : ""
    return ProcInfo(pid: pid, ppid: pid_t(info.pbi_ppid), uid: info.pbi_uid,
                    start: info.pbi_start_tvsec, name: name, args: processArgs(pid))
}

func allPIDs() -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 8192)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    return count > 0 ? Array(pids.prefix(Int(count))).filter { $0 > 0 } : []
}

// PIDs of the user's launchd jobs (servers started on purpose), so they are never treated as orphans.
func launchdJobPIDs() -> Set<pid_t> {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = ["list"]
    task.standardOutput = pipe
    guard (try? task.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
        pid_t($0.split(separator: "\t").first ?? "")
    })
}

func notify(_ title: String, _ body: String) {
    let quote = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "display notification \"\(quote(body))\" with title \"\(quote(title))\""]
    try? task.run()
}

func megabytes(_ bytes: UInt64) -> String {
    bytes >= 1 << 30 ? String(format: "%.1f GB", Double(bytes) / Double(1 << 30))
                     : "\(bytes >> 20) MB"
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
    var floor = config; floor.minFootprintMB = ["test.safe": 1024]
    precondition(!eligible(safe, floor, pressure: 4, pressureDuration: 100, cooldown: 100, sinceAttempt: 9000))
    precondition(eligible(Candidate(pid: 1, bundle: "test.safe", idle: 1201, footprint: 2 << 30,
        foreground: false, regular: true), floor, pressure: 4, pressureDuration: 100, cooldown: 100, sinceAttempt: 9000))
    var off = config; off.enabled = false
    precondition(!eligible(safe, off, pressure: 4, pressureDuration: 100,
        cooldown: 100, sinceAttempt: 9000))
    var permissive = config; permissive.allowedBundles.append("com.openai.codex")
    precondition(!eligible(Candidate(pid: 1, bundle: "com.openai.codex", idle: 9000,
        footprint: 10, foreground: false, regular: true), permissive, pressure: 4,
        pressureDuration: 100, cooldown: 100, sinceAttempt: 9000))
    precondition(treeFootprint(1, children: { [1: [2, 3], 2: [4], 3: [4], 4: [1]][$0] ?? [] },
        measure: { UInt64($0) * 10 }) == 100)
    precondition(treeFootprint(1, children: { _ in [] }, measure: { _ in 0 }) == 0)
    let me: uid_t = 501, home = "/Users/test", gb: UInt64 = 1 << 30
    func reason(_ p: ProcInfo, footprint: UInt64 = 0, launchd: Set<pid_t> = []) -> String? {
        killReason(p, footprint: footprint, launchdPIDs: launchd, me: me, now: 10_000,
                   pylanceLimit: gb, home: home)
    }
    let pylance = ProcInfo(pid: 50, ppid: 40, uid: me, start: 9_990, name: "Code Helper (Plugin)",
        args: "/x/ms-python.vscode-pylance-1/dist/server.bundle.js --stdio")
    precondition(reason(pylance, footprint: 2 * gb) == "pylance")
    precondition(reason(pylance, footprint: gb / 2) == nil)
    let orphan = ProcInfo(pid: 60, ppid: 1, uid: me, start: 9_000, name: "python3.12",
        args: "python -m pytest -n auto")
    precondition(reason(orphan) == "orphan")
    precondition(reason(orphan, launchd: [60]) == nil)
    precondition(reason(ProcInfo(pid: 60, ppid: 1, uid: me, start: 9_950, name: "python3.12",
        args: "python -m pytest")) == nil)
    precondition(reason(ProcInfo(pid: 60, ppid: 1, uid: 0, start: 9_000, name: "python3.12",
        args: "python -m pytest")) == nil)
    precondition(reason(ProcInfo(pid: 60, ppid: 70, uid: me, start: 9_000, name: "python3.12",
        args: "python -m pytest")) == nil)
    precondition(reason(ProcInfo(pid: 60, ppid: 1, uid: me, start: 9_000, name: "Spotify",
        args: "/Users/test/code/x")) == nil)
    precondition(reason(ProcInfo(pid: 60, ppid: 1, uid: me, start: 9_000, name: "python3",
        args: "/Users/test/muse/server.py")) == nil)
    precondition(reason(ProcInfo(pid: 60, ppid: 1, uid: me, start: 9_000, name: "node",
        args: "node /Users/test/code/app/server.js")) == "orphan")
    print("14 policy checks, 2 process-tree checks and 10 process-kill checks passed")
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
if CommandLine.arguments.contains("--probe-kill") {
    // Dry run: lists what stopProcesses would target right now, without sending signals.
    let launchd = launchdJobPIDs(), wall = UInt64(Date().timeIntervalSince1970)
    let limitMB = UInt64(ProcessInfo.processInfo.environment["PYLANCE_LIMIT_MB"] ?? "") ?? 1024
    for pid in allPIDs() {
        guard let p = processInfo(pid) else { continue }
        let bytes = footprint(pid)
        if let reason = killReason(p, footprint: bytes, launchdPIDs: launchd, me: getuid(), now: wall,
                                   pylanceLimit: limitMB << 20, home: NSHomeDirectory()) {
            print("\(reason)\t\(pid)\t\(megabytes(bytes))\t\(p.name)\t\(p.args.prefix(140))")
        }
    }
    exit(0)
}
if CommandLine.arguments.contains("--probe") {
    let apps = NSWorkspace.shared.runningApplications.compactMap { app -> [String: Any]? in
        guard let bundle = app.bundleIdentifier else { return nil }
        return ["bundle": bundle, "pid": app.processIdentifier,
                "foreground": app.isActive, "footprintBytes": footprint(app.processIdentifier),
                "treeFootprintBytes": treeFootprint(app.processIdentifier)]
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
    var terminating: [pid_t: (start: UInt64, deadline: Double, label: String)] = [:]
    var lastPylanceKill = -Double.greatestFiniteMagnitude

    func start() {
        log("started", ["pid": getpid(), "version": 3])
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
        let treeBytes = Dictionary(uniqueKeysWithValues: monitored.map {
            ($0.processIdentifier, treeFootprint($0.processIdentifier))
        })
        let rows: [[String: Any]] = monitored.map { app in
            ["bundle": app.bundleIdentifier ?? "", "pid": app.processIdentifier,
             "idleSeconds": Int(now - (lastActive[app.processIdentifier] ?? now)),
             "foreground": app.isActive || app.processIdentifier == frontmostPID,
             "footprintBytes": footprint(app.processIdentifier),
             "treeFootprintBytes": treeBytes[app.processIdentifier] ?? 0]
        }
        writeJSON(["time": ISO8601DateFormatter().string(from: Date()), "pid": getpid(),
            "enabled": config.enabled, "pressure": pressure,
            "pressureSeconds": Int(now - pressureSince), "swapUsedBytes": swapUsed() ?? 0,
            "monitoredApps": rows, "wakeGraceSeconds": max(0, Int(wakeGraceUntil - now))], to: statusURL)
        if now - lastTelemetry >= 60 {
            log("sample", ["pressure": pressure, "swapUsedBytes": swapUsed() ?? 0, "apps": rows])
            lastTelemetry = now
        }
        escalateTerminations(now)
        guard now >= wakeGraceUntil else { return }
        let critical = pressure == 4
        if config.enabled, config.killProcesses ?? false, pressure == 2 || critical,
           now - pressureSince >= (critical ? config.criticalSeconds : config.warningSeconds) {
            stopProcesses(config, pressure: pressure, now: now)
        }
        let candidates = monitored.filter { app in
            let pid = app.processIdentifier
            let candidate = Candidate(pid: pid, bundle: app.bundleIdentifier ?? "",
                idle: now - (lastActive[pid] ?? now), footprint: treeBytes[pid] ?? footprint(pid),
                foreground: app.isActive || pid == frontmostPID, regular: app.activationPolicy == .regular
                    || app.bundleIdentifier == "app.cotypist.Cotypist"
                    || app.bundleIdentifier == "com.facmartoni.DepotBar")
            return eligible(candidate, config, pressure: pressure,
                pressureDuration: now - pressureSince, cooldown: now - lastAction,
                sinceAttempt: now - (lastAttempt[pid] ?? -Double.greatestFiniteMagnitude))
        }.sorted { (treeBytes[$0.processIdentifier] ?? 0) > (treeBytes[$1.processIdentifier] ?? 0) }
        guard let app = candidates.first, !app.isTerminated, !app.isActive,
              app.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let pid = app.processIdentifier
        lastAttempt[pid] = now; lastAction = now
        let bundle = app.bundleIdentifier ?? ""
        let bytes = footprint(pid)
        let accepted = app.terminate()
        log("quit_requested", ["bundle": bundle, "pid": pid, "accepted": accepted,
            "footprintBytes": bytes, "treeFootprintBytes": treeBytes[pid] ?? 0, "pressure": pressure,
            "idleSeconds": Int(now - (lastActive[pid] ?? now))])
        if accepted {
            pending[pid] = bundle
            if config.notify ?? true {
                notify("RAM Guardian", "Cerré \(app.localizedName ?? bundle) (\(megabytes(treeBytes[pid] ?? bytes))) por falta de memoria")
            }
        }
    }

    // SIGTERM first; SIGKILL on a later tick if the same process is still alive after 10 s.
    func stopProcesses(_ config: Configuration, pressure: Int32, now: Double) {
        let me = getuid(), home = NSHomeDirectory(), wall = UInt64(Date().timeIntervalSince1970)
        let limit = UInt64((config.pylanceLimitMB ?? 1024) * 1_048_576)
        let launchd = launchdJobPIDs()
        var stopped: [String] = []
        for pid in allPIDs() where terminating[pid] == nil {
            guard let p = processInfo(pid) else { continue }
            let bytes = footprint(pid)
            guard let reason = killReason(p, footprint: bytes, launchdPIDs: launchd, me: me,
                                          now: wall, pylanceLimit: limit, home: home) else { continue }
            if reason == "pylance" {
                guard now - lastPylanceKill >= 300 else { continue }
                lastPylanceKill = now
            }
            let label = reason == "pylance" ? "Pylance"
                : "\(devMarkers.first { p.args.contains($0) } ?? p.name) huérfano"
            guard kill(pid, SIGTERM) == 0 else { continue }
            terminating[pid] = (p.start, now + 10, label)
            log("process_terminated", ["pid": pid, "reason": reason, "name": p.name,
                "args": String(p.args.prefix(200)), "footprintBytes": bytes, "pressure": pressure])
            stopped.append("\(label) (\(megabytes(bytes)))")
        }
        if !stopped.isEmpty, config.notify ?? true {
            notify("RAM Guardian", "Terminé: " + stopped.joined(separator: ", "))
        }
    }

    func escalateTerminations(_ now: Double) {
        for (pid, entry) in terminating where now >= entry.deadline {
            terminating.removeValue(forKey: pid)
            guard let p = processInfo(pid), p.start == entry.start else { continue }
            if kill(pid, SIGKILL) == 0 {
                log("process_killed", ["pid": pid, "label": entry.label])
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let guardian = Guardian()
guardian.start()
app.run()
