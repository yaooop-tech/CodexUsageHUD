import Foundation

enum ClaudeBridgeStatus: Equatable {
    case installed
    case disabled
    case conflict
    case helperMissing
    case invalidSettings
    case failed
}

enum ClaudeBridgePaths {
    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Codex Usage HUD", isDirectory: true)
    static let installedHelper = supportDirectory.appendingPathComponent("ClaudeUsageBridge")
    static let usageCache = supportDirectory.appendingPathComponent("claude-usage.json")
    static let activityCache = supportDirectory.appendingPathComponent("claude-activity.json")
    static let activityDirectory = supportDirectory.appendingPathComponent("claude-activities", isDirectory: true)
    static let claudeSettings = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
}

enum ClaudeBridgeService {
    static func configure(enabled: Bool) -> ClaudeBridgeStatus {
        enabled ? install() : uninstall()
    }

    private static func install() -> ClaudeBridgeStatus {
        guard let bundledHelper = Bundle.main.resourceURL?.appendingPathComponent("ClaudeUsageBridge"),
              FileManager.default.isExecutableFile(atPath: bundledHelper.path) else {
            return .helperMissing
        }

        do {
            try FileManager.default.createDirectory(at: ClaudeBridgePaths.supportDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: ClaudeBridgePaths.installedHelper.path) {
                try FileManager.default.removeItem(at: ClaudeBridgePaths.installedHelper)
            }
            try FileManager.default.copyItem(at: bundledHelper, to: ClaudeBridgePaths.installedHelper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ClaudeBridgePaths.installedHelper.path)

            var settings = try readSettings()
            if let existing = settings["statusLine"], !(existing is NSNull), !isOurStatusLine(existing) {
                return .conflict
            }

            settings["statusLine"] = [
                "type": "command",
                "command": shellQuoted(ClaudeBridgePaths.installedHelper.path)
            ]
            try writeSettings(settings)
            return .installed
        } catch SettingsError.invalidRoot {
            return .invalidSettings
        } catch {
            return .failed
        }
    }

    private static func uninstall() -> ClaudeBridgeStatus {
        do {
            var settings = try readSettings()
            if let existing = settings["statusLine"], isOurStatusLine(existing) {
                settings.removeValue(forKey: "statusLine")
                try writeSettings(settings)
            }
            return .disabled
        } catch SettingsError.invalidRoot {
            return .invalidSettings
        } catch {
            return .failed
        }
    }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: ClaudeBridgePaths.claudeSettings.path) else {
            return [:]
        }
        let data = try Data(contentsOf: ClaudeBridgePaths.claudeSettings)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsError.invalidRoot
        }
        return root
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: ClaudeBridgePaths.claudeSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: ClaudeBridgePaths.claudeSettings, options: .atomic)
    }

    private static func isOurStatusLine(_ value: Any) -> Bool {
        guard let statusLine = value as? [String: Any],
              let command = statusLine["command"] as? String else {
            return false
        }
        return command.contains("Codex Usage HUD") && command.contains("ClaudeUsageBridge")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private enum SettingsError: Error {
        case invalidRoot
    }
}
