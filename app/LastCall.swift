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
let logFile = lcDir.appendingPathComponent("lastcall.log")

/// Appends one line to ~/.lastcall/lastcall.log (the same log the hook writes).
func logLine(_ text: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    let line = "\(f.string(from: Date())) app: \(text)\n"
    NSLog("Last Call: %@", text)
    try? FileManager.default.createDirectory(at: lcDir, withIntermediateDirectories: true)
    // Same rule as the hook: append only, never through a symlink.
    let fd = open(logFile.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o644)
    guard fd >= 0 else {
        NSLog("Last Call: could not open %@ (errno %d)", logFile.path, errno)
        return
    }
    defer { close(fd) }
    let bytes = Array(line.utf8)
    if write(fd, bytes, bytes.count) != bytes.count {
        NSLog("Last Call: could not write %@ (errno %d)", logFile.path, errno)
    }
}

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
    // Same rules as the hook: drop all whitespace, values are unsigned digits only.
    if let text = try? String(contentsOf: configFile, encoding: .utf8) {
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: "=", maxSplits: 1).map { String($0.filter { !$0.isWhitespace }) }
            guard parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let v = Int(parts[1]) else { continue }
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

/// Number of running `claude` processes, or nil when pgrep could not run.
func claudeProcessCount() -> Int? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "claude"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch {
        logLine("could not run pgrep: \(error.localizedDescription)")
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").count
}

/// Shows a macOS notification. Returns false (and logs) when osascript could not start;
/// a non-zero exit from osascript is logged and reported through onFailure.
@discardableResult
func notify(_ title: String, _ body: String, onFailure: (() -> Void)? = nil) -> Bool {
    // osascript works for an unsigned app built from source; no notification entitlement needed.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.terminationHandler = { proc in
        guard proc.terminationStatus != 0 else { return }
        logLine("osascript exited \(proc.terminationStatus) showing notification \"\(title)\"")
        if let onFailure = onFailure { DispatchQueue.main.async(execute: onFailure) }
    }
    do {
        try p.run()
        return true
    } catch {
        logLine("could not show notification \"\(title)\": \(error.localizedDescription)")
        return false
    }
}

/// Resolves a handoff path from handoffs.log against the cwd the hook recorded.
/// Returns nil for anything that is not a .lastcall/HANDOFF.md file.
func resolveHandoff(_ path: String, cwd: String?) -> String? {
    var full = path
    if !path.hasPrefix("/") {
        guard let cwd = cwd, cwd.hasPrefix("/") else { return nil }
        full = URL(fileURLWithPath: cwd).appendingPathComponent(path).path
    }
    full = URL(fileURLWithPath: full).standardizedFileURL.path
    guard full.hasSuffix("/.lastcall/HANDOFF.md") else { return nil }
    return full
}

