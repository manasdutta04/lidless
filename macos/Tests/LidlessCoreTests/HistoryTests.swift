import Foundation
import Testing
@testable import LidlessCore

struct HistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(_ start: TimeInterval, _ length: TimeInterval, lid: TimeInterval = 0,
               reason: EndReason = .expired, clean: Bool = true) -> HistoryEntry {
        HistoryEntry(id: UUID(), startedAt: t0.addingTimeInterval(start), endedAt: t0.addingTimeInterval(start + length),
                     reason: reason, closedLidSeconds: lid, owner: .app, command: nil, restoreComplete: clean)
    }

    @Test func statsTotals() {
        let entries = [entry(0, 3_600, lid: 1_800), entry(7_200, 600, reason: .batteryFloor, clean: false), entry(9_000, 1_200)]
        let s = UsageStats.compute(entries, now: t0.addingTimeInterval(10_000))
        #expect(s.sessions == 3)
        #expect(s.totalAwakeSeconds == 5_400)
        #expect(s.closedLidSeconds == 1_800)
        #expect(s.longestSeconds == 3_600)
        #expect(s.averageSeconds == 1_800)
        #expect(s.endedBySafety == 1)
        #expect(s.cleanRestorePercent == 67)
        #expect(s.lastSevenDays.count == 7)
        #expect(abs(s.lastSevenDays.map(\.awakeSeconds).reduce(0, +) - 5_400) < 0.001)
    }

    @Test func emptyStats() {
        let s = UsageStats.compute([], now: t0)
        #expect(s.sessions == 0 && s.cleanRestorePercent == nil && s.firstSession == nil)
    }

    @Test func sessionAcrossMidnightIsSplitByDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let midnight = cal.startOfDay(for: t0).addingTimeInterval(86_400)
        let e = HistoryEntry(id: UUID(), startedAt: midnight.addingTimeInterval(-3_600), endedAt: midnight.addingTimeInterval(1_800),
                             reason: .expired, closedLidSeconds: 0, owner: .cli, command: nil, restoreComplete: true)
        let s = UsageStats.compute([e], now: midnight.addingTimeInterval(7_200), calendar: cal)
        #expect(s.lastSevenDays[5].awakeSeconds == 3_600)
        #expect(s.lastSevenDays[6].awakeSeconds == 1_800)
    }

    @Test func dailyAndHourly() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = cal.startOfDay(for: t0)
        // 09:30–11:15 on one day.
        let e = HistoryEntry(id: UUID(), startedAt: day.addingTimeInterval(9.5 * 3_600), endedAt: day.addingTimeInterval(11.25 * 3_600),
                             reason: .expired, closedLidSeconds: 0, owner: .app, command: nil, restoreComplete: true)
        let days = UsageStats.daily([e], days: 84, now: day.addingTimeInterval(20 * 3_600), calendar: cal)
        #expect(days.count == 84)
        #expect(days.last?.awakeSeconds == 6_300)
        let hours = UsageStats.hourOfDay([e], calendar: cal)
        #expect(hours[9] == 1_800)
        #expect(hours[10] == 3_600)
        #expect(hours[11] == 900)
        #expect(hours.reduce(0, +) == 6_300)
    }

    @Test func appendCapsAndDedupes() throws {
        let h = Harness()
        defer { h.cleanup() }
        let e = entry(0, 60)
        History.append(e, store: h.store)
        History.append(e, store: h.store)
        #expect(History.read(h.store).count == 1)
    }

    @Test func ownerRecordsHistoryWithLidTime() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let owner = await SessionOwner(env: h.env())
        try await owner.start(duration: 3_600, kind: .app)
        h.sensors.lid = true
        _ = await owner.tick(); _ = await owner.tick()
        h.clock.advance(600)
        await owner.end(.stopped)
        let entries = History.read(h.store)
        #expect(entries.count == 1)
        #expect(entries[0].reason == .stopped)
        #expect(entries[0].closedLidSeconds == 600)
    }

    @Test func parsesRealLogFormat() {
        let log = """
        2026-10-13T06:26:19.800Z [21908] INFO session 39474289-BD45-45F2-85D8-99F687996BC7 starting for 30m, owner app pid 21908
        2026-10-13T06:26:25.056Z [21908] INFO session 39474289-BD45-45F2-85D8-99F687996BC7 engaged and verified (SleepDisabled set by Lidless)
        2026-10-13T06:26:40.757Z [21908] INFO lid closed
        2026-10-13T06:36:10.727Z [21908] INFO lid opened
        2026-10-13T06:36:18.272Z [21908] INFO session 39474289-BD45-45F2-85D8-99F687996BC7 ended: stopped; restore complete=true
        2026-10-13T06:41:43.589Z [24092] INFO session 207C8FD2-6AFD-411D-B6DA-27A2B0058148 starting for 1d, owner run pid 24092
        2026-10-13T06:41:48.953Z [24092] INFO session 207C8FD2-6AFD-411D-B6DA-27A2B0058148 engaged and verified (SleepDisabled set by Lidless)
        2026-10-13T06:42:09.019Z [24092] INFO session 207C8FD2-6AFD-411D-B6DA-27A2B0058148 ended: commandExited; restore complete=true
        2026-10-13T07:00:00.000Z [9] INFO session 11111111-1111-1111-1111-111111111111 starting for 5m, owner cli pid 9
        """
        let entries = History.parseLog(log)
        #expect(entries.count == 2)
        #expect(entries[0].reason == .stopped)
        #expect(abs(entries[0].closedLidSeconds - 569.97) < 0.01)
        #expect(abs(entries[0].duration - 593.216) < 0.01)
        #expect(entries[1].reason == .commandExited && entries[1].owner == .run)
    }
}

struct UpdateTests {
    @Test func versionComparison() {
        #expect(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        #expect(UpdateChecker.isNewer("v0.10.0", than: "0.9.3"))
        #expect(UpdateChecker.isNewer("1.0", than: "0.99.99"))
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.1.1"))
        #expect(!UpdateChecker.isNewer("0.2.0-beta", than: "0.2.0"))
    }

    @Test func parsesGitHubRelease() throws {
        let json = #"{"tag_name":"v0.2.0","html_url":"https://github.com/manasdutta04/lidless/releases/tag/v0.2.0","body":"Notes","published_at":"2026-11-01T10:00:00Z","assets":[{"name":"Lidless-0.2.0.zip","browser_download_url":"https://x/z.zip"},{"name":"Lidless-0.2.0.dmg","browser_download_url":"https://x/d.dmg"}]}"#
        let r = try UpdateChecker.parse(Data(json.utf8))
        #expect(r.version == "0.2.0")
        #expect(r.downloadURL?.absoluteString == "https://x/d.dmg")
        #expect(r.downloadName == "Lidless-0.2.0.dmg")
        #expect(r.publishedAt != nil)
    }
}
