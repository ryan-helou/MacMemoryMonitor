# Contributing

Ideas, bug reports and pull requests are welcome.

## Build and run
```bash
./build.sh                         # build, install to ~/Applications, launch
.build/release/MacMonitor --dump   # print one reading in the terminal
./build.sh --package               # universal zip in dist/ (what releases ship)
```
Needs macOS 14+ and Apple's command line tools (`xcode-select --install`).

## Where things live
| File | What it does |
|---|---|
| `Config.swift` | Every threshold, timing and app list. Start here to customize. |
| `SystemMemory.swift` | Memory pressure, swap, CPU and disk readings. |
| `ProcessScanner.swift` | Lists processes, measures their real memory and groups them into apps, sessions and scripts. |
| `Monitor.swift` | Tips, alerts, auto-pause, auto-free and the Quit/Pause/Stop actions. |
| `Views.swift`, `App.swift` | The menu bar item and the panel. |

## Releasing
Bump `CFBundleShortVersionString` in `Resources/Info.plist`, commit, then push a tag (`git tag v1.0.1 && git push --tags`). GitHub Actions builds the zip and publishes the release.

## Ground rules
- The app must stay light: no network calls, no dependencies, under ~60 MB of memory.
- Anything that quits or stops something needs a confirm click, or an explicit opt-in for automatic actions.
