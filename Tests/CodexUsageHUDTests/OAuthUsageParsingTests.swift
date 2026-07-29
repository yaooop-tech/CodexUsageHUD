import Foundation
import Testing
@testable import CodexUsageHUD

struct OAuthUsageParsingTests {
    @Test func mapsFrontmostApplicationsToAllProviders() {
        #expect(FrontmostApplicationProvider.provider(for: "com.openai.codex") == .codex)
        #expect(FrontmostApplicationProvider.provider(for: "com.anthropic.claudefordesktop") == .claude)
        #expect(FrontmostApplicationProvider.provider(for: "com.moonshot.kimichat") == .kimi)
        #expect(FrontmostApplicationProvider.provider(for: "com.apple.Safari") == nil)
    }

    @Test func parsesCodexUsageWindows() throws {
        let data = Data(#"""
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {"used_percent": 25, "limit_window_seconds": 18000, "reset_at": 1783731600},
            "secondary_window": {"used_percent": 60, "limit_window_seconds": 604800, "reset_at": 1784246400}
          }
        }
        """#.utf8)
        let root = try OAuthJSON.dictionary(data)
        let result = try #require(CodexOAuthUsageService.rateLimit(from: root))

        #expect(result.primary?.usedPercent == 25)
        #expect(result.primary?.windowDurationMins == 300)
        #expect(result.secondary?.usedPercent == 60)
        #expect(result.planType == "plus")
    }

    @Test func parsesClaudeFractionalUtilizationAndISOReset() throws {
        let data = Data(#"{"utilization": 12.5, "resets_at": "2026-07-11T16:16:00Z"}"#.utf8)
        let object = try OAuthJSON.dictionary(data)
        let window = try #require(ClaudeOAuthUsageParser.window(object))

        #expect(window.usedPercent == 13)
        #expect(window.resetsAt != nil)
    }

    @Test func preservedSnapshotRetainsLastSuccessfulTimestamp() {
        let successfulAt = Date(timeIntervalSinceNow: -601)
        let original = UsageSnapshot(
            provider: .codex,
            account: nil,
            requiresOpenaiAuth: false,
            rateLimit: nil,
            resetCredits: nil,
            tokenUsage: nil,
            claudeSessionUsage: nil,
            source: .appServer,
            sourceUpdatedAt: successfulAt,
            sourceError: nil,
            fetchedAt: successfulAt
        )
        let preserved = original.preservingData(sourceError: "temporary failure")

        #expect(preserved.sourceUpdatedAt == successfulAt)
        #expect(preserved.sourceError == "temporary failure")
        #expect(preserved.isSourceStale)
    }

    @Test func codexMergeKeepsTokenDataWhenQuotaUsesOAuthFallback() throws {
        let now = Date()
        let quota = makeSnapshot(
            primary: nil,
            secondary: RateLimitWindow(
                usedPercent: 20,
                windowDurationMins: 10_080,
                resetsAt: nil),
            source: .oauth)
        let tokenUsage = AccountTokenUsageResponse(
            summary: AccountTokenUsageSummary(
                lifetimeTokens: 1_036_546_867,
                peakDailyTokens: 94_592_750,
                longestRunningTurnSec: nil,
                currentStreakDays: nil,
                longestStreakDays: nil),
            dailyUsageBuckets: [
                AccountTokenUsageDailyBucket(startDate: "2026-07-28", tokens: 5_125_623),
            ])

        let merged = UsageService.merge(
            quota: quota,
            account: nil,
            tokenUsage: tokenUsage,
            previous: nil,
            warnings: ["Rate limits: temporary failure"],
            fetchedAt: now)

        #expect(merged.source == .oauth)
        #expect(merged.secondaryWindow?.remainingPercent == 80)
        #expect(merged.tokenUsage?.summary.lifetimeTokens == 1_036_546_867)
        #expect(merged.tokenUsage?.dailyUsageBuckets?.count == 1)
        #expect(merged.sourceError == "Rate limits: temporary failure")
    }

    @Test func defaultClaudeSnapshotWaitsForStatusLineWithoutOAuth() {
        let snapshot = ClaudeUsageService().waitingSnapshot(account: nil, session: nil)

        #expect(snapshot.provider == .claude)
        #expect(snapshot.source == .statusLine)
        #expect(snapshot.sourceUpdatedAt == nil)
        #expect(snapshot.primaryWindow == nil)
        #expect(snapshot.secondaryWindow == nil)
    }

    @Test func switchesToWeeklyOnlyWhenFiveHourWindowIsMissing() {
        let snapshot = makeSnapshot(primary: nil, secondary: RateLimitWindow(
            usedPercent: 40,
            windowDurationMins: 10_080,
            resetsAt: nil
        ))

        #expect(snapshot.displayWindows.map(\.kind) == [.weekly])
        #expect(snapshot.collapsedDisplayWindows.count == 1)
        #expect(snapshot.secondaryWindow?.remainingPercent == 60)
    }

    @Test func recognizesWeeklyWindowWhenAPIPlacesItInPrimaryPosition() {
        let snapshot = makeSnapshot(primary: RateLimitWindow(
            usedPercent: 4,
            windowDurationMins: 10_080,
            resetsAt: nil
        ), secondary: nil)

        #expect(snapshot.displayWindows.map(\.kind) == [.weekly])
        #expect(snapshot.primaryWindow == nil)
        #expect(snapshot.secondaryWindow?.remainingPercent == 96)
    }

    @Test func returnsToDefaultModeWhenFiveHourWindowReappears() {
        let snapshot = makeSnapshot(
            primary: RateLimitWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: nil),
            secondary: RateLimitWindow(usedPercent: 40, windowDurationMins: 10_080, resetsAt: nil)
        )

        #expect(snapshot.displayWindows.map(\.kind) == [.fiveHour, .weekly])
        #expect(snapshot.primaryWindow?.remainingPercent == 80)
    }

    @Test func weeklyOnlyFallbackDoesNotChangeClaudeDisplayMode() {
        let codexSnapshot = makeSnapshot(primary: nil, secondary: RateLimitWindow(
            usedPercent: 40,
            windowDurationMins: 10_080,
            resetsAt: nil
        ))
        let claudeSnapshot = UsageSnapshot(
            provider: .claude,
            account: codexSnapshot.account,
            requiresOpenaiAuth: codexSnapshot.requiresOpenaiAuth,
            rateLimit: codexSnapshot.rateLimit,
            resetCredits: codexSnapshot.resetCredits,
            tokenUsage: codexSnapshot.tokenUsage,
            claudeSessionUsage: codexSnapshot.claudeSessionUsage,
            source: codexSnapshot.source,
            sourceUpdatedAt: codexSnapshot.sourceUpdatedAt,
            sourceError: codexSnapshot.sourceError,
            fetchedAt: codexSnapshot.fetchedAt
        )

        #expect(claudeSnapshot.primaryWindow == nil)
        #expect(claudeSnapshot.secondaryWindow?.remainingPercent == 60)
    }

    private func makeSnapshot(
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?,
        source: UsageDataSource = .appServer
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: .codex,
            account: nil,
            requiresOpenaiAuth: false,
            rateLimit: RateLimitSnapshot(
                limitId: "codex",
                limitName: nil,
                primary: primary,
                secondary: secondary,
                credits: nil,
                individualLimit: nil,
                planType: "plus",
                rateLimitReachedType: nil
            ),
            resetCredits: nil,
            tokenUsage: nil,
            claudeSessionUsage: nil,
            source: source,
            sourceUpdatedAt: Date(),
            sourceError: nil,
            fetchedAt: Date()
        )
    }
}
