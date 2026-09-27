import AppKit
import UserNotifications
import ServiceManagement

private final class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
}

// Monitors the global SleepDisabled switch; it does not assert that the Mac is asleep.
@main
struct SleepGuardMain {
    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            let monitor = PowerMonitor()
            monitor.check { result in
                let status: String
                switch result.mode {
                case .allowed: status = "allowed"
                case .disabled: status = "disabled"
                case .unknown(let reason): status = "unknown: \(reason)"
                }
                let record = ["status": status, "checkedAt": ISO8601DateFormatter().string(from: result.checkedAt)]
                if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                   let text = String(data: data, encoding: .utf8) { print(text) }
                exit(status.hasPrefix("unknown") ? 1 : 0)
            }
            RunLoop.main.run()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    private let monitor = PowerMonitor()
    private let verificationMonitor = PowerMonitor()
    private let recovery = SleepRecovery()
    private var recoveryInProgress = false
    private var recoveryMessage: String?
    private var checkGeneration = 0
    private let defaults = UserDefaults.standard
    private let notifications = UNUserNotificationCenter.current()
    private var item: NSStatusItem!
    private var menu = NSMenu()
    private var timer: Timer?
    private var result: SleepCheckResult?
    private var lastKnownMode: SleepMode?
    private var lastReminder: Date?
    private var reminderInFlight = false
    private var retryAfter: Date?
    private var reminderEpisode = UUID()
    private var pendingTestNotification = false
    private var disabledSince: Date?
    private var notificationStatus: UNAuthorizationStatus = .notDetermined
    private var notificationError: String?
    private var history: [String] = []
    private var observers: [NSObjectProtocol] = []
    private var window: NSWindow?
    private let titleLabel = NSTextField(labelWithString: "正在检测")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "读取系统电源设置…")
    private let timeLabel = NSTextField(labelWithString: "")
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let historyLabel = NSTextField(wrappingLabelWithString: "尚无状态变化记录")
    private let notificationsToggle = NSButton(checkboxWithTitle: "休眠禁用时通知我", target: nil, action: nil)
    private let loginToggle = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let notificationButton = NSButton(title: "启用通知", target: nil, action: nil)
    private let loginHint = NSTextField(wrappingLabelWithString: "")
    private let recoveryButton = NSButton(title: "恢复休眠", target: nil, action: nil)
    private let recoveryLabel = NSTextField(wrappingLabelWithString: "")
    private static let reminderMinutes = [0, 5, 15, 30, 60]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let identifier = Bundle.main.bundleIdentifier ?? "local.kundu.sleepguard"
        if NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        defaults.register(defaults: ["notificationsEnabled": true, "reminderMinutes": 30])
        notifications.delegate = self
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        item.menu = menu
        updateUI()
        refreshNotificationStatus()
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.check()
        }
        timer?.tolerance = 2
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.check() })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshNotificationStatus()
            self?.check()
        })
        if !defaults.bool(forKey: "hasLaunched") {
            defaults.set(true, forKey: "hasLaunched")
            showWindow(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        recovery.cancel()
        timer?.invalidate()
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshNotificationStatus()
        check()
        updateUI()
    }

    private var reminderInterval: TimeInterval {
        TimeInterval(defaults.integer(forKey: "reminderMinutes") * 60)
    }

    @objc private func checkNow(_ sender: Any?) { check() }

    private func check() {
        guard !recoveryInProgress else { return }
        let generation = checkGeneration
        monitor.check { [weak self] reading in
            guard let self = self, self.checkGeneration == generation, !self.recoveryInProgress else { return }
            self.accept(reading)
        }
    }

    private func accept(_ reading: SleepCheckResult) {
        result = reading
        switch reading.mode {
        case .disabled:
            if lastKnownMode != .disabled {
                disabledSince = reading.checkedAt
                lastReminder = nil
                retryAfter = nil
                reminderEpisode = UUID()
                record("检测到系统休眠禁用", at: reading.checkedAt)
            }
            lastKnownMode = .disabled
            considerReminder()
        case .allowed:
            if lastKnownMode != .allowed {
                record("检测到系统允许休眠", at: reading.checkedAt)
            }
            if lastKnownMode == .disabled {
                notifications.removeDeliveredNotifications(withIdentifiers: ["sleep-disabled"])
                notifications.removePendingNotificationRequests(withIdentifiers: ["sleep-disabled"])
            }
            lastKnownMode = .allowed
            disabledSince = nil
            lastReminder = nil
            retryAfter = nil
            reminderEpisode = UUID()
        case .unknown:
            // Keep the last known state for transition history, but show unknown and stop reminders.
            break
        }
        updateUI()
    }

    private func record(_ text: String, at date: Date) {
        history.insert("\(formatDate(date))  \(text)", at: 0)
        history = Array(history.prefix(5))
    }

    private func considerReminder() {
        guard result?.mode == .disabled, defaults.bool(forKey: "notificationsEnabled"),
              notificationStatus == .authorized || notificationStatus == .provisional else { return }
        let now = Date()
        guard !reminderInFlight, retryAfter.map({ now >= $0 }) ?? true else { return }
        if let last = lastReminder, reminderInterval == 0 || now.timeIntervalSince(last) < reminderInterval { return }
        let episode = reminderEpisode
        reminderInFlight = true
        sendNotification(title: "系统休眠已禁用", body: "Mac 当前处于禁止系统休眠的模式。准备合盖或收进包前，请检查并恢复休眠。", identifier: "sleep-disabled") { [weak self] error in
            guard let self = self else { return }
            self.reminderInFlight = false
            guard self.reminderEpisode == episode else {
                self.notifications.removeDeliveredNotifications(withIdentifiers: ["sleep-disabled"])
                self.considerReminder()
                return
            }
            if error == nil { self.lastReminder = now; self.retryAfter = nil }
            else { self.retryAfter = Date().addingTimeInterval(60) }
        }
    }

    private func sendNotification(title: String, body: String, identifier: String, completion: ((Error?) -> Void)? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        notifications.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { [weak self] error in
            DispatchQueue.main.async {
                self?.notificationError = error.map { "通知提交失败：\($0.localizedDescription)" }
                completion?(error)
                self?.updateUI()
            }
        }
    }

    private func refreshNotificationStatus() {
        notifications.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let wasAuthorized = self.notificationStatus == .authorized || self.notificationStatus == .provisional
                self.notificationStatus = settings.authorizationStatus
                if !wasAuthorized { self.considerReminder() }
                if self.pendingTestNotification && settings.authorizationStatus != .notDetermined {
                    self.pendingTestNotification = false
                    if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                        self.testNotification(nil)
                    }
                }
                self.updateUI()
            }
        }
    }

    @objc private func requestNotifications(_ sender: Any?) {
        if notificationStatus == .denied {
            openNotificationSettings(nil)
            return
        }
        defaults.set(true, forKey: "notificationsEnabled")
        notifications.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.notificationError = error.map { "无法启用通知：\($0.localizedDescription)" }
                self?.refreshNotificationStatus()
            }
        }
    }

    @objc private func testNotification(_ sender: Any?) {
        guard notificationStatus == .authorized || notificationStatus == .provisional else {
            pendingTestNotification = notificationStatus == .notDetermined
            requestNotifications(sender)
            return
        }
        sendNotification(title: "休眠哨兵 · 测试提醒", body: "通知通道已提交测试提醒。休眠禁用时，菜单栏也会持续显示橙色提醒。", identifier: "test-notification")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.showWindow(nil); completionHandler() }
    }

    private func statePresentation() -> (String, String, String, NSColor) {
        guard let result = result else { return ("正在检测", "读取系统电源设置…", "moon", .secondaryLabelColor) }
        switch result.mode {
        case .allowed: return ("系统允许休眠", "系统级休眠禁用已关闭。外接显示器、应用活动等仍可能影响实际休眠。", "moon.zzz.fill", .systemGreen)
        case .disabled: return ("系统休眠已禁用", "系统级休眠禁用已开启，合盖可能继续运行。准备收起电脑时，请先恢复休眠。", "moon.slash.fill", .systemOrange)
        case .unknown(let reason): return ("休眠状态未知", "无法确认当前状态：\(reason)", "questionmark.circle.fill", .secondaryLabelColor)
        }
    }

    private func updateUI() {
        guard item != nil else { return }
        let (title, explanation, symbol, color) = statePresentation()
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.button?.image?.isTemplate = true
        item.button?.contentTintColor = color
        switch result?.mode {
        case .disabled?: item.button?.title = " 休眠禁用"
        case .allowed?: item.button?.title = ""
        default: item.button?.title = " 未知"
        }
        item.button?.toolTip = "休眠哨兵：\(title)"
        item.button?.setAccessibilityLabel("休眠哨兵，\(title)")
        menu.removeAllItems()
        addMenu(title, enabled: false)
        if let reading = result {
            let value: String
            switch reading.mode { case .allowed: value = "0"; case .disabled: value = "1"; case .unknown: value = "未知" }
            addMenu("SleepDisabled = \(value)", enabled: false)
            addMenu("最近检测：\(formatTime(reading.checkedAt))", enabled: false)
        }
        addMenu(notificationSummary, enabled: false)
        menu.addItem(.separator())
        addMenu("马上检测", action: #selector(checkNow(_:)))
        addMenu("状态与设置…", action: #selector(showWindow(_:)))
        addMenu("测试提醒", action: #selector(testNotification(_:)))
        addMenu(recoveryInProgress ? "正在恢复休眠…" : "恢复休眠", action: #selector(restoreSleep(_:)), enabled: !recoveryInProgress && result?.mode != .allowed)
        menu.addItem(.separator())
        addMenu("退出休眠哨兵", action: #selector(quit(_:)), key: "q")
        titleLabel.stringValue = title
        titleLabel.textColor = color
        descriptionLabel.stringValue = explanation
        timeLabel.stringValue = result.map { "最近检测：\(formatDate($0.checkedAt)) · 每 10 秒检测" } ?? "每 10 秒检测，唤醒后立即重查"
        if let since = disabledSince, result?.mode == .disabled {
            timeLabel.stringValue += "\n首次发现禁用：\(formatDate(since))"
        }
        notificationsToggle.state = defaults.bool(forKey: "notificationsEnabled") ? .on : .off
        permissionLabel.stringValue = notificationSummary + "\n通知显示还受 macOS 专注模式和通知样式影响。"
        notificationButton.title = notificationStatus == .notDetermined ? "启用通知" : "通知设置…"
        if let index = Self.reminderMinutes.firstIndex(of: defaults.integer(forKey: "reminderMinutes")) { intervalPopup.selectItem(at: index) }
        historyLabel.stringValue = history.isEmpty ? "尚无状态变化记录" : history.joined(separator: "\n")
        recoveryButton.title = recoveryInProgress ? "正在恢复…" : "恢复休眠"
        recoveryButton.isEnabled = !recoveryInProgress && result?.mode != .allowed
        recoveryLabel.stringValue = recoveryMessage ?? (result?.mode == .allowed
            ? "当前已允许休眠，无需恢复。"
            : "点击“恢复休眠”，按 macOS 提示完成管理员授权；无需打开终端。")
        switch SMAppService.mainApp.status {
        case .enabled: loginToggle.state = .on; loginHint.stringValue = "下次登录后自动监测。"
        case .requiresApproval: loginToggle.state = .mixed; loginHint.stringValue = "启动项等待批准，请前往系统设置 → 通用 → 登录项。"
        default: loginToggle.state = .off; loginHint.stringValue = "建议先将应用放入“应用程序”文件夹，再开启。"
        }
    }

    private var notificationSummary: String {
        if let error = notificationError { return error }
        if !defaults.bool(forKey: "notificationsEnabled") { return "提醒已暂停，菜单栏继续监测" }
        switch notificationStatus {
        case .authorized: return "系统通知已获授权"
        case .provisional: return "系统通知为静默投递"
        case .denied: return "系统通知未获授权，菜单栏继续提醒"
        case .notDetermined: return "通知尚未授权，点击“启用通知”"
        default: return "通知权限未知，菜单栏继续监测"
        }
    }

    private func addMenu(_ title: String, action: Selector? = nil, key: String = "", enabled: Bool = true) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        entry.isEnabled = enabled
        menu.addItem(entry)
    }

    @objc private func showWindow(_ sender: Any?) {
        if window == nil { buildWindow() }
        updateUI()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let availableHeight = NSScreen.main?.visibleFrame.height ?? 900
        let windowHeight = min(840, max(480, availableHeight - 80))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: windowHeight),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "休眠哨兵"
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedContentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        if let content = window.contentView {
            content.addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: content.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
                stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
                stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
                stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
                stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
            ])
        }
        let brand = NSTextField(labelWithString: "休眠哨兵  /  Sleep Guard")
        brand.font = .systemFont(ofSize: 13, weight: .semibold)
        brand.textColor = .secondaryLabelColor
        stack.addArrangedSubview(brand)
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        stack.addArrangedSubview(titleLabel)
        descriptionLabel.font = .systemFont(ofSize: 14)
        descriptionLabel.preferredMaxLayoutWidth = 444
        stack.addArrangedSubview(descriptionLabel)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.maximumNumberOfLines = 2
        stack.addArrangedSubview(timeLabel)
        let actions = NSStackView()
        actions.spacing = 10
        actions.addArrangedSubview(button("马上检测", #selector(checkNow(_:))))
        recoveryButton.target = self
        recoveryButton.action = #selector(restoreSleep(_:))
        recoveryButton.bezelStyle = .rounded
        actions.addArrangedSubview(recoveryButton)
        stack.addArrangedSubview(actions)
        recoveryLabel.font = .systemFont(ofSize: 12)
        recoveryLabel.textColor = .secondaryLabelColor
        recoveryLabel.preferredMaxLayoutWidth = 444
        stack.addArrangedSubview(recoveryLabel)
        stack.addArrangedSubview(divider())
        notificationsToggle.target = self
        notificationsToggle.action = #selector(toggleNotifications(_:))
        stack.addArrangedSubview(notificationsToggle)
        let intervalRow = NSStackView()
        intervalRow.spacing = 12
        intervalRow.addArrangedSubview(NSTextField(labelWithString: "持续禁用时重复提醒"))
        intervalPopup.addItems(withTitles: ["只在首次发现时", "每 5 分钟", "每 15 分钟", "每 30 分钟", "每 60 分钟"])
        intervalPopup.target = self
        intervalPopup.action = #selector(changeInterval(_:))
        intervalRow.addArrangedSubview(intervalPopup)
        stack.addArrangedSubview(intervalRow)
        permissionLabel.font = .systemFont(ofSize: 11)
        permissionLabel.textColor = .secondaryLabelColor
        permissionLabel.preferredMaxLayoutWidth = 444
        stack.addArrangedSubview(permissionLabel)
        let permissionActions = NSStackView()
        permissionActions.spacing = 10
        notificationButton.target = self
        notificationButton.action = #selector(notificationAction(_:))
        notificationButton.bezelStyle = .rounded
        permissionActions.addArrangedSubview(notificationButton)
        permissionActions.addArrangedSubview(button("测试提醒", #selector(testNotification(_:))))
        stack.addArrangedSubview(permissionActions)
        loginToggle.target = self
        loginToggle.action = #selector(toggleLogin(_:))
        stack.addArrangedSubview(loginToggle)
        loginHint.font = .systemFont(ofSize: 11)
        loginHint.textColor = .secondaryLabelColor
        loginHint.preferredMaxLayoutWidth = 444
        stack.addArrangedSubview(loginHint)
        stack.addArrangedSubview(divider())
        let historyHeading = NSTextField(labelWithString: "本次运行的状态记录")
        historyHeading.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(historyHeading)
        historyLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        historyLabel.textColor = .secondaryLabelColor
        historyLabel.preferredMaxLayoutWidth = 444
        stack.addArrangedSubview(historyLabel)
        for label in [descriptionLabel, recoveryLabel, permissionLabel, loginHint, historyLabel] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for view in stack.arrangedSubviews where view is NSBox {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    @objc private func toggleNotifications(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "notificationsEnabled")
        lastReminder = nil
        if sender.state == .on && notificationStatus == .notDetermined { requestNotifications(nil) }
        if sender.state != .on {
            notifications.removeDeliveredNotifications(withIdentifiers: ["sleep-disabled"])
            notifications.removePendingNotificationRequests(withIdentifiers: ["sleep-disabled"])
        }
        considerReminder()
        updateUI()
    }

    @objc private func changeInterval(_ sender: NSPopUpButton) {
        guard Self.reminderMinutes.indices.contains(sender.indexOfSelectedItem) else { return }
        defaults.set(Self.reminderMinutes[sender.indexOfSelectedItem], forKey: "reminderMinutes")
    }

    @objc private func notificationAction(_ sender: Any?) {
        if notificationStatus == .notDetermined { requestNotifications(sender) }
        else { openNotificationSettings(sender) }
    }

    @objc private func openNotificationSettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            updateUI()
            return
        }
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法更新登录启动项"
            alert.informativeText = "请先把应用放入“应用程序”文件夹，再试一次。\n\(error.localizedDescription)"
            alert.runModal()
        }
        updateUI()
    }

    @objc private func restoreSleep(_ sender: Any?) {
        guard !recoveryInProgress else { return }
        guard result?.mode != .allowed else { return }
        recoveryInProgress = true
        // Ignore callbacks from any query that began before this user action.
        checkGeneration += 1
        recoveryMessage = "等待 macOS 管理员授权…请在系统窗口完成授权，或选择取消。"
        showWindow(nil)
        recovery.restore { [weak self] execution in
            guard let self = self else { return }
            self.recoveryMessage = "正在重新检测休眠设置…"
            self.updateUI()
            // This dedicated monitor never shares a pre-write polling query.
            // Recheck after errors too: a timed-out authorization process may
            // already have started the fixed system command.
            self.verificationMonitor.check { [weak self] reading in
                guard let self = self else { return }
                self.recoveryInProgress = false
                let message = RecoveryPresentation.message(for: execution.outcome, mode: reading.mode)
                self.recoveryMessage = "\(self.formatTime(reading.checkedAt))  \(message)"
                self.record(message, at: reading.checkedAt)
                self.accept(reading)
            }
        }
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
