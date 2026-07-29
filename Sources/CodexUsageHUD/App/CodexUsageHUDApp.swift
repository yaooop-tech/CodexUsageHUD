import AppKit
import OSLog
import SwiftUI

@main
struct CodexUsageHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(DefaultsKey.language) private var language = AppLanguage.english.rawValue

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: language) ?? .english
    }

    init() {
        AppPreferencesMigration.apply()
#if DEBUG
        if let scenario = DemoPresentation.scenarioFromEnvironment {
            UserDefaults.standard.set(
                scenario == .idle || scenario == .running || scenario == .needsConfirmation || scenario == .singleTaskCompleted,
                forKey: DefaultsKey.collapsed)
            UserDefaults.standard.set(AppTheme.dark.rawValue, forKey: DefaultsKey.theme)
            UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: DefaultsKey.language)
            UserDefaults.standard.set(false, forKey: DefaultsKey.launchAtLogin)
        }
#endif
        UserDefaults.standard.register(defaults: [
            DefaultsKey.refreshSeconds: 120.0,
            DefaultsKey.claudeMonitoringEnabled: false,
            DefaultsKey.claudeOAuthEnabled: false
        ])
        LaunchAtLoginService.registerDefaults()
    }

    var body: some Scene {
        WindowGroup("Codex Usage HUD") {
#if DEBUG
            if DemoPresentation.scenarioFromEnvironment == .settings {
                SettingsView(viewModel: appDelegate.viewModel)
                    .frame(width: 440, height: 430)
            } else {
                HUDView(viewModel: appDelegate.viewModel)
            }
#else
            HUDView(viewModel: appDelegate.viewModel)
#endif
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.text(.refreshNow, language: appLanguage)) {
                    appDelegate.viewModel.refreshNow()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsView(viewModel: appDelegate.viewModel)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = UsageViewModel()
    private let logger = Logger(subsystem: AppMetadata.bundleIdentifier, category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application did finish launching")
        NSApp.setActivationPolicy(.accessory)
#if DEBUG
        if DemoPresentation.scenarioFromEnvironment == nil {
            LaunchAtLoginService.collapseOnLaunch()
            LaunchAtLoginService.syncWithPreference()
        }
#else
        LaunchAtLoginService.collapseOnLaunch()
        LaunchAtLoginService.syncWithPreference()
#endif
        viewModel.start()
#if DEBUG
        if DemoPresentation.scenarioFromEnvironment == .settings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
#endif
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}
