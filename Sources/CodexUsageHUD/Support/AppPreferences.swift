import SwiftUI

enum AppPreferencesMigration {
    private static let obsoleteActivityEffectKey = "appearance.activity.effect"

    static func apply(to defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: obsoleteActivityEffectKey)
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    func resolvedColorScheme(system: ColorScheme) -> ColorScheme {
        colorScheme ?? system
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english
    case chinese

    var id: String { rawValue }
}

enum L10n {
    static func text(_ key: Key, language: AppLanguage) -> String {
        switch language {
        case .english:
            return key.english
        case .chinese:
            return key.chinese
        }
    }

    enum Key {
        case fiveHour
        case fiveHourCompact
        case weekly
        case codeSevenDay
        case monthly
        case resetCredits
        case tokenUsage
        case tokenUnavailable
        case sevenDayTotal
        case dailyAverage
        case collectingData
        case noTokenTrend
        case lifetime
        case peakDay
        case streak
        case daySuffix
        case quotaRestores
        case currentPlan
        case subscriptionAccount
        case expiresAt
        case unavailable
        case remaining
        case refresh
        case refreshInterval
        case expanded
        case collapsed
        case refreshHint
        case minuteUnit
        case monitoring
        case currentSource
        case recentIssue
        case displaySource
        case automatic
        case fixedCodex
        case fixedClaude
        case fixedKimi
        case openKimiLogin
        case claudeMonitoring
        case claudeMonitoringHint
        case instantSync
        case instantSyncHint
        case connectClaude
        case reconnectClaude
        case connectingClaude
        case claudeConnected
        case claudeCLIMissing
        case waitingClaudeResponse
        case bridgeConnected
        case bridgeConflict
        case bridgeDisabled
        case bridgeUnavailable
        case sessionUsage
        case inputTokens
        case outputTokens
        case contextLeft
        case lastSynced
        case waitingClaudeSync
        case staleClaudeData
        case startup
        case launchAtLogin
        case collapsedByDefault
        case appearance
        case theme
        case restoreSevenDays
        case restoreSevenDaysCompact
        case language
        case system
        case light
        case dark
        case englishLanguage
        case chineseLanguage
        case version
        case currentVersion
        case updateMethod
        case manualReplacement
        case refreshNow
        case expand
        case collapse
        case quit

        var english: String {
            switch self {
            case .fiveHour: return "5-hour"
            case .fiveHourCompact: return "5h"
            case .weekly: return "Weekly"
            case .codeSevenDay: return "Code 7-day"
            case .monthly: return "Monthly"
            case .resetCredits: return "Reset credits"
            case .tokenUsage: return "Token usage"
            case .tokenUnavailable: return "Token data temporarily unavailable"
            case .sevenDayTotal: return "7D total"
            case .dailyAverage: return "Daily avg"
            case .collectingData: return "Collecting daily data"
            case .noTokenTrend: return "No daily usage data"
            case .lifetime: return "Lifetime"
            case .peakDay: return "Peak day"
            case .streak: return "Streak"
            case .daySuffix: return "d"
            case .quotaRestores: return "Resets"
            case .currentPlan: return "Current plan"
            case .subscriptionAccount: return "Subscription account"
            case .expiresAt: return "Expires at"
            case .unavailable: return "Unavailable"
            case .remaining: return "left"
            case .refresh: return "Refresh"
            case .refreshInterval: return "Refresh interval"
            case .expanded: return "Expanded"
            case .collapsed: return "Collapsed"
            case .refreshHint: return "The compact and expanded HUD use this interval. Default is 2 minutes."
            case .minuteUnit: return "min"
            case .monitoring: return "Monitoring"
            case .displaySource: return "Display source"
            case .automatic: return "Automatic"
            case .fixedCodex: return "Always Codex"
            case .fixedClaude: return "Always Claude"
            case .fixedKimi: return "Always Kimi"
            case .openKimiLogin: return "Open Kimi Login"
            case .claudeMonitoring: return "Claude monitoring"
            case .claudeMonitoringHint: return "Uses Claude's local status line by default. No credentials or prompts are stored."
            case .instantSync: return "Instant OAuth sync"
            case .instantSyncHint: return "Optional. Connect Claude for usage updates without waiting for a new session."
            case .connectClaude: return "Connect Claude"
            case .reconnectClaude: return "Reconnect Claude"
            case .connectingClaude: return "Connecting in browser..."
            case .claudeConnected: return "Claude connected"
            case .claudeCLIMissing: return "Install Claude Code to connect"
            case .waitingClaudeResponse: return "Run Claude once to sync usage, or connect for instant updates."
            case .currentSource: return "Current source"
            case .recentIssue: return "Recent issue"
            case .bridgeConnected: return "Bridge connected"
            case .bridgeConflict: return "Existing Claude status line was preserved"
            case .bridgeDisabled: return "Bridge disabled"
            case .bridgeUnavailable: return "Bridge unavailable"
            case .sessionUsage: return "Latest Claude session"
            case .inputTokens: return "Input"
            case .outputTokens: return "Output"
            case .contextLeft: return "Context left"
            case .lastSynced: return "Last synced"
            case .waitingClaudeSync: return "Waiting for the first Claude sync"
            case .staleClaudeData: return "Usage data may be out of date"
            case .startup: return "Startup"
            case .launchAtLogin: return "Start automatically after login"
            case .collapsedByDefault: return "The HUD opens collapsed by default."
            case .appearance: return "Appearance"
            case .theme: return "Theme"
            case .restoreSevenDays: return "Restore latest 7 days"
            case .restoreSevenDaysCompact: return "7D"
            case .language: return "Language"
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            case .englishLanguage: return "English"
            case .chineseLanguage: return "Chinese"
            case .version: return "Version"
            case .currentVersion: return "Current version"
            case .updateMethod: return "Update method"
            case .manualReplacement: return "Manual app replacement"
            case .refreshNow: return "Refresh Now"
            case .expand: return "Expand"
            case .collapse: return "Collapse"
            case .quit: return "Quit"
            }
        }

