import AppKit
import ServiceManagement

final class SparklineView: NSView {
    var samples: [Double] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 14, dy: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4).fill()
        guard samples.count > 1, let lo = samples.min(), let hi = samples.max() else { return }
        let floor = lo - 2, range = max(hi + 2 - floor, 1)
        let path = NSBezierPath()
        for (i, v) in samples.enumerated() {
            let x = inset.minX + inset.width * CGFloat(i) / CGFloat(AppDelegate.historyLength - 1)
            let y = inset.minY + inset.height * CGFloat((v - floor) / range)
            i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
        }
        AppDelegate.color(for: samples.last!).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

/// Info row drawn as a plain label. Menu items without an action are drawn
/// disabled (dimmed grey) no matter what colour their title asks for; a custom
/// view sidesteps that and stays full-contrast in light and dark mode.
final class ReadoutView: NSView {
    private let label = NSTextField(labelWithString: "")
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        label.font = .menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let historyLength = 120          // 2 minutes at 1s
    private let sensors = TempSensors()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sparkline = SparklineView(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
    private let maxRow = ReadoutView()
    private let avgRow = ReadoutView()
    private let peakRow = ReadoutView()
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private var history: [Double] = []
    private var log: [Sample] = []
    private static let logLength = 600     // 10 minutes, shared with the cputemp CLI
    private var sessionPeak = 0.0

    static func color(for temp: Double) -> NSColor {
        switch temp {
        case ..<60: return .systemGreen
        case ..<80: return .systemOrange
        default: return .systemRed
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "CPU Temperature"))
        let chartItem = NSMenuItem()
        chartItem.view = sparkline
        menu.addItem(chartItem)
        for row in [maxRow, avgRow, peakRow] {
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(makeHardResetItem())
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        refreshLoginState()
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)   // keep updating while the menu is open
    }

    private func tick() {
        guard let reading = sensors.read() else {
            statusItem.button?.title = "--°"
            return
        }
        history.append(reading.max)
        if history.count > Self.historyLength { history.removeFirst() }
        sessionPeak = max(sessionPeak, reading.max)
        log.append(Sample(t: Date(), max: reading.max, avg: reading.average))
        if log.count > Self.logLength { log.removeFirst() }
        History.save(log)

        let text = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: Self.color(for: reading.max)])
        text.append(NSAttributedString(string: String(format: "%.0f°C", reading.max),
                                       attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)]))
        statusItem.button?.attributedTitle = text

        maxRow.text = String(format: "Hottest core:  %.1f °C", reading.max)
        avgRow.text = String(format: "Average (%d sensors):  %.1f °C", reading.sensorCount, reading.average)
        peakRow.text = String(format: "Peak this session:  %.1f °C", sessionPeak)
        sparkline.samples = history
    }

    private func makeHardResetItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(confirmHardReset), keyEquivalent: "")
        item.target = self
        item.attributedTitle = NSAttributedString(string: "Kill All Background Processes…", attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.menuFont(ofSize: 0),
        ])
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        item.image = NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: "Danger")?
            .withSymbolConfiguration(config)
        item.toolTip = """
            DANGER: hard reset without restarting.
            Force-quits every process you own: all open apps (unsaved work is lost), \
            Terminal and its shells, AI agents (Claude Code, etc.), node/python, \
            MCP servers, dev servers and Electron helpers.
            Spared: macOS system processes, Finder, Dock and the menu bar.
            You'll see what will be killed and confirm first.
            """
        return item
    }

    @objc private func confirmHardReset() {
        let targets = HardReset.targets()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Kill \(targets.count) processes?"
        alert.informativeText = """
            This force-quits all your apps, terminals, AI agents, node processes and \
            other background work. Unsaved changes will be lost. macOS system \
            processes, Finder, Dock and the menu bar are spared.

            \(HardReset.summary(targets))
            """
        let kill = alert.addButton(withTitle: "Kill \(targets.count) Processes")
        kill.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        kill.keyEquivalent = ""   // Return must not trigger the destructive action
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = HardReset.kill(targets)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let done = NSAlert()
                done.messageText = "Hard reset complete"
                done.informativeText = "\(result.terminated) processes exited, \(result.forced) had to be force-killed."
                done.runModal()
            }
        }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("Launch at login toggle failed: \(error)")
        }
        refreshLoginState()
    }

    private func refreshLoginState() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
