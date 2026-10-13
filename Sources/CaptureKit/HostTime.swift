import AVFoundation
import Darwin
import Foundation

/// Converts Core Audio host times (the hardware capture time of a buffer) to wall-clock dates, so delivery delays
/// under load don't shift where audio lands on the session timeline.
public enum HostTime {
    public static func date(for hostTime: UInt64, now: Date = Date(), nowHostTime: UInt64 = mach_absolute_time()) -> Date {
        guard hostTime > 0 else { return now }
        let age = AVAudioTime.seconds(forHostTime: nowHostTime) - AVAudioTime.seconds(forHostTime: hostTime)
        return now.addingTimeInterval(-age)
    }
}
