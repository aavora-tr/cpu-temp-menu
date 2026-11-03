import AppKit
import Darwin

/// "Hard reset" without a reboot: terminate every process the current user owns
/// except macOS system processes and the core UI, so the session stays logged in.
enum HardReset {
    struct Target { let pid: pid_t; let name: String }

    /// Executables under these prefixes belong to macOS itself and are never touched.
    private static let protectedPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
    /// Core session UI, spared by name as a safety net (killing loginwindow logs you out).
    private static let protectedNames: Set<String> = [
        "loginwindow", "Finder", "Dock", "SystemUIServer", "ControlCenter",
        "NotificationCenter", "WindowManager", "Spotlight", "launchd",
        // Device management: killing these can flag the Mac as non-compliant.
        "Microsoft Intune Agent", "Company Portal",
    ]

    static func targets() -> [Target] {
        let me = getpid(), uid = getuid()
        var result: [pid_t: Target] = [:]

        // Every process owned by this user that isn't macOS's own.
        let count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(Int(max(n, 0))) where pid > 1 && pid != me {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  info.pbi_uid == uid else { continue }
            guard let path = executablePath(pid) else { continue }
            if protectedPrefixes.contains(where: path.hasPrefix) { continue }
            let name = displayName(path)
            if protectedNames.contains(name) { continue }
            result[pid] = Target(pid: pid, name: name)
        }

        // Plus every open GUI app, including Apple ones in /System/Applications (Terminal, Mail...).
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier, name = app.localizedName ?? "app"
            if pid == me || protectedNames.contains(name) || app.bundleIdentifier == "com.apple.finder" { continue }
            result[pid] = Target(pid: pid, name: name)
        }
        return Array(result.values)
    }

    /// SIGTERM everything, then SIGKILL whatever is still alive after `grace` seconds.
    static func kill(_ targets: [Target], grace: TimeInterval = 3) -> (terminated: Int, forced: Int) {
        for t in targets { Darwin.kill(t.pid, SIGTERM) }
        Thread.sleep(forTimeInterval: grace)
        var forced = 0
        for t in targets where Darwin.kill(t.pid, 0) == 0 {
            if Darwin.kill(t.pid, SIGKILL) == 0 { forced += 1 }
        }
        return (targets.count - forced, forced)
    }

    /// "Google Chrome ×38, node ×12, claude ×3, …" for the confirmation dialog.
    static func summary(_ targets: [Target], limit: Int = 12) -> String {
        let counts = Dictionary(grouping: targets, by: \.name).mapValues(\.count)
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var parts = counts.prefix(limit).map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
        if counts.count > limit { parts.append("and \(counts.count - limit) more") }
        return parts.joined(separator: ", ")
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// App name for anything inside a .app bundle (so Electron helpers group under their app), else the binary name.
    private static func displayName(_ path: String) -> String {
        if let r = path.range(of: ".app/") {   // outermost bundle
            return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
        }
        // Versioned binaries (Claude Code lives at .../claude/versions/2.1.317): use the first
        // path component up the tree that isn't a version number or a "versions" folder.
        let parts = path.split(separator: "/").map(String.init)
        return parts.last { !($0.first?.isNumber ?? true) && $0 != "versions" } ?? (path as NSString).lastPathComponent
    }
}
