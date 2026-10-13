import Foundation
import Testing
@testable import LidlessCore

struct SpecVectorTests {
    @Test func durations() throws {
        let v = try #require(try loadVector("durations.json") as? [String: Any])
        let valid = try #require(v["valid"] as? [[String: Any]])
        for c in valid {
            let input = c["input"] as! String
            let seconds = (c["seconds"] as! NSNumber).doubleValue
            #expect(try DurationParser.parse(input) == seconds, "\(input)")
        }
        let invalid = try #require(v["invalid"] as? [String])
        for input in invalid {
            #expect(throws: LidlessError.self, "\(input)") { try DurationParser.parse(input) }
        }
    }

    @Test func floors() throws {
        let v = try #require(try loadVector("floors.json") as? [String: Any])
        let base = try #require(v["defaultConfig"] as? [String: Any])
        for c in try #require(v["cases"] as? [[String: Any]]) {
            var merged = base
            (c["config"] as? [String: Any])?.forEach { merged[$0.key] = $0.value }
            let config = try LidlessJSON.decoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: merged))
            let decision = FloorRules.decide(
                onBattery: c["onBattery"] as! Bool,
                percent: (c["percent"] as? NSNumber)?.intValue,
                unreadableCount: (c["unreadable"] as! NSNumber).intValue,
                thermal: ThermalLevel(rawValue: c["thermal"] as! String)!,
                lidClosed: c["lidClosed"] as! Bool,
                config: config
            )
            let name = c["name"] as! String
            #expect(decision.end?.rawValue == c["end"] as? String, "\(name)")
            #expect(decision.wantLowPower == c["wantLowPower"] as! Bool, "\(name)")
        }
    }

    @Test func durationFormatting() {
        #expect(DurationParser.format(5400) == "1h 30m")
        #expect(DurationParser.format(93600) == "1d 2h")
        #expect(DurationParser.format(30) == "30s")
        #expect(DurationParser.clock(3661) == "1:01:01")
        #expect(DurationParser.clock(90061) == "1d 1:01:01")
    }
}
