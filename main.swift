import AppKit
import CoreServices
import Foundation

// MARK: - Localization
private enum L10n {
    static let isChinese = Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true

    static func text(_ chinese: String, _ english: String) -> String {
        isChinese ? chinese : english
    }
}

// MARK: - Signal State
enum SignalState: String {
    case running
    case waiting
    case idle

    var title: String {
        switch self {
        case .running: return L10n.text("执行中", "Running")
        case .waiting: return L10n.text("待确认", "Needs attention")
        case .idle: return L10n.text("空闲", "Idle")
        }
    }

    var subtitle: String {
        switch self {
        case .running: return L10n.text("Codex 正在工作", "Codex is working")
        case .waiting: return L10n.text("需要你的选择", "Your input is required")
        case .idle: return L10n.text("随时可以开始", "Ready when you are")
        }
    }

    var color: NSColor {
        switch self {
        case .running: return NSColor(calibratedRed: 1.00, green: 0.25, blue: 0.22, alpha: 1)
        case .waiting: return NSColor(calibratedRed: 1.00, green: 0.73, blue: 0.16, alpha: 1)
        case .idle: return NSColor(calibratedRed: 0.24, green: 0.90, blue: 0.46, alpha: 1)
        }
    }
}

// MARK: - Data Models
struct StatusSnapshot: Equatable {
    let state: SignalState
    let activeCount: Int
    let weeklyRemainingPercent: Int?
}

private struct WeeklyUsage {
    let remainingPercent: Int
    let updatedAt: Date
}

private struct TurnRecord {
    let id: String
    let file: String
    let startedAt: Date
    var lastEventAt: Date
    var active: Bool
    var pendingInteractiveCalls: Set<String>
}

// MARK: - Notification Manager (轻量级系统通知)
final class NotificationManager {
    static let shared = NotificationManager()
    
    private var lastNotifiedState: SignalState?
    
    func notifyStateChange(_ state: SignalState, activeCount: Int = 0) {
        // 避免重复通知
        guard state != lastNotifiedState else { return }
        lastNotifiedState = state
        
        switch state {
        case .waiting:
            let body = L10n.text(
                "Codex 需要你的授权才能继续执行，请点击图标查看并确认。",
                "Codex needs your approval to continue. Click the icon to view and confirm."
            )
            sendNotification(
                title: L10n.text("🔔 Codex 等待授权", "🔔 Codex Needs Approval"),
                body: body,
                sound: true
            )
        case .running:
            if activeCount > 1 {
                let body = L10n.text(
                    "Codex 正在处理 \(activeCount) 个任务，请稍候。",
                    "Codex is processing \(activeCount) tasks. Please wait."
                )
                sendNotification(
                    title: L10n.text("⚙️ Codex 开始工作", "⚙️ Codex Started Working"),
                    body: body,
                    sound: false
                )
            }
        case .idle:
            // 空闲状态不发送通知
            break
        }
    }
    
    func resetState() {
        lastNotifiedState = nil
    }
    
    private func sendNotification(title: String, body: String, sound: Bool) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = sound ? NSUserNotificationDefaultSoundName : nil
        NSUserNotificationCenter.default.deliver(notification)
    }
}

// MARK: - Status Engine
final class StatusEngine {
    private var turns: [String: TurnRecord] = [:]
    private var currentTurnByFile: [String: String] = [:]
    private var pendingCallToTurn: [String: String] = [:]
    private var weeklyUsageByFile: [String: WeeklyUsage] = [:]
    private let timestampParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func removeEvents(from file: String) {
        let removedTurnIDs = turns.values.filter { $0.file == file }.map(\.id)
        for turnID in removedTurnIDs {
            turns.removeValue(forKey: turnID)
        }
        pendingCallToTurn = pendingCallToTurn.filter { !removedTurnIDs.contains($0.value) }
        currentTurnByFile.removeValue(forKey: file)
        weeklyUsageByFile.removeValue(forKey: file)
    }

