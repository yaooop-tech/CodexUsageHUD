import Foundation

enum AgentActivityState: String, Sendable {
    case idle
    case unread
    case thinking
    case attention
    case error

    func label(language: AppLanguage) -> String {
        switch (self, language) {
        case (.idle, .english): return "Idle"
        case (.unread, .english): return "Unread"
        case (.thinking, .english): return "Thinking"
        case (.attention, .english): return "Input"
        case (.error, .english): return "Error"
        case (.idle, .chinese): return "空闲"
        case (.unread, .chinese): return "未读完成"
        case (.thinking, .chinese): return "思考中"
        case (.attention, .chinese): return "需要确认"
        case (.error, .chinese): return "发生错误"
        }
    }
}

enum AgentActivitySourceState: Sendable, Equatable {
    case idle
    case completed
    case thinking
    case attention
    case error
}

enum AgentInteractionState: Sendable, Equatable {
    case idle
    case running
    case awaitingToolResult
    case awaitingPlanApproval
    case completed
    case error

    var sourceState: AgentActivitySourceState {
        switch self {
        case .idle: return .idle
        case .running: return .thinking
        case .awaitingToolResult, .awaitingPlanApproval: return .attention
        case .completed: return .completed
        case .error: return .error
        }
    }
}

struct AgentActivityReading: Sendable, Equatable {
    let provider: UsageProvider
    let state: AgentActivitySourceState
    let updatedAt: Date
}

struct AgentTaskActivity: Sendable, Equatable, Identifiable {
    let provider: UsageProvider
    let taskID: String
    let state: AgentActivitySourceState
    let updatedAt: Date

    var id: String { "\(provider.rawValue):\(taskID)" }
}

struct CompletionEventID: Sendable, Hashable {
    let provider: UsageProvider
    let taskID: String
    let completedAt: Date
}

struct ProviderActivitySummary: Sendable, Equatable, Identifiable {
    let provider: UsageProvider
    let thinkingCount: Int
    let attentionCount: Int
    let errorCount: Int
    let unreadCompletionCount: Int

    var id: UsageProvider { provider }
    var activeTaskCount: Int { thinkingCount + attentionCount + errorCount }
    var hasActivity: Bool { activeTaskCount + unreadCompletionCount > 0 }

    func description(language: AppLanguage) -> String {
        var parts: [String] = []
        switch language {
        case .english:
            if thinkingCount > 0 { parts.append("\(thinkingCount) running") }
            if attentionCount > 0 { parts.append("\(attentionCount) needs input") }
            if errorCount > 0 { parts.append("\(errorCount) error") }
            if unreadCompletionCount > 0 { parts.append("\(unreadCompletionCount) completed unread") }
        case .chinese:
            if thinkingCount > 0 { parts.append("\(thinkingCount) 个运行中") }
            if attentionCount > 0 { parts.append("\(attentionCount) 个等待确认") }
            if errorCount > 0 { parts.append("\(errorCount) 个发生错误") }
            if unreadCompletionCount > 0 { parts.append("\(unreadCompletionCount) 个已完成未读") }
        }
        return parts.joined(separator: language == .chinese ? "，" : ", ")
    }
}

struct AgentActivitySummary: Sendable, Equatable {
    let providerSummaries: [UsageProvider: ProviderActivitySummary]

    static let empty = AgentActivitySummary(providerSummaries: Dictionary(
        uniqueKeysWithValues: UsageProvider.allCases.map { provider in
            (provider, ProviderActivitySummary(
                provider: provider,
                thinkingCount: 0,
                attentionCount: 0,
                errorCount: 0,
                unreadCompletionCount: 0))
        }))

    var thinkingCount: Int { providerSummaries.values.reduce(0) { $0 + $1.thinkingCount } }
    var attentionCount: Int { providerSummaries.values.reduce(0) { $0 + $1.attentionCount } }
    var errorCount: Int { providerSummaries.values.reduce(0) { $0 + $1.errorCount } }
    var activeTaskCount: Int { thinkingCount + attentionCount + errorCount }
    var unreadCompletionCount: Int { providerSummaries.values.reduce(0) { $0 + $1.unreadCompletionCount } }
    var shouldShowCompletionBadge: Bool {
        unreadCompletionCount > 0 && (activeTaskCount > 0 || unreadCompletionCount > 1)
    }
    var activeProviderSummaries: [ProviderActivitySummary] {
        UsageProvider.allCases.compactMap { provider in
            guard let summary = providerSummaries[provider], summary.hasActivity else { return nil }
            return summary
        }
    }
    var hasActivity: Bool { activeTaskCount + unreadCompletionCount > 0 }
    var primaryState: AgentActivityState {
        if errorCount > 0 { return .error }
        if attentionCount > 0 { return .attention }
        if thinkingCount > 0 { return .thinking }
        if unreadCompletionCount > 0 { return .unread }
        return .idle
    }

