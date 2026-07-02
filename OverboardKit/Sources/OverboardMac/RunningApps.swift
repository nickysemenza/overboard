import AppKit

/// Snapshot + change notifications for running regular apps, keyed by bundle
/// URL path (matches AppIndex's canonical /Applications paths).
@MainActor
public final class RunningApps {
    public var onChange: () -> Void = {}
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public func snapshot() -> Set<String> {
        Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleURL?.path }
        )
    }

    public func startObserving() {
        guard self.observers.isEmpty else { return }
        let notificationCenter = NSWorkspace.shared.notificationCenter

        let launchObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onChange()
        }
        let terminateObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onChange()
        }

        self.observers = [launchObserver, terminateObserver]
    }

    public func stopObserving() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in self.observers {
            notificationCenter.removeObserver(observer)
        }
        self.observers.removeAll()
    }
}