    func process(line: Data, file: String) {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["type"] as? String,
            let payload = object["payload"] as? [String: Any]
        else {
            return
        }

        let eventDate = parseDate(object["timestamp"] as? String) ?? Date()

        if type == "event_msg", let payloadType = payload["type"] as? String {
            switch payloadType {
            case "task_started":
                guard let turnID = payload["turn_id"] as? String else { return }
                turns[turnID] = TurnRecord(
                    id: turnID,
                    file: file,
                    startedAt: eventDate,
                    lastEventAt: eventDate,
                    active: true,
                    pendingInteractiveCalls: []
                )
                currentTurnByFile[file] = turnID

            case "task_complete", "turn_aborted":
                guard let turnID = payload["turn_id"] as? String else { return }
                if var turn = turns[turnID] {
                    turn.active = false
                    turn.lastEventAt = eventDate
                    for callID in turn.pendingInteractiveCalls {
                        pendingCallToTurn.removeValue(forKey: callID)
                    }
                    turn.pendingInteractiveCalls.removeAll()
                    turns[turnID] = turn
                }

            case "token_count":
                if let rateLimits = payload["rate_limits"] as? [String: Any],
                   let weeklyUsage = parseWeeklyUsage(rateLimits, updatedAt: eventDate),
                   weeklyUsage.updatedAt >= (weeklyUsageByFile[file]?.updatedAt ?? .distantPast) {
                    weeklyUsageByFile[file] = weeklyUsage
                }
                touchCurrentTurn(for: file, at: eventDate)

            default:
                touchCurrentTurn(for: file, at: eventDate)
            }
            return
        }

        guard type == "response_item", let payloadType = payload["type"] as? String else {
            return
        }

        switch payloadType {
        case "function_call", "custom_tool_call":
            touchCurrentTurn(for: file, at: eventDate)
            guard
                let callID = payload["call_id"] as? String,
                let turnID = currentTurnByFile[file],
                isInteractiveCall(payload)
            else {
                return
            }
            pendingCallToTurn[callID] = turnID
            if var turn = turns[turnID], turn.active {
                turn.pendingInteractiveCalls.insert(callID)
                turn.lastEventAt = eventDate
                turns[turnID] = turn
            }

        case "function_call_output", "custom_tool_call_output":
            touchCurrentTurn(for: file, at: eventDate)
            guard
                let callID = payload["call_id"] as? String,
                let turnID = pendingCallToTurn.removeValue(forKey: callID),
                var turn = turns[turnID]
            else {
                return
            }
            turn.pendingInteractiveCalls.remove(callID)
            turn.lastEventAt = eventDate
            turns[turnID] = turn

        default:
            touchCurrentTurn(for: file, at: eventDate)
        }
    }

    func snapshot(now: Date = Date(), codexLaunchDate: Date? = nil) -> StatusSnapshot {
        let eligible = turns.values.filter { turn in
            guard turn.active else { return false }

            if let launchDate = codexLaunchDate {
                return turn.startedAt >= launchDate.addingTimeInterval(-8)
            }

            // Fallback for CLI/extension sessions and environments where LaunchServices
            // does not expose Codex. It also drops abandoned turns after a crash.
            return turn.lastEventAt >= now.addingTimeInterval(-12 * 60 * 60)
        }

        let weeklyRemaining = weeklyUsageByFile.values
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .remainingPercent

        if eligible.contains(where: { !$0.pendingInteractiveCalls.isEmpty }) {
            return StatusSnapshot(state: .waiting, activeCount: eligible.count, weeklyRemainingPercent: weeklyRemaining)
        }
        if !eligible.isEmpty {
            return StatusSnapshot(state: .running, activeCount: eligible.count, weeklyRemainingPercent: weeklyRemaining)
        }
        return StatusSnapshot(state: .idle, activeCount: 0, weeklyRemainingPercent: weeklyRemaining)
    }