    func description(language: AppLanguage) -> String {
        let aggregate = ProviderActivitySummary(
            provider: .codex,
            thinkingCount: thinkingCount,
            attentionCount: attentionCount,
            errorCount: errorCount,
            unreadCompletionCount: unreadCompletionCount)
        let value = aggregate.description(language: language)
        switch language {
        case .english: return value.isEmpty ? "No agent activity" : value
        case .chinese: return value.isEmpty ? "没有任务活动" : value
        }
    }
}

struct AgentActivityReducer: Sendable {
    private let startedAt: Date
    private var currentTasks: [UsageProvider: [String: AgentTaskActivity]] = [:]
    private var unreadCompletions = Set<CompletionEventID>()
    private var acknowledgedThrough: [UsageProvider: Date] = [:]

    init(startedAt: Date) {
        self.startedAt = startedAt
        for provider in UsageProvider.allCases {
            acknowledgedThrough[provider] = startedAt
        }
    }

    mutating func apply(_ activities: [UsageProvider: [AgentTaskActivity]]) -> AgentActivitySummary {
        for provider in UsageProvider.allCases {
            let tasks = activities[provider] ?? []
            let previousTasks = currentTasks[provider] ?? [:]
            currentTasks[provider] = Dictionary(tasks.map { ($0.taskID, $0) }, uniquingKeysWith: { _, latest in latest })

            let cutoff = acknowledgedThrough[provider] ?? startedAt
            for task in tasks where task.state == .completed && task.updatedAt > cutoff {
                let previous = previousTasks[task.taskID]
                let isNewCompletion = previous == nil
                    || previous?.state != .completed
                    || (provider != .kimi && task.updatedAt > (previous?.updatedAt ?? .distantPast))
                guard isNewCompletion else { continue }
                unreadCompletions.insert(CompletionEventID(
                    provider: provider,
                    taskID: task.taskID,
                    completedAt: task.updatedAt))
            }
        }
        return makeSummary()
    }

    mutating func acknowledge(provider: UsageProvider, at date: Date) -> AgentActivitySummary {
        acknowledgedThrough[provider] = max(acknowledgedThrough[provider] ?? startedAt, date)
        unreadCompletions = unreadCompletions.filter { event in
            event.provider != provider || event.completedAt > date
        }
        return makeSummary()
    }

    private func makeSummary() -> AgentActivitySummary {
        let summaries = UsageProvider.allCases.map { provider in
            let tasks = currentTasks[provider]?.values ?? Dictionary<String, AgentTaskActivity>().values
            let acknowledgementDate = acknowledgedThrough[provider] ?? startedAt
            return (provider, ProviderActivitySummary(
                provider: provider,
                thinkingCount: tasks.filter { $0.state == .thinking }.count,
                attentionCount: tasks.filter { $0.state == .attention }.count,
                errorCount: tasks.filter { $0.state == .error && $0.updatedAt > acknowledgementDate }.count,
                unreadCompletionCount: unreadCompletions.filter { $0.provider == provider }.count))
        }
        return AgentActivitySummary(providerSummaries: Dictionary(uniqueKeysWithValues: summaries))
    }
}

