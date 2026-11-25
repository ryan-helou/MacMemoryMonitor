import Foundation

/// Every number and list you might want to tweak lives here. Change a value, run `./build.sh`.
enum Config {
    static let MB: Double = 1_048_576
    static let GB: Double = 1_073_741_824

    // When is the Mac "lagging"? (swap read back per second)
    static var thrashingSwapReadRate: Double { [40, 20, 10][Prefs.lagSensitivity] * MB }  // red
    static var strainedSwapReadRate: Double { [10, 5, 2.5][Prefs.lagSensitivity] * MB }   // orange

    // How often it looks
    static let sampleInterval: TimeInterval = 2
    static let scanEverySamplesVisible = 1       // panel open
    static var scanEverySamplesHealthy: Int { [15, 8, 3][Prefs.updateSpeed] }
    static var scanEverySamplesStrained: Int { [5, 3, 1][Prefs.updateSpeed] }
    static let historyLength = 90                // graph points (90 × 2 s = 3 min)

    // The list
    static var minRowMemory: Double { Prefs.double("hideBelowMB", 15) * MB }
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
    static var alertCooldown: TimeInterval { Prefs.double("alertEveryMinutes", 15) * 60 }

    // History, leaks, forecasts
    static let jumpEventSize = 600 * MB          // log "X jumped by…" events above this
    static let leakGrowth = 0.8 * GB             // steady growth worth a "restart it" tip
    static let typicalSessionCost = 300 * MB     // used for "room for N more sessions" when none are open

    // Habits
    static var unusedAppHours: Double { Prefs.double("unusedAppHours", 3) }   // 0 = off
    static let unusedAppMinMemory = 200 * MB
    static let restartReminderDays: Double = 3
    static let restartReminderSwap = 3 * GB
    static var stepAwayMinutes: Double { Prefs.double("stepAwayMinutes", 15) }
    static var claudeRestartAbove: Double { Prefs.double("claudeRestartAboveGB", 1.5) * GB }
    static let claudeRestartCooldown: Double = 6 * 3600
    static let hugeSessionMemory = 600 * MB
    static let hugeTranscript: UInt64 = 150_000_000
    static let mcpServerCost = 26 * MB            // rough memory per local MCP server process

    // Disk screen
    static let diskScanFolders = ["Downloads", "Movies", "Desktop", "Library/Developer/Xcode/DerivedData",
                                  "Library/Developer/CoreSimulator/Devices", "Library/Caches"]
    static let diskMinItem = 300 * MB

    /// Plain-language "what is this?" shown when you hover an app.
    static let explanations: [String: String] = [
        "com.google.Chrome": "Web browser. Each tab and extension runs separately. Memory Saver unloads idle tabs.",
        "com.anthropic.claudefordesktop": "The Claude app. Its window grows the longer it stays open; restarting it is safe — sessions are saved.",
        "com.spotify.client": "Music player built on a browser engine. Safe to quit when you're not listening.",
        "com.hnc.Discord": "Chat app built on a browser engine. Safe to quit; the web version uses less.",
        "com.microsoft.teams2": "Chat and meetings, built on a browser engine. Safe to quit outside meetings.",
        "com.tinyspeck.slackmacgap": "Chat app built on a browser engine. Safe to quit; the web version uses less.",
        "com.microsoft.VSCode": "Code editor built on a browser engine; extensions add their own processes.",
        "com.apple.Safari": "Web browser. Close tabs you aren't using.",
        "com.google.drivefs": "Syncs Google Drive files. Safe to quit when you don't need syncing.",
        "com.apple.dt.Xcode": "Apple's developer tool. Uses a lot while building; quit it when you're done.",
        "com.figma.Desktop": "Design app built on a browser engine. Big files use a lot of memory.",
        "notion.id": "Notes app built on a browser engine. Safe to quit; the web version uses less.",
        "us.zoom.xos": "Video calls. Safe to quit outside calls.",
        "com.apple.MobileSMS": "Messages. Usually small; photos in long chats can add up.",
        "com.docker.docker": "Runs a Linux virtual machine. Quit it when you're not using containers.",
    ]

    // Grouping
    static let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "login", "tmux", "screen", "sudo", "caffeinate"]
    static let terminalApps: Set<String> = ["Terminal.app", "iTerm.app", "Warp.app", "Ghostty.app", "kitty.app", "Alacritty.app", "WezTerm.app"]
    static let interpreters: Set<String> = ["node", "python", "python3", "bun", "deno", "ruby", "java", "Python"]
}

/// Everything you can change in Settings → Advanced. Stored in UserDefaults; missing = the default above.
enum Prefs {
    static let d = UserDefaults.standard
    static func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
    static var lagSensitivity: Int { min(2, max(0, d.object(forKey: "lagSensitivity") as? Int ?? 1)) }  // 0 low, 1 normal, 2 high
    static var updateSpeed: Int { min(2, max(0, d.object(forKey: "updateSpeed") as? Int ?? 1)) }        // 0 battery saver, 1 normal, 2 fast
    static var disabledTips: Set<String> { Set(d.stringArray(forKey: "disabledTips") ?? []) }

    /// Tip kinds you can switch off, with the name shown in Settings.
    static let tipKinds: [(id: String, name: String)] = [
        ("swap", "Memory spilled to disk"), ("leak", "App memory keeps climbing"), ("claude", "Many Claude sessions"),
        ("dup", "Duplicate Claude sessions"), ("huge", "Very long Claude session"), ("mcp", "MCP servers in every session"),
        ("chrome", "Chrome Memory Saver"), ("unused", "Apps you haven't used"), ("electron", "Browser-engine apps"),
        ("hog", "High CPU"), ("spotlight", "Spotlight indexing"), ("restart", "Restart reminder"),
        ("disk", "Low disk space"), ("update", "Updates available"),
    ]

    /// Every key Settings can change, for "Reset to defaults".
    static let allKeys = ["lagSensitivity", "updateSpeed", "hideBelowMB", "stepAwayMinutes", "claudeRestartAboveGB",
                          "unusedAppHours", "alertEveryMinutes", "disabledTips", "autoPauseEnabled", "autoPauseMinutes",
                          "smartPause", "keepRecentSessions", "nightlyClaudeRestart", "guardEnabled", "alertsEnabled",
                          "weeklyUpdateCheck", "menuBarStyle"]
}
