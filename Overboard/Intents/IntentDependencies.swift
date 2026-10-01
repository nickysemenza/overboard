import Foundation
import OverboardCore
import OverboardMac

/// The slice of the running app that the App Intents need.
///
/// App Intents are instantiated by the system — Shortcuts, Siri, Spotlight
/// actions — and never by us, so there's no initializer to inject through and
/// the seam has to be type-level. `current` resolves from `AppServices.shared`
/// the first time it's read (a `static var`'s initializer is lazy, so nothing
/// builds the object graph just because this file exists) and can be replaced
/// wholesale to run an intent's body against a scratch store.
struct IntentDependencies {
    var store: ClipStore
    var pasteback: PastebackService
    /// Marker-tagged copy + HUD — the same path the launcher's ⌘↩ takes, so a
    /// shortcut's copy doesn't re-enter history.
    var copyString: (String, String) async throws -> Void
    var checkLibrary: () throws -> Void = {}
    var showLauncher: () -> Void
    var showDrawer: () -> Void
    var setCapturePaused: (Bool) -> Void

    /// Swappable seam; the running app's composition root by default.
    static var current: IntentDependencies = .live()

    static func ensureLibraryAvailable() throws {
        try self.current.checkLibrary()
    }

    private static func live() -> IntentDependencies {
        let services = AppServices.shared
        return IntentDependencies(
            store: services.store,
            pasteback: services.pasteback,
            copyString: { text, hud in
                switch await services.actions.copyStringAndWait(text, hud: hud) {
                case .copied: return
                case .cancelled: throw CancellationError()
                case .dispatched, .failed: throw IntentDeliveryError.failed
                }
            },
            checkLibrary: {
                guard services.libraryRecovery == nil else { throw IntentDeliveryError.libraryUnavailable }
            },
            showLauncher: {
                guard services.isStarted else { return }
                services.launcher.show()
            },
            showDrawer: {
                guard services.isStarted else { return }
                services.overlay.show()
            },
            setCapturePaused: { services.setCapturePaused($0) }
        )
    }
}

enum IntentDeliveryError: LocalizedError {
    case failed
    case libraryUnavailable

    var errorDescription: String? {
        switch self {
        case .failed: "Clipboard publication did not complete. Try again."
        case .libraryUnavailable: "The Overboard library needs recovery. Open Overboard for recovery options."
        }
    }
}
