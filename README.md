# MacMemoryMonitor

A lightweight macOS menu bar app that shows **why your Mac is lagging** and helps you fix it. It's built for 8 GB Macs running lots of Claude Code sessions, Chrome and Electron apps.

It's native Swift/SwiftUI with no Electron, and it uses about 50 MB of RAM and under 1% CPU.

## What it shows
- **Menu bar:** `● 64%` memory pressure, coloured green / orange / red.
- **Real memory per app,** measured as *physical footprint* (what Activity Monitor shows). Plain RSS hides compressed and swapped memory, so on a swapping Mac it badly undercounts.
- **Swap read rate:** the number that actually equals lag.
- **Grouping:** helper processes are grouped into what you recognise (Chrome, Spotify, each Claude Code session with its MCP servers, background scripts, virtual machines).
- **Tips** based on what's open: Chrome Memory Saver, Electron apps, CPU hogs, Spotlight indexing, low disk.

## What it does
- **Quit / Relaunch / Force Quit** apps. Relaunching hands back memory an app has leaked over time.
- **Pause** a Claude Code session. This stops the process and its MCP servers, but the conversation stays saved and resumes from the Claude sidebar.
- **Stop** background scripts. Destructive actions need a second click to confirm.
- **Auto-free (opt-in):** when memory is critical, it quits only the apps you've marked ⚡, biggest first.
- **Notifications** when memory runs out, and an **Open at login** option.

## Install
Requires macOS 14+ and Xcode command line tools.

```bash
git clone https://github.com/ryan-helou/MacMemoryMonitor.git
cd MacMemoryMonitor
./build.sh
```

`build.sh` builds a release binary, wraps it in `Mac Monitor.app` (ad-hoc signed), installs it to `~/Applications` and launches it.

To print one reading in the terminal: `.build/release/MacMonitor --dump`.

## How it works
- `SystemMemory.swift`: `host_statistics64`, `vm.swapusage` and `kern.memorystatus_*` for pressure, swap rates and CPU.
- `ProcessScanner.swift`: `proc_listallpids` + `proc_pid_rusage` (physical footprint, CPU time), grouping by `.app` bundle, process tree and Claude Code session.
- `Monitor.swift`: sampling, tips, alerts, the auto-free guard and actions.
- `Views.swift` / `App.swift`: an `NSStatusItem` with a SwiftUI popover.
