#if DEBUG
import Foundation

/// Local-only presentation fixtures used to capture public documentation images.
/// This code is excluded from production builds and never reads account data.
struct DemoPresentation {
    enum Scenario: String {
        case idle
        case dualWindows
        case weeklyOnly
        case running
        case needsConfirmation
        case singleTaskCompleted
        case settings
    }

    static var scenarioFromEnvironment: Scenario? {
        ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_DEMO"].flatMap(Scenario.init(rawValue:))
    }

    let scenario: Scenario
    private let now = Date(timeIntervalSince1970: 1_784_214_400)

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    var snapshot: UsageSnapshot {
        let windows: (RateLimitWindow?, RateLimitWindow?)
        switch scenario {
        case .weeklyOnly:
            windows = (RateLimitWindow(usedPercent: 42, windowDurationMins: 10_080, resetsAt: Int64(now.addingTimeInterval(4 * 86_400).timeIntervalSince1970)), nil)
        default:
            windows = (
                RateLimitWindow(usedPercent: 36, windowDurationMins: 300, resetsAt: Int64(now.addingTimeInterval(2 * 3_600).timeIntervalSince1970)),
                RateLimitWindow(usedPercent: 58, windowDurationMins: 10_080, resetsAt: Int64(now.addingTimeInterval(4 * 86_400).timeIntervalSince1970)))
        }

        return UsageSnapshot(
            provider: .codex,
            account: AccountInfo(type: "chatgpt", email: nil, planType: "Pro"),
            requiresOpenaiAuth: false,
            rateLimit: RateLimitSnapshot(
                limitId: "codex",
                limitName: "Codex",
                primary: windows.0,
                secondary: windows.1,
                credits: nil,
                individualLimit: nil,
                planType: "Pro",
                rateLimitReachedType: nil),
            resetCredits: 2,
            tokenUsage: AccountTokenUsageResponse(
                summary: AccountTokenUsageSummary(lifetimeTokens: 12_800_000, peakDailyTokens: 1_140_000, longestRunningTurnSec: nil, currentStreakDays: 7, longestStreakDays: 12),
                dailyUsageBuckets: [
                    AccountTokenUsageDailyBucket(startDate: "2026-07-21", tokens: 780_000),
                    AccountTokenUsageDailyBucket(startDate: "2026-07-22", tokens: 920_000),
                    AccountTokenUsageDailyBucket(startDate: "2026-07-23", tokens: 610_000),
                    AccountTokenUsageDailyBucket(startDate: "2026-07-24", tokens: 1_140_000),
                    AccountTokenUsageDailyBucket(startDate: "2026-07-25", tokens: 860_000),
                    AccountTokenUsageDailyBucket(startDate: "2026-07-26", tokens: 1_020_000),
                    AccountTokenUsageDailyBucket(startDate: "2026-07-27", tokens: 740_000)
                ]),
            claudeSessionUsage: nil,
            source: .appServer,
            sourceUpdatedAt: now,
            sourceError: nil,
            fetchedAt: now)
    }

    var activitySummary: AgentActivitySummary {
        let values: [UsageProvider: ProviderActivitySummary]
        switch scenario {
        case .running:
            values = [
                .codex: ProviderActivitySummary(provider: .codex, thinkingCount: 2, attentionCount: 0, errorCount: 0, unreadCompletionCount: 0),
                .claude: ProviderActivitySummary(provider: .claude, thinkingCount: 1, attentionCount: 0, errorCount: 0, unreadCompletionCount: 0),
                .kimi: ProviderActivitySummary(provider: .kimi, thinkingCount: 0, attentionCount: 0, errorCount: 0, unreadCompletionCount: 0)
            ]
        case .needsConfirmation:
            values = [
                .codex: ProviderActivitySummary(provider: .codex, thinkingCount: 0, attentionCount: 1, errorCount: 0, unreadCompletionCount: 0),
                .claude: ProviderActivitySummary(provider: .claude, thinkingCount: 0, attentionCount: 0, errorCount: 0, unreadCompletionCount: 0),
                .kimi: ProviderActivitySummary(provider: .kimi, thinkingCount: 0, attentionCount: 0, errorCount: 0, unreadCompletionCount: 0)
            ]
        case .singleTaskCompleted:
            values = [
                .codex: ProviderActivitySummary(provider: .codex, thinkingCount: 0, attentionCount: 0, errorCount: 0, unreadCompletionCount: 1),
                .claude: ProviderActivitySummary(provider: .claude, thinkingCount: 0, attentionCount: 0, errorCount: 0, unreadCompletionCount: 0),
                .kimi: ProviderActivitySummary(provider: .kimi, thinkingCount: 0, attentionCount: 0, errorCount: 0, unreadCompletionCount: 0)
            ]
        default:
            values = AgentActivitySummary.empty.providerSummaries
        }
        return AgentActivitySummary(providerSummaries: values)
    }
}
#endif
