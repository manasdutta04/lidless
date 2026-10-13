import Foundation

/// Parses and formats durations per spec/session.md ("2h", "90m", "1d2h", "45").
public enum DurationParser {
    private static let units: [(Character, Int)] = [("d", 86_400), ("h", 3_600), ("m", 60), ("s", 1)]

    public static func parse(_ raw: String) throws -> TimeInterval {
        let input = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !input.isEmpty else { throw LidlessError.usage("Duration is empty. Try 2h, 90m or 1d2h.") }

        if input.allSatisfy(\.isASCIIDigit) {
            guard let minutes = Int(input), minutes > 0 else {
                throw LidlessError.usage("Duration must be greater than zero.")
            }
            return TimeInterval(minutes) * 60
        }

        var total = 0
        var number = ""
        var nextUnitIndex = 0
        var sawPart = false
        for ch in input {
            if ch.isASCIIDigit {
                number.append(ch)
            } else if ch == " " {
                guard number.isEmpty else { throw invalid(raw) }
            } else if let idx = units.firstIndex(where: { $0.0 == ch }) {
                guard !number.isEmpty, idx >= nextUnitIndex, let n = Int(number) else { throw invalid(raw) }
                let (product, overflow) = n.multipliedReportingOverflow(by: units[idx].1)
                guard !overflow else { throw invalid(raw) }
                total += product
                number = ""
                nextUnitIndex = idx + 1
                sawPart = true
            } else {
                throw invalid(raw)
            }
        }
        guard number.isEmpty, sawPart else { throw invalid(raw) }
        guard total > 0 else { throw LidlessError.usage("Duration must be greater than zero.") }
        return TimeInterval(total)
    }

    private static func invalid(_ raw: String) -> LidlessError {
        .usage("Invalid duration \"\(raw)\". Use units d, h, m, s in that order, e.g. 2h, 90m, 1d2h, 1h 30m.")
    }

    /// "1d 2h", "1h 30m", "45m", "30s".
    public static func format(_ seconds: TimeInterval) -> String {
        var s = max(0, Int(seconds.rounded()))
        if s == 0 { return "0s" }
        let d = s / 86_400; s %= 86_400
        let h = s / 3_600; s %= 3_600
        let m = s / 60; s %= 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if s > 0 && d == 0 && h == 0 { parts.append("\(s)s") }
        return parts.isEmpty ? "0s" : parts.joined(separator: " ")
    }

    /// Countdown clock: "1:02:03" or "2d 3:04:05".
    public static func clock(_ seconds: TimeInterval) -> String {
        var s = max(0, Int(seconds.rounded(.up)))
        let d = s / 86_400; s %= 86_400
        let h = s / 3_600; s %= 3_600
        let m = s / 60; s %= 60
        let hms = String(format: "%d:%02d:%02d", h, m, s)
        return d > 0 ? "\(d)d \(hms)" : hms
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
