import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel
    @StateObject private var systemAppearance = SystemAppearanceMonitor()
    @AppStorage(DefaultsKey.refreshSeconds) private var refreshSeconds = 120.0
    @AppStorage(DefaultsKey.launchAtLogin) private var launchAtLogin = true
    @AppStorage(DefaultsKey.theme) private var theme = AppTheme.system.rawValue
    @AppStorage(DefaultsKey.language) private var language = AppLanguage.english.rawValue
    @AppStorage(DefaultsKey.displaySource) private var displaySource = DisplaySourceMode.automatic.rawValue
    @AppStorage(DefaultsKey.claudeMonitoringEnabled) private var claudeMonitoringEnabled = true
    @AppStorage(DefaultsKey.claudeOAuthEnabled) private var claudeOAuthEnabled = false

    private var appTheme: AppTheme {
        AppTheme(rawValue: theme) ?? .system
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: language) ?? .english
    }

    private var effectiveColorScheme: ColorScheme {
        appTheme.resolvedColorScheme(system: systemAppearance.colorScheme)
    }

    var body: some View {
        Form {
            Section(L10n.text(.refresh, language: appLanguage)) {
                Stepper(value: $refreshSeconds, in: 120...1800, step: 60) {
                    Text("\(L10n.text(.refreshInterval, language: appLanguage)): \(Int(refreshSeconds / 60)) \(L10n.text(.minuteUnit, language: appLanguage))")
                }
                .onChange(of: refreshSeconds) { _, _ in
                    viewModel.refreshSettingsChanged()
                }

                Text(L10n.text(.refreshHint, language: appLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.text(.monitoring, language: appLanguage)) {
                Picker(L10n.text(.displaySource, language: appLanguage), selection: $displaySource) {
                    Text(L10n.text(.automatic, language: appLanguage)).tag(DisplaySourceMode.automatic.rawValue)
                    Text(L10n.text(.fixedCodex, language: appLanguage)).tag(DisplaySourceMode.codex.rawValue)
                    Text(L10n.text(.fixedClaude, language: appLanguage)).tag(DisplaySourceMode.claude.rawValue)
                    Text(L10n.text(.fixedKimi, language: appLanguage)).tag(DisplaySourceMode.kimi.rawValue)
                }
                .onChange(of: displaySource) { _, _ in
                    viewModel.displaySourceChanged()
                }

                Toggle(L10n.text(.claudeMonitoring, language: appLanguage), isOn: $claudeMonitoringEnabled)
                    .onChange(of: claudeMonitoringEnabled) { _, enabled in
                        viewModel.setClaudeMonitoringEnabled(enabled)
                    }

                Text(bridgeStatusText)
                    .font(.caption)
                    .foregroundStyle(viewModel.bridgeStatus == .conflict ? .orange : .secondary)

                Text(L10n.text(.claudeMonitoringHint, language: appLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(L10n.text(.instantSync, language: appLanguage), isOn: $claudeOAuthEnabled)
                    .onChange(of: claudeOAuthEnabled) { _, enabled in
                        viewModel.setClaudeOAuthEnabled(enabled)
                    }

                Text(L10n.text(.instantSyncHint, language: appLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.connectClaude()
                } label: {
                    Label(connectionButtonTitle, systemImage: connectionButtonIcon)
                }
                .disabled(viewModel.claudeConnectionState == .connecting)

                Button {
                    viewModel.openKimiLogin()
                } label: {
                    Label(L10n.text(.openKimiLogin, language: appLanguage), systemImage: "person.crop.circle.badge.checkmark")
                }

                if let snapshot = viewModel.snapshot {
                    LabeledContent(L10n.text(.currentSource, language: appLanguage), value: sourceName(snapshot.source))
                    if snapshot.sourceUpdatedAt != nil, snapshot.isSourceStale {
                        Text(L10n.text(.staleClaudeData, language: appLanguage))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let sourceError = snapshot.sourceError {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.text(.recentIssue, language: appLanguage))
                                .font(.caption.weight(.semibold))
                            Text(sourceError)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section(L10n.text(.appearance, language: appLanguage)) {
                Picker(L10n.text(.theme, language: appLanguage), selection: $theme) {
                    Text(L10n.text(.system, language: appLanguage)).tag(AppTheme.system.rawValue)
                    Text(L10n.text(.light, language: appLanguage)).tag(AppTheme.light.rawValue)
                    Text(L10n.text(.dark, language: appLanguage)).tag(AppTheme.dark.rawValue)
                }
                Picker(L10n.text(.language, language: appLanguage), selection: $language) {
                    Text(L10n.text(.englishLanguage, language: appLanguage)).tag(AppLanguage.english.rawValue)
                    Text(L10n.text(.chineseLanguage, language: appLanguage)).tag(AppLanguage.chinese.rawValue)
                }
            }

            Section(L10n.text(.startup, language: appLanguage)) {
                Toggle(L10n.text(.launchAtLogin, language: appLanguage), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLoginService.setEnabled(newValue)
                    }
                Text(L10n.text(.collapsedByDefault, language: appLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.text(.version, language: appLanguage)) {
                LabeledContent(L10n.text(.currentVersion, language: appLanguage), value: AppMetadata.version)
                LabeledContent(L10n.text(.updateMethod, language: appLanguage), value: L10n.text(.manualReplacement, language: appLanguage))
            }

            Section {
                Button(L10n.text(.refreshNow, language: appLanguage)) {
                    viewModel.refreshNow()
                }
            }
        }
        .formStyle(.grouped)
        .background(SettingsScrollViewConfigurator())
        .padding()
        .frame(width: 420)
        .preferredColorScheme(effectiveColorScheme)
    }

    private var bridgeStatusText: String {
        switch viewModel.bridgeStatus {
        case .installed:
            return L10n.text(.bridgeConnected, language: appLanguage)
        case .disabled:
            return L10n.text(.bridgeDisabled, language: appLanguage)
        case .conflict:
            return L10n.text(.bridgeConflict, language: appLanguage)
        case .helperMissing, .invalidSettings, .failed:
            return L10n.text(.bridgeUnavailable, language: appLanguage)
        }
    }

    private func sourceName(_ source: UsageDataSource) -> String {
        switch (source, appLanguage) {
        case (.appServer, .english): return "App server"
        case (.appServer, .chinese): return "本地 App Server"
        case (.oauth, .english): return "Read-only OAuth"
        case (.oauth, .chinese): return "只读 OAuth"
        case (.statusLine, .english): return "Local status line"
        case (.statusLine, .chinese): return "本地状态栏"
        case (.kimiDesktop, .english): return "Kimi desktop session"
        case (.kimiDesktop, .chinese): return "Kimi 桌面端会话"
        case (.kimiCodeCLI, .english): return "Kimi Code CLI"
        case (.kimiCodeCLI, .chinese): return "Kimi Code CLI"
        case (.kimiCombined, .english): return "Kimi desktop + CLI"
        case (.kimiCombined, .chinese): return "Kimi 桌面端 + CLI"
        }
    }

    private var connectionButtonTitle: String {
        switch viewModel.claudeConnectionState {
        case .connecting:
            return L10n.text(.connectingClaude, language: appLanguage)
        case .connected:
            return L10n.text(.reconnectClaude, language: appLanguage)
        case .cliMissing:
            return L10n.text(.claudeCLIMissing, language: appLanguage)
        case .idle, .failed:
            return L10n.text(claudeOAuthEnabled ? .reconnectClaude : .connectClaude, language: appLanguage)
        }
    }

    private var connectionButtonIcon: String {
        switch viewModel.claudeConnectionState {
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle"
        case .cliMissing: return "exclamationmark.triangle"
        case .idle, .failed: return "person.badge.key"
        }
    }
}

private struct SettingsScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsScrollViewProbe {
        let view = SettingsScrollViewProbe()
        view.onAttach = configureScrollView
        return view
    }

    func updateNSView(_ nsView: SettingsScrollViewProbe, context: Context) {
        nsView.onAttach = configureScrollView
        nsView.configureWhenAttached()
    }

    private func configureScrollView(from probe: NSView) {
        guard let contentView = probe.window?.contentView else { return }

        for scrollView in contentView.descendants.compactMap({ $0 as? NSScrollView }) {
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.scrollerStyle = .overlay

            if !(scrollView.verticalScroller is SettingsTracklessScroller) {
                let scroller = SettingsTracklessScroller(frame: .zero)
                scroller.controlSize = scrollView.verticalScroller?.controlSize ?? .regular
                scrollView.verticalScroller = scroller
            }
        }
    }
}

private final class SettingsTracklessScroller: NSScroller {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }
}

private final class SettingsScrollViewProbe: NSView {
    var onAttach: ((NSView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWhenAttached()
    }

    func configureWhenAttached() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onAttach?(self)
        }
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
