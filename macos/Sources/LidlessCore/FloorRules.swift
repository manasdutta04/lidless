import Foundation

/// Pure safety-floor decision (spec/floors.md, vectors/floors.json).
public struct FloorDecision: Sendable, Equatable {
    public var end: EndReason?
    public var wantLowPower: Bool

    public init(end: EndReason?, wantLowPower: Bool) {
        self.end = end
        self.wantLowPower = wantLowPower
    }
}

public enum FloorRules {
    public static func decide(
        onBattery: Bool,
        percent: Int?,
        unreadableCount: Int,
        thermal: ThermalLevel,
        lidClosed: Bool,
        config: Config
    ) -> FloorDecision {
        let c = config.normalized()
        var end: EndReason?
        var wantLowPower = false

        if onBattery {
            if let p = percent {
                if p < c.lowPowerBelowPercent { wantLowPower = true }
                if c.endBelowPercent > 0 && p < c.endBelowPercent { end = .batteryFloor }
            } else if unreadableCount >= 2 {
                end = .batteryUnreadable
            }
            if lidClosed && c.lowPowerOnLidClose { wantLowPower = true }
            if c.thermalRules && (thermal == .serious || thermal == .critical) { wantLowPower = true }
        }

        if c.thermalRules && thermal == .critical && end == nil {
            end = .thermalFloor
        }
        return FloorDecision(end: end, wantLowPower: wantLowPower)
    }
}
