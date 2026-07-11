# Work Log

A Windows desktop tool for logging what you work on without breaking your
flow. Select any text (like a Jira ticket URL) in any application, press
**Ctrl+Alt+L**, and it's saved under today's date — no need to switch to
this app first.

Built on the [Native SDK](https://native-sdk.dev) using its WebView-shell
architecture: the UI is generated HTML/CSS/JS served from an embedded
WebView, with all app logic in Zig (`src/main.zig`).

## Features

- **Global hotkey capture** — Ctrl+Alt+L stores the current text selection
  under today's date from anywhere on the desktop.
- **Month / Week / Day views** — browse logged entries with real calendar
  navigation; delete entries inline.
- **Analytics** — time spent per ticket, inferred from gaps between
  consecutive entries, with configurable working hours and a fill-gaps
  option for the last entry of the day.
- **Settings** — working hours, light/dark/auto theme, fill-gaps behavior.
- **CSV export** — back up all entries via the native Save dialog.
- **System tray** — runs from the tray with an icon that adapts to
  Windows light/dark taskbar theme.
- **About panel** — in-app explanation of how the app works.

## Commands

```sh
native dev     # build and run the app with hot reload
native test    # run the app's test suite
native build   # produce a ReleaseFast binary in zig-out/bin/
native check   # validate app.zon
```

## Packaging

```sh
native build
native package-windows --binary zig-out/bin/work-log.exe --output zig-out/package/windows
```

Produces a portable folder (`zig-out/package/windows/`) — copy it anywhere
and run `bin\work-log.exe`. There is currently no installer; the Native
SDK's packaging step only produces the portable artifact.

## Data storage

Entries are stored as tab-separated `date\ttimestamp\ttext` lines in
`%APPDATA%\work-log\data.csv`. Settings live alongside in `settings.txt`.
