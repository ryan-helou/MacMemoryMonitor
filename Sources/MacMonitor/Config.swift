import Foundation

/// Every number and list you might want to tweak lives here. Change a value, run `./build.sh`.
enum Config {
    static let MB: Double = 1_048_576
    static let GB: Double = 1_073_741_824

    // When is the Mac "lagging"? (swap read back per second)
    static let thrashingSwapReadRate = 20 * MB   // red (with macOS pressure warning)
    static let strainedSwapReadRate = 5 * MB     // orange

    // How often it looks
    static let sampleInterval: TimeInterval = 2
    static let scanEverySamplesVisible = 1       // panel open
    static let scanEverySamplesHealthy = 8
    static let scanEverySamplesStrained = 3
    static let historyLength = 90                // graph points (90 × 2 s = 3 min)

    // The list
    static let minRowMemory = 15 * MB            // hide smaller items
    static let rowWarnMemory = 0.7 * GB          // orange
    static let rowAlarmMemory = 1.5 * GB         // red
    static let showCPUAbove: Double = 5

    // Tips
    static let tipSwapUsed = 2 * GB
    static let tipClaudeSessions = 3
    static let tipChromeMemory = 1.2 * GB
    static let tipCPUHog: Double = 60
    static let tipSpotlightCPU: Double = 40
    static let tipLowDisk = 15 * GB
    /// Apps that each ship their own browser engine (Electron etc.).
    static let webAppBundleIDs: Set<String> = [
        "com.spotify.client", "com.hnc.Discord", "com.microsoft.teams2", "com.microsoft.teams",
        "com.tinyspeck.slackmacgap", "notion.id", "com.figma.Desktop", "com.microsoft.VSCode",
    ]

    // Claude Code sessions
    static let autoPauseOnByDefault = true
    static let autoPauseDefaultMinutes = 15
    static let autoPauseChoices = [10, 15, 30, 60]
    static let sessionBusyCPU: Double = 3         // above this = active
    static let sessionTaskGrace: TimeInterval = 60 // processes started later = real work, never paused

    // Alerts and auto-free
    static let criticalFor: TimeInterval = 15
    static let autoFreeCooldown: TimeInterval = 30
    static let alertCooldown: TimeInterval = 15 * 60

    // Grouping
    static let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "login", "tmux", "screen", "sudo", "caffeinate"]
    static let terminalApps: Set<String> = ["Terminal.app", "iTerm.app", "Warp.app", "Ghostty.app", "kitty.app", "Alacritty.app", "WezTerm.app"]
    static let interpreters: Set<String> = ["node", "python", "python3", "bun", "deno", "ruby", "java", "Python"]
}
