# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1.0] - 2026-10-12

### Added

- **What's using your limit**: each project's share of the current session window,
  weighted by API cost, from Claude Code usage on this Mac.
- **API cost estimate** for the session window, today and the last 14 days. It uses
  published list prices and covers cache-write TTLs, fast mode and Haiku long-context rates.
- **Anthropic status** from status.claude.com. There's a banner and menu bar badge when claude.ai,
  the API or Claude Code is affected, and a footer note for other incidents. You can turn it off in settings.

### Changed

- The session-window breakdown replaces today's top projects list.

## [1.0.0] - 2026-10-12

### Added

- Menu bar ring gauge with session %, optionally weekly % too. It turns red at 90%.
- Popover with every plan limit: session (5 h), weekly, and per-model weekly limits,
  with reset countdowns and an elapsed-time marker.
- Pace projection: where each limit lands at the current rate, and when you'd hit it.
- Extra usage (overage credits) spent against the monthly cap.
- Claude Code activity on this Mac: tokens, output, replies, sessions, active
  sessions, model mix, a 14-day chart and top projects.
- Notifications at 80% and 95% of any limit, once per reset window.
- Launch at login.
