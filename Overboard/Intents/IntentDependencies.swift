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
    var copyString: (String, String) -> Void
    var showLauncher: () -> Void
    var showDrawer: () -> Void
    var setCapturePaused: (Bool) -> Void

    /// Swappable seam; the running app's composition root by default.
    static var current: IntentDependencies = .live()

    private static func live() -> IntentDependencies {
        let services = AppServices.shared
        return IntentDependencies(
            store: services.store,
            pasteback: services.pasteback,
            copyString: { services.copyString($0, hud: $1) },
            showLauncher: { services.launcher.show() },
            showDrawer: { services.overlay.show() },
            setCapturePaused: { services.setCapturePaused($0) }
        )
    }
}
