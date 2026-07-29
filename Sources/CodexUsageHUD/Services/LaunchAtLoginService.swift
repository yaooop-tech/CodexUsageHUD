import Foundation
import OSLog
import ServiceManagement

enum LaunchAtLoginService {
    private static let logger = Logger(subsystem: AppMetadata.bundleIdentifier, category: "login-item")

    static func registerDefaults() {
        migrateRefreshIntervalDefault()
        UserDefaults.standard.register(defaults: [
            DefaultsKey.collapsed: true,
            DefaultsKey.refreshSeconds: 120.0,
            DefaultsKey.launchAtLogin: true,
            DefaultsKey.theme: AppTheme.system.rawValue,
            DefaultsKey.language: AppLanguage.english.rawValue,
            DefaultsKey.snapEdge: HUDSnapEdge.right.rawValue,
            DefaultsKey.railMidY: 0.0,
            DefaultsKey.displaySource: DisplaySourceMode.automatic.rawValue,
            DefaultsKey.selectedProvider: UsageProvider.codex.rawValue,
            DefaultsKey.claudeMonitoringEnabled: false
        ])
    }

    static func collapseOnLaunch() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.collapsed)
    }

    static func syncWithPreference() {
        setEnabled(UserDefaults.standard.bool(forKey: DefaultsKey.launchAtLogin))
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            logger.info("Launch at login is \(enabled ? "enabled" : "disabled", privacy: .public)")
        } catch {
            logger.error("Unable to update launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func migrateRefreshIntervalDefault() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: DefaultsKey.refreshSeconds) == nil else {
            return
        }

        let collapsedValue = defaults.double(forKey: DefaultsKey.collapsedRefreshSeconds)
        let expandedValue = defaults.double(forKey: DefaultsKey.expandedRefreshSeconds)
        let migratedValue = collapsedValue > 0 ? collapsedValue : expandedValue
        defaults.set(migratedValue > 0 ? migratedValue : 120.0, forKey: DefaultsKey.refreshSeconds)
    }
}