    private func touchCurrentTurn(for file: String, at date: Date) {
        guard let turnID = currentTurnByFile[file], var turn = turns[turnID], turn.active else {
            return
        }
        turn.lastEventAt = date
        turns[turnID] = turn
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = timestampParser.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private func parseWeeklyUsage(_ rateLimits: [String: Any], updatedAt: Date) -> WeeklyUsage? {
        for key in ["primary", "secondary"] {
            guard let window = rateLimits[key] as? [String: Any],
                  let minutes = number(window["window_minutes"]),
                  Int(minutes) == 10_080,
                  let usedPercent = number(window["used_percent"]) else {
                continue
            }
            let remaining = Int(max(0, min(100, 100 - usedPercent)).rounded())
            return WeeklyUsage(remainingPercent: remaining, updatedAt: updatedAt)
        }
        return nil
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func isInteractiveCall(_ payload: [String: Any]) -> Bool {
        guard let name = payload["name"] as? String else { return false }

        // 修复：添加 request_permissions 支持（WenChao 修复）
        if ["request_user_input", "request_plugin_install", "request_permissions"].contains(name) {
            return true
        }

        let execNames = ["exec_command", "exec"]
        guard execNames.contains(name),
              let arguments = (payload["arguments"] as? String) ?? (payload["input"] as? String) else {
            return false
        }
        guard
            let data = arguments.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return arguments.contains("\"sandbox_permissions\":\"require_escalated\"")
                || arguments.contains("\"sandbox_permissions\": \"require_escalated\"")
        }
        return decoded["sandbox_permissions"] as? String == "require_escalated"
    }
}

// MARK: - File Monitor
private struct FileCursor {
    var offset: UInt64 = 0
    var remainder = Data()
}

final class CodexStatusMonitor {
    private let maxBytesPerFilePerPass = 1_048_576
    private let maxIncompleteEventBytes = 4_194_304
    private let queue = DispatchQueue(label: "local.codexsignal.monitor", qos: .userInitiated)
    private let engine = StatusEngine()
    private var cursors: [String: FileCursor] = [:]
    private var timer: DispatchSourceTimer?
    private var tick = 0
    private var lastSnapshot = StatusSnapshot(state: .idle, activeCount: 0, weeklyRemainingPercent: nil)
    private let callback: (StatusSnapshot) -> Void
    private let fileManager = FileManager.default
    private let roots: [URL]

    init(callback: @escaping (StatusSnapshot) -> Void) {
        self.callback = callback
        let home = fileManager.homeDirectoryForCurrentUser
        roots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.discoverFiles()
            self.readChangedFiles()
            self.publish()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            // 动态轮询：空闲时 2秒，工作时 0.5秒，等待时 1秒
            timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.tick += 1
                // 每 10 次扫描一次新文件（优化性能）
                if self.tick % 10 == 0 {
                    self.discoverFiles()
                }
                self.readChangedFiles()
                self.publish()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func forceRefresh() {
        queue.async { [weak self] in
            self?.discoverFiles()
            self?.readChangedFiles()
            self?.publish(force: true)
        }
    }

    private func discoverFiles() {
        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values?.isRegularFile == true else { continue }
                guard (values?.contentModificationDate ?? .distantPast) >= cutoff else { continue }
                if cursors[url.path] == nil {
                    cursors[url.path] = FileCursor()
                }
            }
        }
    }

    private func readChangedFiles() {
        for path in Array(cursors.keys) {
            guard
                let attributes = try? fileManager.attributesOfItem(atPath: path),
                let number = attributes[.size] as? NSNumber
            else {
                engine.removeEvents(from: path)
                cursors.removeValue(forKey: path)
                continue
            }

            let size = number.uint64Value
            var cursor = cursors[path] ?? FileCursor()

            if size < cursor.offset {
                engine.removeEvents(from: path)
                cursor = FileCursor()
            }
            guard size > cursor.offset else {
                cursors[path] = cursor
                continue
            }

            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                continue
            }
            do {
                try handle.seek(toOffset: cursor.offset)
                let newData = try handle.read(upToCount: maxBytesPerFilePerPass) ?? Data()
                cursor.offset += UInt64(newData.count)
                cursor.remainder.append(newData)
                consumeLines(from: &cursor.remainder, file: path)
                if cursor.remainder.count > maxIncompleteEventBytes {
                    // Ignore an abnormally large unterminated record instead of allowing
                    // an untrusted local session file to grow memory without a bound.
                    cursor.remainder.removeAll(keepingCapacity: false)
                }
                cursors[path] = cursor
                try handle.close()
            } catch {
                try? handle.close()
            }
        }
    }

    private func consumeLines(from data: inout Data, file: String) {
        let newline = Data([0x0A])
        while let range = data.range(of: newline) {
            let line = data.subdata(in: data.startIndex..<range.lowerBound)
            data.removeSubrange(data.startIndex...range.lowerBound)
            if !line.isEmpty {
                engine.process(line: line, file: file)
            }
        }
    }

    private func publish(force: Bool = false) {
        let snapshot = engine.snapshot(codexLaunchDate: codexLaunchDate())
        guard force || snapshot != lastSnapshot else { return }
        
        // 发送系统通知（WenChao 新增）
        if snapshot.state != lastSnapshot.state {
            DispatchQueue.main.async {
                NotificationManager.shared.notifyStateChange(snapshot.state, activeCount: snapshot.activeCount)
            }
        }
        
        lastSnapshot = snapshot
        DispatchQueue.main.async { [callback] in
            callback(snapshot)
        }
    }

    private func codexLaunchDate() -> Date? {
        let bundleIDs = ["com.openai.codex", "com.openai.chat"]
        for bundleID in bundleIDs {
            if let date = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .compactMap(\.launchDate)
                .max() {
                return date
            }
        }
        return NSWorkspace.shared.runningApplications
            .filter { ($0.localizedName ?? "").localizedCaseInsensitiveContains("Codex") }
            .compactMap(\.launchDate)
            .max()
    }
}

