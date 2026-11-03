import Foundation

/// The heaviest CPU users right now, grouped by app so an app's helper
/// processes (Chrome renderers, Electron helpers…) count as one entry.
enum TopCPU {
    struct Entry { let name: String; let cpu: Double; let processes: Int }

    /// Uses /bin/ps because it runs setuid root and can see every process's CPU use,
    /// including system daemons that the app itself isn't allowed to read.
    /// `cpu` is percent of one core, the same as Activity Monitor and `cputemp`.
    static func sample(limit: Int = 3) -> [Entry] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pcpu=,pid=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        let me = Int(getpid())
        var totals: [String: (cpu: Double, n: Int)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let cpu = Double(parts[0]), let pid = Int(parts[1]), pid != me else { continue }
            let name = HardReset.displayName(String(parts[2]))
            totals[name, default: (0, 0)].cpu += cpu
            totals[name, default: (0, 0)].n += 1
        }
        return totals.map { Entry(name: $0.key, cpu: $0.value.cpu, processes: $0.value.n) }
            .sorted { $0.cpu > $1.cpu }
            .prefix(limit)
            .map { $0 }
    }
}
