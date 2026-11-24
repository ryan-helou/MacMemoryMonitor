<div align="center">

# Mac Memory Monitor

**A lightweight Mac app that sits in the menu bar and shows why your computer is slowing down, then helps you fix it.**

<a href="#get-it"><img alt="Install on macOS 14 or newer" src="https://img.shields.io/badge/Install-macOS_14+-24292f?style=for-the-badge"></a>

<img alt="Uses about_50_MB" src="https://img.shields.io/badge/Uses-about_50_MB-24292f?style=for-the-badge"> <img alt="CPU under_1%25" src="https://img.shields.io/badge/CPU-under_1%25-24292f?style=for-the-badge"> <img alt="Lives_in the_menu_bar" src="https://img.shields.io/badge/Lives_in-the_menu_bar-24292f?style=for-the-badge"> <img alt="Made_for 8_GB_Macs" src="https://img.shields.io/badge/Made_for-8_GB_Macs-24292f?style=for-the-badge">

</div>

<br>

When a Mac runs out of memory, it starts borrowing space from the disk, and everything gets sluggish. This app shows how close you are to that point and which apps are using the most memory, counted the same way Apple's Activity Monitor does. I built it for Macs with 8 GB of memory running lots of browser tabs, chat apps and AI coding sessions at once. It runs on macOS 14 or newer and barely uses any memory itself.

<p align="center">
  <img src="docs/main.png" width="300" alt="The panel: memory pressure, a tip, and the apps using the most memory">
  <img src="docs/history.png" width="300" alt="History: 24 hours of memory with lag periods and events">
</p>

## What you can do with it

- See your memory pressure at a glance in the menu bar, as a percentage that turns green, orange or red.
- See which apps use the most memory, with each app's background helpers grouped under its name.
- Quit, restart or force-quit a heavy app with one click. Restarting gives back memory an app has slowly piled up.
- Pause an AI coding session (Claude Code) without losing the conversation, and stop stray background scripts.
- Automatically pause Claude Code sessions you haven't touched in a while (15 minutes by default). It never pauses a session that's still running something in the background.
- Get plain tips based on what's open, such as turning on Chrome's Memory Saver, plus a warning when memory runs out.
- Optionally let it close apps you've marked as safe to close, biggest first, when memory gets critical.
- See the last 24 hours: when your Mac lagged, which app jumped, and what was paused or quit.
- Get told when an app's memory keeps climbing (a leak), with a one-click restart.
- Find big files in Downloads, Movies and developer caches and move them to the Trash.
- See how many more Claude sessions fit, each session's real title and when you last used it, and which MCP servers load in every session.
- Act straight from the "out of memory" notification, and press ⌥⌘M anywhere to open the panel.

## Get it

**[⬇ Download the latest version](https://github.com/ryan-helou/MacMemoryMonitor/releases/latest)** (`MacMemoryMonitor-x.y.z.zip`), unzip it and drag **Mac Memory Monitor** into your Applications folder. It works on Apple Silicon and Intel Macs.

The first time you open it, macOS warns that it can't check the app, because it isn't notarized by Apple. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only need to do this once.

Don't see it in the menu bar? On macOS 26, open **System Settings → Menu Bar** and switch **Mac Memory Monitor** on under **Allow in the Menu Bar**. If your menu bar is very full, it may also be hidden behind the notch or other icons.

### Or with Homebrew

```bash
brew trust ryan-helou/tap
brew install --cask ryan-helou/tap/mac-memory-monitor
```

### Or build it yourself

Open the Terminal app and paste these three lines. It builds the app, puts it in your Applications folder and opens it. You need Apple's free developer tools; if they're missing, your Mac will offer to install them.

```bash
git clone https://github.com/ryan-helou/MacMemoryMonitor.git
cd MacMemoryMonitor
./build.sh
```

## Customize it

Every threshold, timing and app list lives in one file, [`Sources/MacMonitor/Config.swift`](Sources/MacMonitor/Config.swift). Examples: when the menu bar turns orange or red, how long before idle Claude sessions are paused, which apps count as "browser engine" apps. Change a value and run `./build.sh` again. Most day-to-day options (auto-pause, auto-free, warnings, open at login) are also switches at the bottom of the panel. See [CONTRIBUTING.md](CONTRIBUTING.md) for a map of the code.

## Privacy

It never connects to the internet and collects nothing. Everything it shows is read from your own Mac and stays there.

## Uninstall

Quit it from its panel (**Quit Mac Memory Monitor**) and drag **Mac Memory Monitor** from Applications to the Trash.

## License

MIT. Use it, change it and share it freely.
