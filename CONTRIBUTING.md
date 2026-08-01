# Contributing to Codex Usage HUD

Thanks for helping improve Codex Usage HUD. Bug reports, feature ideas, documentation fixes, and small code changes are welcome.

## Before opening an issue

- Check existing issues first.
- Use the smallest reproducible example you can.
- Do not include tokens, cookies, passwords, email addresses, prompts, private logs, or personal screenshots.
- Include the app version, macOS version, provider, and whether the problem affects a release build or a source build.

## Local development

The project is a Swift Package for macOS 14 or later.

```bash
swift test
./script/build_and_run.sh --no-run
```

Use fixed demonstration data only for documentation captures. Do not commit real account data or machine-specific configuration.

## Pull requests

Please keep each pull request focused and explain the user-facing impact. A useful pull request normally includes:

- a short summary of the behavior being changed;
- tests for parsing, provider, or activity-state changes;
- updated documentation or screenshots when the visible behavior changes;
- confirmation that no credentials or personal data are included.

Before submitting, run `swift test` and review the complete diff with `git diff --check`.

## Security

Do not report security issues with credentials or private diagnostic material in a public issue. Read [SECURITY.md](SECURITY.md) first.
