import Foundation

private enum BridgePaths {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Codex Usage HUD", isDirectory: true)
    static let cache: URL = {
        if let override = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_CLAUDE_CACHE"] {
            return URL(fileURLWithPath: override)
        }
        return directory.appendingPathComponent("claude-usage.json")
    }()
    static let activityCache: URL = {
        if let override = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_CLAUDE_ACTIVITY_CACHE"] {
            return URL(fileURLWithPath: override)
        }
        return directory.appendingPathComponent("claude-activity.json")
    }()
    static let activityDirectory = directory.appendingPathComponent("claude-activities", isDirectory: true)
}

private func number(_ value: Any?) -> NSNumber? {
    value as? NSNumber
}

private func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func compact(_ dictionary: [String: Any]) -> [String: Any] {
    dictionary.filter { !($0.value is NSNull) }
}

private func jsonNumber(_ value: Int64?) -> Any {
    value.map { NSNumber(value: $0) } ?? NSNull()
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard
    !input.isEmpty,
    let root = try? JSONSerialization.jsonObject(with: input) as? [String: Any]
else {
    exit(0)
}

let activityPayload: [String: Any] = compact([
    "capturedAt": Date().timeIntervalSince1970,
    "sessionID": root["session_id"] as? String ?? NSNull(),
    "transcriptPath": root["transcript_path"] as? String ?? NSNull()
])
if let activityOutput = try? JSONSerialization.data(withJSONObject: activityPayload, options: [.sortedKeys]) {
    do {
        try FileManager.default.createDirectory(at: BridgePaths.activityCache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try activityOutput.write(to: BridgePaths.activityCache, options: .atomic)

        let rawActivityID = (root["session_id"] as? String)
            ?? (root["transcript_path"] as? String).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        if let rawActivityID, !rawActivityID.isEmpty {
            let safeActivityID = rawActivityID.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                    ? Character(String(scalar))
                    : "_"
            }
            let filename = String(safeActivityID.prefix(120)) + ".json"
            try FileManager.default.createDirectory(at: BridgePaths.activityDirectory, withIntermediateDirectories: true)
            try activityOutput.write(to: BridgePaths.activityDirectory.appendingPathComponent(filename), options: .atomic)
        }
    } catch {
        // Activity monitoring is best effort and must never interrupt Claude Code.
    }
}

let rateLimits = dictionary(root["rate_limits"])
let fiveHour = dictionary(rateLimits?["five_hour"])
let sevenDay = dictionary(rateLimits?["seven_day"])
let context = dictionary(root["context_window"])
let currentUsage = dictionary(context?["current_usage"])

let directInput = number(currentUsage?["input_tokens"])?.int64Value
let cacheCreation = number(currentUsage?["cache_creation_input_tokens"])?.int64Value ?? 0
let cacheRead = number(currentUsage?["cache_read_input_tokens"])?.int64Value ?? 0
let inputTokens = directInput.map { $0 + cacheCreation + cacheRead }
    ?? number(context?["total_input_tokens"])?.int64Value
let outputTokens = number(currentUsage?["output_tokens"])?.int64Value
    ?? number(context?["total_output_tokens"])?.int64Value

guard number(fiveHour?["used_percentage"]) != nil || number(sevenDay?["used_percentage"]) != nil else {
    exit(0)
}

let payload: [String: Any] = compact([
    "schemaVersion": 1,
    "capturedAt": Date().timeIntervalSince1970,
    "fiveHour": compact([
        "usedPercentage": number(fiveHour?["used_percentage"]) ?? NSNull(),
        "resetsAt": number(fiveHour?["resets_at"]) ?? NSNull()
    ]),
    "sevenDay": compact([
        "usedPercentage": number(sevenDay?["used_percentage"]) ?? NSNull(),
        "resetsAt": number(sevenDay?["resets_at"]) ?? NSNull()
    ]),
    "session": compact([
        "inputTokens": jsonNumber(inputTokens),
        "outputTokens": jsonNumber(outputTokens),
        "contextRemainingPercentage": number(context?["remaining_percentage"]) ?? NSNull(),
        "claudeVersion": root["version"] as? String ?? NSNull()
    ])
])

guard let output = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
    exit(0)
}

if let existingData = try? Data(contentsOf: BridgePaths.cache),
   var existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
    var next = payload
    existing.removeValue(forKey: "capturedAt")
    next.removeValue(forKey: "capturedAt")
    if NSDictionary(dictionary: existing).isEqual(to: next) {
        exit(0)
    }
}

do {
    try FileManager.default.createDirectory(at: BridgePaths.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    try output.write(to: BridgePaths.cache, options: .atomic)
} catch {
    // Status line helpers must stay silent so they never disrupt Claude Code's UI.
}
