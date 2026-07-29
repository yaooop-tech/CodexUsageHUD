import AppKit
import Darwin
import Foundation
import OSLog
import UserNotifications

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private var snapshots: [UsageProvider: UsageSnapshot] = [:]
    @Published private var errors: [UsageProvider: String] = [:]
    @Published private(set) var selectedProvider: UsageProvider
    @Published private(set) var isRefreshing = false
    @Published private(set) var nextRefreshAt: Date?
    @Published private(set) var bridgeStatus: ClaudeBridgeStatus = .disabled
    @Published private(set) var claudeConnectionState: ClaudeConnectionState = .idle
    @Published private(set) var activitySummary: AgentActivitySummary = .empty
    @Published private(set) var permitsActiveWork = true

    var snapshot: UsageSnapshot? { snapshots[selectedProvider] }
    var lastError: String? { errors[selectedProvider] }
    var activityState: AgentActivityState { activitySummary.primaryState }
    var unreadCompletionCount: Int { activitySummary.unreadCompletionCount }
    var shouldOfferClaudeConnection: Bool {
        guard selectedProvider == .claude else { return false }
        return snapshot?.primaryWindow == nil && snapshot?.secondaryWindow == nil
    }

    private let logger = Logger(subsystem: AppMetadata.bundleIdentifier, category: "usage")
    private let codexService = UsageService()
    private let claudeService = ClaudeUsageService()
    private let kimiService = KimiUsageService()
    private let claudeConnectionService = ClaudeConnectionService()
    private var refreshTask: Task<Void, Never>?
    private var refreshTimerTask: Task<Void, Never>?
    private var powerResumeTask: Task<Void, Never>?
    private var claudeReloadTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var applicationClickMonitor: Any?
    private var cacheMonitor: DispatchSourceFileSystemObject?
    private var cacheMonitorDescriptor: Int32 = -1
    private var lastClaudeUsageCacheModification: Date?
    private var hasStarted = false
    private var notifiedProviders = Set<UsageProvider>()
    private let activityStartedAt: Date
    private let activityMonitor: AgentActivityMonitor
    private let powerCoordinator = ApplicationPowerCoordinator()
    private var activityReducer: AgentActivityReducer
    private var frontmostProvider: UsageProvider?

#if DEBUG
    private let demoScenario: DemoPresentation.Scenario?
