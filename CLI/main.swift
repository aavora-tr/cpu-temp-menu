import Foundation

// cputemp — print a thermal snapshot of this Mac.
//   cputemp          human-readable report
//   cputemp --json   machine-readable report
//   cputemp --hook   Claude Code UserPromptSubmit hook: reads the hook payload on stdin and,
//                    when the prompt is about heat/performance, injects the report as context.

struct Proc: Codable { let name: String; let pid: Int; let cpu: Double }

struct Report: Codable {
    let timestamp: Date
    let hottestC: Double?
    let averageC: Double?
    let sensorCount: Int
    let thermalState: String
    let loadAverage: [Double]
    let cpuCores: Int
    let powerSource: String
    let trend: [String: Double]      // max temp N minutes ago, from the menu bar app's log
    let sessionPeakC: Double?
    let topProcesses: [Proc]
}

func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func topProcesses(limit: Int) -> [Proc] {
    shell("/bin/ps", ["-Aceo", "pcpu=,pid=,comm=", "-r"])
        .split(separator: "\n")
        .compactMap { line -> Proc? in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let cpu = Double(parts[0]), let pid = Int(parts[1]),
                  pid != Int(getpid()) else { return nil }
            return Proc(name: String(parts[2]), pid: pid, cpu: cpu)
        }
        .prefix(limit)
        .map { $0 }
}

func chipName() -> String {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "CPU" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    return String(cString: buf)
}

func thermalStateName() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious (throttling likely)"
    case .critical: return "critical (heavy throttling)"
    @unknown default: return "unknown"
    }
}

func powerSource() -> String {
    let out = shell("/usr/bin/pmset", ["-g", "batt"]).split(separator: "\n")
    let source = out.first.map { $0.contains("AC Power") ? "AC power" : "battery" } ?? "unknown"
    if let line = out.dropFirst().first, let pct = line.split(separator: "\t").last {
        return "\(source); \(pct.split(separator: ";").prefix(2).joined(separator: ";"))"
    }
    return source
}

func buildReport() -> Report {
    let reading = TempSensors().read()
    var load = [Double](repeating: 0, count: 3)
    getloadavg(&load, 3)

    let log = History.load()
    var trend: [String: Double] = [:]
    var peak: Double?
    if let last = log.last, Date().timeIntervalSince(last.t) < 30 {
        for minutes in [1, 5, 10] {
            let target = Date().addingTimeInterval(-Double(minutes) * 60)
            if let s = log.min(by: { abs($0.t.timeIntervalSince(target)) < abs($1.t.timeIntervalSince(target)) }),
               abs(s.t.timeIntervalSince(target)) < 30 {
                trend["\(minutes)m_ago"] = (s.max * 10).rounded() / 10
            }
        }
        peak = log.map(\.max).max()
    }

    return Report(timestamp: Date(),
                  hottestC: reading.map { ($0.max * 10).rounded() / 10 },
                  averageC: reading.map { ($0.average * 10).rounded() / 10 },
                  sensorCount: reading?.sensorCount ?? 0,
                  thermalState: thermalStateName(),
                  loadAverage: load.map { ($0 * 100).rounded() / 100 },
                  cpuCores: ProcessInfo.processInfo.activeProcessorCount,
                  powerSource: powerSource(),
                  trend: trend,
                  sessionPeakC: peak,
                  topProcesses: topProcesses(limit: 8))
}

func text(_ r: Report) -> String {
    func c(_ v: Double?) -> String { v.map { String(format: "%.1f°C", $0) } ?? "n/a" }
    var lines = [
        "CPU temperature (\(chipName()) die sensors, \(r.sensorCount) sensors)",
        "  hottest: \(c(r.hottestC))   average: \(c(r.averageC))",
        "  macOS thermal state: \(r.thermalState)",
    ]
    if !r.trend.isEmpty {
        let t = ["1m_ago", "5m_ago", "10m_ago"].compactMap { k in r.trend[k].map { "\(k.replacingOccurrences(of: "_ago", with: "")) ago \(c($0))" } }
        lines.append("  trend (hottest): " + t.joined(separator: ", ") + "; 10-min peak \(c(r.sessionPeakC))")
    }
    lines.append(String(format: "  load average: %.2f / %.2f / %.2f (1/5/15 min) on %d cores",
                        r.loadAverage[0], r.loadAverage[1], r.loadAverage[2], r.cpuCores))
    lines.append("  power: \(r.powerSource)")
    lines.append("Top processes by CPU (% of one core):")
    for p in r.topProcesses {
        lines.append(String(format: "  %6.1f%%  %@ (pid %d)", p.cpu, p.name as NSString, p.pid))
    }
    return lines.joined(separator: "\n")
}

let args = CommandLine.arguments.dropFirst()

if args.contains("--hook") {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let prompt = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any])?["prompt"] as? String ?? ""
    let pattern = #"\b(temp|temps|temperature|hot|hotter|heat|heating|thermal|throttl\w*|fans?|cpu|overheat\w*|warm|sluggish|laggy)\b"#
    guard prompt.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { exit(0) }
    let context = "Live system thermal snapshot from `cputemp` (taken as this prompt was sent; run `cputemp` again for a fresh reading):\n" + text(buildReport())
    let out = ["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": context]]
    FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: out))
} else if args.contains("--json") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try! encoder.encode(buildReport()))
    print()
} else {
    print(text(buildReport()))
}