enum AgentActivityReader {
    static func readAll(startedAt: Date, now: Date = Date()) -> [UsageProvider: [AgentTaskActivity]] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            .codex: CodexActivityReader.read(
                sessionsRoot: home.appendingPathComponent(".codex/sessions", isDirectory: true),
                startedAt: startedAt,
                now: now),
            .claude: ClaudeActivityReader.read(
                activityDirectory: ClaudeBridgePaths.activityDirectory,
                legacyActivityURL: ClaudeBridgePaths.activityCache,
                startedAt: startedAt,
                now: now),
            .kimi: KimiActivityReader.read(
                statusURL: home.appendingPathComponent("Library/Application Support/kimi-desktop/kimi-agent/conversation-statuses.json"),
                errorURL: home.appendingPathComponent("Library/Application Support/kimi-desktop/kimi-agent/conversation-errors.json"),
                startedAt: startedAt,
                now: now),
        ]
    }

    static func monitoredURLs(now: Date = Date()) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexRoot = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let kimiRoot = home.appendingPathComponent(
            "Library/Application Support/kimi-desktop/kimi-agent",
            isDirectory: true)
        let kimiStatus = kimiRoot.appendingPathComponent("conversation-statuses.json")
        let kimiErrors = kimiRoot.appendingPathComponent("conversation-errors.json")
        return Array(Set(
            CodexActivityReader.monitorURLs(root: codexRoot, now: now)
                + ClaudeActivityReader.monitorURLs(
                    activityDirectory: ClaudeBridgePaths.activityDirectory,
                    legacyActivityURL: ClaudeBridgePaths.activityCache)
                + [kimiRoot, kimiStatus, kimiErrors]
        )).filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum CodexActivityReader {
    static func read(sessionsRoot: URL, startedAt: Date, now: Date) -> [AgentTaskActivity] {
        recentRollouts(root: sessionsRoot, now: now).compactMap { url in
            guard let data = FileTailReader.read(url: url),
                  let reading = classify(data: data),
                  isRelevant(reading, startedAt: startedAt, now: now) else { return nil }
            return AgentTaskActivity(
                provider: .codex,
                taskID: url.standardizedFileURL.path,
                state: reading.state,
                updatedAt: reading.updatedAt)
        }
    }

    static func classify(data: Data) -> AgentActivityReading? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var interactionState: AgentInteractionState = .idle
        var updatedAt: Date?
        var isPlanTurn = false
        var awaitsPlanApproval = false
        var pendingInteractionCallIDs = Set<String>()

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let timestamp = date(root["timestamp"]) else { continue }

            let envelopeType = root["type"] as? String
            let payload = root["payload"] as? [String: Any] ?? [:]
            if envelopeType == "event_msg", let event = payload["type"] as? String {
                switch event {
                case "task_started":
                    isPlanTurn = payload["collaboration_mode_kind"] as? String == "plan"
                    awaitsPlanApproval = false
                    pendingInteractionCallIDs.removeAll()
                    interactionState = .running
                    updatedAt = timestamp
                case "agent_reasoning", "agent_message", "token_count",
                     "patch_apply_begin", "web_search_begin", "mcp_tool_call_begin":
                    interactionState = pendingInteractionCallIDs.isEmpty && !awaitsPlanApproval
                        ? .running
                        : awaitsPlanApproval ? .awaitingPlanApproval : .awaitingToolResult
                    updatedAt = timestamp
                case "task_complete":
                    if awaitsPlanApproval {
                        interactionState = .awaitingPlanApproval
                    } else if !pendingInteractionCallIDs.isEmpty {
                        interactionState = .awaitingToolResult
                    } else {
                        interactionState = .completed
                    }
                    updatedAt = timestamp
                case "turn_aborted", "task_cancelled", "task_canceled":
                    interactionState = .idle
                    updatedAt = timestamp
                default:
                    break
                }
            } else if envelopeType == "response_item" {
                let itemType = payload["type"] as? String ?? ""
                let name = (payload["name"] as? String ?? payload["tool_name"] as? String ?? "").lowercased()
                let callID = payload["call_id"] as? String

                if itemType == "function_call", isUserInteractionTool(name) {
                    pendingInteractionCallIDs.insert(callID ?? "pending:\(timestamp.timeIntervalSince1970)")
                    interactionState = .awaitingToolResult
                    updatedAt = timestamp
                } else if itemType == "function_call_output", let callID {
                    pendingInteractionCallIDs.remove(callID)
                    interactionState = awaitsPlanApproval
                        ? .awaitingPlanApproval
                        : pendingInteractionCallIDs.isEmpty ? .running : .awaitingToolResult
                    updatedAt = timestamp
                } else if itemType == "message" {
                    let role = payload["role"] as? String
                    if role == "assistant", isPlanTurn, containsProposedPlan(payload) {
                        awaitsPlanApproval = true
                        interactionState = .awaitingPlanApproval
                        updatedAt = timestamp
                    } else if role == "user" {
                        awaitsPlanApproval = false
                        pendingInteractionCallIDs.removeAll()
                        interactionState = .running
                        updatedAt = timestamp
                    }
                } else if itemType.hasSuffix("_output") || itemType.contains("call") || itemType == "reasoning" {
                    interactionState = awaitsPlanApproval
                        ? .awaitingPlanApproval
                        : pendingInteractionCallIDs.isEmpty ? .running : .awaitingToolResult
                    updatedAt = timestamp
                }
                if payload["error"] != nil {
                    interactionState = .error
                    updatedAt = timestamp
                }
            }
        }

        guard let updatedAt else { return nil }
        return AgentActivityReading(provider: .codex, state: interactionState.sourceState, updatedAt: updatedAt)
    }

    private static func isUserInteractionTool(_ name: String) -> Bool {
        name.contains("request_user_input")
            || name.contains("approval")
            || name.contains("ask_user")
    }

    private static func containsProposedPlan(_ payload: [String: Any]) -> Bool {
        let content = payload["content"] as? [[String: Any]] ?? []
        return content.contains { item in
            (item["text"] as? String)?.contains("<proposed_plan>") == true
        }
    }

    private static func isRelevant(_ reading: AgentActivityReading, startedAt: Date, now: Date) -> Bool {
        switch reading.state {
        case .thinking, .attention: return now.timeIntervalSince(reading.updatedAt) < 60 * 60
        case .completed: return reading.updatedAt >= startedAt
        case .error: return reading.updatedAt >= startedAt && now.timeIntervalSince(reading.updatedAt) < 30 * 60
        case .idle: return false
        }
    }

    static func monitorURLs(root: URL, now: Date) -> [URL] {
        [root] + recentDayFolders(root: root, now: now)
            + recentRollouts(root: root, now: now)
    }

    private static func recentRollouts(root: URL, now: Date) -> [URL] {
        recentDayFolders(root: root, now: now)
            .flatMap { folder in
                (try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles])) ?? []
            }
            .filter { $0.pathExtension == "jsonl" }
            .sorted { modificationDate($0) > modificationDate($1) }
            .prefix(16)
            .map { $0 }
    }

    private static func recentDayFolders(root: URL, now: Date) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy/MM/dd"

        var folders: [URL] = []
        for offset in 0 ... 3 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let folder = root.appendingPathComponent(formatter.string(from: date), isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                folders.append(folder)
            }
        }
        return folders
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return parseActivityDate(string)
    }
}

