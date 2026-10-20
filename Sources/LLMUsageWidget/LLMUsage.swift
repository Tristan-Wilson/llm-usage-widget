import Foundation

// MARK: - Model

struct UsageWindow: Sendable {
    let title: String
    /// 0...1
    let usedRatio: Double
    let resetsAt: Date?
    /// Shown in the menu bar label. Other windows show only in the menu.
    let inLabel: Bool
}

struct UsageSnapshot: Sendable {
    let windows: [UsageWindow]
    let notes: [String]
}

/// Why a probe gave no usage. The reason is a short fixed text, never raw command output.
struct ProbeError: Error, Sendable {
    enum Kind: Sendable {
        /// The CLI is not installed. The app hides the provider.
        case notInstalled
        /// The account has no plan limits, for example an API key. The app hides the provider.
        case noPlanLimits
        /// The user must log in again.
        case loginRequired
        /// The CLI's output changed and the app cannot read it. The app probably needs an update.
        case unreadable
        /// A timeout, crash or server error. Probably temporary.
        case failed
    }

    let kind: Kind
    let reason: String

    init(_ kind: Kind, _ reason: String) {
        self.kind = kind
        self.reason = reason
    }
}

struct ProviderState {
    private(set) var snapshot: UsageSnapshot?
    private(set) var lastSuccess: Date?
    private(set) var error: ProbeError?

    var isHidden: Bool {
        error?.kind == .notInstalled || error?.kind == .noPlanLimits
    }

    mutating func record(_ result: Result<UsageSnapshot, ProbeError>) {
        switch result {
        case .success(let new):
            snapshot = new
            lastSuccess = Date()
            error = nil
        case .failure(let failure):
            error = failure
        }
    }
}

// MARK: - Claude

