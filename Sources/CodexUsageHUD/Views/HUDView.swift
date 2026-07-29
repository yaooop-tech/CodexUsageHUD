import AppKit
import Charts
import Combine
import SwiftUI

struct HUDView: View {
    @ObservedObject var viewModel: UsageViewModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @StateObject private var systemAppearance = SystemAppearanceMonitor()
    @AppStorage(DefaultsKey.collapsed) private var isCollapsed = true
    @AppStorage(DefaultsKey.theme) private var theme = AppTheme.system.rawValue
    @AppStorage(DefaultsKey.language) private var language = AppLanguage.english.rawValue
    @AppStorage(DefaultsKey.snapEdge) private var snapEdge = HUDSnapEdge.right.rawValue
    @State private var collapsedDragSuppressesClick = false
    @State private var hoverCollapseTask: Task<Void, Never>?
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var tokenChartRange: TokenChartRange? = .sevenDays

    private var horizontalWindowPadding: CGFloat {
        2
    }

    private var topWindowPadding: CGFloat {
        2
    }

    private var bottomWindowPadding: CGFloat {
        2
    }

    private var cornerRadius: CGFloat {
        10
    }

    private var panelSize: CGSize {
        if isCollapsed {
            return CGSize(width: 64, height: collapsedRowCount <= 1 ? 226 : 376)
        }
        let height: CGFloat
        switch viewModel.selectedProvider {
        case .codex:
            height = 430
        case .claude:
            height = 374
        case .kimi:
            height = expandedWindows.count == 3 ? 420 : 374
        }
        return CGSize(width: 360, height: height)
    }

    private var collapsedWindows: [UsageDisplayWindow] {
        viewModel.snapshot?.collapsedDisplayWindows ?? []
    }

    private var expandedWindows: [UsageDisplayWindow] {
        viewModel.snapshot?.displayWindows ?? []
    }

    private var collapsedRowCount: Int {
        if viewModel.selectedProvider == .claude { return 2 }
        if viewModel.selectedProvider == .codex && collapsedWindows.isEmpty { return 2 }
        return max(1, collapsedWindows.count)
    }

    private var collapsedMode: CollapsedHUDMode {
        CollapsedHUDMode(activityState: viewModel.activityState)
    }

    private var activeQuotaDividerPadding: EdgeInsets {
        guard collapsedMode.isActive, collapsedRowCount > 1 else {
            return EdgeInsets(top: 7, leading: 0, bottom: 7, trailing: 0)
        }
        return EdgeInsets(top: 22, leading: 0, bottom: 22, trailing: 0)
    }

    private var activeQuotaItems: [ActiveQuotaItem] {
        if viewModel.selectedProvider == .claude {
            return [
                ActiveQuotaItem(kind: .fiveHour, window: viewModel.snapshot?.primaryWindow),
                ActiveQuotaItem(kind: .weekly, window: viewModel.snapshot?.secondaryWindow),
            ]
        }
        if viewModel.selectedProvider == .codex && collapsedWindows.isEmpty {
            return [
                ActiveQuotaItem(kind: .fiveHour, window: nil),
                ActiveQuotaItem(kind: .weekly, window: nil),
            ]
        }
        if collapsedWindows.isEmpty {
            return [
                ActiveQuotaItem(
                    kind: viewModel.selectedProvider == .kimi ? .monthly : .fiveHour,
                    window: nil),
            ]
        }
        return collapsedWindows.map { ActiveQuotaItem(kind: $0.kind, window: $0.window) }
    }