        var chinese: String {
            switch self {
            case .fiveHour: return "5 小时剩余"
            case .fiveHourCompact: return "5 小时"
            case .weekly: return "周剩余"
            case .codeSevenDay: return "Code 7 天剩余"
            case .monthly: return "月度额度"
            case .resetCredits: return "可用重置次数"
            case .tokenUsage: return "Token 使用量"
            case .tokenUnavailable: return "Token 数据暂不可用"
            case .sevenDayTotal: return "近 7 日"
            case .dailyAverage: return "日均"
            case .collectingData: return "每日数据积累中"
            case .noTokenTrend: return "暂无每日使用数据"
            case .lifetime: return "累计"
            case .peakDay: return "峰值日"
            case .streak: return "连续"
            case .daySuffix: return "天"
            case .quotaRestores: return "额度恢复"
            case .currentPlan: return "套餐类型"
            case .subscriptionAccount: return "订阅账户"
            case .expiresAt: return "到期时间"
            case .unavailable: return "暂无数据"
            case .remaining: return "剩余"
            case .refresh: return "刷新"
            case .refreshInterval: return "刷新频率"
            case .expanded: return "展开态"
            case .collapsed: return "收起态"
            case .refreshHint: return "收起和展开都使用这个刷新频率，默认 2 分钟。"
            case .minuteUnit: return "分钟"
            case .monitoring: return "监控来源"
            case .displaySource: return "显示来源"
            case .automatic: return "自动切换"
            case .fixedCodex: return "固定显示 Codex"
            case .fixedClaude: return "固定显示 Claude"
            case .fixedKimi: return "固定显示 Kimi"
            case .openKimiLogin: return "打开 Kimi 登录"
            case .claudeMonitoring: return "Claude 用量监控"
            case .claudeMonitoringHint: return "默认使用 Claude 本地状态栏数据，不保存凭据或提示词。"
            case .instantSync: return "即时 OAuth 同步"
            case .instantSyncHint: return "可选。连接 Claude 后无需等待新会话即可更新用量。"
            case .connectClaude: return "连接 Claude"
            case .reconnectClaude: return "重新连接 Claude"
            case .connectingClaude: return "正在浏览器中连接…"
            case .claudeConnected: return "Claude 已连接"
            case .claudeCLIMissing: return "请先安装 Claude Code"
            case .waitingClaudeResponse: return "运行一次 Claude 即可同步，也可连接后即时更新。"
            case .currentSource: return "当前数据来源"
            case .recentIssue: return "最近问题"
            case .bridgeConnected: return "本地桥接已连接"
            case .bridgeConflict: return "已保留现有 Claude 状态栏配置"
            case .bridgeDisabled: return "本地桥接已停用"
            case .bridgeUnavailable: return "本地桥接不可用"
            case .sessionUsage: return "最近一次 Claude 会话"
            case .inputTokens: return "输入"
            case .outputTokens: return "输出"
            case .contextLeft: return "上下文剩余"
            case .lastSynced: return "最后同步"
            case .waitingClaudeSync: return "等待 Claude 首次同步"
            case .staleClaudeData: return "用量数据可能已过期"
            case .startup: return "启动"
            case .launchAtLogin: return "登录后自动启动"
            case .collapsedByDefault: return "HUD 默认以收起态打开。"
            case .appearance: return "外观"
            case .theme: return "颜色主题"
            case .restoreSevenDays: return "恢复最近 7 日"
            case .restoreSevenDaysCompact: return "近7日"
            case .language: return "语言"
            case .system: return "随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            case .englishLanguage: return "英文"
            case .chineseLanguage: return "中文"
            case .version: return "版本"
            case .currentVersion: return "当前版本"
            case .updateMethod: return "更新方式"
            case .manualReplacement: return "手动替换应用"
            case .refreshNow: return "立即刷新"
            case .expand: return "展开"
            case .collapse: return "收起"
            case .quit: return "退出"
            }
        }
    }
}
