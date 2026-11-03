import AppKit
import ServiceManagement

/// Insets that line custom menu views up with standard items on macOS 26:
/// text starts after the checkmark column, and trailing content ends where "⌘Q" does.
enum MenuMetrics {
    static let leading: CGFloat = 30
    static let trailing: CGFloat = 16
}

final class SparklineView: NSView {
    var samples: [Double] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let inset = NSRect(x: MenuMetrics.leading, y: 6,
                           width: bounds.width - MenuMetrics.leading - MenuMetrics.trailing, height: bounds.height - 12)
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
    private let valueLabel = NSTextField(labelWithString: "")
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
    /// Optional right-aligned value, e.g. "38%".
    var value: String {
        get { valueLabel.stringValue }
        set { valueLabel.stringValue = newValue }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        autoresizingMask = [.width]   // stretch to the menu's width
        label.font = .menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .right
        for v in [label, valueLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.leading),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailing),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let historyLength = 120          // 2 minutes at 1s
    private let sensors = TempSensors()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sparkline: SparklineView = {
        let v = SparklineView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        v.autoresizingMask = [.width]   // stretch to the menu's width
        return v
    }()
    private let maxRow = ReadoutView()
    private let avgRow = ReadoutView()
    private let peakRow = ReadoutView()
    private let topRows = (0..<3).map { _ in ReadoutView() }
    private var menuOpen = false
    private var topTicks = 0
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private var history: [Double] = []
    private var log: [Sample] = []
    private lazy var hardResetItem = makeHardResetItem()
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
        menu.delegate = self
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
        menu.addItem(.sectionHeader(title: "Top CPU (% of one core)"))
        for row in topRows {
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
        }
        menu.addItem(.separator())
        styleHardResetItem(highlighted: false)
        menu.addItem(hardResetItem)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        refreshLoginState()
        tick()
        if CommandLine.arguments.contains("--show-menu") { showMenuForScreenshot() }
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

        maxRow.text = "Hottest core"
        maxRow.value = String(format: "%.1f °C", reading.max)
        avgRow.text = "Average (\(reading.sensorCount) sensors)"
        avgRow.value = String(format: "%.1f °C", reading.average)
        peakRow.text = "Peak this session"
        peakRow.value = String(format: "%.1f °C", sessionPeak)
        sparkline.samples = history
        if menuOpen {
            topTicks += 1
            if topTicks % 2 == 0 { refreshTopCPU() }
        }
    }

    /// systemRed is too light to read as text on the light menu background.
    /// This is a deep red in light mode (about 6:1 contrast) and a soft red in dark mode.
    private static let dangerRed = NSColor(name: "dangerRed") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.40, alpha: 1)    // #FF6B66
            : NSColor(srgbRed: 0.70, green: 0.08, blue: 0.08, alpha: 1)   // #B31414
    }

    /// Red normally; white while highlighted, because red on the blue selection is unreadable.
    private func styleHardResetItem(highlighted: Bool) {
        let color = highlighted ? NSColor.white : Self.dangerRed
        hardResetItem.attributedTitle = NSAttributedString(string: "Kill All Background Processes…", attributes: [
            .foregroundColor: color,
            .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold),
        ])
        hardResetItem.image = NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: "Danger")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        styleHardResetItem(highlighted: item === hardResetItem)
    }

    /// `open -a CPUTemp --args --show-menu`: opens the menu for 12 s, for screenshots while developing.
    private func showMenuForScreenshot() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let menu = self.statusItem.menu else { return }
            let close = Timer(timeInterval: 12, repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(close, forMode: .common)
            self.statusItem.button?.performClick(nil)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        topTicks = 0
        refreshTopCPU()
    }

    /// Only sampled while the menu is open (every 2 s), so it costs nothing otherwise.
    private func refreshTopCPU() {
        DispatchQueue.global(qos: .utility).async {
            let top = TopCPU.sample(limit: self.topRows.count)
            // .common so the update lands while the menu is open and tracking events.
            RunLoop.main.perform(inModes: [.common]) {
                for (i, row) in self.topRows.enumerated() {
                    let e = i < top.count ? top[i] : nil
                    row.text = e.map { $0.processes > 1 ? "\($0.name) (\($0.processes))" : $0.name } ?? ""
                    row.value = e.map { String(format: "%.0f%%", $0.cpu) } ?? ""
                    row.needsLayout = true
                    row.layoutSubtreeIfNeeded()
                }
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        styleHardResetItem(highlighted: false)
    }

    private func makeHardResetItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(confirmHardReset), keyEquivalent: "")
        item.target = self
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

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
