import AudioToolbox
import CoreAudio
import Foundation

public struct CoreAudioError: Error, LocalizedError, Sendable {
    public let operation: String
    public let status: OSStatus

    public init(_ operation: String, _ status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var errorDescription: String? {
        "\(operation) failed (OSStatus \(status)\(fourCC.map { " '\($0)'" } ?? ""))"
    }

    private var fourCC: String? {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(operation(), status) }
}

enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Get property \(selector)")
        return value
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Get size \(selector)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: initial, count: count)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values), "Get array \(selector)")
        return values
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Get string \(selector)")
        return value?.takeRetainedValue() as String?
    }
}

/// One process known to the Core Audio HAL (only processes that have touched audio appear).
public struct AudioProcessInfo: Sendable, Hashable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool
}

public enum AudioProcessInspector {
    /// All processes the HAL currently tracks.
    public static func processes() -> [AudioProcessInfo] {
        let ids = (try? CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, initial: AudioObjectID(0))) ?? []
        return ids.compactMap { id in
            guard let pid = try? CoreAudioProperty.scalar(id, kAudioProcessPropertyPID, initial: pid_t(0)) else { return nil }
            let bundleID = try? CoreAudioProperty.string(id, kAudioProcessPropertyBundleID)
            let input = (try? CoreAudioProperty.scalar(id, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) ?? 0
            let output = (try? CoreAudioProperty.scalar(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcessInfo(objectID: id, pid: pid, bundleID: bundleID ?? nil, isRunningInput: input != 0, isRunningOutput: output != 0)
        }
    }

    /// Processes belonging to an app family: the main app plus helpers (Chrome/Teams/Slack play audio from helper processes).
    public static func processes(in family: AppAudioFamily) -> [AudioProcessInfo] {
        processes().filter { family.contains($0) }
    }
}

/// Identifies every process that plays audio on behalf of one app.
public struct AppAudioFamily: Sendable, Hashable, Codable {
    /// Bundle ID prefixes, e.g. "com.google.Chrome" matches "com.google.Chrome.helper".
    public var bundlePrefixes: [String]
    /// Extra PIDs (e.g. the app's main PID when it has no bundle ID in the HAL).
    public var pids: [Int32]

    public init(bundlePrefixes: [String], pids: [Int32] = []) {
        self.bundlePrefixes = bundlePrefixes
        self.pids = pids
    }

    public func contains(_ process: AudioProcessInfo) -> Bool {
        if pids.contains(process.pid) { return true }
        guard let bundleID = process.bundleID?.lowercased() else { return false }
        return bundlePrefixes.contains { prefix in
            let p = prefix.lowercased()
            return bundleID == p || bundleID.hasPrefix(p + ".")
        }
    }

    /// True when two families would capture any of the same processes, i.e. audio can't be separated.
    public func overlaps(_ other: AppAudioFamily) -> Bool {
        if !Set(pids).isDisjoint(with: other.pids) { return true }
        return bundlePrefixes.contains { a in
            other.bundlePrefixes.contains { b in
                let a = a.lowercased(), b = b.lowercased()
                return a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
            }
        }
    }
}

enum AudioDevices {
    static func defaultOutputDeviceID() throws -> AudioDeviceID {
        try CoreAudioProperty.scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioDeviceID(0))
    }

    static func uid(of device: AudioDeviceID) throws -> String {
        guard let uid = try CoreAudioProperty.string(device, kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError("Read device UID", kAudioHardwareUnknownPropertyError)
        }
        return uid
    }
}
