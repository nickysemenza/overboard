import Foundation

/// One CoreAudio output device, as surfaced by OverboardMac's
/// `AudioOutputService`. Core holds only the plain identifiers a row needs to
/// render and re-select a device — it has no CoreAudio dependency itself.
public struct AudioOutputDevice: Sendable, Equatable, Identifiable {
    /// The device's `AudioDeviceID`, boxed as `UInt32` so Core doesn't need to
    /// import CoreAudio for its own typedef.
    public let id: UInt32
    public let name: String
    public let isDefault: Bool

    public init(id: UInt32, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}
