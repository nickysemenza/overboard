import Foundation

/// Named `NSEvent.keyCode` values for the specific keys the panel
/// controllers (`Overlay/OverlayController`, `Launcher/LauncherPanelController`,
/// `Emoji/EmojiPanelController`) switch on. These are virtual key codes
/// (physical key position, not the character produced), so they're stable
/// across keyboard layouts — exactly why the controllers match on `keyCode`
/// instead of `charactersIgnoringModifiers` for shortcuts.
enum KeyCode: UInt16 {
    case e = 14
    case y = 16
    case one = 18
    case two = 19
    case three = 20
    case four = 21
    case p = 35
    case k = 40
    case comma = 43
    case slash = 44
    case space = 49
    case delete = 51
    case escape = 53
    case returnKey = 36
    case keypadEnter = 76
    case leftArrow = 123
    case rightArrow = 124
    case downArrow = 125
    case upArrow = 126
}
