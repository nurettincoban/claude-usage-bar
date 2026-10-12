# Contributing

Thanks for helping out! ClaudeBar is a small app and aims to stay that way:
one popover, no dependencies, nothing leaves your Mac except the usage request
to Anthropic.

## Getting started

Requirements: macOS 15+ and Xcode 16+ (or the matching Swift toolchain).

```sh
make test      # run the test suite
make run       # run from the terminal
make install   # build the .app, copy it to ~/Applications and launch it
```

## Before opening a pull request

- `make test` passes. Add a test when you change parsing, the transcript
  scanner or the pace maths. They're all pure and easy to test.
- UI changes come with fresh screenshots: `make screenshots` renders the
  popover from demo data, so no personal data ends up in the repository.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/),
  e.g. `feat: show reset time in menu bar` or `fix(scanner): skip truncated files`.
- Keep the scope tight. New stats are welcome if they fit the popover without
  making it scroll.

## How the code is organised

| File | Responsibility |
| --- | --- |
| `UsageAPI.swift` | Reads Claude Code's login, calls the usage endpoint, parses the response |
| `LocalStats.swift` | Tails `~/.claude/projects/**/*.jsonl` incrementally and aggregates activity |
| `UsageStore.swift` | Observable app state, polling, notifications |
| `PopoverView.swift` | The popover UI |
| `ClaudeBarApp.swift` | App entry point and the menu bar icon |
| `Snapshot.swift` | `--snapshot` rendering used for screenshots |

## Reporting bugs

Please include your macOS version, how you installed ClaudeBar, and what the
popover shows. If the usage request fails, the error banner text helps a lot.
Never paste your access token or the contents of your keychain item.