    private var appTheme: AppTheme {
        AppTheme(rawValue: theme) ?? .system
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: language) ?? .english
    }

    private var effectiveColorScheme: ColorScheme {
        appTheme.resolvedColorScheme(system: systemAppearance.colorScheme)
    }

    private var usesLightSurface: Bool {
        effectiveColorScheme == .light
    }

    private var panelFill: Color {
        if usesLightSurface {
            return Color(red: 0.985, green: 0.985, blue: 0.975)
        }
        return Color(red: 0.105, green: 0.108, blue: 0.112)
    }

    private var panelBackground: some View {
        panelFill
    }

    private var desiredSize: CGSize {
        CGSize(
            width: panelSize.width + horizontalWindowPadding * 2,
            height: panelSize.height + topWindowPadding + bottomWindowPadding)
    }

    private var contentAnimation: Animation? {
        accessibilityReduceMotion
            ? nil
            : .easeOut(duration: HUDWindowMotion.transitionDuration)
    }

    private var expansionAlignment: Alignment {
        HUDSnapEdge(rawValue: snapEdge) == .left ? .leading : .trailing
    }

    private var panelStroke: Color {
        usesLightSurface ? Color.black.opacity(0.055) : Color.white.opacity(0.065)
    }

    var body: some View {
        ZStack(alignment: expansionAlignment) {
            if isCollapsed {
                collapsedContent
                    .frame(width: panelSize.width, height: panelSize.height)
                    .transition(.opacity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(collapsedDragGesture)
                    .onTapGesture {
                        expandFromClick()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(viewModel.selectedProvider.displayName), \(viewModel.activitySummary.description(language: appLanguage))")
                    .accessibilityHint(L10n.text(.expand, language: appLanguage))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        expandFromClick()
                    }
            } else {
                expandedContent
                    .frame(width: panelSize.width, height: panelSize.height)
                    .transition(.opacity)
            }
        }
        // The window clips this edge-aligned surface while its frame animates,
        // producing a mirrored reveal from the attached screen edge.
        .animation(contentAnimation, value: isCollapsed)
        .frame(
            width: panelSize.width,
            height: panelSize.height,
            alignment: expansionAlignment)
        .background { panelBackground }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(panelStroke, lineWidth: 0.5)
        }
        .padding(.horizontal, horizontalWindowPadding)
        .padding(.top, topWindowPadding)
        .padding(.bottom, bottomWindowPadding)
        .frame(width: desiredSize.width, height: desiredSize.height)
        .background(Color.clear)
        .background(FloatingWindowConfigurator(
            desiredSize: desiredSize,
            contentInsets: NSEdgeInsets(
                top: topWindowPadding,
                left: horizontalWindowPadding,
                bottom: bottomWindowPadding,
                right: horizontalWindowPadding),
            isCollapsed: isCollapsed,
            cornerRadius: cornerRadius,
            theme: appTheme,
            systemColorScheme: systemAppearance.colorScheme,
            reducesMotion: accessibilityReduceMotion))
        .preferredColorScheme(effectiveColorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onHover { isInside in
            handleWindowHover(isInside)
        }
        .onAppear {
            viewModel.setCollapsed(isCollapsed)
        }
        .onChange(of: isCollapsed) { _, newValue in
            viewModel.setCollapsed(newValue)
            if newValue {
                hoverCollapseTask?.cancel()
                hoverCollapseTask = nil
            }
        }
        .onDisappear {
            hoverCollapseTask?.cancel()
            hoverCollapseTask = nil
        }
    }

    private var collapsedContent: some View {
        ZStack {
            if collapsedMode.isActive {
                collapsedActiveContent
                    .transition(.opacity)
                    .accessibilityHidden(!collapsedMode.isActive)
            } else {
                collapsedIdleContent
                    .transition(.opacity)
                    .accessibilityHidden(collapsedMode.isActive)
            }
        }
        .animation(
            accessibilityReduceMotion
                ? .easeOut(duration: 0.12)
                : .easeOut(duration: 0.20),
            value: collapsedMode)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .help("\(L10n.text(.expand, language: appLanguage)) · \(viewModel.activitySummary.description(language: appLanguage))")
        .accessibilityLabel("\(viewModel.selectedProvider.displayName), \(viewModel.activitySummary.description(language: appLanguage))")
    }

    private var collapsedIdleContent: some View {
        VStack(spacing: 8) {
            VStack(spacing: 4) {
                ProviderLogoView(provider: viewModel.selectedProvider, size: 18)
                Text(viewModel.selectedProvider.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity)
            }

            if viewModel.selectedProvider == .claude {
                RailMetric(title: windowTitle(.fiveHour, compact: true), window: viewModel.snapshot?.primaryWindow, showsDate: false, usesLightSurface: usesLightSurface)
                RailDivider()
                RailMetric(title: windowTitle(.weekly, compact: true), window: viewModel.snapshot?.secondaryWindow, showsDate: true, usesLightSurface: usesLightSurface)
            } else if viewModel.selectedProvider == .codex && collapsedWindows.isEmpty {
                RailMetric(title: windowTitle(.fiveHour, compact: true), window: nil, showsDate: false, usesLightSurface: usesLightSurface)
                RailDivider()
                RailMetric(title: windowTitle(.weekly, compact: true), window: nil, showsDate: true, usesLightSurface: usesLightSurface)
            } else if collapsedWindows.isEmpty {
                RailMetric(title: viewModel.selectedProvider == .kimi ? windowTitle(.monthly, compact: true) : windowTitle(.fiveHour, compact: true), window: nil, showsDate: true, usesLightSurface: usesLightSurface)
            } else {
                ForEach(Array(collapsedWindows.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { RailDivider() }
                    RailMetric(
                        title: windowTitle(item.kind, compact: true),
                        window: item.window,
                        showsDate: item.kind != .fiveHour,
                        usesLightSurface: usesLightSurface)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 10)
    }

    private var collapsedActiveContent: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                collapsedStatusVisual
                    .frame(height: proxy.size.height * (collapsedRowCount > 1 ? 0.46 : 0.52))
                collapsedActiveQuotaSection
            }
        }
    }

    @ViewBuilder
    private var collapsedStatusVisual: some View {
        if let visualTheme = collapsedMode.theme {
            CollapsedStatusVisual(
                theme: visualTheme,
                presentation: CollapsedStatusPresentation(
                    state: viewModel.activityState,
                    unreadCompletionCount: viewModel.unreadCompletionCount,
                    language: appLanguage),
                accessibilityDescription: viewModel.activitySummary.description(language: appLanguage),
                panelFill: panelFill,
                usesLightSurface: usesLightSurface,
                permitsActiveWork: viewModel.permitsActiveWork && isCollapsed,
                isLowPowerModeEnabled: isLowPowerModeEnabled,
                reducesMotion: accessibilityReduceMotion)
        }
    }

    private var collapsedActiveQuotaSection: some View {
        VStack(spacing: collapsedRowCount > 1 ? 8 : 10) {
            Text(viewModel.selectedProvider.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            VStack(spacing: 0) {
                ForEach(Array(activeQuotaItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        RailDivider()
                            .padding(activeQuotaDividerPadding)
                    }
                    ActiveQuotaMetric(
                        title: windowTitle(item.kind, compact: true),
                        window: item.window,
                        compact: true)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.top, collapsedRowCount > 1 ? 11 : 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(panelFill)
    }

    private var collapsedDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard isCollapsed else {
                    return
                }
                if abs(value.translation.width) > 3 || abs(value.translation.height) > 3 {
                    collapsedDragSuppressesClick = true
                }
            }
            .onEnded { _ in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    collapsedDragSuppressesClick = false
                }
            }
    }

    private var expandedContent: some View {
        expandedIdleContent
    }

    private var expandedIdleContent: some View {
        VStack(spacing: 8) {
            expandedIdentityHeader

            VStack(spacing: 12) {
                if viewModel.selectedProvider == .codex {
                    codexExpandedContent
                } else if viewModel.selectedProvider == .claude {
                    claudeExpandedContent
                } else {
                    kimiExpandedContent
                }

                if let lastError = viewModel.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var expandedIdentityHeader: some View {
        HStack(spacing: 6) {
            ProviderLogoView(provider: viewModel.selectedProvider, size: 16)

            Text(viewModel.selectedProvider.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 0)
            Button {
                viewModel.refreshNow()
            } label: {
                Image(systemName: viewModel.isRefreshing ? "arrow.triangle.2.circlepath.circle" : "arrow.clockwise")
            }
            .controlButtonStyle()
            .disabled(viewModel.isRefreshing)
            .help(L10n.text(.refresh, language: appLanguage))
            .accessibilityLabel(L10n.text(.refresh, language: appLanguage))

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .controlButtonStyle()
            .help(L10n.text(.appearance, language: appLanguage))
            .accessibilityLabel(L10n.text(.appearance, language: appLanguage))

            Button {
                viewModel.shutdown()
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark")
            }
            .controlButtonStyle()
            .help(L10n.text(.quit, language: appLanguage))
            .accessibilityLabel(L10n.text(.quit, language: appLanguage))
        }
        .frame(height: 28)
    }

    private var codexExpandedContent: some View {
        Group {
            VStack(spacing: 12) {
                if expandedWindows.isEmpty {
                    WindowRow(title: windowTitle(.fiveHour), window: nil, resetStyle: .timeOnly, language: appLanguage)
                    WindowRow(title: windowTitle(.weekly), window: nil, resetStyle: .dateTime, language: appLanguage)
                } else if expandedWindows.count == 2 {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(expandedWindows) { item in
                            InlineQuotaRow(
                                title: windowTitle(item.kind, compact: true),
                                window: item.window,
                                resetStyle: resetStyle(item.kind),
                                language: appLanguage)
                        }
                    }
                } else {
                    ForEach(expandedWindows) { item in
                        WindowRow(title: windowTitle(item.kind), window: item.window, resetStyle: resetStyle(item.kind), language: appLanguage)
                    }
                }
                DetailRow(label: L10n.text(.resetCredits, language: appLanguage), value: resetCreditText)
            }

            PanelDivider()
            codexSubscriptionSection
            VStack(spacing: 8) {
                PanelDivider()
                codexTokenSection
            }

            if viewModel.snapshot?.isSourceStale == true, viewModel.lastError == nil {
                Text(L10n.text(.staleClaudeData, language: appLanguage))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var claudeExpandedContent: some View {
        Group {
            if viewModel.shouldOfferClaudeConnection {
                VStack(spacing: 14) {
                    Spacer(minLength: 18)
                    ProviderLogoView(provider: .claude, size: 34)
                    Text(L10n.text(.waitingClaudeResponse, language: appLanguage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                    Button {
                        viewModel.connectClaude()
                    } label: {
                        Label(claudeConnectionButtonTitle, systemImage: claudeConnectionButtonIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.claudeConnectionState == .connecting || viewModel.claudeConnectionState == .connected)
                    Spacer(minLength: 18)
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 12) {
                    WindowRow(title: windowTitle(.fiveHour), window: viewModel.snapshot?.primaryWindow, resetStyle: .timeOnly, language: appLanguage)
                    WindowRow(title: windowTitle(.weekly), window: viewModel.snapshot?.secondaryWindow, resetStyle: .dateTime, language: appLanguage)
                }

                PanelDivider()
                claudeSubscriptionSection
                PanelDivider()
                claudeSessionSection

                Text(claudeSyncStatus)
                    .font(.caption2)
                    .foregroundStyle(viewModel.snapshot?.isSourceStale == true ? .orange : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var kimiExpandedContent: some View {
        Group {
            VStack(spacing: 12) {
                if expandedWindows.isEmpty {
                    WindowRow(title: windowTitle(.monthly), window: nil, resetStyle: .dateTime, language: appLanguage)
                } else {
                    ForEach(expandedWindows) { item in
                        WindowRow(title: windowTitle(item.kind), window: item.window, resetStyle: resetStyle(item.kind), language: appLanguage)
                    }
                }
            }

            PanelDivider()
            VStack(spacing: 5) {
                MetadataRow(label: L10n.text(.currentPlan, language: appLanguage), value: planText)
                MetadataRow(label: L10n.text(.currentSource, language: appLanguage), value: kimiSourceText)
                MetadataRow(label: L10n.text(.lastSynced, language: appLanguage), value: kimiUpdatedText)
            }

            if viewModel.snapshot?.isSourceStale == true {
                Text(L10n.text(.staleClaudeData, language: appLanguage))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var codexTokenSection: some View {
        let trend = TokenUsageTrend(buckets: viewModel.snapshot?.tokenUsage?.dailyUsageBuckets)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                Text(L10n.text(.tokenUsage, language: appLanguage))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                tokenRangeSelector
            }
            .frame(height: 20)

            HStack(spacing: 5) {
                TokenKPI(
                    title: L10n.text(.sevenDayTotal, language: appLanguage),
                    value: HUDFormatters.tokenCount(trend.total))
                TokenKPI(
                    title: L10n.text(.dailyAverage, language: appLanguage),
                    value: HUDFormatters.tokenCount(trend.dailyAverage))
                TokenKPI(
                    title: L10n.text(.lifetime, language: appLanguage),
                    value: HUDFormatters.tokenCount(viewModel.snapshot?.tokenUsage?.summary.lifetimeTokens))
                TokenKPI(
                    title: L10n.text(.peakDay, language: appLanguage),
                    value: HUDFormatters.tokenCount(viewModel.snapshot?.tokenUsage?.summary.peakDailyTokens))
            }

            TokenTrendChart(
                trend: trend,
                accentColor: Color(red: 0.04, green: 0.48, blue: 1.0),
                language: appLanguage,
                selectedRange: $tokenChartRange)
                .frame(height: 104)
        }
    }

    private var tokenRangeSelector: some View {
        HStack(spacing: 3) {
            ForEach(TokenChartRange.displayOrder) { range in
                TokenRangeButton(
                    range: range,
                    language: appLanguage,
                    isSelected: tokenChartRange == range
                ) {
                    tokenChartRange = range
                }
            }
        }
    }

    private var codexSubscriptionSection: some View {
        VStack(spacing: 5) {
            MetadataRow(label: L10n.text(.currentPlan, language: appLanguage), value: planText)
            MetadataRow(label: L10n.text(.subscriptionAccount, language: appLanguage), value: accountText)
            MetadataRow(label: L10n.text(.expiresAt, language: appLanguage), value: L10n.text(.unavailable, language: appLanguage))
        }
    }

    private var claudeSubscriptionSection: some View {
        VStack(spacing: 5) {
            MetadataRow(label: L10n.text(.currentPlan, language: appLanguage), value: planText)
            MetadataRow(label: L10n.text(.subscriptionAccount, language: appLanguage), value: accountText)
        }
    }

    private var claudeSessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(.sessionUsage, language: appLanguage))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack {
                DetailPill(
                    title: L10n.text(.inputTokens, language: appLanguage),
                    value: HUDFormatters.tokenCount(viewModel.snapshot?.claudeSessionUsage?.inputTokens)
                )
                DetailPill(
                    title: L10n.text(.outputTokens, language: appLanguage),
                    value: HUDFormatters.tokenCount(viewModel.snapshot?.claudeSessionUsage?.outputTokens)
                )
                DetailPill(
                    title: L10n.text(.contextLeft, language: appLanguage),
                    value: contextRemainingText
                )
            }
        }
    }

    private var planText: String {
        guard let snapshot = viewModel.snapshot else {
            return "-"
        }
        return snapshot.planLabel.capitalized
    }

    private var accountText: String {
        viewModel.snapshot?.accountEmail ?? "-"
    }

    private var resetCreditText: String {
        guard let resetCredits = viewModel.snapshot?.resetCredits else {
            return "-"
        }
        return "\(resetCredits)"
    }

    private var contextRemainingText: String {
        guard let remaining = viewModel.snapshot?.claudeSessionUsage?.contextRemainingPercent else {
            return "-"
        }
        return "\(remaining)%"
    }

    private var claudeSyncStatus: String {
        guard let updatedAt = viewModel.snapshot?.sourceUpdatedAt else {
            return L10n.text(.waitingClaudeSync, language: appLanguage)
        }
        if viewModel.snapshot?.isSourceStale == true {
            return "\(L10n.text(.staleClaudeData, language: appLanguage)) · \(HUDFormatters.time.string(from: updatedAt))"
        }
        return "\(L10n.text(.lastSynced, language: appLanguage)) \(HUDFormatters.time.string(from: updatedAt))"
    }

    private var kimiSourceText: String {
        guard let source = viewModel.snapshot?.source else { return "-" }
        switch (source, appLanguage) {
        case (.kimiDesktop, .chinese): return "Kimi 桌面端会话"
        case (.kimiCodeCLI, .chinese): return "Kimi Code CLI"
        case (.kimiCombined, .chinese): return "桌面端 + CLI"
        default: return source.displayName
        }
    }

    private var kimiUpdatedText: String {
        guard let updated = viewModel.snapshot?.sourceUpdatedAt else { return "-" }
        return HUDFormatters.dateTime.string(from: updated)
    }

    private func windowTitle(_ kind: UsageWindowKind, compact: Bool = false) -> String {
        switch kind {
        case .fiveHour:
            return L10n.text(compact ? .fiveHourCompact : .fiveHour, language: appLanguage)
        case .weekly:
            return L10n.text(.weekly, language: appLanguage)
        case .codeSevenDay:
            return L10n.text(.codeSevenDay, language: appLanguage)
        case .monthly:
            return L10n.text(.monthly, language: appLanguage)
        }
    }

    private func resetStyle(_ kind: UsageWindowKind) -> ResetDisplayStyle {
        kind == .fiveHour ? .timeOnly : .dateTime
    }

    private var claudeConnectionButtonTitle: String {
        switch viewModel.claudeConnectionState {
        case .connecting: return L10n.text(.connectingClaude, language: appLanguage)
        case .connected: return L10n.text(.claudeConnected, language: appLanguage)
        case .cliMissing: return L10n.text(.claudeCLIMissing, language: appLanguage)
        case .idle, .failed: return L10n.text(.connectClaude, language: appLanguage)
        }
    }

    private var claudeConnectionButtonIcon: String {
        switch viewModel.claudeConnectionState {
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle"
        case .cliMissing: return "exclamationmark.triangle"
        case .idle, .failed: return "person.badge.key"
        }
    }

    private func expandFromClick() {
        if isCollapsed && !collapsedDragSuppressesClick {
            isCollapsed = false
        }
    }

    private func handleWindowHover(_ isInside: Bool) {
        hoverCollapseTask?.cancel()
        hoverCollapseTask = nil

        guard !isInside, !isCollapsed, !viewModel.activitySummary.hasActivity else {
            return
        }

        hoverCollapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, !isCollapsed, !viewModel.activitySummary.hasActivity else {
                return
            }
            isCollapsed = true
        }
    }

}

private struct ActiveQuotaItem: Identifiable {
    var id: String { kind.rawValue }
    let kind: UsageWindowKind
    let window: UsageWindow?
}

struct TokenUsageTrend: Equatable {
    struct Point: Identifiable, Equatable {
        let sourceDate: String
        let date: Date
        let tokens: Int64

        var id: String { sourceDate }

        var shortDateLabel: String {
            Self.shortDateFormatter.string(from: date)
        }

        private static let shortDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "M/d"
            return formatter
        }()
    }

    let points: [Point]
    let hasSourceData: Bool
    let calendar: Calendar

    init(
        buckets: [AccountTokenUsageDailyBucket]?,
        referenceDate: Date = Date(),
        calendar suppliedCalendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        var calendar = suppliedCalendar
        calendar.timeZone = .current
        self.calendar = calendar
        hasSourceData = buckets != nil

        let normalized = (buckets ?? []).compactMap { bucket -> (Date, Int64)? in
            guard let parsedDate = Self.parseDate(bucket.startDate) else { return nil }
            return (calendar.startOfDay(for: parsedDate), max(0, bucket.tokens))
        }
        let usageByDate = Dictionary(grouping: normalized, by: \.0)
            .mapValues { values in values.reduce(Int64(0)) { $0 + $1.1 } }

        let today = calendar.startOfDay(for: referenceDate)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let latestBucketDate = normalized.map(\.0).max()
        let endDate = max(yesterday, latestBucketDate ?? yesterday)
        let fallbackStart = calendar.date(byAdding: .day, value: -6, to: endDate) ?? endDate
        let startDate = min(normalized.map(\.0).min() ?? fallbackStart, fallbackStart)
        let dayCount = max(
            7,
            (calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 6) + 1)

        points = (0 ..< dayCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            return Point(
                sourceDate: Self.sourceDateFormatter.string(from: date),
                date: date,
                tokens: usageByDate[date] ?? 0)
        }
    }

    var total: Int64? {
        guard hasSourceData else { return nil }
        return recentPoints.reduce(0) { $0 + $1.tokens }
    }

    var dailyAverage: Int64? {
        guard let total else { return nil }
        return Int64((Double(total) / 7.0).rounded())
    }

    var peakPoint: Point? {
        guard hasSourceData else { return nil }
        return recentPoints.max { $0.tokens < $1.tokens }
    }

    var canDrawChart: Bool {
        points.count >= 7
    }

    var recentPoints: [Point] {
        Array(points.suffix(7))
    }

    var rangeLabel: String {
        guard let first = recentPoints.first, let last = recentPoints.last else { return "" }
        return "\(first.shortDateLabel)–\(last.shortDateLabel)"
    }

    func accessibilityDescription(language: AppLanguage) -> String {
        let totalText = HUDFormatters.tokenCount(total)
        let averageText = HUDFormatters.tokenCount(dailyAverage)
        let peakText = HUDFormatters.tokenCount(peakPoint?.tokens)
        switch language {
        case .english:
            return "Token usage \(rangeLabel), total \(totalText), daily average \(averageText), peak day \(peakText)"
        case .chinese:
            return "Token 使用量 \(rangeLabel)，总量 \(totalText)，日均 \(averageText)，峰值日 \(peakText)"
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) {
            return date
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: value) {
            return date
        }
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        return dayFormatter.date(from: String(value.prefix(10)))
    }

    private static let sourceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct CollapsedStatusPresentation: Equatable {
    static let capsuleHeight: CGFloat = 20

    let state: AgentActivityState
    let unreadCompletionCount: Int
    let language: AppLanguage

    var fullLabel: String {
        state.label(language: language)
    }

    var compactLabel: String {
        if state == .thinking {
            return language == .english ? "THK" : "思考"
        }
        return fullLabel
    }

    var isCompletionCountOnly: Bool {
        state == .unread && unreadCompletionCount >= 2
    }

    var showsInlineCompletionCount: Bool {
        state != .unread && state != .idle && unreadCompletionCount > 0
    }

    var visibleCompletionCount: Int? {
        guard isCompletionCountOnly || showsInlineCompletionCount else { return nil }
        return unreadCompletionCount
    }

    var completionCountText: String? {
        guard let visibleCompletionCount else { return nil }
        return visibleCompletionCount > 9 ? "9+" : "\(visibleCompletionCount)"
    }
}

private struct TokenKPI: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Text(value)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(.secondary.opacity(0.065), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }
}

private struct TokenRangeButton: View {
    let range: TokenChartRange
    let language: AppLanguage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(range.label(language: language))
                .font(.system(size: 8, weight: .semibold))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .frame(minWidth: 27)
                .frame(height: 20)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .background(
                    isSelected
                        ? Color.secondary.opacity(0.14)
                        : Color.secondary.opacity(0.045),
                    in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(
                            isSelected
                                ? Color.secondary.opacity(0.18)
                                : Color.secondary.opacity(0.08),
                            lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .help(range.accessibilityLabel(language: language))
        .accessibilityLabel(range.accessibilityLabel(language: language))
        .accessibilityValue(isSelected ? selectedAccessibilityValue : "")
    }

    private var selectedAccessibilityValue: String {
        language == .chinese ? "已选择" : "Selected"
    }
}

struct TokenChartViewport: Equatable {
    static let secondsPerDay: TimeInterval = 86_400

    let firstDate: Date
    let lastDate: Date
    let maximumDays: Double
    let calendar: Calendar
    var leadingDate: Date
    var visibleDays: Double

    init(trend: TokenUsageTrend) {
        let first = trend.points.first?.date ?? Date()
        let last = trend.points.last?.date ?? first
        firstDate = first
        lastDate = last
        maximumDays = max(3, Double(trend.points.count))
        calendar = trend.calendar
        visibleDays = min(7, maximumDays)
        leadingDate = last.addingTimeInterval(-(visibleDays - 1) * Self.secondsPerDay)
        clamp()
    }

    var domainLength: TimeInterval {
        max(2, visibleDays - 1) * Self.secondsPerDay
    }

    var trailingDate: Date {
        leadingDate.addingTimeInterval(domainLength)
    }

    var middleDate: Date {
        leadingDate.addingTimeInterval(domainLength / 2)
    }

    var isDefault: Bool {
        matches(.sevenDays)
    }

    mutating func reset() {
        select(.sevenDays)
    }

    mutating func select(_ range: TokenChartRange) {
        visibleDays = range.visibleDays(
            maximumDays: maximumDays,
            lastDate: lastDate,
            calendar: calendar)
        leadingDate = lastDate.addingTimeInterval(-domainLength)
        clamp()
    }

    func matches(_ range: TokenChartRange) -> Bool {
        abs(visibleDays - range.visibleDays(
            maximumDays: maximumDays,
            lastDate: lastDate,
            calendar: calendar)) < 0.02
            && abs(trailingDate.timeIntervalSince(lastDate)) < 120
    }

    mutating func zoom(scale: Double, anchorFraction: Double) {
        let anchor = min(1, max(0, anchorFraction))
        let anchorDate = leadingDate.addingTimeInterval(domainLength * anchor)
        visibleDays = min(maximumDays, max(3, visibleDays / max(scale, 0.01)))
        leadingDate = anchorDate.addingTimeInterval(-domainLength * anchor)
        clamp()
    }

    mutating func pan(from start: Date, translation: CGFloat, plotWidth: CGFloat) {
        guard plotWidth > 1 else { return }
        let seconds = Double(translation / plotWidth) * domainLength
        leadingDate = start.addingTimeInterval(-seconds)
        clamp()
    }

    mutating func pan(by translation: CGFloat, plotWidth: CGFloat) {
        pan(from: leadingDate, translation: translation, plotWidth: plotWidth)
    }

    mutating func clamp() {
        visibleDays = min(maximumDays, max(3, visibleDays))
        let latestLeading = lastDate.addingTimeInterval(-domainLength)
        if leadingDate < firstDate {
            leadingDate = firstDate
        }
        if leadingDate > latestLeading {
            leadingDate = max(firstDate, latestLeading)
        }
    }
}

enum TokenChartRange: String, CaseIterable, Identifiable, Equatable {
    case all
    case yearToDate
    case sixMonths
    case oneMonth
    case sevenDays

    static let displayOrder: [TokenChartRange] = [
        .all,
        .yearToDate,
        .sixMonths,
        .oneMonth,
        .sevenDays,
    ]

    var id: String { rawValue }

    func visibleDays(
        maximumDays: Double,
        lastDate: Date,
        calendar: Calendar
    ) -> Double {
        let requestedDays: Double
        switch self {
        case .all: requestedDays = maximumDays
        case .yearToDate:
            requestedDays = yearToDateDayCount(
                endingAt: lastDate,
                calendar: calendar)
        case .sixMonths:
            requestedDays = calendarMonthDayCount(
                months: 6,
                endingAt: lastDate,
                calendar: calendar)
        case .oneMonth:
            requestedDays = calendarMonthDayCount(
                months: 1,
                endingAt: lastDate,
                calendar: calendar)
        case .sevenDays: requestedDays = 7
        }
        return min(maximumDays, requestedDays)
    }

    private func yearToDateDayCount(
        endingAt lastDate: Date,
        calendar: Calendar
    ) -> Double {
        let year = calendar.component(.year, from: lastDate)
        guard let firstDay = calendar.date(
            from: DateComponents(year: year, month: 1, day: 1))
        else {
            return 365
        }
        let days = calendar.dateComponents(
            [.day],
            from: firstDay,
            to: lastDate).day ?? 364
        return Double(max(3, days + 1))
    }

    private func calendarMonthDayCount(
        months: Int,
        endingAt lastDate: Date,
        calendar: Calendar
    ) -> Double {
        guard let leadingDate = calendar.date(
            byAdding: .month,
            value: -months,
            to: lastDate)
        else {
            return Double(months * 30)
        }
        let days = calendar.dateComponents(
            [.day],
            from: leadingDate,
            to: lastDate).day ?? months * 30
        return Double(max(3, days + 1))
    }

    func label(language: AppLanguage) -> String {
        switch (self, language) {
        case (.all, .english): return "All"
        case (.yearToDate, .english): return "YTD"
        case (.sixMonths, .english): return "6M"
        case (.oneMonth, .english): return "1M"
        case (.sevenDays, .english): return "7D"
        case (.all, .chinese): return "全部"
        case (.yearToDate, .chinese): return "YTD"
        case (.sixMonths, .chinese): return "半年"
        case (.oneMonth, .chinese): return "1月"
        case (.sevenDays, .chinese): return "7日"
        }
    }

    func accessibilityLabel(language: AppLanguage) -> String {
        switch (self, language) {
        case (.all, .english): return "Show all token history"
        case (.yearToDate, .english): return "Show token history from the start of this year"
        case (.sixMonths, .english): return "Show the latest six months"
        case (.oneMonth, .english): return "Show the latest month"
        case (.sevenDays, .english): return "Show the latest seven days"
        case (.all, .chinese): return "显示全部 Token 历史"
        case (.yearToDate, .chinese): return "显示今年年初至今"
        case (.sixMonths, .chinese): return "显示最近半年"
        case (.oneMonth, .chinese): return "显示最近一个月"
        case (.sevenDays, .chinese): return "显示最近七日"
        }
    }
}

struct TokenChartRenderWindow: Equatable {
    let points: [TokenUsageTrend.Point]
    let selectablePoints: [TokenUsageTrend.Point]
    let yDomain: ClosedRange<Double>

    init(
        points sourcePoints: [TokenUsageTrend.Point],
        leadingDate: Date,
        trailingDate: Date
    ) {
        let sorted = sourcePoints.sorted { $0.date < $1.date }
        selectablePoints = sorted.filter {
            $0.date >= leadingDate && $0.date <= trailingDate
        }

        guard leadingDate < trailingDate,
              let leading = Self.boundaryPoint(
                at: leadingDate,
                points: sorted,
                identifier: "viewport-leading"),
              let trailing = Self.boundaryPoint(
                at: trailingDate,
                points: sorted,
                identifier: "viewport-trailing")
        else {
            points = selectablePoints
            let peak = max(selectablePoints.map { Double($0.tokens) }.max() ?? 0, 1)
            yDomain = (-peak * 0.035) ... (peak * 1.08)
            return
        }

        let interior = sorted.filter {
            $0.date > leadingDate && $0.date < trailingDate
        }
        var rendered = [leading]
        rendered.append(contentsOf: interior)
        if trailing.date.timeIntervalSince(leading.date) > 0.5 {
            rendered.append(trailing)
        }
        points = rendered
        let peak = max(rendered.map { Double($0.tokens) }.max() ?? 0, 1)
        yDomain = (-peak * 0.035) ... (peak * 1.08)
    }

    private static func boundaryPoint(
        at date: Date,
        points: [TokenUsageTrend.Point],
        identifier: String
    ) -> TokenUsageTrend.Point? {
        if let exact = points.first(where: {
            abs($0.date.timeIntervalSince(date)) < 0.5
        }) {
            return exact
        }
        guard let previous = points.last(where: { $0.date < date }),
              let next = points.first(where: { $0.date > date })
        else {
            return nil
        }
        let interval = next.date.timeIntervalSince(previous.date)
        guard interval > 0 else { return previous }
        let progress = min(1, max(0, date.timeIntervalSince(previous.date) / interval))
        let interpolated = Double(previous.tokens)
            + (Double(next.tokens) - Double(previous.tokens)) * progress
        return TokenUsageTrend.Point(
            sourceDate: "\(identifier)-\(date.timeIntervalSince1970)",
            date: date,
            tokens: Int64(interpolated.rounded()))
    }
}

private struct TokenTrendChart: View {
    let trend: TokenUsageTrend
    let accentColor: Color
    let language: AppLanguage
    @Binding var selectedRange: TokenChartRange?
    @State private var selectedPointID: String?
    @State private var viewport: TokenChartViewport
    @State private var isDragging = false

    init(
        trend: TokenUsageTrend,
        accentColor: Color,
        language: AppLanguage,
        selectedRange: Binding<TokenChartRange?>
    ) {
        self.trend = trend
        self.accentColor = accentColor
        self.language = language
        _selectedRange = selectedRange
        _viewport = State(initialValue: TokenChartViewport(trend: trend))
    }

    private var selectedPoint: TokenUsageTrend.Point? {
        guard let selectedPointID else { return nil }
        return trend.points.first { $0.id == selectedPointID }
    }

    private var visibleLabels: (
        first: TokenUsageTrend.Point?,
        middle: TokenUsageTrend.Point?,
        last: TokenUsageTrend.Point?
    ) {
        (
            nearestPoint(to: viewport.leadingDate),
            nearestPoint(to: viewport.middleDate),
            nearestPoint(to: viewport.trailingDate)
        )
    }

    private var renderWindow: TokenChartRenderWindow {
        TokenChartRenderWindow(
            points: trend.points,
            leadingDate: viewport.leadingDate,
            trailingDate: viewport.trailingDate)
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Chart {
                    if trend.hasSourceData {
                        ForEach(renderWindow.points) { point in
                            AreaMark(
                                x: .value("Date", point.date),
                                y: .value("Tokens", Double(point.tokens)))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [accentColor.opacity(0.18), accentColor.opacity(0.02)],
                                        startPoint: .top,
                                        endPoint: .bottom))

                            LineMark(
                                x: .value("Date", point.date),
                                y: .value("Tokens", Double(point.tokens)))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(accentColor)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                    }

                    if let selectedPoint, !isDragging {
                        RuleMark(x: .value("Selected date", selectedPoint.date))
                            .foregroundStyle(.secondary.opacity(0.30))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        PointMark(
                            x: .value("Selected date", selectedPoint.date),
                            y: .value("Selected tokens", Double(selectedPoint.tokens)))
                            .foregroundStyle(accentColor)
                            .symbolSize(24)
                    }
                }
                .chartLegend(.hidden)
                .chartYAxis(.hidden)
                .chartXAxis(.hidden)
                .chartXScale(domain: viewport.leadingDate ... viewport.trailingDate)
                .chartYScale(domain: renderWindow.yDomain)
                .chartPlotStyle { plotArea in
                    plotArea
                        .padding(.vertical, 2)
                        .clipped()
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
                .clipped()

                TokenChartInputBridge(
                    onPan: { translation, width in
                        withTransaction(Transaction(animation: nil)) {
                            viewport.pan(by: translation, plotWidth: width)
                        }
                        selectedRange = nil
                        selectedPointID = nil
                    },
                    onZoom: { scale, anchorFraction in
                        withTransaction(Transaction(animation: nil)) {
                            viewport.zoom(scale: scale, anchorFraction: anchorFraction)
                        }
                        selectedRange = nil
                        selectedPointID = nil
                    },
                    onHover: { fraction in
                        guard !isDragging, let fraction else {
                            selectedPointID = nil
                            return
                        }
                        let date = viewport.leadingDate.addingTimeInterval(
                            viewport.domainLength * min(1, max(0, fraction)))
                        selectedPointID = nearestPoint(to: date)?.id
                    },
                    onDraggingChanged: { dragging in
                        isDragging = dragging
                        if dragging {
                            selectedPointID = nil
                        }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 86)
            .clipped()
            .overlay {
                if !trend.hasSourceData {
                    Text(L10n.text(.tokenUnavailable, language: language))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let selectedPoint, !isDragging {
                    Text("\(selectedPoint.shortDateLabel) · \(HUDFormatters.tokenCount(selectedPoint.tokens))")
                        .font(.system(size: 8, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Text(visibleLabels.first?.shortDateLabel ?? "-")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Text(visibleLabels.middle?.shortDateLabel ?? "-")
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
                Text(visibleLabels.last?.shortDateLabel ?? "-")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 8, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
        }
        .onChange(of: trend) { _, newTrend in
            viewport = TokenChartViewport(trend: newTrend)
            selectedRange = .sevenDays
            selectedPointID = nil
        }
        .onChange(of: selectedRange) { _, newRange in
            guard let newRange else { return }
            withTransaction(Transaction(animation: nil)) {
                viewport.select(newRange)
            }
            selectedPointID = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trend.accessibilityDescription(language: language))
    }

    private func nearestPoint(to date: Date) -> TokenUsageTrend.Point? {
        renderWindow.selectablePoints.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }
}

enum TokenChartInteractionPolicy: Equatable {
    case pan(CGFloat)
    case zoom(Double)
    case passThrough

    static func scroll(
        precise: Bool,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> TokenChartInteractionPolicy {
        if precise {
            guard abs(deltaX) > max(0.2, abs(deltaY) * 0.65) else {
                return .passThrough
            }
            return .pan(deltaX)
        }
        guard abs(deltaY) > 0.01 else { return .passThrough }
        return .zoom(exp(Double(deltaY) * 0.08))
    }
}

enum TokenChartMagnificationPolicy {
    static func scale(for magnificationDelta: CGFloat) -> Double {
        min(1.25, max(0.75, 1 + Double(magnificationDelta)))
    }
}

private struct TokenChartInputBridge: NSViewRepresentable {
    let onPan: @MainActor (CGFloat, CGFloat) -> Void
    let onZoom: @MainActor (Double, Double) -> Void
    let onHover: @MainActor (Double?) -> Void
    let onDraggingChanged: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> TokenChartInputView {
        let view = TokenChartInputView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: TokenChartInputView, context: Context) {
        update(nsView)
    }

    static func dismantleNSView(
        _ nsView: TokenChartInputView,
        coordinator: ()
    ) {
        nsView.invalidateInputLifecycle()
    }

    private func update(_ view: TokenChartInputView) {
        view.onPan = onPan
        view.onZoom = onZoom
        view.onHover = onHover
        view.onDraggingChanged = onDraggingChanged
    }
}

@MainActor
final class TokenChartInputView: NSView {
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((Double, Double) -> Void)?
    var onHover: ((Double?) -> Void)?
    var onDraggingChanged: ((Bool) -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var lastDragPoint: NSPoint?
    private weak var gestureWindow: NSWindow?
    private var magnificationRecognizer: NSMagnificationGestureRecognizer?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        reinstallMagnificationRecognizer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        reinstallMagnificationRecognizer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== gestureWindow else { return }
        gestureWindow = window
        if window != nil {
            reinstallMagnificationRecognizer()
            updateTrackingAreas()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self)
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onHover?(anchorFraction(for: event))
    }

    override func scrollWheel(with event: NSEvent) {
        switch TokenChartInteractionPolicy.scroll(
            precise: event.hasPreciseScrollingDeltas,
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY
        ) {
        case .pan(let delta):
            onPan?(delta, bounds.width)
        case .zoom(let scale):
            onZoom?(scale, anchorFraction(for: event))
        case .passThrough:
            super.scrollWheel(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDragPoint = convert(event.locationInWindow, from: nil)
        onDraggingChanged?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let previous = lastDragPoint, abs(point.x - previous.x) > 0.01 {
            onPan?(point.x - previous.x, bounds.width)
        }
        lastDragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        onDraggingChanged?(false)
        mouseMoved(with: event)
    }

    @objc private func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onDraggingChanged?(true)
            recognizer.magnification = 0
        case .changed:
            let delta = recognizer.magnification
            guard abs(delta) > 0.0001 else { return }
            onZoom?(
                TokenChartMagnificationPolicy.scale(for: delta),
                anchorFraction(for: recognizer.location(in: self)))
            recognizer.magnification = 0
        case .ended, .cancelled, .failed:
            onDraggingChanged?(false)
            onHover?(anchorFraction(for: recognizer.location(in: self)))
        default:
            break
        }
    }

    func reinstallMagnificationRecognizer() {
        if let magnificationRecognizer {
            removeGestureRecognizer(magnificationRecognizer)
        }
        let recognizer = NSMagnificationGestureRecognizer(
            target: self,
            action: #selector(handleMagnification(_:)))
        magnificationRecognizer = recognizer
        addGestureRecognizer(recognizer)
    }

    func invalidateInputLifecycle() {
        onDraggingChanged?(false)
        if let magnificationRecognizer {
            removeGestureRecognizer(magnificationRecognizer)
        }
        magnificationRecognizer = nil
        gestureWindow = nil
        lastDragPoint = nil
        onPan = nil
        onZoom = nil
        onHover = nil
        onDraggingChanged = nil
    }

    var magnificationRecognizerForTesting: NSMagnificationGestureRecognizer? {
        magnificationRecognizer
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(anchorFraction(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    private func anchorFraction(for event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        return anchorFraction(for: point)
    }

    private func anchorFraction(for point: NSPoint) -> Double {
        guard bounds.width > 1 else { return 0.5 }
        return min(1, max(0, Double(point.x / bounds.width)))
    }
}

private struct CollapsedStatusVisual: View {
    let theme: ActivityVisualTheme
    let presentation: CollapsedStatusPresentation
    let accessibilityDescription: String
    let panelFill: Color
    let usesLightSurface: Bool
    let permitsActiveWork: Bool
    let isLowPowerModeEnabled: Bool
    let reducesMotion: Bool
    @State private var completionPulse = false
    @State private var isWindowVisible = true

    var body: some View {
        ZStack(alignment: .bottom) {
            StarlightFlowField(
                theme: theme,
                usesLightSurface: usesLightSurface,
                isVisible: isWindowVisible && permitsActiveWork,
                isLowPowerModeEnabled: isLowPowerModeEnabled,
                reducesMotion: reducesMotion)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.42),
                    .init(color: panelFill.opacity(0.14), location: 0.64),
                    .init(color: panelFill.opacity(0.50), location: 0.82),
                    .init(color: panelFill.opacity(0.86), location: 0.94),
                    .init(color: panelFill, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            statusCapsule
                .padding(.horizontal, 3)
                .padding(.bottom, 9)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityDescription)
        }
        .background {
            WindowVisibilityReader(isVisible: $isWindowVisible)
                .allowsHitTesting(false)
        }
        .onChange(of: presentation.unreadCompletionCount) { oldValue, newValue in
            guard newValue > oldValue, presentation.visibleCompletionCount != nil else { return }
            withAnimation(.easeOut(duration: 0.10)) {
                completionPulse = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(110))
                withAnimation(.easeOut(duration: 0.10)) {
                    completionPulse = false
                }
            }
        }
    }

    @ViewBuilder
    private var statusCapsule: some View {
        if presentation.isCompletionCountOnly {
            completionCount
                .foregroundStyle(Color.black.opacity(0.82))
                .padding(.horizontal, 7)
                .frame(height: CollapsedStatusPresentation.capsuleHeight)
                .fixedSize(horizontal: true, vertical: false)
                .background(completionColor, in: Capsule())
        } else if presentation.showsInlineCompletionCount {
            combinedStatus(label: presentation.compactLabel)
            .padding(.horizontal, 6)
            .frame(height: CollapsedStatusPresentation.capsuleHeight)
            .fixedSize(horizontal: true, vertical: false)
            .background(labelBackground, in: Capsule())
        } else {
            Text(presentation.fullLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(height: CollapsedStatusPresentation.capsuleHeight)
                .fixedSize(horizontal: true, vertical: false)
                .background(labelBackground, in: Capsule())
        }
    }

    private func combinedStatus(label: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(labelColor)
            completionCount
                .foregroundStyle(completionColor)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.90)
    }

    private var completionCount: some View {
        HStack(spacing: 1) {
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .black))
            Text(presentation.completionCountText ?? "")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .scaleEffect(completionPulse ? 1.08 : 1)
    }

    private var completionColor: Color {
        Color(red: 0.03, green: 0.90, blue: 0.25)
    }

    private var labelColor: Color {
        usesLightSurface ? Color.black.opacity(0.78) : Color.white.opacity(0.92)
    }

    private var labelBackground: Color {
        usesLightSurface ? Color.white.opacity(0.70) : Color.black.opacity(0.35)
    }

}

private struct ActiveQuotaMetric: View {
    let title: String
    let window: UsageWindow?
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 3 : 4) {
            Text(title)
                .font(.system(size: compact ? 9 : 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .center)

            Text(valueText)
                .font(.system(
                    size: compact ? 18 : 29,
                    weight: .bold,
                    design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(compact ? 0.90 : 0.70)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(valueText)")
    }

    private var valueText: String {
        guard let window else { return "—" }
        return "\(UsagePercentFormatter.string(window.remainingPercent))%"
    }
}

private struct ProviderLogoView: View {
    let provider: UsageProvider
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.12)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }

    private var appIcon: NSImage? {
        let path: String
        switch provider {
        case .codex: path = "/Applications/ChatGPT.app"
        case .claude: path = "/Applications/Claude.app"
        case .kimi: path = "/Applications/Kimi.app"
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    private var fallbackSymbol: String {
        switch provider {
        case .codex: return "terminal.fill"
        case .claude: return "sparkles"
        case .kimi: return "moon.stars.fill"
        }
    }
}

private extension View {
    func controlButtonStyle() -> some View {
        self
            .buttonStyle(.borderless)
            .buttonBorderShape(.roundedRectangle(radius: 6))
            .controlSize(.small)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 32, height: 30)
            .contentShape(Rectangle())
    }
}

private struct RailMetric: View {
    let title: String
    let window: UsageWindow?
    let showsDate: Bool
    let usesLightSurface: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(valueText)
                .font(.caption2.monospacedDigit().weight(.bold))
                .lineLimit(1)

            VerticalWaterProgressBar(value: window?.remainingPercent, tint: tint, usesLightSurface: usesLightSurface)

            VStack(spacing: 1) {
                if showsDate {
                    Text(resetParts.date)
                }
                Text(resetParts.time)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
    }

    private var valueText: String {
        guard let window else {
            return "-"
        }
        return "\(UsagePercentFormatter.string(window.remainingPercent))%"
    }

    private var resetParts: (date: String, time: String) {
        HUDFormatters.railResetParts(window?.resetsAt)
    }

    private var tint: Color {
        UsageTint.color(for: window?.remainingPercent)
    }
}

private struct RailDivider: View {
    var body: some View {
        Rectangle()
            .fill(.secondary.opacity(0.18))
            .frame(width: 36, height: 1)
    }
}

private struct WindowRow: View {
    let title: String
    let window: UsageWindow?
    let resetStyle: ResetDisplayStyle
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            UsageProgressBar(value: window?.remainingPercent, tint: tint, height: 6)
            Text("\(L10n.text(.quotaRestores, language: language)) \(resetStyle.text(for: window?.resetsAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
    }

    private var valueText: String {
        guard let window else {
            return "-"
        }
        if language == .chinese {
            return "\(L10n.text(.remaining, language: language)) \(UsagePercentFormatter.string(window.remainingPercent))%"
        }
        return "\(UsagePercentFormatter.string(window.remainingPercent))% left"
    }

    private var tint: Color {
        UsageTint.color(for: window?.remainingPercent)
    }
}

private struct InlineQuotaRow: View {
    let title: String
    let window: UsageWindow?
    let resetStyle: ResetDisplayStyle
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                Spacer(minLength: 4)
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            UsageProgressBar(value: window?.remainingPercent, tint: tint, height: 6)
            Text("\(L10n.text(.quotaRestores, language: language)) \(resetStyle.text(for: window?.resetsAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(valueText)")
    }

    private var valueText: String {
        guard let window else { return "—" }
        return "\(UsagePercentFormatter.string(window.remainingPercent))%"
    }

    private var tint: Color {
        UsageTint.color(for: window?.remainingPercent)
    }
}

private enum ResetDisplayStyle {
    case timeOnly
    case dateTime

    func text(for date: Date?) -> String {
        switch self {
        case .timeOnly:
            return HUDFormatters.resetText(date)
        case .dateTime:
            return HUDFormatters.fullResetText(date)
        }
    }
}

private enum UsageTint {
    static func color(for remaining: Double?) -> Color {
        guard let remaining else {
            return .secondary
        }
        if remaining <= 10 {
            return .red
        }
        if remaining <= 20 {
            return .orange
        }
        if remaining <= 50 {
            return .yellow
        }
        return .green
    }
}

private struct UsageProgressBar: View {
    let value: Double?
    let tint: Color
    let height: CGFloat

    private var fraction: CGFloat {
        CGFloat(max(0, min(100, value ?? 0))) / 100
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, proxy.size.width * fraction))
                    .opacity(value == nil ? 0 : 1)
            }
        }
        .frame(height: height)
        .accessibilityLabel("Remaining usage")
        .accessibilityValue(value.map { "\(UsagePercentFormatter.string($0))%" } ?? "No data")
    }
}

private struct VerticalWaterProgressBar: View {
    let value: Double?
    let tint: Color
    let usesLightSurface: Bool

    private var fraction: CGFloat {
        CGFloat(max(0, min(100, value ?? 0))) / 100
    }

    private var trackColor: Color {
        usesLightSurface ? Color.black.opacity(0.16) : Color.white.opacity(0.18)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(trackColor)
                Capsule()
                    .fill(tint)
                    .frame(height: fillHeight(in: proxy.size.height))
                    .opacity(value == nil ? 0 : 1)
            }
        }
        .frame(width: 6, height: 78)
        .accessibilityLabel("Remaining usage")
        .accessibilityValue(value.map { "\(UsagePercentFormatter.string($0))%" } ?? "No data")
    }

    private func fillHeight(in height: CGFloat) -> CGFloat {
        guard value != nil else {
            return 0
        }
        return max(3, height * fraction)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
    }
}

private struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(.secondary.opacity(0.16))
            .frame(height: 1)
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption2)
    }
}

private struct DetailPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
