import AppKit
import ServiceManagement

@main
@MainActor
final class LLMUsageWidgetApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = LLMUsageWidgetApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    /// How often to update the system stats. CPU and network are averages over this time.
    private static let systemInterval: TimeInterval = 10
    /// How often to ask the CLIs for quota usage.
    private static let llmInterval: TimeInterval = 120
    /// After this long without a good result, the label shows "?" in place of a number.
    private static let staleAfter: TimeInterval = 3 * llmInterval
    private static let projectURL = URL(string: "https://github.com/Tristan-Wilson/llm-usage-widget")!

    private let stats = SystemStats()
    private var claude = ProviderState()
    private var codex = ProviderState()
    private var isRefreshing = false

    private var llmStatusItem: NSStatusItem!
    private var systemStatusItem: NSStatusItem!
    private let menu = NSMenu()

    private let cpuItem = NSMenuItem()
    private let gpuItem = NSMenuItem()
    private let memoryItem = NSMenuItem()
    private let pressureItem = NSMenuItem()
    private let networkItem = NSMenuItem()
    private let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
    private let systemToggleItem = NSMenuItem(
        title: "Show System Stats", action: #selector(toggleSystemStats), keyEquivalent: "")
    private let loginItem = NSMenuItem(
        title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
    private let versionItem = NSMenuItem(title: "", action: #selector(openProjectPage), keyEquivalent: "")
    private let quitItem = NSMenuItem(
        title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    private let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    private var text: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.labelColor] }
    private var dimText: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.secondaryLabelColor] }
    private var alertText: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.systemOrange] }

    private var showSystemStats: Bool {
        get { UserDefaults.standard.bool(forKey: "showSystemStats") }
        set { UserDefaults.standard.set(newValue, forKey: "showSystemStats") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // New status items go to the left of older ones, and macOS hides the leftmost items
        // first when the menu bar is full. So the LLM item is made first, to stay visible longest.
        llmStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        llmStatusItem.autosaveName = "llm"
        systemStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        systemStatusItem.autosaveName = "system"
        systemStatusItem.isVisible = showSystemStats

        menu.autoenablesItems = false
        menu.delegate = self
        llmStatusItem.menu = menu
        systemStatusItem.menu = menu
        for item in [refreshItem, systemToggleItem, loginItem, versionItem] {
            item.target = self
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        versionItem.title = "Version \(version) · Open on GitHub"

        // Turn on Start at Login the first time the app runs. After that, the menu toggle decides.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "loginItemConfigured") {
            setLoginItem(enabled: true)
            defaults.set(true, forKey: "loginItemConfigured")
        }
        updateLoginItem()

        renderLLM()
        // Keep sampling while the system item is hidden, so the first values after "show" are correct.
        Task {
            while !Task.isCancelled {
                stats.sample()
                renderSystem()
                // CPU and network need two samples, so take the second one soon after launch.
                try? await Task.sleep(for: .seconds(stats.cpu == nil ? 1 : Self.systemInterval))
            }
        }
        Task {
            while !Task.isCancelled {
                await refreshLLM()
                try? await Task.sleep(for: .seconds(Self.llmInterval))
            }
        }
    }

    // MARK: - LLM usage

    private func refreshLLM() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        async let claudeResult = ClaudeUsageProbe.run()
        async let codexResult = CodexUsageProbe.run()
        claude.record(await claudeResult)
        codex.record(await codexResult)
        isRefreshing = false
        renderLLM()
    }

    @objc private func refreshNow() {
        Task { await refreshLLM() }
    }

    private func renderLLM() {
        let title = NSMutableAttributedString()
        for (name, state) in [("Claude", claude), ("Codex", codex)] where !state.isHidden {
            if title.length > 0 { title.append(NSAttributedString(string: "  ", attributes: text)) }
            appendLabel(name, state, to: title)
        }
        if title.length == 0 {
            // Keep the item visible, so that the menu (and Quit) can still be reached.
            title.append(NSAttributedString(string: "LLM –", attributes: dimText))
        }
        llmStatusItem.button?.attributedTitle = title
    }

    private func appendLabel(_ name: String, _ state: ProviderState, to title: NSMutableAttributedString) {
        title.append(NSAttributedString(string: "\(name) ", attributes: text))

        // These need action from the user, so show them at once, not only when the numbers get old.
        switch state.error?.kind {
        case .loginRequired?:
            title.append(NSAttributedString(string: "login", attributes: alertText))
            return
        case .unreadable?:
            title.append(NSAttributedString(string: "error", attributes: alertText))
            return
        default:
            break
        }

        let windows = state.snapshot?.windows.filter(\.inLabel) ?? []
        guard let lastSuccess = state.lastSuccess,
              Date().timeIntervalSince(lastSuccess) < Self.staleAfter,
              !windows.isEmpty
        else {
            // No result yet, or the last one is too old to trust: show no number.
            let waiting = state.lastSuccess == nil && state.error == nil
            title.append(NSAttributedString(string: waiting ? "…" : "?", attributes: dimText))
            return
        }

        for (index, window) in windows.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "·", attributes: dimText)) }
            let color = usageColor(window.usedRatio)
            title.append(NSAttributedString(
                string: percentText(window.usedRatio),
                attributes: text.merging([.foregroundColor: color]) { $1 }))
        }
    }

    private func usageColor(_ ratio: Double) -> NSColor {
        switch ratio {
        case 0.9...: .systemRed
        case 0.75...: .systemOrange
        default: .labelColor
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !claude.isHidden {
            addSection("Claude", claude, loginCommand: "claude /login", to: menu)
        }
        if !codex.isHidden {
            addSection("Codex", codex, loginCommand: "codex login", to: menu)
        }
        if claude.isHidden, codex.isHidden {
            menu.addItem(infoItem("No Claude Code or Codex plan found"))
            menu.addItem(.separator())
        }

        if showSystemStats {
            menu.addItem(.sectionHeader(title: "System"))
            for item in [cpuItem, gpuItem, memoryItem, pressureItem, networkItem] {
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        refreshItem.title = isRefreshing ? "Refreshing…" : "Refresh Now"
        refreshItem.isEnabled = !isRefreshing
        systemToggleItem.state = showSystemStats ? .on : .off
        for item in [refreshItem, systemToggleItem, loginItem, .separator(), versionItem, quitItem] {
            menu.addItem(item)
        }
    }

    private func addSection(_ title: String, _ state: ProviderState, loginCommand: String, to menu: NSMenu) {
        menu.addItem(.sectionHeader(title: title))
        let now = Date()

        for window in state.snapshot?.windows ?? [] {
            var line = "\(window.title): \(percentText(window.usedRatio))"
            if let reset = window.resetsAt {
                line += " · resets \(resetText(reset, now: now))"
            }
            menu.addItem(withTitle: line, action: nil, keyEquivalent: "")
        }
        for note in state.snapshot?.notes ?? [] {
            menu.addItem(withTitle: note, action: nil, keyEquivalent: "")
        }

        if let error = state.error {
            let reason = error.reason.prefix(1).uppercased() + error.reason.dropFirst()
            menu.addItem(withTitle: "⚠︎ \(reason)", action: nil, keyEquivalent: "")
            switch error.kind {
            case .loginRequired:
                menu.addItem(infoItem("Run “\(loginCommand)” in Terminal"))
            case .unreadable:
                menu.addItem(infoItem("The CLI output changed. Check for an app update."))
            default:
                break
            }
        }

        if let lastSuccess = state.lastSuccess {
            menu.addItem(infoItem(
                "Updated " + RelativeDateTimeFormatter().localizedString(for: lastSuccess, relativeTo: now)))
        } else {
            menu.addItem(infoItem(state.error == nil ? "Loading…" : "No data yet"))
        }
        menu.addItem(.separator())
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openProjectPage() {
        NSWorkspace.shared.open(Self.projectURL)
    }

    // MARK: - System stats

    @objc private func toggleSystemStats() {
        showSystemStats.toggle()
        systemStatusItem.isVisible = showSystemStats
    }

    private func renderSystem() {
        let dot = text.merging([.foregroundColor: stats.pressure.color]) { $1 }

        let title = NSMutableAttributedString(
            string: "CPU \(percent(stats.cpu))  GPU \(percent(stats.gpu))  MEM \(gigabytes(stats.memoryUsed)) ",
            attributes: text)
        title.append(NSAttributedString(string: "●", attributes: dot))
        title.append(NSAttributedString(
            string: "  ↓\(shortRate(stats.download)) ↑\(shortRate(stats.upload))",
            attributes: text))
        systemStatusItem.button?.attributedTitle = title

        cpuItem.title = "CPU: \(stats.cpu.map { "\($0)%" } ?? "–")"
        gpuItem.title = "GPU: \(stats.gpu.map { "\($0)%" } ?? "–")"
        memoryItem.title = stats.memoryUsed.map {
            String(format: "Memory: %.1f GB of %.0f GB used", gib($0), gib(stats.memoryTotal))
        } ?? "Memory: –"
        pressureItem.title = "Memory pressure: \(stats.pressure.name)"
        networkItem.title = "Network: ↓ \(longRate(stats.download))   ↑ \(longRate(stats.upload))"
    }

    // MARK: - Start at Login

    @objc private func toggleLoginItem() {
        setLoginItem(enabled: SMAppService.mainApp.status != .enabled)
        updateLoginItem()
    }

    private func setLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Could not change login item: \(error)")
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func updateLoginItem() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

private extension MemoryPressure {
    var color: NSColor {
        switch self {
        case .normal: .systemGreen
        case .warning: .systemYellow
        case .critical: .systemRed
        case .unknown: .secondaryLabelColor
        }
    }
}

// MARK: - Formatting

/// A figure space is as wide as a digit, so padded values keep the label width steady.
private let figureSpace: Character = "\u{2007}"

private func padded(_ s: String, to width: Int) -> String {
    String(repeating: figureSpace, count: max(0, width - s.count)) + s
}

private func percent(_ value: Int?) -> String {
    padded(value.map { "\($0)" } ?? "–", to: 2) + "%"
}

private func percentText(_ ratio: Double) -> String {
    "\(Int((ratio * 100).rounded()))%"
}

/// "in 17m (14:50)", "in 2d 14h (Wed 05:00)", in the user's 12- or 24-hour style.
private func resetText(_ date: Date, now: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSince(now)))
    let days = seconds / 86_400
    let hours = seconds % 86_400 / 3600
    let minutes = seconds % 3600 / 60
    let relative = days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"

    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate(
        Calendar.current.isDate(date, inSameDayAs: now) ? "jmm" : "EEE jmm")
    return "in \(relative) (\(formatter.string(from: date)))"
}

private func gib(_ bytes: UInt64) -> Double {
    Double(bytes) / 1_073_741_824
}

private func gigabytes(_ bytes: UInt64?) -> String {
    padded(bytes.map { String(format: "%.1f", gib($0)) } ?? "–", to: 4) + "G"
}

/// Bytes per second in at most 4 characters: "0K"…"999K", "1.2M", "45M", "1.1G".
private func shortRate(_ bytesPerSecond: Double?) -> String {
    guard let b = bytesPerSecond else { return padded("–", to: 4) }
    let s: String
    switch b {
    case ..<999_500: s = "\(Int((b / 1e3).rounded()))K"
    case ..<9_950_000: s = String(format: "%.1fM", b / 1e6)
    case ..<999_500_000: s = "\(Int((b / 1e6).rounded()))M"
    default: s = String(format: "%.1fG", b / 1e9)
    }
    return padded(s, to: 4)
}

private let rateFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    formatter.allowsNonnumericFormatting = false
    return formatter
}()

private func longRate(_ bytesPerSecond: Double?) -> String {
    guard let b = bytesPerSecond else { return "–" }
    return rateFormatter.string(fromByteCount: Int64(b)) + "/s"
}