// MARK: - Status Item Icon (支持动画)
private enum StatusItemIcon {
    static func make(for activeState: SignalState, alpha: CGFloat = 1.0) -> NSImage {
        let image = NSImage(size: NSSize(width: 42, height: 18))
        image.lockFocus()
        defer { image.unlockFocus() }

        let housing = NSBezierPath(
            roundedRect: NSRect(x: 1, y: 1, width: 40, height: 16),
            xRadius: 8,
            yRadius: 8
        )
        NSColor(calibratedWhite: 0.025, alpha: 0.76).setFill()
        housing.fill()

        let states: [SignalState] = [.running, .waiting, .idle]
        let centers: [CGFloat] = [9, 21, 33]
        for (index, state) in states.enumerated() {
            let active = state == activeState
            let rect = NSRect(x: centers[index] - 4, y: 5, width: 8, height: 8)
            
            if active {
                // 活动状态：应用呼吸动画的 alpha 值
                let animatedColor = state.color.withAlphaComponent(alpha)
                animatedColor.setFill()
            } else {
                // 非活动状态：半透明
                state.color.withAlphaComponent(0.20).setFill()
            }
            NSBezierPath(ovalIn: rect).fill()

            if active {
                NSColor.white.withAlphaComponent(0.48).setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.minX + 1.5, y: rect.maxY - 3, width: 2.5, height: 1.5)).fill()
            }
        }

        image.isTemplate = false
        return image
    }
}

// MARK: - App Delegate (支持动画和快捷键)
final class AppDelegate: NSObject, NSApplicationDelegate {
    var monitor: CodexStatusMonitor?
    private var statusItem: NSStatusItem?
    private var stateItem: NSMenuItem?
    private var detailItem: NSMenuItem?
    private var weeklyItem: NSMenuItem?
    private var latestSnapshot = StatusSnapshot(state: .idle, activeCount: 0, weeklyRemainingPercent: nil)
    
    // 灯动画相关（只针对灯本身，不影响文字）
    private var breathingTimer: Timer?
    private var breathingPhase: CGFloat = 0
    private var currentAnimationState: SignalState = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createStatusItem()
        setupHotkeys() // 设置快捷键

        monitor = CodexStatusMonitor { [weak self] snapshot in
            self?.apply(snapshot)
        }
        monitor?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopBreathingAnimation()
        monitor?.stop()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let stateItem = NSMenuItem(title: "Codex · \(SignalState.idle.title)", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        stateItem.image = StatusItemIcon.make(for: .idle)
        menu.addItem(stateItem)

        let detailItem = NSMenuItem(title: SignalState.idle.subtitle, action: nil, keyEquivalent: "")
        detailItem.isEnabled = false
        menu.addItem(detailItem)

        let weeklyItem = NSMenuItem(title: L10n.text("7 天剩余：同步中…", "7-day remaining: syncing…"), action: nil, keyEquivalent: "")
        weeklyItem.isEnabled = false
        menu.addItem(weeklyItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: L10n.text("打开 Codex", "Open Codex"), action: #selector(openCodex), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(title: L10n.text("立即刷新", "Refresh now"), action: #selector(refreshStatus), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L10n.text("退出 Codex 状态灯", "Quit Codex Status Light"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Credit by WenChao
        let creditItem = NSMenuItem(title: "Made with ❤️ by WenChao", action: nil, keyEquivalent: "")
        creditItem.isEnabled = false
        menu.addItem(creditItem)

        item.menu = menu
        statusItem = item
        self.stateItem = stateItem
        self.detailItem = detailItem
        self.weeklyItem = weeklyItem
        apply(latestSnapshot)
    }

    // MARK: - 快捷键设置
    private func setupHotkeys() {
        // 全局快捷键：⌘⇧C 打开 Codex
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 8 {
                self?.openCodex()
            }
        }
    }

