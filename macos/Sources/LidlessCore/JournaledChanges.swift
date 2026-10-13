import Foundation

public struct RestoreReport: Sendable, Equatable {
    public var restored: [String] = []
    public var failures: [String] = []
    public var complete: Bool { failures.isEmpty }

    public init() {}
}

public enum SleepEngageOutcome: Sendable, Equatable {
    /// We changed SleepDisabled 0 → 1 and journaled it.
    case changedByUs
    /// It was already 1; something else owns it and we will not restore it.
    case alreadyDisabled
}

/// Every system change Lidless makes on macOS goes through here, following
/// the change protocol in spec/journal.md: lock → read current → journal the
/// original → change. Restore only ever writes a journaled original.
public struct JournaledChanges: Sendable {
    public let store: Store
    public let power: PowerControlling
    public let now: @Sendable () -> Date
    public let lockTimeout: TimeInterval

    public init(store: Store, power: PowerControlling, now: @escaping @Sendable () -> Date = { Date() }, lockTimeout: TimeInterval = 30) {
        self.store = store
        self.power = power
        self.now = now
        self.lockTimeout = lockTimeout
    }

    // MARK: Sleep

    public func disableSleep() async throws -> SleepEngageOutcome {
        try await withStateLock {
            let current: Bool
            do {
                current = try await power.readSleepDisabled()
            } catch {
                throw LidlessError.verificationFailed("Could not read the current sleep setting, so Lidless did not change it: \(error)")
            }
            if current {
                Log.warn("SleepDisabled was already 1 before this session; leaving ownership with whoever set it")
                return .alreadyDisabled
            }
            var journal = try store.readJournal()
            if journal.macos.sleepDisabled == nil {
                journal.macos.sleepDisabled = BoolEntry(original: false, recordedAt: now())
            }
            try store.writeJournal(journal, now: now())
            Log.info("journaled sleepDisabled(original=0); running pmset -a disablesleep 1")
            let r = await power.setSleepDisabled(true)
            guard r.succeeded else {
                throw LidlessError.notReady(Self.describeFailure("sudo -n pmset -a disablesleep 1", r))
            }
            return .changedByUs
        }
    }

    // MARK: Low Power Mode

    /// Turns battery Low Power Mode on if it is off. Returns true when Lidless
    /// now owns it (journal entry present).
    @discardableResult
    public func enableLowPower() async throws -> Bool {
        try await withStateLock {
            var journal = try store.readJournal()
            if journal.macos.lowPowerMode != nil { return true }
            let current = try await power.readLowPowerMode()
            if current { return false }
            journal.macos.lowPowerMode = BoolEntry(original: false, recordedAt: now())
            try store.writeJournal(journal, now: now())
            Log.info("journaled lowPowerMode(original=0); running pmset -b lowpowermode 1")
            let r = await power.setLowPowerMode(true)
            guard r.succeeded else {
                throw LidlessError.system(Self.describeFailure("sudo -n pmset -b lowpowermode 1", r))
            }
            return true
        }
    }

    /// Restores Low Power Mode only if Lidless turned it on.
    public func releaseLowPower() async throws -> RestoreReport {
        try await withStateLock {
            var report = RestoreReport()
            try await restoreLowPowerLocked(&report)
            return report
        }
    }

    // MARK: Restore everything

    /// Undoes every journal entry (Low Power Mode first, then sleep). Entries
    /// whose undo fails stay in the journal for the next recovery run.
    public func restoreAll() async -> RestoreReport {
        do {
            return try await withStateLock {
                var report = RestoreReport()
                try await restoreLowPowerLocked(&report)
                try await restoreSleepLocked(&report)
                return report
            }
        } catch {
            var report = RestoreReport()
            report.failures.append("\(error)")
            return report
        }
    }

    /// Callers that already hold the lock (recovery) use this.
    public func restoreAllLocked() async -> RestoreReport {
        var report = RestoreReport()
        do {
            try await restoreLowPowerLocked(&report)
            try await restoreSleepLocked(&report)
        } catch {
            report.failures.append("\(error)")
        }
        return report
    }

    private func restoreLowPowerLocked(_ report: inout RestoreReport) async throws {
        var journal = try store.readJournal()
        guard let entry = journal.macos.lowPowerMode else { return }
        let current = try? await power.readLowPowerMode()
        if current == entry.original {
            journal.macos.lowPowerMode = nil
            try store.writeJournal(journal, now: now())
            report.restored.append("lowPowerMode (already \(entry.original ? 1 : 0))")
            return
        }
        let r = await power.setLowPowerMode(entry.original)
        if r.succeeded {
            journal.macos.lowPowerMode = nil
            try store.writeJournal(journal, now: now())
            report.restored.append("lowPowerMode → \(entry.original ? 1 : 0)")
            Log.info("restored lowPowerMode to \(entry.original ? 1 : 0)")
        } else {
            let msg = Self.describeFailure("sudo -n pmset -b lowpowermode \(entry.original ? 1 : 0)", r)
            report.failures.append(msg)
            Log.error(msg)
        }
    }

    private func restoreSleepLocked(_ report: inout RestoreReport) async throws {
        var journal = try store.readJournal()
        guard let entry = journal.macos.sleepDisabled else { return }
        let current = try? await power.readSleepDisabled()
        if current == entry.original {
            journal.macos.sleepDisabled = nil
            try store.writeJournal(journal, now: now())
            report.restored.append("sleepDisabled (already \(entry.original ? 1 : 0))")
            return
        }
        let r = await power.setSleepDisabled(entry.original)
        if r.succeeded {
            journal.macos.sleepDisabled = nil
            try store.writeJournal(journal, now: now())
            report.restored.append("sleepDisabled → \(entry.original ? 1 : 0)")
            Log.info("restored SleepDisabled to \(entry.original ? 1 : 0)")
        } else {
            let msg = Self.describeFailure("sudo -n pmset -a disablesleep \(entry.original ? 1 : 0)", r)
            report.failures.append(msg)
            Log.error(msg)
        }
    }

    // MARK: Helpers

    func withStateLock<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try store.paths.ensureHome()
        let lock = FileLock(url: store.paths.lock)
        try lock.lock(timeout: lockTimeout)
        defer { lock.unlock() }
        return try await body()
    }

    static func describeFailure(_ command: String, _ r: CommandResult) -> String {
        if let pid = r.stillRunningPid {
            return "`\(command)` did not finish within \(Int(PmsetPowerControl.privilegedTimeout)) s and is still running as pid \(pid). Lidless kept its journal entry. If it stays stuck: sudo kill \(pid)"
        }
        if r.timedOut {
            return "`\(command)` timed out and was stopped. Lidless kept its journal entry and will retry."
        }
        let err = r.stderr.trimmed
        if err.contains("password is required") || err.contains("a terminal is required") {
            return "`\(command)` needs a password, so the Lidless sudoers rule is missing or out of date. Run scripts/install.sh, then `lidless doctor`."
        }
        return "`\(command)` failed (status \(r.status))\(err.isEmpty ? "" : ": \(err)")"
    }
}
