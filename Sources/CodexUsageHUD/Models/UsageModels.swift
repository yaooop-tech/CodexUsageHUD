import Foundation
import SwiftUI

enum UsageProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case kimi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .kimi: return "Kimi"
        }
    }
}

enum UsageDataSource: String, Codable {
    case appServer
    case oauth
    case statusLine
    case kimiDesktop
    case kimiCodeCLI
    case kimiCombined

    var displayName: String {
        switch self {
        case .appServer: return "App server"
        case .oauth: return "OAuth"
        case .statusLine: return "Status line"
        case .kimiDesktop: return "Kimi desktop session"
        case .kimiCodeCLI: return "Kimi Code CLI"
        case .kimiCombined: return "Kimi desktop + CLI"
        }
    }
}

enum DisplaySourceMode: String, CaseIterable, Identifiable {
    case automatic
    case codex
    case claude
    case kimi

    var id: String { rawValue }
}

enum FrontmostApplicationProvider {
    static func provider(for bundleIdentifier: String?) -> UsageProvider? {
        switch bundleIdentifier {
        case "com.openai.codex": return .codex
        case "com.anthropic.claudefordesktop": return .claude
        case "com.moonshot.kimichat": return .kimi
        default: return nil
        }
    }
}

struct AccountReadResponse: Decodable, Sendable {
    let account: AccountInfo?
    let requiresOpenaiAuth: Bool
}

struct AccountInfo: Decodable, Sendable {
    let type: String
    let email: String?
    let planType: String?
}

struct AccountRateLimitsResponse: Decodable, Sendable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: RateLimitResetCreditsSummary?
}

struct RateLimitResetCreditsSummary: Decodable, Sendable {
    let availableCount: Int64
}

struct RateLimitSnapshot: Decodable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let individualLimit: SpendControlLimitSnapshot?
    let planType: String?
    let rateLimitReachedType: String?
}

struct RateLimitWindow: Decodable, Sendable {
    let usedPercent: Double
    let windowDurationMins: Int64?
    let resetsAt: Int64?

    init(usedPercent: Double, windowDurationMins: Int64?, resetsAt: Int64?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

struct CreditsSnapshot: Decodable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct SpendControlLimitSnapshot: Decodable, Sendable {
    let limit: String
    let used: String
    let remainingPercent: Int
    let resetsAt: Int64
}

struct AccountTokenUsageResponse: Decodable, Sendable {
    let summary: AccountTokenUsageSummary
    let dailyUsageBuckets: [AccountTokenUsageDailyBucket]?
}

struct AccountTokenUsageSummary: Decodable, Sendable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSec: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
}

struct AccountTokenUsageDailyBucket: Decodable, Identifiable, Sendable {
    var id: String { startDate }
    let startDate: String
    let tokens: Int64
}

struct UsageSnapshot {
    let provider: UsageProvider
    let account: AccountInfo?
    let requiresOpenaiAuth: Bool
    let rateLimit: RateLimitSnapshot?
    let resetCredits: Int64?
    let tokenUsage: AccountTokenUsageResponse?
    let claudeSessionUsage: ClaudeSessionUsage?
    let source: UsageDataSource
    let sourceUpdatedAt: Date?
    let sourceError: String?
    let fetchedAt: Date
    let supplementalWindows: [UsageDisplayWindow]

    init(
        provider: UsageProvider,
        account: AccountInfo?,
        requiresOpenaiAuth: Bool,
        rateLimit: RateLimitSnapshot?,
        resetCredits: Int64?,
        tokenUsage: AccountTokenUsageResponse?,
        claudeSessionUsage: ClaudeSessionUsage?,
        source: UsageDataSource,
        sourceUpdatedAt: Date?,
        sourceError: String?,
        fetchedAt: Date,
        supplementalWindows: [UsageDisplayWindow] = [])
    {
        self.provider = provider
        self.account = account
        self.requiresOpenaiAuth = requiresOpenaiAuth
        self.rateLimit = rateLimit
        self.resetCredits = resetCredits
        self.tokenUsage = tokenUsage
        self.claudeSessionUsage = claudeSessionUsage
        self.source = source
        self.sourceUpdatedAt = sourceUpdatedAt
        self.sourceError = sourceError
        self.fetchedAt = fetchedAt
        self.supplementalWindows = supplementalWindows
    }

