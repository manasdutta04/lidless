import Foundation
import Testing
@testable import LidlessCore

struct InstallerTests {
    @Test func sudoersAllowsExactlyFourCommands() {
        let lines = Installer.sudoersLines(user: "manas")
        let rule = lines.last!
        #expect(rule.hasPrefix("manas ALL=(root) NOPASSWD: "))
        let commands = rule.replacingOccurrences(of: "manas ALL=(root) NOPASSWD: ", with: "")
            .components(separatedBy: ", ")
        #expect(commands == [
            "/usr/bin/pmset -a disablesleep 1",
            "/usr/bin/pmset -a disablesleep 0",
            "/usr/bin/pmset -b lowpowermode 1",
            "/usr/bin/pmset -b lowpowermode 0",
        ])
        #expect(lines.dropLast().allSatisfy { $0.hasPrefix("#") })
    }

    @Test func unsafeUserNamesRejected() {
        #expect(Installer.isSafeUserName("manas"))
        #expect(Installer.isSafeUserName("first.last-2"))
        #expect(!Installer.isSafeUserName(""))
        #expect(!Installer.isSafeUserName("ALL"  + " ALL"))
        #expect(!Installer.isSafeUserName("a'b"))
        #expect(!Installer.isSafeUserName("a;rm -rf /"))
        #expect(!Installer.isSafeUserName("-flag"))
        #expect(throws: LidlessError.self) { try Installer.sudoersInstallScript(user: "x y") }
    }

    @Test func rootScriptWritesFixedTextAndValidates() throws {
        let script = try Installer.sudoersInstallScript(user: "manas")
        #expect(script.contains("/usr/sbin/visudo -cf \"$T\""))
        #expect(script.contains("/usr/bin/install -m 0440 -o root -g wheel \"$T\" /etc/sudoers.d/lidless"))
        #expect(script.contains("mktemp /private/tmp/lidless-sudoers."))
        // Validation must come before install, and the text must not contain
        // a quote that could break out of the printf arguments.
        let v = script.range(of: "visudo")!.lowerBound
        let i = script.range(of: "/usr/bin/install")!.lowerBound
        #expect(v < i)
        for line in Installer.sudoersLines(user: "manas") { #expect(!line.contains("'")) }
    }

    @Test func appleScriptQuotingEscapes() {
        #expect(Installer.appleScriptQuoted(#"a "b" \c"#) == #""a \"b\" \\c""#)
    }

    @Test func launchAgentRunsRecoverEveryMinute() throws {
        let data = try Installer.launchAgentPlist(cliPath: "/Applications/Lidless.app/Contents/Helpers/lidless")
        let dict = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(dict["Label"] as? String == LaunchAgentInfo.label)
        #expect(dict["ProgramArguments"] as? [String] == ["/Applications/Lidless.app/Contents/Helpers/lidless", "recover"])
        #expect(dict["StartInterval"] as? Int == 60)
        #expect(dict["RunAtLoad"] as? Bool == true)
    }
}