let levelNames = ["Normal", "Warning", "Wrap up", "Critical"]

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var lastLevel = 0
    var timer: Timer?
    /// The last action that failed, shown at the top of the menu until the next success.
    var lastError: String?

    /// Records a failed user action: log file, menu text, and a notification when possible.
    func failed(_ what: String, _ error: Error? = nil) {
        let detail = error.map { "\(what): \($0.localizedDescription)" } ?? what
        logLine(detail)
        lastError = what
        notify("Last Call", "\(what). Details in ~/.lastcall/lastcall.log")
        refresh()
    }

    func notifyOrShow(_ title: String, _ body: String) {
        let showFailure = { [weak self] in
            guard let self = self else { return }
            self.lastError = "Could not show notifications"
            self.refresh()
        }
        if !notify(title, body, onFailure: showFailure) { lastError = "Could not show notifications" }
    }

    func succeeded() { lastError = nil }

    func applicationDidFinishLaunching(_ n: Notification) {
        do {
            try FileManager.default.createDirectory(at: lcDir, withIntermediateDirectories: true)
        } catch {
            logLine("could not create \(lcDir.path): \(error.localizedDescription)")
            lastError = "Could not create ~/.lastcall"
        }
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
                case 2: body = manual ? (agents.map { "Wrapping up \($0) agent process(es) now." } ?? "Wrapping up all agents now.") : "Battery at \(pct). Agents are writing handoff notes and committing WIP."
                default: body = "Battery at \(pct). Agents can only write handoff notes and commit."
                }
                notifyOrShow("Last Call: \(levelNames[level])", body)
            } else if level == 0 {
                notifyOrShow("Last Call", "All clear. Agents are back to normal.")
            }
            lastLevel = level
        }

        let menu = NSMenu()
        if let err = lastError {
            menu.addItem(disabled("Failed: \(err)"))
            menu.addItem(.separator())
        }
        let batt = b.map { "Battery \($0.percent)%\($0.onBattery ? "" : ", plugged in")" } ?? "No battery"
        menu.addItem(disabled(batt))
        menu.addItem(disabled("Claude processes running: \(agents.map(String.init) ?? "unknown")"))
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

    /// Recent handoff files from handoffs.log. Lines are "time<TAB>path<TAB>cwd"
    /// (older lines have no cwd). Relative paths resolve against the recorded cwd.
    func recentHandoffs() -> [String] {
        guard FileManager.default.fileExists(atPath: handoffLog.path) else { return [] }
        let text: String
        do { text = try String(contentsOf: handoffLog, encoding: .utf8) } catch {
            logLine("could not read \(handoffLog.path): \(error.localizedDescription)")
            return []
        }
        var seen = Set<String>(), out: [String] = []
        for line in text.split(separator: "\n").reversed() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 2,
                  let path = resolveHandoff(cols[1], cwd: cols.count >= 3 ? cols[2] : nil) else { continue }
            if seen.insert(path).inserted, FileManager.default.fileExists(atPath: path) { out.append(path) }
            if out.count >= 10 { break }
        }
        return out
    }

    @objc func wrapUp() {
        do {
            try FileManager.default.createDirectory(at: lcDir, withIntermediateDirectories: true)
            // O_NOFOLLOW: never create or truncate through a symlink.
            let fd = open(overrideFile.path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o644)
            if fd < 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            close(fd)
            succeeded()
            refresh()
        } catch {
            failed("Could not start the wrap up", error)
        }
    }

    @objc func resume() {
        do {
            // Only ever remove the marker file itself, never a directory or a link target.
            if unlink(overrideFile.path) != 0 && errno != ENOENT {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            succeeded()
            refresh()
        } catch {
            failed("Could not resume normal", error)
        }
    }

    @objc func openHandoff(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        if NSWorkspace.shared.open(URL(fileURLWithPath: p)) { succeeded(); refresh() }
        else { failed("Could not open \(p.replacingOccurrences(of: home.path, with: "~"))") }
    }

    @objc func openSettings() {
        do {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: configFile.path)) != nil {
                failed("~/.lastcall/config is a symlink; not writing it"); return
            }
            if !FileManager.default.fileExists(atPath: configFile.path) {
                let defaults = "# Last Call levels (battery percent, on battery only)\nWARN_AT=20\nWRAP_AT=10\nSTOP_AT=5\n# Set ENABLED=0 to turn the hook off\nENABLED=1\n"
                try FileManager.default.createDirectory(at: lcDir, withIntermediateDirectories: true)
                try defaults.write(to: configFile, atomically: true, encoding: .utf8)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-t", configFile.path]
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { failed("Could not open ~/.lastcall/config"); return }
            succeeded()
            refresh()
        } catch {
            failed("Could not open ~/.lastcall/config", error)
        }
    }

    @objc func toggleLogin() {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: launchAgent.path) {
                try fm.removeItem(at: launchAgent)
            } else {
                let appPath = Bundle.main.bundlePath
                let plist: [String: Any] = [
                    "Label": "com.lastagentcall.menubar",
                    "ProgramArguments": ["/usr/bin/open", "-a", appPath],
                    "RunAtLoad": true,
                ]
                try fm.createDirectory(at: launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: launchAgent, options: .atomic)
            }
            succeeded()
            refresh()
        } catch {
            failed("Could not change Launch at login", error)
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