    var planLabel: String {
        rateLimit?.planType ?? account?.planType ?? "unknown"
    }

    var accountEmail: String? {
        account?.email
    }

    var primaryWindow: UsageWindow? {
        if provider == .kimi {
            return displayWindows.first(where: { $0.kind == .fiveHour })?.window
        }
        let positionalPrimary = UsageWindow(source: rateLimit?.primary)
        guard provider == .codex else { return positionalPrimary }

        let windows = [positionalPrimary, UsageWindow(source: rateLimit?.secondary)].compactMap { $0 }
        if let fiveHour = windows.first(where: \.isFiveHourWindow) {
            return fiveHour
        }
        // If a duration-labelled weekly window is the only Codex window, the
        // API has promoted it to `primary_window`; do not present it as 5-hour.
        return windows.contains(where: \.isWeeklyWindow) ? nil : positionalPrimary
    }

    var secondaryWindow: UsageWindow? {
        if provider == .kimi {
            return displayWindows.first(where: { $0.kind == .codeSevenDay })?.window
                ?? displayWindows.first(where: { $0.kind == .monthly })?.window
        }
        let positionalSecondary = UsageWindow(source: rateLimit?.secondary)
        guard provider == .codex else { return positionalSecondary }

        let windows = [UsageWindow(source: rateLimit?.primary), positionalSecondary].compactMap { $0 }
        return windows.first(where: \.isWeeklyWindow) ?? positionalSecondary
    }

    /// All available windows in their expanded-HUD order. Codex windows are
    /// classified by duration so a weekly-only response is never mislabeled.
    var displayWindows: [UsageDisplayWindow] {
        if provider == .kimi {
            return supplementalWindows.sorted { $0.kind.sortOrder < $1.kind.sortOrder }
        }

        let positional = [UsageWindow(source: rateLimit?.primary), UsageWindow(source: rateLimit?.secondary)]
        if provider == .claude {
            return [
                positional[0].map { UsageDisplayWindow(kind: .fiveHour, window: $0) },
                positional[1].map { UsageDisplayWindow(kind: .weekly, window: $0) },
            ].compactMap { $0 }
        }

        var result: [UsageDisplayWindow] = []
        for (index, window) in positional.enumerated() {
            guard let window else { continue }
            let kind: UsageWindowKind
            if window.isFiveHourWindow {
                kind = .fiveHour
            } else if window.isWeeklyWindow {
                kind = .weekly
            } else {
                kind = index == 0 ? .fiveHour : .weekly
            }
            if !result.contains(where: { $0.kind == kind }) {
                result.append(UsageDisplayWindow(kind: kind, window: window))
            }
        }
        return result.sorted { $0.kind.sortOrder < $1.kind.sortOrder }
    }

    /// The compact HUD shows no more than two signals. Kimi prioritizes the
    /// two coding windows and uses monthly quota to fill an absent second row.
    var collapsedDisplayWindows: [UsageDisplayWindow] {
        if provider != .kimi { return Array(displayWindows.prefix(2)) }
        let coding = displayWindows.filter { $0.kind == .fiveHour || $0.kind == .codeSevenDay }
        if coding.count >= 2 { return Array(coding.prefix(2)) }
        if let monthly = displayWindows.first(where: { $0.kind == .monthly }) {
            return coding + [monthly]
        }
        return coding
    }

    var individualRemainingPercent: Double? {
        rateLimit?.individualLimit.map { Double($0.remainingPercent) }
    }