    // MARK: - 应用状态更新
    private func apply(_ snapshot: StatusSnapshot) {
        latestSnapshot = snapshot
        guard let button = statusItem?.button else { return }

        button.image = StatusItemIcon.make(for: snapshot.state)
        let weeklyText = snapshot.weeklyRemainingPercent.map { " 7D \($0)%" } ?? " 7D --"
        let countText = snapshot.activeCount > 1 ? " · \(snapshot.activeCount)" : ""
        button.title = weeklyText + countText
        button.toolTip = "Codex: \(snapshot.state.title) · \(weeklyText.trimmingCharacters(in: .whitespaces))"
        button.setAccessibilityLabel(L10n.text("Codex 状态：\(snapshot.state.title)", "Codex status: \(snapshot.state.title)"))

        stateItem?.title = "Codex · \(snapshot.state.title)"
        stateItem?.image = StatusItemIcon.make(for: snapshot.state)
        if snapshot.activeCount > 1 {
            detailItem?.title = L10n.text("\(snapshot.state.subtitle) · \(snapshot.activeCount) 个任务", "\(snapshot.state.subtitle) · \(snapshot.activeCount) tasks")
        } else if snapshot.activeCount == 1 {
            detailItem?.title = L10n.text("\(snapshot.state.subtitle) · 1 个任务", "\(snapshot.state.subtitle) · 1 task")
        } else {
            detailItem?.title = snapshot.state.subtitle
        }
        if let remaining = snapshot.weeklyRemainingPercent {
            weeklyItem?.title = L10n.text("7 天剩余：\(remaining)%", "7-day remaining: \(remaining)%")
        } else {
            weeklyItem?.title = L10n.text("7 天剩余：同步中…", "7-day remaining: syncing…")
        }
        
        // 更新动画状态
        updateAnimation(for: snapshot.state)
    }

    // MARK: - 状态灯动画 (WenChao 新增 - 只针对灯本身)
    private func updateAnimation(for state: SignalState) {
        guard currentAnimationState != state else { return }
        currentAnimationState = state
        
        // 停止之前的动画
        stopBreathingAnimation()
        
        // 根据状态添加动画
        switch state {
        case .running:
            // 红灯呼吸动画：1.5秒周期
            startBreathingAnimation(duration: 1.5)
        case .waiting:
            // 黄灯脉冲动画：1.0秒周期
            startBreathingAnimation(duration: 1.0)
        case .idle:
            // 空闲状态：不添加动画，直接更新图标
            updateIcon(alpha: 1.0)
        }
    }
    
