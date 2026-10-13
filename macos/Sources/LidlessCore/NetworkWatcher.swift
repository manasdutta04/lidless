import Foundation
import Network

/// Remote control needs a network. Reports when connectivity has been lost
/// for longer than `grace`, and when it comes back.
@MainActor
public final class NetworkWatcher {
    public private(set) var isOnline = true
    private var monitor: NWPathMonitor?
    private var offlineSince: Date?
    private var warned = false
    private let grace: TimeInterval
    private let onChange: @MainActor (_ lost: Bool) -> Void

    public init(grace: TimeInterval = 30, onChange: @escaping @MainActor (_ lost: Bool) -> Void) {
        self.grace = grace
        self.onChange = onChange
    }

    public func start() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "lidless.network"))
        self.monitor = monitor
    }

    public func stop() {
        monitor?.cancel()
        monitor = nil
    }

    private func update(online: Bool) {
        isOnline = online
        if online {
            offlineSince = nil
            if warned {
                warned = false
                onChange(false)
            }
        } else if offlineSince == nil {
            offlineSince = Date()
        }
    }

    /// Called from the owner's tick.
    public func tick(now: Date) {
        guard let since = offlineSince, !warned, now.timeIntervalSince(since) >= grace else { return }
        warned = true
        onChange(true)
    }
}
