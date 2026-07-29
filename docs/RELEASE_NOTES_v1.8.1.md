# Codex Usage HUD v1.8.1

This is the first public preview build of Codex Usage HUD for macOS 14+ on Apple Silicon.

## Highlights

- **Activity states:** the HUD aggregates running/thinking, completed-but-unread, needs-input, and error states across supported providers. Completion reminders remain visible while other work continues.
- **Edge attachment:** collapsed and expanded HUD states preserve the selected screen-edge attachment. Width changes use an anchored transition so the panel does not drift.
- **Interaction:** use Automatic mode to follow the frontmost supported Codex, Claude, or Kimi app, or pin the HUD to a chosen provider in Settings. Click the compact HUD to expand it; use the header controls to refresh, open settings, or quit.
- **Usage windows:** Codex renders both 5-hour and weekly windows when available, and switches cleanly to weekly-only presentation when the short window is absent.

## Preview notes

This ZIP is not Developer ID signed or Apple notarized. It may require a manual Gatekeeper confirmation on first launch. It contains only the app and its helper, and was checked for author account data, personal paths, credentials, logs, and machine-specific files before release.
