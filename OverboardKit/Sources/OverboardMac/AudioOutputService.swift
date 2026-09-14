import CoreAudio
import Foundation
import os
import OverboardCore

/// Lists and switches the Mac's audio output device via CoreAudio's public
/// HAL API — unlike `SystemActionService`'s lock, nothing here is private.
///
/// nonisolated: the module defaults to the main actor, but `devices()` is
/// called from `AudioOutputSearchProvider`'s closure, which runs off the main
/// actor inside `QueryRouter`'s task group. Every entry point below touches
/// only lock-guarded state or makes its own CoreAudio calls, so the type
/// carries no actor isolation at all.
public final nonisolated class AudioOutputService: @unchecked Sendable {
    public static let shared = AudioOutputService()

    /// nil means "not fetched yet, or invalidated" — `devices()` re-scans on
    /// the next call. CoreAudio's own property listeners (below) invalidate
    /// this on any device or default-output change, so a mid-session AirPods
    /// connect is picked up without polling.
    private let cache = OSAllocatedUnfairLock<[AudioOutputDevice]?>(initialState: nil)

    private init() {
        self.installListeners()
    }

    /// Every device with at least one output stream, current default marked.
    public func devices() -> [AudioOutputDevice] {
        if let cached = self.cache.withLock({ $0 }) {
            return cached
        }
        let fetched = Self.fetchDevices()
        self.cache.withLock { $0 = fetched }
        return fetched
    }

    /// Makes `device` the system's default audio output.
    public func setDefaultOutput(_ device: AudioOutputDevice) throws {
        var deviceID = device.id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
        guard status == noErr else {
            throw AudioOutputError.setDefaultFailed(status: status)
        }
        self.cache.withLock { $0 = nil }
    }

    // MARK: - Enumeration

    private static func fetchDevices() -> [AudioOutputDevice] {
        let defaultID = self.defaultOutputDeviceID()
        return self.allDeviceIDs().compactMap { id in
            guard self.hasOutputStreams(id), let name = self.name(of: id) else { return nil }
            return AudioOutputDevice(id: id, name: name, isDefault: id == defaultID)
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        )
        return status == noErr ? deviceIDs : []
    }

    /// A device counts as an audio output if it has at least one stream in
    /// the output scope — the same test System Settings' Sound pane uses to
    /// decide what belongs in its output list.
    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr else { return false }
        return dataSize > 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, pointer)
        }
        return status == noErr ? (name as String) : nil
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    // MARK: - Invalidation

    /// Invalidates the cache on any device list change (a USB interface or
    /// AirPods connecting/disconnecting) or default-output change (Control
    /// Center, another app) — cheap, since it just clears a flag for the next
    /// `devices()` call to re-scan.
    private func installListeners() {
        let invalidate: AudioObjectPropertyListenerBlock = { [cache] _, _ in
            cache.withLock { $0 = nil }
        }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, .main, invalidate)

        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, .main, invalidate
        )
    }
}

public enum AudioOutputError: Error {
    case setDefaultFailed(status: OSStatus)
}
