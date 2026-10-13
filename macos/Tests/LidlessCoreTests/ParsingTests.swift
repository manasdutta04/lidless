import Foundation
import Testing
@testable import LidlessCore

struct PmsetParsingTests {
    let header = "System-wide power settings:\nCurrently in use:\n standby              1\n"

    @Test func sleepDisabledOn() {
        #expect(PmsetParser.sleepDisabled(fromPmsetG: header + " SleepDisabled\t\t1\n sleep 1\n") == true)
    }

    @Test func sleepDisabledOffExplicit() {
        #expect(PmsetParser.sleepDisabled(fromPmsetG: header + " SleepDisabled  0\n") == false)
    }

    @Test func sleepDisabledLineAbsentMeansOff() {
        // macOS 27 omits the line when the setting is 0.
        #expect(PmsetParser.sleepDisabled(fromPmsetG: header + " sleep 1 (sleep prevented by powerd)\n") == false)
    }

    @Test func garbageIsUnreadable() {
        #expect(PmsetParser.sleepDisabled(fromPmsetG: "") == nil)
        #expect(PmsetParser.sleepDisabled(fromPmsetG: "pmset: error") == nil)
        #expect(PmsetParser.sleepDisabled(fromPmsetG: header + " SleepDisabled x\n") == nil)
    }

    @Test func batteryLowPowerMode() {
        let out = "Battery Power:\n lowpowermode         1\n sleep 1\nAC Power:\n lowpowermode         0\n"
        #expect(PmsetParser.batteryLowPowerMode(fromPmsetCustom: out) == true)
        let out2 = "AC Power:\n lowpowermode 1\nBattery Power:\n lowpowermode 0\n"
        #expect(PmsetParser.batteryLowPowerMode(fromPmsetCustom: out2) == false)
        #expect(PmsetParser.batteryLowPowerMode(fromPmsetCustom: "AC Power:\n lowpowermode 1\n") == nil)
    }
}

struct AgentMatchTests {
    let names = AgentDetector.builtInNames

    @Test func nativeBinary() {
        #expect(AgentDetector.match(executable: "/Users/x/.local/bin/claude", arguments: ["claude"], names: names) == "claude")
        #expect(AgentDetector.match(executable: "/opt/homebrew/bin/codex", arguments: ["codex"], names: names) == "codex")
    }

    @Test func nodeScripts() {
        #expect(AgentDetector.match(executable: "/opt/homebrew/bin/node",
                                    arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"], names: names) == "claude")
        #expect(AgentDetector.match(executable: "/usr/local/bin/node", arguments: ["node", "/usr/local/bin/gemini"], names: names) == "gemini")
        #expect(AgentDetector.match(executable: "/usr/bin/python3", arguments: ["python3", "-m", "http.server"], names: names) == nil)
    }

    @Test func unrelated() {
        #expect(AgentDetector.match(executable: "/bin/zsh", arguments: ["zsh"], names: names) == nil)
        #expect(AgentDetector.match(executable: "/opt/homebrew/bin/node", arguments: ["node", "server.js"], names: names) == nil)
    }
}

struct ConfigTests {
    @Test func missingKeysTakeDefaults() throws {
        let c = try LidlessJSON.decoder().decode(Config.self, from: Data(#"{"endBelowPercent": 5}"#.utf8))
        #expect(c.endBelowPercent == 5)
        #expect(c.lowPowerBelowPercent == 40)
        #expect(c.maxDurationSeconds == 30 * 86_400)
    }

    @Test func crossedFloorsAreFixed() {
        var c = Config()
        c.endBelowPercent = 30
        c.lowPowerBelowPercent = 20
        #expect(c.normalized().lowPowerBelowPercent == 31)
    }

    @Test func maxDurationCappedAt30Days() {
        var c = Config()
        c.maxDurationSeconds = 400 * 86_400
        #expect(c.normalized().maxDurationSeconds == 30 * 86_400)
    }
}