    var tightestRemainingPercent: Double? {
        (displayWindows.map(\.window.remainingPercent) + [individualRemainingPercent])
            .compactMap { $0 }
            .min()
    }

    var isLimitReached: Bool {
        rateLimit?.rateLimitReachedType != nil || tightestRemainingPercent == 0
    }

    var severity: UsageSeverity {
        guard !isLimitReached, let remaining = tightestRemainingPercent else {
            return isLimitReached ? .critical : .unknown
        }
        if remaining <= 10 {
            return .critical
        }
        if remaining <= 20 {
            return .warning
        }
        return .normal
    }

    var statusText: String {
        if isLimitReached {
            return "Limit reached"
        }
        guard let remaining = tightestRemainingPercent else {
            return "No data"
        }
        return "\(UsagePercentFormatter.string(remaining))% left"
    }

    var isSourceStale: Bool {
        guard let sourceUpdatedAt else { return true }
        return Date().timeIntervalSince(sourceUpdatedAt) > 600
    }

    func preservingData(sourceError: String, fetchedAt: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            account: account,
            requiresOpenaiAuth: requiresOpenaiAuth,
            rateLimit: rateLimit,
            resetCredits: resetCredits,
            tokenUsage: tokenUsage,
            claudeSessionUsage: claudeSessionUsage,
            source: source,
            sourceUpdatedAt: sourceUpdatedAt,
            sourceError: sourceError,
            fetchedAt: fetchedAt,
            supplementalWindows: supplementalWindows
        )
    }
}

struct ClaudeSessionUsage {
    let inputTokens: Int64?
    let outputTokens: Int64?
    let contextRemainingPercent: Int?
    let claudeVersion: String?
}

struct UsageWindow: Sendable {
    let usedPercent: Double
    let remainingPercent: Double
    let durationMinutes: Int64?
    let resetsAt: Date?

    init?(source: RateLimitWindow?) {
        guard let source else {
            return nil
        }
        usedPercent = source.usedPercent
        remainingPercent = max(0, min(100, 100 - source.usedPercent))
        durationMinutes = source.windowDurationMins
        if let epoch = source.resetsAt {
            resetsAt = Date(timeIntervalSince1970: TimeInterval(epoch))
        } else {
            resetsAt = nil
        }
    }

    init(usedPercent: Double, durationMinutes: Int64?, resetsAt: Date?) {
        self.usedPercent = max(0, min(100, usedPercent))
        self.remainingPercent = max(0, min(100, 100 - usedPercent))
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }

    var isFiveHourWindow: Bool {
        guard let durationMinutes else { return false }
        return (4 * 60)...(6 * 60) ~= durationMinutes
    }

    var isWeeklyWindow: Bool {
        guard let durationMinutes else { return false }
        return (6 * 24 * 60)...(8 * 24 * 60) ~= durationMinutes
    }

}

enum UsageWindowKind: String, Codable, CaseIterable, Sendable {
    case fiveHour
    case weekly
    case codeSevenDay
    case monthly

    var sortOrder: Int {
        switch self {
        case .fiveHour: return 0
        case .weekly, .codeSevenDay: return 1
        case .monthly: return 2
        }
    }
}

struct UsageDisplayWindow: Identifiable, Sendable {
    var id: String { kind.rawValue }
    let kind: UsageWindowKind
    let window: UsageWindow
}

enum UsagePercentFormatter {
    static func string(_ value: Double) -> String {
        let clamped = max(0, min(100, value))
        if abs(clamped.rounded() - clamped) < 0.05 {
            return String(Int(clamped.rounded()))
        }
        return String(format: "%.1f", clamped)
    }
}

enum UsageSeverity {
    case normal
    case warning
    case critical
    case unknown

    var tint: Color {
        switch self {
        case .normal:
            return .green
        case .warning:
            return .yellow
        case .critical:
            return .red
        case .unknown:
            return .secondary
        }
    }
}
