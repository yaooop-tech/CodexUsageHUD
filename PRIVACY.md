# Privacy

Codex Usage HUD is a local macOS utility. The release archive contains no author account data, local logs, chat history, credentials, or machine-specific configuration.

## What the app reads

- Codex: the local Codex app-server and, when needed, the signed-in Codex OAuth file to request the signed-in user's usage data.
- Claude: the local Claude status-line cache only after the user enables Claude monitoring. Optional OAuth monitoring reads the signed-in user's Claude credentials only after the user enables it.
- Kimi: the signed-in user's Kimi Desktop session or Kimi Code credential only to request that user's usage data.
- Activity indicators: recent local status metadata needed to show running, completed, attention, and error states. The HUD does not upload prompts or transcript contents.

## Network use

When a provider is enabled, the app requests usage information from that provider's service using the user's existing local session. It does not send data to an operator-owned server. There is no analytics, advertising SDK, automatic update service, or telemetry endpoint.

## What the app does not send to the project author

The app does not send prompts, conversation text, OAuth tokens, cookies, passwords, email addresses, or full task transcripts to an author-operated service. Some provider APIs may return account or plan labels for local display. The app does not bundle the author's personal files or credentials.

Provider integrations may change when their local applications or services change. Review the source before use and disable a provider in Settings if you do not want it monitored.
