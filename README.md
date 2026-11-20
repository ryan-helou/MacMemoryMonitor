<div align="center">

# Mac Memory Monitor

**A small Mac app that sits in the menu bar and shows why your computer is slowing down, then helps you fix it.**

<a href="#get-it"><img alt="Install on macOS 14 or newer" src="https://img.shields.io/badge/Install-macOS_14+-24292f?style=for-the-badge"></a>

</div>

<br>

When a Mac runs out of memory, it starts borrowing space from the disk, and everything gets sluggish. This app shows how close you are to that point and which apps are using the most memory, counted the same way Apple's Activity Monitor does. It was made for Macs with 8 GB of memory running lots of browser tabs, chat apps and AI coding sessions at once. It runs on macOS 14 or newer and barely uses any memory itself.

## What you can do with it

- See your memory pressure at a glance in the menu bar, as a percentage that turns green, orange or red.
- See which apps use the most memory, with each app's background helpers grouped under its name.
- Quit, restart or force-quit a heavy app with one click. Restarting gives back memory an app has slowly piled up.
- Pause an AI coding session (Claude Code) without losing the conversation, and stop stray background scripts.
- Get plain tips based on what's open, such as turning on Chrome's Memory Saver, plus a warning when memory runs out.
- Optionally let it close apps you've marked as safe to close, biggest first, when memory gets critical.

## Get it

Open the Terminal app and paste these three lines. It builds the app, puts it in your Applications folder and opens it. You need Apple's free developer tools; if they're missing, your Mac will offer to install them.

```bash
git clone https://github.com/ryan-helou/MacMemoryMonitor.git
cd MacMemoryMonitor
./build.sh
```
