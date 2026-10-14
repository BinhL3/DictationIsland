import AVFoundation
import AppKit
import ApplicationServices
import Speech

/// The macOS permissions the app can use, with live status and where to grant each.
enum Permission: String, CaseIterable, Identifiable {
    case microphone
    case speechRecognition
    case inputMonitoring
    case accessibility
    case systemAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        case .systemAudio: return "System Audio Recording"
        }
    }

    var purpose: String {
        switch self {
        case .microphone: return "Hear you while dictating."
        case .speechRecognition: return "Needed by the Legacy engine; Apple Speech runs on-device."
        case .inputMonitoring: return "Detect the push-to-talk keys (fn, right ⌥, …)."
        case .accessibility: return "Paste the text into the app you're typing in."
        case .systemAudio: return "DJ-style muffle for music while dictating (otherwise volume is lowered)."
        }
    }

    var isRequired: Bool { self == .microphone }

    var isGranted: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speechRecognition: return SFSpeechRecognizer.authorizationStatus() == .authorized
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .accessibility: return AXIsProcessTrusted()
        case .systemAudio: return SystemAudioPermission.status == .authorized
        }
    }

    /// Shows the system prompt where one exists, otherwise opens the right Settings pane.
    func request() {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                openSettings()
            }
        case .speechRecognition:
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { _ in }
            } else {
                openSettings()
            }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openSettings() }
        case .accessibility:
            TextInserter.promptForAccessibility()
            openSettings()
        case .systemAudio:
            if SystemAudioPermission.status == .unknown {
                SystemAudioPermission.request()
            } else {
                openSettings()
            }
        }
    }

    private func openSettings() {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .systemAudio: anchor = "Privacy_AudioCapture"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
