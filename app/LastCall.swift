// Last Call menu bar app. https://lastagentcall.com  (MIT)
// Build: swiftc -O -o LastCall LastCall.swift -framework AppKit -framework IOKit
import AppKit
import IOKit.ps

let home = FileManager.default.homeDirectoryForCurrentUser
let lcDir = home.appendingPathComponent(".lastcall")
let overrideFile = lcDir.appendingPathComponent("override")
let configFile = lcDir.appendingPathComponent("config")
let handoffLog = lcDir.appendingPathComponent("handoffs.log")
let launchAgent = home.appendingPathComponent("Library/LaunchAgents/com.lastagentcall.menubar.plist")

struct Battery { let percent: Int; let onBattery: Bool }

func readBattery() -> Battery? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for src in list {
        guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
              (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
              let cur = d[kIOPSCurrentCapacityKey] as? Int,
              let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        let state = d[kIOPSPowerSourceStateKey] as? String
        return Battery(percent: Int((Double(cur) / Double(max) * 100).rounded()),
                       onBattery: state == kIOPSBatteryPowerValue)
    }
    return nil
}

func readConfig() -> (warn: Int, wrap: Int, stop: Int, enabled: Bool) {
    var warn = 20, wrap = 10, stop = 5, enabled = true
    if let text = try? String(contentsOf: configFile, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let v = Int(parts[1]) else { continue }
            switch parts[0] {
            case "WARN_AT": warn = v
            case "WRAP_AT": wrap = v
            case "STOP_AT": stop = v
            case "ENABLED": enabled = v != 0
            default: break
            }
        }
    }
    return (warn, wrap, stop, enabled)
}

func claudeProcessCount() -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "claude"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return 0 }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").count
}

func notify(_ title: String, _ body: String) {
    // osascript works for an unsigned app built from source; no notification entitlement needed.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
    try? p.run()
}

let levelNames = ["Normal", "Warning", "Wrap up", "Critical"]

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var lastLevel = 0
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(at: lcDir, withIntermediateDirectories: true)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func currentLevel(_ b: Battery?) -> (Int, Bool) {
        let cfg = readConfig()
        var level = 0
        if cfg.enabled, let b = b, b.onBattery {
            if b.percent <= cfg.stop { level = 3 }
            else if b.percent <= cfg.wrap { level = 2 }
            else if b.percent <= cfg.warn { level = 1 }
        }
        let manual = FileManager.default.fileExists(atPath: overrideFile.path)
        if cfg.enabled && manual && level < 2 { level = 2 }
        return (level, manual)
    }

    func refresh() {
        let b = readBattery()
        let (level, manual) = currentLevel(b)
        let agents = claudeProcessCount()

        let pct = b.map { "\($0.percent)%" } ?? "AC"
        item.button?.title = level == 0 ? "LC \(pct)" : "LC \(pct) \(levelNames[level])"

        if level != lastLevel {
            if level > lastLevel {
                let body: String
                switch level {
                case 1: body = "Battery at \(pct). Agents will finish the current step and skip long jobs."
                case 2: body = manual ? "Wrapping up \(agents) agent process(es) now." : "Battery at \(pct). Agents are writing handoff notes and committing WIP."
                default: body = "Battery at \(pct). Agents can only write handoff notes and commit."
                }
                notify("Last Call: \(levelNames[level])", body)
            } else if level == 0 {
                notify("Last Call", "All clear. Agents are back to normal.")
            }
            lastLevel = level
        }

        let menu = NSMenu()
        let batt = b.map { "Battery \($0.percent)%\($0.onBattery ? "" : ", plugged in")" } ?? "No battery"
        menu.addItem(disabled(batt))
        menu.addItem(disabled("Claude processes running: \(agents)"))
        menu.addItem(disabled("Last Call level: \(levelNames[level])\(manual ? " (manual)" : "")"))
        menu.addItem(.separator())
        menu.addItem(action("Wrap up all agents now", #selector(wrapUp), enabled: !manual))
        menu.addItem(action("Resume normal", #selector(resume), enabled: manual))
        menu.addItem(.separator())
        let handoffs = NSMenuItem(title: "Open handoff notes", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let recent = recentHandoffs()
        if recent.isEmpty { sub.addItem(disabled("None yet")) }
        for path in recent {
            let mi = NSMenuItem(title: path.replacingOccurrences(of: home.path, with: "~"), action: #selector(openHandoff(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = path
            sub.addItem(mi)
        }
        handoffs.submenu = sub
        menu.addItem(handoffs)
        menu.addItem(action("Settings", #selector(openSettings)))
        let login = action("Launch at login", #selector(toggleLogin))
        login.state = FileManager.default.fileExists(atPath: launchAgent.path) ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(action("Quit", #selector(quit)))
        item.menu = menu
    }

    func disabled(_ t: String) -> NSMenuItem {
        let mi = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    func action(_ t: String, _ sel: Selector, enabled: Bool = true) -> NSMenuItem {
        let mi = NSMenuItem(title: t, action: enabled ? sel : nil, keyEquivalent: "")
        mi.target = self
        mi.isEnabled = enabled
        return mi
    }

    func recentHandoffs() -> [String] {
        guard let text = try? String(contentsOf: handoffLog, encoding: .utf8) else { return [] }
        var seen = Set<String>(), out: [String] = []
        for line in text.split(separator: "\n").reversed() {
            let cols = line.split(separator: "\t", maxSplits: 1)
            guard cols.count == 2 else { continue }
            let path = String(cols[1])
            if seen.insert(path).inserted, FileManager.default.fileExists(atPath: path) { out.append(path) }
            if out.count >= 10 { break }
        }
        return out
    }

    @objc func wrapUp() {
        FileManager.default.createFile(atPath: overrideFile.path, contents: Data())
        refresh()
    }

    @objc func resume() {
        try? FileManager.default.removeItem(at: overrideFile)
        refresh()
    }

    @objc func openHandoff(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? String { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
    }

    @objc func openSettings() {
        if !FileManager.default.fileExists(atPath: configFile.path) {
            let defaults = "# Last Call levels (battery percent, on battery only)\nWARN_AT=20\nWRAP_AT=10\nSTOP_AT=5\n# Set ENABLED=0 to turn the hook off\nENABLED=1\n"
            try? defaults.write(to: configFile, atomically: true, encoding: .utf8)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", configFile.path]
        try? p.run()
    }

    @objc func toggleLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgent.path) {
            try? fm.removeItem(at: launchAgent)
        } else {
            let appPath = Bundle.main.bundlePath
            let plist: [String: Any] = [
                "Label": "com.lastagentcall.menubar",
                "ProgramArguments": ["/usr/bin/open", "-a", appPath],
                "RunAtLoad": true,
            ]
            try? fm.createDirectory(at: launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: launchAgent)
            }
        }
        refresh()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