/// Reads the quota from the text that Claude Code's `/usage` command prints. That text is
/// not a stable API: if a release changes the wording, the probe fails. It never guesses.
enum ClaudeUsageProbe {
    static func run() async -> Result<UsageSnapshot, ProbeError> {
        do {
            guard let claude = findExecutable("claude") else { throw ProbeError(.notInstalled, "claude not found") }

            let status = try await runCommand(claude, ["auth", "status", "--json"], timeout: 20)
            guard let json = try? JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any],
                  let loggedIn = json["loggedIn"] as? Bool
            else { throw ProbeError(.unreadable, "unexpected auth status output") }
            guard loggedIn else { throw ProbeError(.loginRequired, "not logged in") }

            let output = try await runCommand(
                claude,
                ["-p", "/usage", "--safe-mode", "--strict-mcp-config", "--no-session-persistence"],
                timeout: 100, includeStderr: true)
            do {
                return .success(try parse(output, now: Date()))
            } catch let error as ProbeError {
                // Look for other causes only when the usage lines are missing:
                // the usage report itself can contain text such as "401 requests".
                if let reason = authFailure(in: output) { throw ProbeError(.loginRequired, reason) }
                if isKnownNonSubscription(json) { throw ProbeError(.noPlanLimits, "no plan limits") }
                throw error
            }
        } catch let error as ProbeError {
            return .failure(error)
        } catch {
            return .failure(ProbeError(.failed, "could not run claude"))
        }
    }

    // "Current session: 27% used · resets Oct 19 at 2:50pm (Europe/Zurich)"
    // "Current week (all models): 17% used · resets Oct 22 at 5am (Europe/Zurich)"
    // "Current week (Fable): 17% used · resets in 2h 15m"
    private static let linePattern =
        #"^Current (session|week(?: \(([^)]+)\))?): (\d+(?:\.\d+)?)% used(?:\s*[·•]\s*resets (.+))?$"#

    static func parse(_ output: String, now: Date) throws -> UsageSnapshot {
        var windows: [UsageWindow] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let m = captures(linePattern, in: line) else { continue }
            guard let percent = m[3].flatMap(Double.init) else { throw ProbeError(.unreadable, "unexpected /usage output") }

            var resetsAt: Date?
            if let phrase = m[4] {
                guard let date = parseReset(phrase, now: now) else {
                    throw ProbeError(.unreadable, "could not read reset time")
                }
                resetsAt = date
            }

            let isSession = m[1]?.lowercased() == "session"
            let model = m[2]
            let allModels = model == nil || model?.lowercased() == "all models"
            windows.append(UsageWindow(
                title: isSession ? "Session" : allModels ? "Week" : "Week (\(model!))",
                usedRatio: percent / 100,
                resetsAt: resetsAt,
                inLabel: isSession || allModels))
        }
        guard !windows.isEmpty else { throw ProbeError(.unreadable, "no usage lines in /usage output") }
        return UsageSnapshot(windows: windows, notes: [])
    }

    /// Reads "in 2h 15m", "Oct 22 at 5am (Europe/Zurich)", "Oct 24, 3pm (…)" or "3pm (…)".
    /// A time outside now-1d…now+8d counts as a parse failure.
    static func parseReset(_ phrase: String, now: Date) -> Date? {
        guard let date = relativeReset(phrase, now: now) ?? absoluteReset(phrase, now: now),
              date > now.addingTimeInterval(-86_400),
              date < now.addingTimeInterval(8 * 86_400)
        else { return nil }
        return date
    }

    private static func relativeReset(_ phrase: String, now: Date) -> Date? {
        guard let m = captures(#"^in\s+(?:(\d+)d\s*)?(?:(\d+)h\s*)?(?:(\d+)m(?:in)?)?$"#, in: phrase),
              m[1...3].contains(where: { $0 != nil })
        else { return nil }
        let days = m[1].flatMap(Double.init) ?? 0
        let hours = m[2].flatMap(Double.init) ?? 0
        let minutes = m[3].flatMap(Double.init) ?? 0
        return now.addingTimeInterval(days * 86_400 + hours * 3600 + minutes * 60)
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static func absoluteReset(_ phrase: String, now: Date) -> Date? {
        let pattern = #"^(?:([A-Za-z]{3})\s+(\d{1,2})(?:,|\s+at)?\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)$"#
        guard let m = captures(pattern, in: phrase),
              let hour12 = m[3].flatMap(Int.init), (1...12).contains(hour12),
              let zone = m[6].flatMap(TimeZone.init(identifier:))
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hour = hour12 % 12 + (m[5]?.lowercased() == "pm" ? 12 : 0)
        let minute = m[4].flatMap(Int.init) ?? 0
        let today = calendar.dateComponents([.year, .month, .day], from: now)

        // The text gives no year, and sometimes no date. Take the candidate nearest to now.
        var candidates: [Date] = []
        if let monthName = m[1] {
            guard let month = months.firstIndex(of: monthName.lowercased()),
                  let day = m[2].flatMap(Int.init), (1...31).contains(day)
            else { return nil }
            for year in today.year! - 1 ... today.year! + 1 {
                let components = DateComponents(year: year, month: month + 1, day: day, hour: hour, minute: minute)
                if let date = calendar.date(from: components) { candidates.append(date) }
            }
        } else {
            let components = DateComponents(
                year: today.year, month: today.month, day: today.day, hour: hour, minute: minute)
            guard let date = calendar.date(from: components) else { return nil }
            for offset in -1...1 {
                if let candidate = calendar.date(byAdding: .day, value: offset, to: date) { candidates.append(candidate) }
            }
        }
        return candidates.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }

    private static func authFailure(in output: String) -> String? {
        let text = output.lowercased()
        if text.contains("expired"), text.contains("token") { return "login expired" }
        if text.contains("not logged in") || text.contains("/login") { return "not logged in" }
        if text.range(of: #"\b401\b"#, options: .regularExpression) != nil { return "unauthorized" }
        return nil
    }

    /// True only when the login is known to be something other than a claude.ai plan, such as
    /// an API key or a cloud provider. A missing field counts as unknown, not as "no plan".
    private static func isKnownNonSubscription(_ status: [String: Any]) -> Bool {
        if let method = status["authMethod"] as? String, method != "claude.ai" { return true }
        if let provider = status["apiProvider"] as? String, provider != "firstParty" { return true }
        return false
    }
}

// MARK: - Codex

/// Asks a short-lived `codex app-server` for the account's rate limits, over JSON-RPC on stdio.
enum CodexUsageProbe {
    // Without these flags the app-server runs the plugin auto-upgrade in the live ~/.codex
    // and loads plugins and MCP servers that a usage read does not need.
    private static let arguments = [
        "app-server", "--disable", "plugins", "--disable", "remote_plugin", "--disable", "apps",
        "-c", "mcp_servers={}",
    ]
    private static let timeout: Duration = .seconds(30)

    static func run() async -> Result<UsageSnapshot, ProbeError> {
        do {
            guard let codex = findExecutable("codex") else { throw ProbeError(.notInstalled, "codex not found") }
            return .success(try await probe(codex))
        } catch let error as ProbeError {
            return .failure(error)
        } catch {
            return .failure(ProbeError(.failed, "could not run codex"))
        }
    }

    private static func probe(_ codex: URL) async throws -> UsageSnapshot {
        let process = Process()
        process.executableURL = codex
        process.arguments = arguments
        process.environment = childEnvironment()
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            process.terminate()
        }

        let start = ContinuousClock.now
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            process.terminate()
        }
        defer { watchdog.cancel() }

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        try send([
            "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "llm-usage-widget", "version": "1.0"]],
        ])
        for try await line in output.fileHandleForReading.bytes.lines {
            // Skip notifications and requests from the server: only responses have no method.
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  message["method"] == nil,
                  let id = message["id"] as? Int
            else { continue }
            if let error = message["error"] as? [String: Any] { throw rpcFailure(error) }
            let result = message["result"] as? [String: Any] ?? [:]

            switch id {
            case 1:
                try send(["method": "initialized"])
                // refreshToken false: a presence check that never forces a token refresh.
                try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
            case 2:
                guard let account = result["account"] as? [String: Any] else {
                    // No account: logged out, or a custom model provider that needs no OpenAI login.
                    throw result["requiresOpenaiAuth"] as? Bool == true
                        ? ProbeError(.loginRequired, "not logged in")
                        : ProbeError(.noPlanLimits, "no plan limits")
                }
                // Only ChatGPT plans have rate limit windows.
                if ["apiKey", "amazonBedrock"].contains(account["type"] as? String) {
                    throw ProbeError(.noPlanLimits, "no plan limits")
                }
                try send(["id": 3, "method": "account/rateLimits/read", "params": ["excludeResetCreditDetails": true]])
            case 3:
                return try snapshot(from: result)
            default:
                continue
            }
        }
        throw ContinuousClock.now - start >= timeout
            ? ProbeError(.failed, "codex timed out")
            : ProbeError(.failed, "codex app-server stopped")
    }

    private static func snapshot(from result: [String: Any]) throws -> UsageSnapshot {
        guard let limits = result["rateLimitsByLimitId"] as? [String: Any]
            ?? (result["rateLimits"] as? [String: Any]).map({ ["codex": $0] })
        else { throw ProbeError(.unreadable, "unexpected rate limit data") }

        var windows: [UsageWindow] = []
        var notes: [String] = []
        // The main "codex" limit first, then any others by name.
        for (limitId, value) in limits.sorted(by: { ($0.key == "codex" ? "" : $0.key) < ($1.key == "codex" ? "" : $1.key) }) {
            guard let limit = value as? [String: Any] else { continue }
            let isMain = limitId == "codex"
            let prefix = isMain ? "" : "\(limit["limitName"] as? String ?? limitId) "

            for key in ["primary", "secondary"] {
                guard let window = limit[key] as? [String: Any] else { continue }
                guard let used = window["usedPercent"] as? Double else {
                    throw ProbeError(.unreadable, "unexpected rate limit data")
                }
                windows.append(UsageWindow(
                    title: prefix + windowTitle(minutes: window["windowDurationMins"] as? Int),
                    usedRatio: used / 100,
                    resetsAt: (window["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
                    inLabel: isMain))
            }
            if let reached = limit["rateLimitReachedType"] as? String {
                notes.append("Limit reached: " + reached.replacingOccurrences(of: "_", with: " "))
            }
            if limit["spendControlReached"] as? Bool == true { notes.append("Spend control reached") }
        }
        if result["ordinaryUsageAllowed"] as? Bool == false { notes.append("Ordinary usage not allowed") }

        // Reset credit data is optional: a missing or odd block never fails the probe.
        if let credits = result["rateLimitResetCredits"] as? [String: Any],
           let count = credits["availableCount"] as? Int, count > 0 {
            notes.append("\(count) reset credit\(count == 1 ? "" : "s") available")
        }

        guard !windows.isEmpty else { throw ProbeError(.unreadable, "no rate limit windows") }
        return UsageSnapshot(windows: windows, notes: notes)
    }

    private static func windowTitle(minutes: Int?) -> String {
        switch minutes {
        case 10_080?: "Week"
        case let m? where m % 1440 == 0: "\(m / 1440) days"
        case let m? where m % 60 == 0: "\(m / 60) hours"
        case let m?: "\(m) minutes"
        case nil: "Window"
        }
    }

    /// Maps a JSON-RPC error to a fixed reason. The error body is never shown or logged.
    private static func rpcFailure(_ error: [String: Any]) -> ProbeError {
        let text = (error["message"] as? String ?? "").lowercased()
        if text.contains("refresh"), text.contains("expired") { return ProbeError(.loginRequired, "login expired") }
        if text.contains("401") || text.contains("unauthorized") { return ProbeError(.loginRequired, "unauthorized") }
        return ProbeError(.failed, "app-server error")
    }
}

// MARK: - Commands

/// Where to look for the CLIs. Apps started at login get only a minimal PATH, so this uses the
/// PATH of the user's login shell (which finds npm and nvm installs), then the usual folders.
private let searchPath: [String] = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    let all = loginShellPath() + inherited + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    var seen = Set<String>()
    return all.filter { seen.insert($0).inserted }
}()

/// The PATH that the user's shell sets up, or an empty list if the shell does not answer in time.
private func loginShellPath() -> [String] {
    guard let entry = getpwuid(getuid()), let shellName = entry.pointee.pw_shell else { return [] }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("llm-usage-widget-env-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: String(cString: shellName))
    // -i as well as -l: many people set PATH (nvm, npm) in .zshrc, which only interactive shells read.
    // The output goes to a file, so background jobs that the shell starts cannot keep a pipe open.
    process.arguments = ["-i", "-l", "-c", "/usr/bin/env > '\(file.path)'"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    guard (try? process.run()) != nil else { return [] }
    if done.wait(timeout: .now() + 10) == .timedOut {
        process.terminate()
        return []
    }

    let environment = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    guard let line = environment.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("PATH=") })
    else { return [] }
    return line.dropFirst("PATH=".count).split(separator: ":").map(String.init)
}

private func findExecutable(_ name: String) -> URL? {
    searchPath.lazy
        .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

private func childEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = searchPath.joined(separator: ":")
    return environment
}

/// Runs a command to the end and returns its output. Stops it after `timeout` seconds.
private func runCommand(
    _ executable: URL, _ arguments: [String], timeout: TimeInterval, includeStderr: Bool = false
) async throws -> String {
    let name = executable.lastPathComponent
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = childEnvironment()
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let output = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = includeStderr ? output : FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProbeError(.failed, "could not start \(name)"))
                return
            }

            let start = Date()
            let watchdog = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()

            if process.terminationReason == .uncaughtSignal {
                let timedOut = Date().timeIntervalSince(start) >= timeout
                continuation.resume(throwing: ProbeError(.failed, timedOut ? "\(name) timed out" : "\(name) crashed"))
            } else {
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}

/// The capture groups of the first match, or nil if there is no match. Group 0 is the whole match.
private func captures(_ pattern: String, in text: String) -> [String?]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (0..<match.numberOfRanges).map { i in
        Range(match.range(at: i), in: text).map { String(text[$0]) }
    }
}
