import Foundation
import IOKit
import IOKit.ps

public enum ThermalLevel: String, Codable, Sendable, Comparable {
    case nominal, fair, serious, critical

    private var rank: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rank < b.rank }

    /// Warm enough that the user should be reminded about ventilation.
    public var isWarm: Bool { self >= .fair }

    /// Plain-language heat warning for the start flow, or nil when cool.
    public var startWarning: String? {
        switch self {
        case .nominal: return nil
        case .fair: return "Your Mac is already warm. Closing the lid holds in more heat, so keep it on a hard, open surface."
        case .serious: return "Your Mac is running hot. Closing the lid holds in more heat. Make sure it has open air around it, and consider waiting until it cools down."
        case .critical: return "Your Mac is too hot to keep running with the lid closed. Let it cool down first."
        }
    }

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

public struct BatteryReading: Sendable, Equatable {
    /// False on desktops.
    public var hasBattery: Bool
    public var onBattery: Bool
    /// nil when a battery exists but its level could not be read.
    public var percent: Int?

    public init(hasBattery: Bool, onBattery: Bool, percent: Int?) {
        self.hasBattery = hasBattery
        self.onBattery = onBattery
        self.percent = percent
    }
}

public protocol SystemSensing: Sendable {
    func battery() -> BatteryReading
    func thermal() -> ThermalLevel
    /// nil when the machine has no lid (or the state cannot be read).
    func lidClosed() -> Bool?
}

public struct SystemSensors: SystemSensing {
    public init() {}

    public func battery() -> BatteryReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryReading(hasBattery: false, onBattery: false, percent: nil)
        }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPMBatteryPowerKey
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let present = (desc[kIOPSIsPresentKey] as? Bool) ?? true
            guard present else { continue }
            var percent: Int?
            if let cur = desc[kIOPSCurrentCapacityKey] as? Int, let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percent = Int((Double(cur) / Double(max) * 100).rounded())
            }
            return BatteryReading(hasBattery: true, onBattery: onBattery, percent: percent)
        }
        return BatteryReading(hasBattery: false, onBattery: false, percent: nil)
    }

    public func thermal() -> ThermalLevel {
        ThermalLevel(ProcessInfo.processInfo.thermalState)
    }

    public func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }
}