enum ClaudeActivityReader {
    static func read(
        activityDirectory: URL,
        legacyActivityURL: URL,
        startedAt: Date,
        now: Date
    ) -> [AgentTaskActivity] {
        var descriptors = recentDescriptors(in: activityDirectory)
        if let legacy = descriptor(at: legacyActivityURL) {
            descriptors.append(legacy)
        }

        let unique = Dictionary(descriptors.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
        return unique.values.compactMap { descriptor in
            guard let transcript = FileTailReader.read(url: descriptor.transcriptURL),
                  let reading = classifyTranscript(data: transcript),
                  isRelevant(reading, startedAt: startedAt, now: now) else { return nil }
            return AgentTaskActivity(
                provider: .claude,
                taskID: descriptor.taskID,
                state: reading.state,
                updatedAt: reading.updatedAt)
        }
    }

    static func classifyTranscript(data: Data) -> AgentActivityReading? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var state: AgentActivitySourceState = .idle
        var updatedAt: Date?

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let timestamp = parseActivityDate(root["timestamp"] as? String ?? "") else { continue }
            let type = root["type"] as? String ?? ""

            if root["error"] != nil || root["isApiErrorMessage"] as? Bool == true {
                state = .error
                updatedAt = timestamp
                continue
            }

            switch type {
            case "user", "progress", "queue-operation":
                state = .thinking
                updatedAt = timestamp
            case "assistant":
                let message = root["message"] as? [String: Any] ?? [:]
                let content = message["content"] as? [[String: Any]] ?? []
                let toolNames = content.compactMap { item -> String? in
                    guard item["type"] as? String == "tool_use" else { return nil }
                    return (item["name"] as? String)?.lowercased()
                }
                if toolNames.contains(where: { $0.contains("askuserquestion") || $0.contains("request_user_input") }) {
                    state = .attention
                } else if !toolNames.isEmpty || message["stop_reason"] == nil {
                    state = .thinking
                } else {
                    state = .completed
                }
                updatedAt = timestamp
            case "system":
                if root["subtype"] as? String == "stop_hook_summary" {
                    state = .completed
                    updatedAt = timestamp
                }
            default:
                break
            }
        }

