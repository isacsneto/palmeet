@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

/// Captures the audio output of one app family through a Core Audio process tap (macOS 14.2+).
///
/// Only the tapped processes are heard; the user keeps hearing them normally (`muteBehavior = .unmuted`).
/// The tap is rebuilt when the app family's process set changes (e.g. Chrome's audio service starts later) or the
/// default output device changes (AirPods connect/disconnect), because the aggregate device is pinned to it.
///
/// Threading: IO callbacks run on `ioQueue`. Everything that creates or destroys Core Audio objects runs on
/// `controlQueue`, so teardown (which waits for in-flight IO) never blocks the IO queue and `stop()` can't race a
/// rebuild.
public final class ProcessTapCapture: @unchecked Sendable {
    /// Receives a buffer and the wall-clock time of its first sample (from the hardware host time).
    public typealias BufferHandler = @Sendable (AVAudioPCMBuffer, Date) -> Void

    public let family: AppAudioFamily
    private let name: String
    private let ioQueue = DispatchQueue(label: "app.palmeet.tap.io", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "app.palmeet.tap.control", qos: .userInitiated)
    private let logger = Logger(subsystem: "app.palmeet", category: "ProcessTap")

    // Only touched on controlQueue.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var processObjects: Set<AudioObjectID> = []
    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var handler: BufferHandler?
    private var running = false
    private var monitor: DispatchSourceTimer?

    public init(family: AppAudioFamily, name: String) {
        self.family = family
        self.name = name
    }

    deinit {
        controlQueue.sync { teardownLocked() }
        monitor?.cancel()
    }

    /// Process objects currently included in the tap.
    public var tappedProcesses: Set<AudioObjectID> { controlQueue.sync { processObjects } }

    /// Starts the tap. `handler` is called on a private serial queue with buffers in the tap's native format;
    /// the buffer memory is only valid for the duration of the call.
    public func start(handler: @escaping BufferHandler) throws {
        try controlQueue.sync {
            self.handler = handler
            running = true
            do {
                try rebuildLocked(processes: currentProcessObjects())
            } catch {
                running = false
                self.handler = nil
                throw error
            }
            startMonitoringLocked()
        }
    }

    /// Stops capture. Waits for any in-progress rebuild, so no tap survives the call.
    public func stop() {
        controlQueue.sync {
            running = false
            monitor?.cancel()
            monitor = nil
            teardownLocked()
            handler = nil
        }
    }

    // MARK: - Internals (controlQueue)

    private func currentProcessObjects() -> Set<AudioObjectID> {
        Set(AudioProcessInspector.processes(in: family).map(\.objectID))
    }

    private func startMonitoringLocked() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            self?.checkForChangesLocked()
        }
        timer.resume()
        monitor = timer
    }

    private func checkForChangesLocked() {
        guard running else { return }
        let latest = currentProcessObjects()
        let output = (try? AudioDevices.defaultOutputDeviceID()) ?? outputDeviceID
        let processesChanged = latest != processObjects && !latest.isEmpty
        let outputChanged = output != outputDeviceID && !processObjects.isEmpty
        guard processesChanged || outputChanged else { return }
        logger.info("Rebuilding tap for \(self.name, privacy: .public): processes \(self.processObjects.count)→\(latest.count), output changed: \(outputChanged)")
        do {
            try rebuildLocked(processes: latest)
        } catch {
            logger.error("Tap rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rebuildLocked(processes: Set<AudioObjectID>) throws {
        teardownLocked()
        processObjects = []
        // An app that hasn't produced audio yet has no HAL process object; the monitor picks it up later.
        guard running, !processes.isEmpty, let handler else { return }

        let description = CATapDescription(stereoMixdownOfProcesses: Array(processes))
        description.uuid = UUID()
        description.name = "PalMeet – \(name)"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        var newProc: AudioDeviceIOProcID?
        do {
            try check(AudioHardwareCreateProcessTap(description, &newTap), "Create process tap")
            let output = try AudioDevices.defaultOutputDeviceID()
            newAggregate = try makeAggregateDevice(tapUUID: description.uuid, outputUID: AudioDevices.uid(of: output))
            var streamDescription = try CoreAudioProperty.scalar(newTap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CoreAudioError("Read tap format", kAudioHardwareUnsupportedOperationError)
            }
            try check(AudioDeviceCreateIOProcIDWithBlock(&newProc, newAggregate, ioQueue) { _, inputData, inputTime, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
                let stamp = inputTime.pointee
                let hasHostTime = stamp.mFlags.contains(.hostTimeValid)
                let time = hasHostTime
                    ? HostTime.date(for: stamp.mHostTime)
                    : Date().addingTimeInterval(-Double(buffer.frameLength) / format.sampleRate)
                handler(buffer, time)
            }, "Create IO proc")
            try check(AudioDeviceStart(newAggregate, newProc), "Start aggregate device")

            tapID = newTap
            aggregateID = newAggregate
            procID = newProc
            processObjects = processes
            outputDeviceID = output
        } catch {
            // Destroy whatever was created so a failing rebuild can't leak devices every retry.
            destroy(tap: newTap, aggregate: newAggregate, proc: newProc)
            throw error
        }
    }

    private func makeAggregateDevice(tapUUID: UUID, outputUID: String) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PalMeet Tap",
            kAudioAggregateDeviceUIDKey: "app.palmeet.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "Create aggregate device")
        return aggregateID
    }

    private func teardownLocked() {
        destroy(tap: tapID, aggregate: aggregateID, proc: procID)
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
    }

    private func destroy(tap: AudioObjectID, aggregate: AudioObjectID, proc: AudioDeviceIOProcID?) {
        if aggregate != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
        }
    }
}
