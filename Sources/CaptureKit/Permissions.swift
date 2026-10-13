import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

public enum PermissionKind: String, CaseIterable, Sendable, Identifiable {
    case screenRecording
    case microphone
    case systemAudio
    case accessibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: "Screen & System Audio Recording"
        case .microphone: "Microphone"
        case .systemAudio: "System Audio Recording"
        case .accessibility: "Accessibility (optional)"
        }
    }

    public var purpose: String {
        switch self {
        case .screenRecording: "Lists meeting windows and takes screenshots for context."
        case .microphone: "Records your voice on its own track, so your lines are always attributed to you."
        case .systemAudio: "Records the meeting app's audio (the other participants) without a virtual audio driver."
        case .accessibility: "Reads mute state from desktop meeting apps to route your mic to the right meeting."
        }
    }

    var settingsAnchor: String {
        switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .systemAudio: "Privacy_AudioCapture"
        case .accessibility: "Privacy_Accessibility"
        }
    }
}

public enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// macOS exposes no query API (system audio capture); it's prompted on first use.
    case unknown
}

public enum Permissions {
    public static func state(of kind: PermissionKind) -> PermissionState {
        switch kind {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .systemAudio:
            return .unknown
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        }
    }

    /// Triggers the system prompt where macOS allows it; otherwise opens the right System Settings pane.
    @MainActor
    public static func request(_ kind: PermissionKind) async {
        switch kind {
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSettings(for: kind) }
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else {
                openSettings(for: kind)
            }
        case .systemAudio:
            // The prompt appears the first time a process tap is created; a short probe tap triggers it.
            openSettings(for: kind)
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openSettings(for: kind) }
        }
    }

    @MainActor
    public static func openSettings(for kind: PermissionKind) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
