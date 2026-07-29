import AppKit
import Foundation
import Testing
@testable import CodexUsageHUD

struct AgentActivityTests {
    @Test func codexClassifiesThinkingAttentionCompletionAbortAndError() throws {
        let thinking = try #require(CodexActivityReader.classify(data: lines([
            event("2026-07-18T13:00:00.000Z", type: "task_started"),
            event("2026-07-18T13:00:01.000Z", type: "agent_reasoning"),
        ])))
        #expect(thinking.state == .thinking)

        let attention = try #require(CodexActivityReader.classify(data: lines([
            event("2026-07-18T13:00:00.000Z", type: "task_started"),
            response("2026-07-18T13:00:02.000Z", type: "function_call", name: "request_user_input"),
        ])))
        #expect(attention.state == .attention)

        let completed = try #require(CodexActivityReader.classify(data: lines([
            event("2026-07-18T13:00:00.000Z", type: "task_started"),
            event("2026-07-18T13:00:03.000Z", type: "task_complete"),
        ])))
        #expect(completed.state == .completed)

        let aborted = try #require(CodexActivityReader.classify(data: lines([
            event("2026-07-18T13:00:00.000Z", type: "task_started"),
            event("2026-07-18T13:00:04.000Z", type: "turn_aborted"),
        ])))
        #expect(aborted.state == .idle)

        let failed = try #require(CodexActivityReader.classify(data: lines([
            event("2026-07-18T13:00:00.000Z", type: "task_started"),
            responseError("2026-07-18T13:00:05.000Z"),
        ])))
        #expect(failed.state == .error)
    }

    @Test func claudeClassifiesToolWorkQuestionCompletionAndAPIError() throws {
        let working = try #require(ClaudeActivityReader.classifyTranscript(data: lines([
            claude("2026-07-18T13:00:00.000Z", type: "user"),
            claudeAssistant("2026-07-18T13:00:01.000Z", tool: "Bash"),
        ])))
        #expect(working.state == .thinking)

        let question = try #require(ClaudeActivityReader.classifyTranscript(data: lines([
            claude("2026-07-18T13:00:00.000Z", type: "user"),
            claudeAssistant("2026-07-18T13:00:01.000Z", tool: "AskUserQuestion"),
        ])))
        #expect(question.state == .attention)

        let completed = try #require(ClaudeActivityReader.classifyTranscript(data: lines([
            claude("2026-07-18T13:00:00.000Z", type: "user"),
            claudeAssistant("2026-07-18T13:00:02.000Z", stopReason: "end_turn"),
        ])))
        #expect(completed.state == .completed)

        let error = try #require(ClaudeActivityReader.classifyTranscript(data: lines([
            #"{"timestamp":"2026-07-18T13:00:03.000Z","type":"assistant","error":"authentication_failed","isApiErrorMessage":true}"#,
        ])))
        #expect(error.state == .error)
    }

    @Test func kimiUsesRunningBlockedCompletedAndFreshErrors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = directory.appendingPathComponent("conversation-statuses.json")
        let errors = directory.appendingPathComponent("conversation-errors.json")
        let startedAt = Date().addingTimeInterval(-100)

        try write(#"{"one":"running"}"#, to: status, date: startedAt.addingTimeInterval(1))
        try write("{}", to: errors, date: startedAt)
        #expect(KimiActivityReader.read(statusURL: status, errorURL: errors, startedAt: startedAt, now: startedAt.addingTimeInterval(2)).first?.state == .thinking)

        try write(#"{"one":"blocked"}"#, to: status, date: startedAt.addingTimeInterval(3))
        #expect(KimiActivityReader.read(statusURL: status, errorURL: errors, startedAt: startedAt, now: startedAt.addingTimeInterval(4)).first?.state == .attention)

        try write(#"{"one":"completed"}"#, to: status, date: startedAt.addingTimeInterval(5))
        #expect(KimiActivityReader.read(statusURL: status, errorURL: errors, startedAt: startedAt, now: startedAt.addingTimeInterval(6)).first?.state == .completed)

        try write("{}", to: status, date: startedAt.addingTimeInterval(7))
        try write(#"{"one":["failed"]}"#, to: errors, date: startedAt.addingTimeInterval(8))
        #expect(KimiActivityReader.read(statusURL: status, errorURL: errors, startedAt: startedAt, now: startedAt.addingTimeInterval(9)).first?.state == .error)
    }

    @Test func completionBadgeRequiresMultiTaskContext() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var reducer = AgentActivityReducer(startedAt: startedAt)

        let singleCompletion = reducer.apply([
            .codex: [task(.codex, "done", .completed, startedAt.addingTimeInterval(1))],
        ])
        #expect(singleCompletion.primaryState == .unread)
        #expect(singleCompletion.unreadCompletionCount == 1)
        #expect(!singleCompletion.shouldShowCompletionBadge)

        let completionWithRunningTask = reducer.apply([
            .codex: [
                task(.codex, "done", .completed, startedAt.addingTimeInterval(1)),
                task(.codex, "running", .thinking, startedAt.addingTimeInterval(2)),
            ],
        ])
        #expect(completionWithRunningTask.primaryState == .thinking)
        #expect(completionWithRunningTask.shouldShowCompletionBadge)

        let twoCompletions = reducer.apply([
            .codex: [
                task(.codex, "done", .completed, startedAt.addingTimeInterval(1)),
                task(.codex, "running", .completed, startedAt.addingTimeInterval(3)),
            ],
        ])
        #expect(twoCompletions.unreadCompletionCount == 2)
        #expect(twoCompletions.shouldShowCompletionBadge)
    }

    @Test func reducerKeepsCompletionIndependentFromDominantActiveState() {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        var reducer = AgentActivityReducer(startedAt: startedAt)
        let activities: [UsageProvider: [AgentTaskActivity]] = [
            .codex: [
                task(.codex, "running", .thinking, startedAt.addingTimeInterval(1)),
                task(.codex, "done", .completed, startedAt.addingTimeInterval(2)),
            ],
            .claude: [task(.claude, "question", .attention, startedAt.addingTimeInterval(3))],
        ]

        let first = reducer.apply(activities)
        #expect(first.primaryState == .attention)
        #expect(first.thinkingCount == 1)
        #expect(first.attentionCount == 1)
        #expect(first.unreadCompletionCount == 1)
        #expect(first.shouldShowCompletionBadge)
        #expect(reducer.apply(activities).unreadCompletionCount == 1)

        let withError = reducer.apply(activities.merging([
            .kimi: [task(.kimi, "failed", .error, startedAt.addingTimeInterval(4))],
        ]) { _, new in new })
        #expect(withError.primaryState == .error)
        #expect(withError.unreadCompletionCount == 1)
    }

    @Test func reducerAcknowledgesOnlyActivatedProviderAndUsesActivationWatermark() {
        let startedAt = Date(timeIntervalSince1970: 3_000)
        var reducer = AgentActivityReducer(startedAt: startedAt)
        let completions: [UsageProvider: [AgentTaskActivity]] = [
            .codex: [task(.codex, "codex-done", .completed, startedAt.addingTimeInterval(2))],
            .claude: [task(.claude, "claude-done", .completed, startedAt.addingTimeInterval(3))],
        ]

        #expect(reducer.apply(completions).unreadCompletionCount == 2)
        let afterCodexActivation = reducer.acknowledge(provider: .codex, at: startedAt.addingTimeInterval(4))
        #expect(afterCodexActivation.unreadCompletionCount == 1)
        #expect(afterCodexActivation.providerSummaries[.claude]?.unreadCompletionCount == 1)

        let foregroundCompletion = reducer.apply([
            .codex: [task(.codex, "completed-while-frontmost", .completed, startedAt.addingTimeInterval(5))],
            .claude: completions[.claude] ?? [],
        ])
        #expect(foregroundCompletion.unreadCompletionCount == 2)

        let afterReturning = reducer.acknowledge(provider: .codex, at: startedAt.addingTimeInterval(6))
        #expect(afterReturning.unreadCompletionCount == 1)

        _ = reducer.acknowledge(provider: .kimi, at: startedAt.addingTimeInterval(8))
        let discoveredAfterActivation = reducer.apply([
            .kimi: [task(.kimi, "polled-late", .completed, startedAt.addingTimeInterval(7))],
        ])
        #expect(discoveredAfterActivation.providerSummaries[.kimi]?.unreadCompletionCount == 0)
    }

    @Test func reducerAcknowledgesExistingErrorsButShowsLaterErrors() {
        let startedAt = Date(timeIntervalSince1970: 3_500)
        var reducer = AgentActivityReducer(startedAt: startedAt)
        let firstError = task(.codex, "failed", .error, startedAt.addingTimeInterval(1))

        #expect(reducer.apply([.codex: [firstError]]).primaryState == .error)
        #expect(reducer.acknowledge(provider: .codex, at: startedAt.addingTimeInterval(2)).primaryState == .idle)
        #expect(reducer.apply([.codex: [firstError]]).primaryState == .idle)

        let laterError = task(.codex, "failed-again", .error, startedAt.addingTimeInterval(3))
        #expect(reducer.apply([.codex: [firstError, laterError]]).primaryState == .error)
    }

    @Test func reducerIgnoresKimiSharedFileTimestampChangesUntilStateTransitions() {
        let startedAt = Date(timeIntervalSince1970: 4_000)
        var reducer = AgentActivityReducer(startedAt: startedAt)
        let historical = task(.kimi, "old-completion", .completed, startedAt.addingTimeInterval(-10))
        #expect(reducer.apply([.kimi: [historical]]).unreadCompletionCount == 0)

        let timestampOnlyChange = task(.kimi, "old-completion", .completed, startedAt.addingTimeInterval(2))
        #expect(reducer.apply([.kimi: [timestampOnlyChange]]).unreadCompletionCount == 0)
        #expect(reducer.apply([.kimi: [task(.kimi, "old-completion", .thinking, startedAt.addingTimeInterval(3))]]).thinkingCount == 1)
        #expect(reducer.apply([.kimi: [task(.kimi, "old-completion", .completed, startedAt.addingTimeInterval(4))]]).unreadCompletionCount == 1)
    }

    @Test func codexReaderReturnsConcurrentRollouts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let day = root.appendingPathComponent("2026/07/18", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try #require(parse("2026-07-18T13:00:10.000Z"))
        let running = day.appendingPathComponent("running.jsonl")
        let completed = day.appendingPathComponent("completed.jsonl")
        try write(lines([
            event("2026-07-18T13:00:00.000Z", type: "task_started"),
            event("2026-07-18T13:00:01.000Z", type: "agent_reasoning"),
        ]), to: running, date: now)
        try write(lines([
            event("2026-07-18T13:00:00.000Z", type: "task_started"),
            event("2026-07-18T13:00:02.000Z", type: "task_complete"),
        ]), to: completed, date: now)

        let activities = CodexActivityReader.read(sessionsRoot: root, startedAt: now.addingTimeInterval(-20), now: now)
        let states = Dictionary(uniqueKeysWithValues: activities.map { ($0.taskID, $0.state) })
        #expect(states[running.path] == .thinking)
        #expect(states[completed.path] == .completed)
    }

    @Test func claudeReaderReturnsMultipleSessionsAndDeduplicatesLegacyCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let descriptors = root.appendingPathComponent("activities", isDirectory: true)
        try FileManager.default.createDirectory(at: descriptors, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try #require(parse("2026-07-18T13:00:10.000Z"))
        let transcriptA = root.appendingPathComponent("a.jsonl")
        let transcriptB = root.appendingPathComponent("b.jsonl")
        try write(lines([
            claude("2026-07-18T13:00:00.000Z", type: "user"),
            claudeAssistant("2026-07-18T13:00:01.000Z", tool: "Bash"),
        ]), to: transcriptA, date: now)
        try write(lines([
            claude("2026-07-18T13:00:00.000Z", type: "user"),
            claudeAssistant("2026-07-18T13:00:02.000Z", stopReason: "end_turn"),
        ]), to: transcriptB, date: now)
        let descriptorA = #"{"sessionID":"a","transcriptPath":"\#(transcriptA.path)"}"#
        let descriptorB = #"{"sessionID":"b","transcriptPath":"\#(transcriptB.path)"}"#
        try write(descriptorA, to: descriptors.appendingPathComponent("a.json"), date: now)
        try write(descriptorB, to: descriptors.appendingPathComponent("b.json"), date: now)
        let legacy = root.appendingPathComponent("legacy.json")
        try write(descriptorB, to: legacy, date: now)

        let activities = ClaudeActivityReader.read(
            activityDirectory: descriptors,
            legacyActivityURL: legacy,
            startedAt: now.addingTimeInterval(-20),
            now: now)
        let states = Dictionary(uniqueKeysWithValues: activities.map { ($0.taskID, $0.state) })
        #expect(states.count == 2)
        #expect(states["a"] == .thinking)
        #expect(states["b"] == .completed)
    }

    @Test func kimiReaderPreservesPerConversationStates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = directory.appendingPathComponent("conversation-statuses.json")
        let errors = directory.appendingPathComponent("conversation-errors.json")
        let startedAt = Date(timeIntervalSince1970: 5_000)
        try write(#"{"running":"running","question":"blocked","done":"completed"}"#, to: status, date: startedAt.addingTimeInterval(5))
        try write("{}", to: errors, date: startedAt)

        let activities = KimiActivityReader.read(
            statusURL: status,
            errorURL: errors,
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(6))
        let states = Dictionary(uniqueKeysWithValues: activities.map { ($0.taskID, $0.state) })
        #expect(states["running"] == .thinking)
        #expect(states["question"] == .attention)
        #expect(states["done"] == .completed)
    }

    @Test func planCompletionWaitsForImplementationApprovalUntilNextTurn() throws {
        let awaitingApproval = try #require(CodexActivityReader.classify(data: lines([
            taskStarted("2026-07-18T13:00:00.000Z", mode: "plan"),
            proposedPlan("2026-07-18T13:00:01.000Z"),
            event("2026-07-18T13:00:02.000Z", type: "task_complete"),
        ])))
        #expect(awaitingApproval.state == .attention)

        let implementationStarted = try #require(CodexActivityReader.classify(data: lines([
            taskStarted("2026-07-18T13:00:00.000Z", mode: "plan"),
            proposedPlan("2026-07-18T13:00:01.000Z"),
            event("2026-07-18T13:00:02.000Z", type: "task_complete"),
            taskStarted("2026-07-18T13:00:03.000Z", mode: nil),
        ])))
        #expect(implementationStarted.state == .thinking)
    }

    @Test func pendingUserInputIsNotOverwrittenByTaskCompletion() throws {
        let pending = try #require(CodexActivityReader.classify(data: lines([
            taskStarted("2026-07-18T13:00:00.000Z", mode: nil),
            functionCall("2026-07-18T13:00:01.000Z", name: "request_user_input", callID: "call-1"),
            event("2026-07-18T13:00:02.000Z", type: "task_complete"),
        ])))
        #expect(pending.state == .attention)

        let resolved = try #require(CodexActivityReader.classify(data: lines([
            taskStarted("2026-07-18T13:00:00.000Z", mode: nil),
            functionCall("2026-07-18T13:00:01.000Z", name: "request_user_input", callID: "call-1"),
            functionCallOutput("2026-07-18T13:00:02.000Z", callID: "call-1"),
            event("2026-07-18T13:00:03.000Z", type: "task_complete"),
        ])))
        #expect(resolved.state == .completed)
    }

    @Test func collapsedHUDModeUsesIdleLayoutOnlyWithoutActivity() {
        #expect(CollapsedHUDMode(activityState: .idle) == .idle)
        #expect(CollapsedHUDMode(activityState: .thinking) == .active(.thinking))
        #expect(CollapsedHUDMode(activityState: .attention) == .active(.attention))
        #expect(CollapsedHUDMode(activityState: .error) == .active(.error))
        #expect(CollapsedHUDMode(activityState: .unread) == .active(.completion))
    }

    @Test func activityLabelsCoverBothLanguages() {
        #expect(AgentActivityState.unread.label(language: .english) == "Unread")
        #expect(AgentActivityState.thinking.label(language: .english) == "Thinking")
        #expect(AgentActivityState.attention.label(language: .english) == "Input")
        #expect(AgentActivityState.thinking.label(language: .chinese) == "思考中")
        #expect(AgentActivityState.attention.label(language: .chinese) == "需要确认")
        #expect(AgentActivityState.error.label(language: .english) == "Error")
    }

    @Test func collapsedStatusPresentationAvoidsUnreadCountDuplication() {
        let single = CollapsedStatusPresentation(
            state: .unread,
            unreadCompletionCount: 1,
            language: .english)
        #expect(single.fullLabel == "Unread")
        #expect(!single.isCompletionCountOnly)
        #expect(single.visibleCompletionCount == nil)

        let multiple = CollapsedStatusPresentation(
            state: .unread,
            unreadCompletionCount: 2,
            language: .english)
        #expect(multiple.isCompletionCountOnly)
        #expect(multiple.completionCountText == "2")

        let capped = CollapsedStatusPresentation(
            state: .unread,
            unreadCompletionCount: 12,
            language: .english)
        #expect(capped.completionCountText == "9+")
    }

    @Test func collapsedStatusPresentationUsesThinkingFallbackWithInlineCount() {
        let thinking = CollapsedStatusPresentation(
            state: .thinking,
            unreadCompletionCount: 3,
            language: .english)
        #expect(thinking.fullLabel == "Thinking")
        #expect(thinking.compactLabel == "THK")
        #expect(thinking.showsInlineCompletionCount)
        #expect(thinking.completionCountText == "3")

        let chineseThinking = CollapsedStatusPresentation(
            state: .thinking,
            unreadCompletionCount: 1,
            language: .chinese)
        #expect(chineseThinking.compactLabel == "思考")

        let input = CollapsedStatusPresentation(
            state: .attention,
            unreadCompletionCount: 1,
            language: .english)
        #expect(input.fullLabel == "Input")
        #expect(input.compactLabel == "Input")
        #expect(input.showsInlineCompletionCount)
        #expect(CollapsedStatusPresentation.capsuleHeight == 20)
    }

    @Test func starlightPreferencesAndTextureConfigurationUseExpectedDefaults() throws {
        #expect(L10n.text(.restoreSevenDaysCompact, language: .chinese) == "近7日")
        #expect(L10n.text(.restoreSevenDaysCompact, language: .english) == "7D")

        let suiteName = "CodexUsageHUDTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("pulsingLight", forKey: "appearance.activity.effect")
        AppPreferencesMigration.apply(to: defaults)
        #expect(defaults.object(forKey: "appearance.activity.effect") == nil)

        let compact = StarlightTextureKey(
            theme: .thinking,
            usesLightSurface: false,
            size: CGSize(width: 64, height: 104),
            scale: 2)
        let expanded = StarlightTextureKey(
            theme: .thinking,
            usesLightSurface: false,
            size: CGSize(width: 64, height: 188),
            scale: 2)
        #expect(compact != expanded)
        #expect(compact.renderSize.width > 64)
        #expect(compact.renderSize.height > 104)
    }

    @Test func tokenUsageTrendKeepsHistoryAndCalculatesRecentSevenDaySummary() {
        let buckets = (1 ... 9).reversed().map { day in
            AccountTokenUsageDailyBucket(
                startDate: String(format: "2026-07-%02d", day),
                tokens: Int64(day * 100))
        }
        let trend = TokenUsageTrend(
            buckets: buckets,
            referenceDate: ISO8601DateFormatter().date(from: "2026-07-10T12:00:00Z")!)

        #expect(trend.points.count == 9)
        #expect(trend.points.first?.sourceDate == "2026-07-01")
        #expect(trend.points.last?.sourceDate == "2026-07-09")
        #expect(trend.total == 4_200)
        #expect(trend.dailyAverage == 600)
        #expect(trend.peakPoint?.tokens == 900)
        #expect(trend.canDrawChart)
    }

    @Test func tokenChartViewportZoomsPansClampsAndResets() {
        let buckets = (1 ... 20).map { day in
            AccountTokenUsageDailyBucket(
                startDate: String(format: "2026-07-%02d", day),
                tokens: Int64(day * 100))
        }
        let trend = TokenUsageTrend(
            buckets: buckets,
            referenceDate: ISO8601DateFormatter().date(from: "2026-07-21T12:00:00Z")!)
        var viewport = TokenChartViewport(trend: trend)

        #expect(viewport.visibleDays == 7)
        #expect(viewport.isDefault)

        viewport.zoom(scale: 2, anchorFraction: 0.5)
        #expect(viewport.visibleDays == 3.5)
        #expect(!viewport.isDefault)

        let zoomedLeading = viewport.leadingDate
        viewport.pan(from: zoomedLeading, translation: 1000, plotWidth: 100)
        #expect(viewport.leadingDate == viewport.firstDate)

        viewport.zoom(scale: 0.01, anchorFraction: 0.5)
        #expect(viewport.visibleDays == 20)
        #expect(viewport.leadingDate == viewport.firstDate)

        viewport.reset()
        #expect(viewport.visibleDays == 7)
        #expect(viewport.isDefault)

        let renderWindow = TokenChartRenderWindow(
            points: trend.points,
            leadingDate: viewport.leadingDate,
            trailingDate: viewport.trailingDate)
        #expect(renderWindow.yDomain.lowerBound < 0)
        #expect(renderWindow.yDomain.upperBound > 2_000)
    }

    @Test func tokenChartPresetRangesAlignToLatestAvailableDay() {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let endDate = formatter.date(from: "2026-07-28")!
        let buckets = (0 ..< 200).map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: endDate)!
            return AccountTokenUsageDailyBucket(
                startDate: formatter.string(from: date),
                tokens: Int64(offset))
        }
        let trend = TokenUsageTrend(
            buckets: buckets,
            referenceDate: calendar.date(byAdding: .day, value: 1, to: endDate)!)
        var viewport = TokenChartViewport(trend: trend)

        viewport.select(.oneMonth)
        let oneMonthStart = calendar.date(byAdding: .month, value: -1, to: viewport.lastDate)!
        let oneMonthDays = calendar.dateComponents(
            [.day],
            from: oneMonthStart,
            to: viewport.lastDate).day! + 1
        #expect(viewport.visibleDays == Double(oneMonthDays))
        #expect(viewport.matches(.oneMonth))
        #expect(abs(viewport.trailingDate.timeIntervalSince(viewport.lastDate)) < 1)

        viewport.select(.sixMonths)
        let sixMonthStart = calendar.date(byAdding: .month, value: -6, to: viewport.lastDate)!
        let sixMonthDays = calendar.dateComponents(
            [.day],
            from: sixMonthStart,
            to: viewport.lastDate).day! + 1
        #expect(viewport.visibleDays == Double(sixMonthDays))
        #expect(viewport.matches(.sixMonths))

        viewport.select(.all)
        #expect(viewport.visibleDays == 200)
        #expect(viewport.leadingDate == viewport.firstDate)
        viewport.select(.yearToDate)
        let year = calendar.component(.year, from: viewport.lastDate)
        let yearStart = calendar.date(
            from: DateComponents(year: year, month: 1, day: 1))!
        let yearToDateDays = calendar.dateComponents(
            [.day],
            from: yearStart,
            to: viewport.lastDate).day! + 1
        #expect(viewport.visibleDays == min(200, Double(yearToDateDays)))
        #expect(TokenChartRange.displayOrder == [
            .all,
            .yearToDate,
            .sixMonths,
            .oneMonth,
            .sevenDays,
        ])
        #expect(TokenChartRange.oneMonth.label(language: .chinese) == "1月")
        #expect(TokenChartRange.yearToDate.label(language: .chinese) == "YTD")
    }

    @Test func collapsedWindowRestoresSavedBottomRailPosition() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let railHeight: CGFloat = 230
        let savedBottomMidY = visible.minY + railHeight / 2
        let expandedWindowMidY = visible.minY + 430 / 2

        let restored = HUDWindowPlacement.collapsedRailMidY(
            savedRailMidY: savedBottomMidY,
            currentWindowMidY: expandedWindowMidY,
            visibleFrame: visible,
            railHeight: railHeight)

        #expect(restored == savedBottomMidY)
        #expect(restored < expandedWindowMidY)
    }

    @Test func hudWindowMotionSynchronizesBothEdgeTransitions() {
        #expect(HUDWindowMotion.transitionDuration == 0.24)
        #expect(HUDWindowMotion.duration(isCollapsed: true, reducesMotion: false) == 0.24)
        #expect(HUDWindowMotion.duration(isCollapsed: false, reducesMotion: false) == 0.24)
        #expect(HUDWindowMotion.snapDuration(reducesMotion: false) == 0.16)
        #expect(HUDWindowMotion.duration(isCollapsed: true, reducesMotion: true) == 0)
        #expect(HUDWindowMotion.duration(isCollapsed: false, reducesMotion: true) == 0)
        #expect(HUDWindowMotion.snapDuration(reducesMotion: true) == 0)
    }

    @Test func hudWindowHorizontalResizeKeepsAttachedEdgeStationary() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let insets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        let collapsedWidth: CGFloat = 68
        let expandedWidth: CGFloat = 364

        let leftCollapsedX = HUDWindowPlacement.anchoredX(
            edge: .left,
            width: collapsedWidth,
            visibleFrame: visible,
            contentInsets: insets)
        let leftExpandedX = HUDWindowPlacement.anchoredX(
            edge: .left,
            width: expandedWidth,
            visibleFrame: visible,
            contentInsets: insets)
        #expect(leftCollapsedX == leftExpandedX)

        let rightCollapsedX = HUDWindowPlacement.anchoredX(
            edge: .right,
            width: collapsedWidth,
            visibleFrame: visible,
            contentInsets: insets)
        let rightExpandedX = HUDWindowPlacement.anchoredX(
            edge: .right,
            width: expandedWidth,
            visibleFrame: visible,
            contentInsets: insets)
        #expect(rightCollapsedX + collapsedWidth == rightExpandedX + expandedWidth)
    }

    @Test func hudWindowTransitionAnimatesOnlyAnchoredWidth() {
        let current = NSRect(x: 1374, y: 300, width: 68, height: 230)
        let target = NSRect(x: 1078, y: 200, width: 364, height: 434)

        let rightStart = HUDWindowPlacement.widthOnlyTransitionStart(
            currentFrame: current,
            targetFrame: target,
            edge: .right)
        #expect(rightStart.maxX == target.maxX)
        #expect(rightStart.width == current.width)
        #expect(rightStart.minY == target.minY)
        #expect(rightStart.height == target.height)

        let leftStart = HUDWindowPlacement.widthOnlyTransitionStart(
            currentFrame: current,
            targetFrame: target,
            edge: .left)
        #expect(leftStart.minX == target.minX)
        #expect(leftStart.width == current.width)
        #expect(leftStart.minY == target.minY)
        #expect(leftStart.height == target.height)
    }

    @Test func tokenChartInteractionPolicySeparatesTrackpadAndMouseInput() {
        #expect(TokenChartInteractionPolicy.scroll(
            precise: true,
            deltaX: 12,
            deltaY: 1) == .pan(12))
        #expect(TokenChartInteractionPolicy.scroll(
            precise: true,
            deltaX: 0,
            deltaY: 12) == .passThrough)
        let mouse = TokenChartInteractionPolicy.scroll(
            precise: false,
            deltaX: 0,
            deltaY: 2)
        guard case .zoom(let scale) = mouse else {
            Issue.record("Mouse wheel should zoom")
            return
        }
        #expect(scale > 1)
    }

    @Test func tokenChartMagnificationUsesIncrementalNativeGestureDeltas() {
        #expect(TokenChartMagnificationPolicy.scale(for: 0.2) == 1.2)
        #expect(TokenChartMagnificationPolicy.scale(for: -0.2) == 0.8)
        #expect(TokenChartMagnificationPolicy.scale(for: 2) == 1.25)
        #expect(TokenChartMagnificationPolicy.scale(for: -2) == 0.75)
    }

    @MainActor
    @Test func tokenChartInputLifecycleReinstallsOneMagnificationRecognizer() throws {
        let view = TokenChartInputView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
        let initial = try #require(view.magnificationRecognizerForTesting)
        #expect(view.gestureRecognizers.count == 1)

        view.reinstallMagnificationRecognizer()
        let reinstalled = try #require(view.magnificationRecognizerForTesting)
        #expect(view.gestureRecognizers.count == 1)
        #expect(initial !== reinstalled)

        view.invalidateInputLifecycle()
        #expect(view.gestureRecognizers.isEmpty)
        #expect(view.magnificationRecognizerForTesting == nil)
    }

    @Test func starlightUsesDistinctMotionProfiles() {
        let thinking = StarlightMotionProfile.profile(for: .thinking)
        let attention = StarlightMotionProfile.profile(for: .attention)
        let error = StarlightMotionProfile.profile(for: .error)
        let completion = StarlightMotionProfile.profile(for: .completion)
        #expect(thinking != attention)
        #expect(error.speed > thinking.speed)
        #expect(attention.speed < thinking.speed)
        #expect(attention.pulseCadence != nil)
        #expect(thinking.pulseCadence == nil)
        #expect(error.pulseCadence == nil)
        #expect(completion.speed == 0.62)
        #expect(completion.pulseCadence == nil)
        #expect(completion.scaleDepth > thinking.scaleDepth)
    }

    @Test func tokenChartRenderWindowClipsOutsidePointsAndInterpolatesBoundaries() throws {
        let buckets = (1 ... 10).map { day in
            AccountTokenUsageDailyBucket(
                startDate: String(format: "2026-07-%02d", day),
                tokens: day == 10 ? 1_000_000 : Int64(day * 100))
        }
        let trend = TokenUsageTrend(
            buckets: buckets,
            referenceDate: ISO8601DateFormatter().date(from: "2026-07-11T12:00:00Z")!)
        let third = try #require(trend.points.first { $0.sourceDate == "2026-07-03" })
        let eighth = try #require(trend.points.first { $0.sourceDate == "2026-07-08" })
        let exact = TokenChartRenderWindow(
            points: trend.points,
            leadingDate: third.date,
            trailingDate: eighth.date)

        #expect(exact.points.first?.date == third.date)
        #expect(exact.points.last?.date == eighth.date)
        #expect(exact.points.allSatisfy { $0.date >= third.date && $0.date <= eighth.date })
        #expect(exact.points.map(\.tokens).max() == 800)
        #expect(exact.yDomain.upperBound > 800)
        #expect(exact.yDomain.upperBound < 1_000_000)

        let fractionalLeading = third.date.addingTimeInterval(12 * 60 * 60)
        let fractional = TokenChartRenderWindow(
            points: trend.points,
            leadingDate: fractionalLeading,
            trailingDate: eighth.date)
        #expect(fractional.points.first?.date == fractionalLeading)
        #expect(fractional.points.first?.tokens == 350)
        #expect(fractional.points.allSatisfy {
            $0.date >= fractionalLeading && $0.date <= eighth.date
        })
    }

    @Test func tokenChartViewportKeepsRapidZoomAndPanInsideHistory() {
        let buckets = (1 ... 28).map { day in
            AccountTokenUsageDailyBucket(
                startDate: String(format: "2026-07-%02d", day),
                tokens: Int64((day % 6) * 1_000))
        }
        let trend = TokenUsageTrend(
            buckets: buckets,
            referenceDate: ISO8601DateFormatter().date(from: "2026-07-29T12:00:00Z")!)
        var viewport = TokenChartViewport(trend: trend)

        for index in 0 ..< 160 {
            viewport.zoom(
                scale: index.isMultiple(of: 2) ? 1.31 : 0.73,
                anchorFraction: Double(index % 11) / 10)
            viewport.pan(
                by: index.isMultiple(of: 3) ? 240 : -180,
                plotWidth: 320)
            #expect(viewport.leadingDate >= viewport.firstDate)
            #expect(viewport.trailingDate <= viewport.lastDate.addingTimeInterval(0.5))

            let rendered = TokenChartRenderWindow(
                points: trend.points,
                leadingDate: viewport.leadingDate,
                trailingDate: viewport.trailingDate)
            #expect(rendered.points.allSatisfy {
                $0.date >= viewport.leadingDate && $0.date <= viewport.trailingDate
            })
            #expect(rendered.yDomain.lowerBound < 0)
        }
    }

    @Test func fileTailReaderReusesAndExtendsCachedTail() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("activity.jsonl")
        try Data("{\"value\":1}\n".utf8).write(to: url)
        #expect(String(data: try #require(FileTailReader.read(url: url)), encoding: .utf8) == "{\"value\":1}\n")

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"value\":2}\n".utf8))
        try handle.close()
        let appended = try #require(FileTailReader.read(url: url))
        #expect(String(data: appended, encoding: .utf8) == "{\"value\":1}\n{\"value\":2}\n")
    }

    @Test func tokenUsageTrendUsesStatFallbackForSparseOrMissingData() {
        let referenceDate = ISO8601DateFormatter().date(from: "2026-07-04T12:00:00Z")!
        let sparse = TokenUsageTrend(
            buckets: [
                AccountTokenUsageDailyBucket(startDate: "2026-07-01", tokens: 100),
                AccountTokenUsageDailyBucket(startDate: "invalid", tokens: 900),
                AccountTokenUsageDailyBucket(startDate: "2026-07-03", tokens: -50),
            ],
            referenceDate: referenceDate)
        #expect(sparse.points.count == 7)
        #expect(sparse.points.map(\.tokens) == [0, 0, 0, 0, 100, 0, 0])
        #expect(sparse.total == 100)
        #expect(sparse.dailyAverage == 14)
        #expect(sparse.canDrawChart)
        #expect(sparse.rangeLabel == "6/27–7/3")

        let empty = TokenUsageTrend(buckets: nil, referenceDate: referenceDate)
        #expect(empty.points.count == 7)
        #expect(empty.points.allSatisfy { $0.tokens == 0 })
        #expect(empty.total == nil)
        #expect(empty.dailyAverage == nil)
        #expect(empty.canDrawChart)
    }

    @Test func hudDateFormattersUseSlashSeparators() {
        let date = ISO8601DateFormatter().date(from: "2026-08-05T12:31:00Z")!
        #expect(!HUDFormatters.fullResetText(date).contains("-"))
        #expect(HUDFormatters.fullResetText(date).contains("/"))
        #expect(!HUDFormatters.compactFullResetText(date).contains("-"))
        #expect(!HUDFormatters.railResetParts(date).date.contains("-"))
    }

    @MainActor
    @Test func powerCoordinatorSuspendsUntilEveryPowerReasonClears() async {
        let coordinator = ApplicationPowerCoordinator()
        var suspensionCount = 0
        var resumeCount = 0
        coordinator.start(
            onSuspend: { suspensionCount += 1 },
            onResume: { resumeCount += 1 })
        defer { coordinator.stop() }

        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await Task.yield()
        #expect(!coordinator.permitsActiveWork)
        #expect(suspensionCount == 1)

        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await Task.yield()
        #expect(!coordinator.permitsActiveWork)
        #expect(resumeCount == 0)

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await Task.yield()
        #expect(coordinator.permitsActiveWork)
        #expect(resumeCount == 1)
    }

    private func event(_ timestamp: String, type: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"\#(type)"}}"#
    }

    private func taskStarted(_ timestamp: String, mode: String?) -> String {
        let modeValue = mode.map { #","collaboration_mode_kind":"\#($0)""# } ?? ""
        return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"task_started"\#(modeValue)}}"#
    }

    private func response(_ timestamp: String, type: String, name: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"\#(type)","name":"\#(name)"}}"#
    }

    private func functionCall(_ timestamp: String, name: String, callID: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"function_call","name":"\#(name)","call_id":"\#(callID)"}}"#
    }

    private func functionCallOutput(_ timestamp: String, callID: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"function_call_output","call_id":"\#(callID)"}}"#
    }

    private func proposedPlan(_ timestamp: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"<proposed_plan>Plan</proposed_plan>"}]}}"#
    }

    private func responseError(_ timestamp: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"function_call_output","error":{"message":"failed"}}}"#
    }

    private func claude(_ timestamp: String, type: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"\#(type)","message":{"content":"hello"}}"#
    }

    private func claudeAssistant(_ timestamp: String, tool: String? = nil, stopReason: String? = nil) -> String {
        let content: String
        if let tool {
            content = #"[{"type":"tool_use","name":"\#(tool)"}]"#
        } else {
            content = #"[{"type":"text","text":"done"}]"#
        }
        let stop = stopReason.map { #", "stop_reason":"\#($0)""# } ?? ""
        return #"{"timestamp":"\#(timestamp)","type":"assistant","message":{"content":\#(content)\#(stop)}}"#
    }

    private func lines(_ values: [String]) -> Data {
        Data(values.joined(separator: "\n").utf8)
    }

    private func task(_ provider: UsageProvider, _ id: String, _ state: AgentActivitySourceState, _ date: Date) -> AgentTaskActivity {
        AgentTaskActivity(provider: provider, taskID: id, state: state, updatedAt: date)
    }

    private func parse(_ value: String) -> Date? {
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
    }

    private func write(_ value: String, to url: URL, date: Date) throws {
        try Data(value.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func write(_ value: Data, to url: URL, date: Date) throws {
        try value.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
