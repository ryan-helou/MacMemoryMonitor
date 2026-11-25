import XCTest
@testable import MacMonitor

/// Feeds made-up processes into the grouping logic and checks what a person would see in the list.
final class GroupingTests: XCTestCase {
    private let mb: UInt64 = 1_048_576
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func proc(_ pid: pid_t, parent: pid_t, _ path: String, mb m: UInt64 = 10, uid: uid_t = 501,
                      startedAfter secs: TimeInterval = 0) -> RawProc {
        RawProc(pid: pid, ppid: parent, uid: uid, name: (path as NSString).lastPathComponent, path: path,
                footprint: m * mb, cpu: 0, start: t0.addingTimeInterval(secs))
    }

    private func scanner() -> ProcessScanner {
        let s = ProcessScanner()
        s.cwdProvider = { _ in "/Users/test/Developer/shop-app" }
        s.argsProvider = { _ in ["node", "/Users/test/bots/run.mjs"] }
        s.sessionInfoProvider = { _ in SessionInfo(title: "Fix checkout", lastActivity: nil, transcriptBytes: 0) }
        return s
    }

    private func group(_ procs: [RawProc]) -> [ProcGroup] {
        scanner().group(Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })).groups
    }

    func testAppHelpersAreFoldedIntoTheApp() {
        let groups = group([
            proc(100, parent: 1, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", mb: 300),
            proc(101, parent: 100, "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", mb: 200),
        ])
        let chrome = groups.first { $0.kind == .app }
        XCTAssertEqual(chrome?.name, "Google Chrome")
        XCTAssertEqual(chrome?.processCount, 2)
        XCTAssertEqual(chrome?.memory, 500 * mb)
    }

    func testClaudeSessionIncludesItsHelpersAndKnowsItCameFromTheApp() {
        let groups = group([
            proc(10, parent: 1, "/Applications/Claude.app/Contents/MacOS/Claude"),
            proc(11, parent: 10, "/Applications/Claude.app/Contents/Helpers/disclaimer"),
            proc(12, parent: 11, "/Users/test/Library/Application Support/Claude/claude-code/2.1/x/claude.app/Contents/MacOS/claude", mb: 250),
            proc(13, parent: 12, "/opt/homebrew/bin/node", mb: 26, startedAfter: 2),   // MCP server, starts with the session
        ])
        let session = groups.first { $0.kind == .claudeSession }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.processCount, 2)
        XCTAssertEqual(session?.memory, 276 * mb)
        XCTAssertEqual(session?.name, "shop-app")
        XCTAssertEqual(session?.sessionTitle, "Fix checkout")
        XCTAssertTrue(session?.fromDesktop ?? false)
        XCTAssertNil(session?.runningTask, "helpers started with the session don't count as work")
    }

    func testSessionRunningACommandIsMarkedBusy() {
        let groups = group([
            proc(10, parent: 1, "/Applications/Claude.app/Contents/Helpers/disclaimer"),
            proc(12, parent: 10, "/Users/test/Library/Application Support/Claude/claude-code/2.1/x/claude.app/Contents/MacOS/claude"),
            proc(14, parent: 12, "/bin/zsh", startedAfter: 600),
        ])
        let session = groups.first { $0.kind == .claudeSession }
        XCTAssertEqual(session?.runningTask, "zsh", "a command started later means the session is busy — never auto-pause it")
    }

    func testTerminalSessionIsNotFromTheDesktopApp() {
        let groups = group([
            proc(20, parent: 1, "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            proc(21, parent: 20, "/bin/zsh"),
            proc(22, parent: 21, "/Users/test/.local/share/claude-code/2.1/x/claude.app/Contents/MacOS/claude"),
        ])
        XCTAssertEqual(groups.first { $0.kind == .claudeSession }?.fromDesktop, false)
    }

    func testNativeInstallerSessionInATerminalIsRecognised() {
        // The terminal install runs as ~/.local/share/claude/versions/<version>, so its name is a version number.
        var claude = proc(62, parent: 61, "/Users/test/.local/share/claude/versions/2.1.292", mb: 240)
        claude.tty = 0x1000003
        let groups = group([
            proc(60, parent: 1, "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            proc(61, parent: 60, "/bin/zsh"),
            claude,
            proc(63, parent: 62, "/opt/homebrew/bin/uvx", mb: 30, startedAfter: 1),
        ])
        let session = groups.first { $0.kind == .claudeSession }
        XCTAssertNotNil(session, "native-installer Claude Code must count as a session")
        XCTAssertEqual(session?.memory, 270 * mb, "its MCP helpers (uvx) belong to it")
        XCTAssertEqual(session?.fromDesktop, false)
        XCTAssertNotNil(session?.tty, "terminal sessions remember their terminal, to print how to resume")
    }

    func testNpmInstalledClaudeCodeIsRecognised() {
        let s = scanner()
        s.argsProvider = { pid in pid == 72 ? ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"] : ["node", "server.js"] }
        let procs = [
            proc(71, parent: 1, "/bin/zsh"),
            proc(72, parent: 71, "/opt/homebrew/bin/node", mb: 200),
            proc(73, parent: 72, "/opt/homebrew/bin/node", mb: 25, startedAfter: 1),
        ]
        let groups = s.group(Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })).groups
        let session = groups.first { $0.kind == .claudeSession }
        XCTAssertEqual(session?.processCount, 2)
        XCTAssertEqual(session?.memory, 225 * mb)
    }

    func testScriptStartedFromATerminalStandsAlone() {
        let groups = group([
            proc(30, parent: 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            proc(31, parent: 30, "/bin/zsh"),
            proc(32, parent: 31, "/opt/homebrew/bin/node", mb: 150),
        ])
        let script = groups.first { $0.kind == .script }
        XCTAssertEqual(script?.name, "node · bots/run.mjs")
        XCTAssertEqual(script?.memory, 150 * mb)
    }

    func testHelperLaunchedByAnAppCountsTowardsThatApp() {
        let groups = group([
            proc(40, parent: 1, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", mb: 200),
            proc(41, parent: 40, "/opt/homebrew/bin/node", mb: 80),
        ])
        let app = groups.first { $0.kind == .app }
        XCTAssertEqual(app?.memory, 280 * mb)
        XCTAssertFalse(groups.contains { $0.kind == .script })
    }

    func testSystemProcessesAreNeverActionable() {
        let groups = group([
            proc(50, parent: 1, "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            proc(51, parent: 1, "/usr/libexec/logd", uid: 0),
        ])
        XCTAssertEqual(groups.filter { $0.kind != .system }.count, 0)
        XCTAssertEqual(groups.first { $0.kind == .system }?.processCount, 2)
    }
}

final class HelperTests: XCTestCase {
    func testOuterBundle() {
        XCTAssertEqual(outerBundle("/Applications/Google Chrome.app/Contents/Frameworks/X.app/Contents/MacOS/X"), "/Applications/Google Chrome.app")
        XCTAssertNil(outerBundle("/usr/bin/node"))
    }

    func testVersionComparison() {
        XCTAssertTrue(Updates.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(Updates.isNewer("1.3.1", than: "1.3"))
        XCTAssertFalse(Updates.isNewer("1.3.0", than: "1.3.0"))
    }

    func testByteFormatting() {
        XCTAssertEqual(fmtBytes(1_073_741_824), "1.0 GB")
        XCTAssertEqual(fmtBytes(524_288_000), "500 MB")
    }

    func testHealth() {
        var s = MemorySnapshot()
        XCTAssertEqual(s.health, .healthy)
        s.pressureLevel = 4
        XCTAssertEqual(s.health, .critical)
    }
}