#endif

    init() {
        let startedAt = Date()
        activityStartedAt = startedAt
        activityMonitor = AgentActivityMonitor(startedAt: startedAt)
        activityReducer = AgentActivityReducer(startedAt: startedAt)
        let saved = UserDefaults.standard.string(forKey: DefaultsKey.selectedProvider)
        selectedProvider = UsageProvider(rawValue: saved ?? "") ?? .codex
#if DEBUG
        demoScenario = DemoPresentation.scenarioFromEnvironment
        if let demoScenario {
            let presentation = DemoPresentation(scenario: demoScenario)
            selectedProvider = .codex
            snapshots = [.codex: presentation.snapshot]
            activitySummary = presentation.activitySummary
        }
#endif
    }

    func start() {
#if DEBUG
        if demoScenario != nil {
            hasStarted = true
            return
        }
#endif
        guard !hasStarted else {
            logger.info("Refresh start skipped because the refresh loop is already active")
            return
        }
        hasStarted = true
        logger.info("Starting multi-provider usage refresh loop")
        powerCoordinator.start(
            onSuspend: { [weak self] in self?.suspendForPowerState() },
            onResume: { [weak self] in self?.resumeAfterPowerState() })
        configureClaudeBridge()
        startClaudeCacheMonitor()
        startActivityMonitor()
        startApplicationMonitor()
        applyDisplaySource(for: NSWorkspace.shared.frontmostApplication, acknowledgesActivity: false)
        refreshNow()
    }

    func setCollapsed(_: Bool) {
        if hasStarted, !isRefreshing {
            scheduleNextRefresh()
        }
    }

    func refreshNow() {
#if DEBUG
        if demoScenario != nil { return }
#endif
        guard permitsActiveWork else { return }
        hasStarted = true
        isRefreshing = true
        logger.info("Manual multi-provider usage refresh requested")
        refreshTimerTask?.cancel()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshAll(forceAll: true)
        }
    }

    func refreshSettingsChanged() {
        guard hasStarted, !isRefreshing else {
            return
        }
        logger.info("Refresh settings changed; rescheduling timer")
        scheduleNextRefresh()
    }

    func displaySourceChanged() {
        applyDisplaySource(for: NSWorkspace.shared.frontmostApplication, acknowledgesActivity: false)
    }

    func setClaudeMonitoringEnabled(_ enabled: Bool) {
        bridgeStatus = ClaudeBridgeService.configure(enabled: enabled)
        if enabled {
            startClaudeCacheMonitor()
            reloadClaudeCache()
        }
    }

    func setClaudeOAuthEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.claudeOAuthEnabled)
        if !enabled { claudeConnectionState = .idle }
        refreshNow()
    }

    func connectClaude() {
        guard claudeConnectionState != .connecting else { return }
        claudeConnectionState = .connecting
        errors.removeValue(forKey: .claude)
        do {
            try claudeConnectionService.connect { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success:
                        UserDefaults.standard.set(true, forKey: DefaultsKey.claudeOAuthEnabled)
                        self.claudeConnectionState = .connected
                        self.refreshNow()
                    case .failure(let error):
                        self.claudeConnectionState = .failed(error.localizedDescription)
                        self.errors[.claude] = error.localizedDescription
                    }
                }
            }
        } catch ClaudeConnectionError.cliMissing {
            claudeConnectionState = .cliMissing
        } catch {
            claudeConnectionState = .failed(error.localizedDescription)
            errors[.claude] = error.localizedDescription
        }
    }

    func shutdown() {
        refreshTimerTask?.cancel()
        refreshTimerTask = nil
        powerResumeTask?.cancel()
        powerResumeTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        claudeReloadTask?.cancel()
        claudeReloadTask = nil
        activityMonitor.stop()
        powerCoordinator.stop()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        stopApplicationClickMonitor()
        stopClaudeCacheMonitor()
        CodexAppServerClient.shared.stop()
        claudeConnectionService.cancel()
    }

    private func refreshAll(forceAll: Bool = false) async {
        guard permitsActiveWork, !Task.isCancelled else {
            return
        }

        logger.info("Multi-provider usage refresh started")
        isRefreshing = true
        let providers = [selectedProvider] + UsageProvider.allCases.filter { $0 != selectedProvider }
        for provider in providers {
            guard permitsActiveWork, !Task.isCancelled else {
                isRefreshing = false
                return
            }
            guard forceAll || provider == selectedProvider || shouldRefreshBackground(provider) else {
                continue
            }
            await refresh(provider)
        }
        isRefreshing = false
        scheduleNextRefresh()
    }

    private func refresh(_ provider: UsageProvider) async {
        switch provider {
        case .codex: await refreshCodex()
        case .claude: await refreshClaude()
        case .kimi: await refreshKimi()
        }
    }

    private func shouldRefreshBackground(_ provider: UsageProvider) -> Bool {
        guard let snapshot = snapshots[provider] else { return true }
        return Date().timeIntervalSince(snapshot.fetchedAt) >= 10 * 60
    }

    private func refreshCodex() async {
        do {
            let fetched = try await codexService.fetchSnapshot(previous: snapshots[.codex])
            snapshots[.codex] = fetched
            errors.removeValue(forKey: .codex)
            handleLimitNotification(snapshot: fetched)
            let remaining = fetched.tightestRemainingPercent.map(UsagePercentFormatter.string) ?? "unknown"
            logger.info("Codex usage refresh succeeded; source: \(fetched.source.rawValue, privacy: .public); tightest remaining percent: \(remaining, privacy: .public)")
        } catch {
            errors[.codex] = error.localizedDescription
            logger.error("Codex usage refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshClaude() async {
        do {
            let oauthEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.claudeOAuthEnabled)
            let fetched = try await claudeService.fetchSnapshot(previous: snapshots[.claude], oauthEnabled: oauthEnabled)
            snapshots[.claude] = fetched
            errors.removeValue(forKey: .claude)
            if oauthEnabled {
                if fetched.source == .oauth {
                    claudeConnectionState = .connected
                } else if let sourceError = fetched.sourceError {
                    claudeConnectionState = .failed(sourceError)
                }
            }
            handleLimitNotification(snapshot: fetched)
            let remaining = fetched.tightestRemainingPercent.map(UsagePercentFormatter.string) ?? "unknown"
            logger.info("Claude usage refresh succeeded; source: \(fetched.source.rawValue, privacy: .public); tightest remaining percent: \(remaining, privacy: .public)")
        } catch {
            errors[.claude] = error.localizedDescription
            if UserDefaults.standard.bool(forKey: DefaultsKey.claudeOAuthEnabled) {
                claudeConnectionState = .failed(error.localizedDescription)
            }
            logger.error("Claude usage refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshKimi() async {
        do {
            let fetched = try await kimiService.fetchSnapshot(previous: snapshots[.kimi])
            snapshots[.kimi] = fetched
            if let sourceError = fetched.sourceError {
                errors[.kimi] = sourceError
            } else {
                errors.removeValue(forKey: .kimi)
            }
            handleLimitNotification(snapshot: fetched)
            let remaining = fetched.tightestRemainingPercent.map(UsagePercentFormatter.string) ?? "unknown"
            logger.info("Kimi usage refresh succeeded; source: \(fetched.source.rawValue, privacy: .public); tightest remaining percent: \(remaining, privacy: .public)")
        } catch {
            errors[.kimi] = error.localizedDescription
            logger.error("Kimi usage refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reloadClaudeCache() {
        claudeReloadTask?.cancel()
        claudeReloadTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshClaude()
        }
    }

    private func scheduleNextRefresh() {
        refreshTimerTask?.cancel()
        guard permitsActiveWork else {
            nextRefreshAt = nil
            return
        }
        let interval = refreshSeconds()
        nextRefreshAt = Date().addingTimeInterval(interval)
        logger.info("Next multi-provider refresh scheduled in \(Int(interval), privacy: .public) seconds")

        refreshTimerTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            await self?.refreshAll(forceAll: false)
        }
    }

    private func refreshSeconds() -> TimeInterval {
        let value = UserDefaults.standard.double(forKey: DefaultsKey.refreshSeconds)
        return value > 0 ? value : 120
    }

    private func configureClaudeBridge() {
        let enabled = UserDefaults.standard.bool(forKey: DefaultsKey.claudeMonitoringEnabled)
        bridgeStatus = ClaudeBridgeService.configure(enabled: enabled)
    }

    private func startApplicationMonitor() {
        guard activationObserver == nil else {
            return
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.applyDisplaySource(for: application, acknowledgesActivity: true)
            }
        }
    }

    private func updateApplicationClickMonitor() {
        let needsMonitor = permitsActiveWork
            && activitySummary.providerSummaries.values.contains {
                $0.unreadCompletionCount > 0 || $0.errorCount > 0
            }
        if needsMonitor, applicationClickMonitor == nil {
            applicationClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    let application = NSWorkspace.shared.frontmostApplication
                    guard let provider = FrontmostApplicationProvider.provider(for: application?.bundleIdentifier) else {
                        return
                    }
                    self?.acknowledgeActivity(for: provider)
                }
            }
        } else if !needsMonitor {
            stopApplicationClickMonitor()
        }
    }

    private func stopApplicationClickMonitor() {
        if let applicationClickMonitor {
            NSEvent.removeMonitor(applicationClickMonitor)
        }
        applicationClickMonitor = nil
    }

    private func acknowledgeActivity(for provider: UsageProvider, at date: Date = Date()) {
        activitySummary = activityReducer.acknowledge(provider: provider, at: date)
        updateApplicationClickMonitor()
    }

    private func applyDisplaySource(for application: NSRunningApplication?, acknowledgesActivity: Bool) {
        let activatedProvider = FrontmostApplicationProvider.provider(for: application?.bundleIdentifier)
        if acknowledgesActivity,
           let activatedProvider,
           frontmostProvider != activatedProvider {
            acknowledgeActivity(for: activatedProvider)
        }
        frontmostProvider = activatedProvider
        let rawMode = UserDefaults.standard.string(forKey: DefaultsKey.displaySource)
        let mode = DisplaySourceMode(rawValue: rawMode ?? "") ?? .automatic

        switch mode {
        case .codex:
            select(.codex)
        case .claude:
            select(.claude)
        case .kimi:
            select(.kimi)
        case .automatic:
            guard let provider = FrontmostApplicationProvider.provider(for: application?.bundleIdentifier) else { return }
            select(provider)
        }
    }

    private func startActivityMonitor() {
        guard permitsActiveWork else { return }
        activityMonitor.start { [weak self] readings in
            self?.applyActivityReadings(readings)
        }
    }

    private func applyActivityReadings(_ readings: [UsageProvider: [AgentTaskActivity]]) {
        activitySummary = activityReducer.apply(readings)
        updateApplicationClickMonitor()
    }

    private func select(_ provider: UsageProvider) {
        guard selectedProvider != provider else {
            return
        }
        selectedProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: DefaultsKey.selectedProvider)
        logger.info("Displayed usage provider changed to \(provider.rawValue, privacy: .public)")

        guard hasStarted else {
            return
        }
        if provider == .claude {
            reloadClaudeCache()
        } else if (snapshots[provider] == nil || shouldRefreshBackground(provider)), !isRefreshing {
            refreshNow()
        }
    }

    func openKimiLogin() {
        let appURL = URL(fileURLWithPath: "/Applications/Kimi.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        } else if let webURL = URL(string: "https://www.kimi.com") {
            NSWorkspace.shared.open(webURL)
        }
    }

    private func startClaudeCacheMonitor() {
        guard permitsActiveWork, cacheMonitor == nil else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: ClaudeBridgePaths.supportDirectory, withIntermediateDirectories: true)
        } catch {
            logger.error("Unable to prepare Claude cache directory")
            return
        }

        let descriptor = open(ClaudeBridgePaths.supportDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }
        cacheMonitorDescriptor = descriptor
        lastClaudeUsageCacheModification = claudeUsageCacheModificationDate()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let modification = self.claudeUsageCacheModificationDate()
            guard modification != self.lastClaudeUsageCacheModification else { return }
            self.lastClaudeUsageCacheModification = modification
            self.reloadClaudeCache()
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        cacheMonitor = source
        source.resume()
    }

    private func stopClaudeCacheMonitor() {
        cacheMonitor?.cancel()
        cacheMonitor = nil
        cacheMonitorDescriptor = -1
    }

    private func suspendForPowerState() {
        guard permitsActiveWork else { return }
        logger.info("Suspending HUD background work for system power state")
        permitsActiveWork = false
        nextRefreshAt = nil
        refreshTimerTask?.cancel()
        refreshTimerTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        claudeReloadTask?.cancel()
        claudeReloadTask = nil
        powerResumeTask?.cancel()
        powerResumeTask = nil
        activityMonitor.stop()
        stopApplicationClickMonitor()
        stopClaudeCacheMonitor()
        CodexAppServerClient.shared.stop()
        claudeConnectionService.cancel()
    }

    private func resumeAfterPowerState() {
        guard !permitsActiveWork else { return }
        logger.info("Resuming HUD background work after system wake")
        permitsActiveWork = true
        startClaudeCacheMonitor()
        startActivityMonitor()
        updateApplicationClickMonitor()
        powerResumeTask?.cancel()
        powerResumeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self, self.permitsActiveWork else { return }
            if self.snapshots[self.selectedProvider] == nil
                || self.shouldRefreshBackground(self.selectedProvider) {
                self.isRefreshing = true
                await self.refresh(self.selectedProvider)
                self.isRefreshing = false
            }
            self.scheduleNextRefresh()
        }
    }

    private func claudeUsageCacheModificationDate() -> Date? {
        try? ClaudeBridgePaths.usageCache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func handleLimitNotification(snapshot: UsageSnapshot) {
        let provider = snapshot.provider
        if snapshot.isLimitReached, !notifiedProviders.contains(provider) {
            notifiedProviders.insert(provider)
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "\(provider.displayName) usage limit reached"
                content.body = "Codex Usage HUD detected a \(provider.displayName) rate limit state."
                let identifier = "\(provider.rawValue)-limit-\(UUID().uuidString)"
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                )
            }
        } else if !snapshot.isLimitReached {
            notifiedProviders.remove(provider)
        }
    }
}