    private func startBreathingAnimation(duration: Double) {
        breathingPhase = 0
        breathingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // 计算呼吸效果的 alpha 值（0.5 到 1.0 之间）
            self.breathingPhase += CGFloat(0.05 / duration)
            if self.breathingPhase > 1.0 {
                self.breathingPhase -= 1.0
            }
            
            // 使用正弦函数实现平滑的呼吸效果
            let alpha = 0.5 + 0.5 * sin(self.breathingPhase * .pi * 2)
            
            // 只更新图标，不影响文字
            self.updateIcon(alpha: alpha)
        }
    }
    
    private func stopBreathingAnimation() {
        breathingTimer?.invalidate()
        breathingTimer = nil
        breathingPhase = 0
    }
    
    private func updateIcon(alpha: CGFloat) {
        guard let button = statusItem?.button else { return }
        button.image = StatusItemIcon.make(for: latestSnapshot.state, alpha: alpha)
    }

    // MARK: - Actions
    @objc private func openCodex() {
        for bundleID in ["com.openai.codex", "com.openai.chat"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                return
            }
        }

        let fallback = URL(fileURLWithPath: "/Applications/Codex.app")
        if FileManager.default.fileExists(atPath: fallback.path) {
            NSWorkspace.shared.open(fallback)
        }
    }

    @objc private func refreshStatus() {
        monitor?.forceRefresh()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Self Test
private func runSelfTest() -> Int32 {
    let engine = StatusEngine()
    let file = "/tmp/codex-status-test.jsonl"

    func feed(_ json: String) {
        engine.process(line: Data(json.utf8), file: file)
    }

    feed(#"{"timestamp":"2026-06-20T10:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#)
    guard engine.snapshot(now: ISO8601DateFormatter().date(from: "2026-06-20T10:01:00Z")!).state == .running else {
        fputs("FAIL: task_started should be running\n", stderr)
        return 1
    }

    feed(#"{"timestamp":"2026-06-20T10:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{}","call_id":"call-1"}}"#)
    guard engine.snapshot(now: ISO8601DateFormatter().date(from: "2026-06-20T10:01:00Z")!).state == .waiting else {
        fputs("FAIL: pending request_user_input should be waiting\n", stderr)
        return 1
    }

    feed(#"{"timestamp":"2026-06-20T10:00:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"ok"}}"#)
    guard engine.snapshot(now: ISO8601DateFormatter().date(from: "2026-06-20T10:01:00Z")!).state == .running else {
        fputs("FAIL: answered input should resume running\n", stderr)
        return 1
    }

    feed(#"{"timestamp":"2026-06-20T10:00:03.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#)
    guard engine.snapshot(now: ISO8601DateFormatter().date(from: "2026-06-20T10:01:00Z")!).state == .idle else {
        fputs("FAIL: task_complete should be idle\n", stderr)
        return 1
    }

    feed(#"{"timestamp":"2026-06-20T10:02:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}"#)
    feed(#"{"timestamp":"2026-06-20T10:02:01.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"true\",\"sandbox_permissions\":\"require_escalated\"}","call_id":"call-2"}}"#)
    guard engine.snapshot(now: ISO8601DateFormatter().date(from: "2026-06-20T10:03:00Z")!).state == .waiting else {
        fputs("FAIL: pending approval should be waiting\n", stderr)
        return 1
    }

    feed(#"{"timestamp":"2026-06-20T10:02:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-2","output":"ok"}}"#)
    feed(#"{"timestamp":"2026-06-20T10:02:03.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({\"cmd\":\"true\",\"sandbox_permissions\":\"require_escalated\"});","call_id":"call-3"}}"#)
    guard engine.snapshot(now: ISO8601DateFormatter().date(from: "2026-06-20T10:03:00Z")!).state == .waiting else {
        fputs("FAIL: current custom-tool approval should be waiting\n", stderr)
        return 1
    }

    feed(#"{"timestamp":"2026-06-20T10:02:04.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-3","output":"ok"}}"#)
    guard engine.snapshot(now: ISO8601DateFormatter().date(from: "2026-06-20T10:03:00Z")!).state == .running else {
        fputs("FAIL: completed custom-tool approval should resume running\n", stderr)
        return 1
    }

    feed(#"{"timestamp":"2026-06-20T10:02:05.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":23.0,"window_minutes":10080,"resets_at":1784799278},"secondary":null}}}"#)
    guard engine.snapshot(now: ISO8601DateFormatter().date(from: "2026-06-20T10:03:00Z")!).weeklyRemainingPercent == 77 else {
        fputs("FAIL: 7-day remaining balance should be parsed\n", stderr)
        return 1
    }

    // 测试 request_permissions (WenChao 新增测试)
    feed(#"{"timestamp":"2026-06-20T10:03:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-3"}}"#)
    feed(#"{"timestamp":"2026-06-20T10:03:01.000Z","type":"response_item","payload":{"type":"function_call","name":"request_permissions","arguments":"{\"permissions\":{\"file_system\":{\"write\":[\"/Desktop\"]}}}","call_id":"call-4"}}"#)
    guard engine.snapshot(now: ISO8601DateFormatter().date(from: "2026-06-20T10:04:00Z")!).state == .waiting else {
        fputs("FAIL: pending request_permissions should be waiting\n", stderr)
        return 1
    }

    print("PASS: status engine (WenChao version)")
    return 0
}

// MARK: - Main Entry
if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTest())
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