        guard let updatedAt else { return nil }
        return AgentActivityReading(provider: .claude, state: state, updatedAt: updatedAt)
    }

    static func monitorURLs(
        activityDirectory: URL,
        legacyActivityURL: URL
    ) -> [URL] {
        var descriptors = recentDescriptors(in: activityDirectory)
        if let legacy = descriptor(at: legacyActivityURL) {
            descriptors.append(legacy)
        }
        return [activityDirectory, legacyActivityURL]
            + descriptors.flatMap { [$0.sourceURL, $0.transcriptURL] }
    }

    private struct Descriptor {
        let taskID: String
        let sourceURL: URL
        let transcriptURL: URL
    }

    private static func recentDescriptors(in directory: URL) -> [Descriptor] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { modificationDate($0) > modificationDate($1) }
            .prefix(16)
            .compactMap { descriptor(at: $0) }
    }

    private static func descriptor(at url: URL) -> Descriptor? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = root["transcriptPath"] as? String else { return nil }
        let taskID = (root["sessionID"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? path
        return Descriptor(
            taskID: taskID,
            sourceURL: url,
            transcriptURL: URL(fileURLWithPath: path))
    }

    private static func isRelevant(_ reading: AgentActivityReading, startedAt: Date, now: Date) -> Bool {
        switch reading.state {
        case .thinking, .attention: return now.timeIntervalSince(reading.updatedAt) < 60 * 60
        case .completed: return reading.updatedAt >= startedAt
        case .error: return reading.updatedAt >= startedAt && now.timeIntervalSince(reading.updatedAt) < 30 * 60
        case .idle: return false
        }
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

enum KimiActivityReader {
    static func read(statusURL: URL, errorURL: URL, startedAt: Date, now: Date) -> [AgentTaskActivity] {
        let statusDate = modificationDate(statusURL)
        let errorDate = modificationDate(errorURL)
        let statuses = stringDictionary(statusURL)
        let errors = errorDictionary(errorURL)

        var activities: [String: AgentTaskActivity] = [:]
        for (taskID, rawStatus) in statuses {
            let state: AgentActivitySourceState?
            switch rawStatus.lowercased() {
            case "running": state = now.timeIntervalSince(statusDate) < 60 * 60 ? .thinking : nil
            case "blocked": state = now.timeIntervalSince(statusDate) < 60 * 60 ? .attention : nil
            case "completed": state = .completed
            case "failed", "error": state = errorDate >= startedAt && now.timeIntervalSince(errorDate) < 30 * 60 ? .error : nil
            default: state = nil
            }
            guard let state else { continue }
            activities[taskID] = AgentTaskActivity(
                provider: .kimi,
                taskID: taskID,
                state: state,
                updatedAt: state == .error ? errorDate : statusDate)
        }

        if errorDate >= startedAt, now.timeIntervalSince(errorDate) < 30 * 60 {
            for (taskID, messages) in errors where !messages.isEmpty && statuses[taskID] == nil {
                activities[taskID] = AgentTaskActivity(
                    provider: .kimi,
                    taskID: taskID,
                    state: .error,
                    updatedAt: errorDate)
            }
        }
        return Array(activities.values)
    }

    private static func stringDictionary(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func errorDictionary(_ url: URL) -> [String: [String]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

enum FileTailReader {
    private struct Entry {
        let fileIdentifier: String
        let size: UInt64
        let data: Data
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: Entry] = [:]
    }

    private static let cache = Cache()

    static func read(url: URL, maximumBytes: UInt64 = 96 * 1024) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let identifier = (attributes[.systemFileNumber] as? NSNumber)
            .map { "\($0.uint64Value)" }
            ?? url.path
        let key = url.standardizedFileURL.path
        let cached = cache.lock.withLock { cache.entries[key] }

        if let cached,
           cached.fileIdentifier == identifier,
           cached.size == size {
            return cached.data
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var data: Data
        if let cached,
           cached.fileIdentifier == identifier,
           size > cached.size {
            try? handle.seek(toOffset: cached.size)
            data = cached.data
            data.append((try? handle.readToEnd()) ?? Data())
        } else {
            let offset = size > maximumBytes ? size - maximumBytes : 0
            try? handle.seek(toOffset: offset)
            data = (try? handle.readToEnd()) ?? Data()
            if offset > 0, let newline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(data.startIndex ... newline)
            }
        }

        if data.count > Int(maximumBytes) {
            let lower = data.count - Int(maximumBytes)
            data.removeSubrange(data.startIndex ..< data.index(data.startIndex, offsetBy: lower))
            if let newline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(data.startIndex ... newline)
            }
        }
        cache.lock.withLock {
            cache.entries[key] = Entry(
                fileIdentifier: identifier,
                size: size,
                data: data)
        }
        return data
    }
}

private func parseActivityDate(_ value: String) -> Date? {
    let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    if let date = try? fractional.parse(value) { return date }
    return try? Date.ISO8601FormatStyle().parse(value)
}
