import AVFoundation
import AppKit
import ApplicationServices
import Observation
import Speech

/// Live app state that permission screens need but that isn't a permission itself.
@MainActor
@Observable
final class AppStatus {
    static let shared = AppStatus()
    /// The push-to-talk key listener (CGEvent tap) is running. With Accessibility granted it
    /// normally is; if not, Input Monitoring is offered as well.
    var keyListenerRunning = false
    /// The push-to-talk key held right now, so Home can light it up.
    var heldKey: TriggerKey?
    /// Home is in front and plays the live island itself, so the notch copy stays hidden.
    var islandShownInApp = false
    /// Bumped on every real key press or click (from the key listener). See "Fix that".
    @ObservationIgnored var inputRevision = 0
}

/// The macOS permissions the app can use, with live status and where to grant each.
enum Permission: String, CaseIterable, Identifiable {
    case microphone
    case speechRecognition
    case inputMonitoring
    case accessibility
    case systemAudio
    case screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        case .systemAudio: return "System Audio Recording"
        case .screenRecording: return "Screen Recording"
        }
    }

    var purpose: String {
        switch self {
        case .microphone: return "Hear you while dictating."
        case .speechRecognition: return "Needed by the Legacy engine only."
        case .inputMonitoring: return "Only if the push-to-talk key doesn't respond with Accessibility alone."
        case .accessibility: return "Hear the push-to-talk key and paste into the app you're typing in."
        case .systemAudio: return "DJ-style muffle for music while dictating (otherwise volume is lowered)."
        case .screenRecording: return "Record the screen for annotations."
        }
    }

    /// Microphone and Accessibility are all dictation needs: Accessibility covers both the key
    /// listener and pasting (as in Hex), so most people never see the other three.
    var isRequired: Bool { self == .microphone || self == .accessibility }

    /// The rows worth showing right now: optional ones only when they'd make a difference.
    @MainActor static var visible: [Permission] {
        var list: [Permission] = [.microphone, .accessibility]
        if inputMonitoring.isGranted || (accessibility.isGranted && !AppStatus.shared.keyListenerRunning) {
            list.append(.inputMonitoring)
        }
        if speechRecognition.isGranted || AppSettings.shared.speechEngine == .legacy { list.append(.speechRecognition) }
        list.append(.systemAudio)
        if AppSettings.shared.annotateEnabled || screenRecording.isGranted { list.append(.screenRecording) }
        return list
    }

    @MainActor static var requiredMissing: Bool { allCases.contains { $0.isRequired && !$0.isGranted } }

    /// The microphone was refused once; macOS won't prompt again, only System Settings can fix it.
    var isDenied: Bool {
        switch self {
        case .microphone:
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            return status == .denied || status == .restricted
        default: return false
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speechRecognition: return SFSpeechRecognizer.authorizationStatus() == .authorized
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .accessibility: return AXIsProcessTrusted()
        case .systemAudio: return SystemAudioPermission.status == .authorized
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }

    /// Shows the system prompt where one exists, otherwise opens the right Settings pane with
    /// the floating guide docked under it.
    @MainActor func request() {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                PermissionGuide.shared.show(for: self)
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
            PermissionGuide.shared.show(for: self)
        case .systemAudio:
            if SystemAudioPermission.status == .unknown {
                SystemAudioPermission.request()
            } else {
                openSettings()
            }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { PermissionGuide.shared.show(for: self) }
        }
    }

    /// Clears this app's entry so macOS asks again. Fixes the common case where System Settings
    /// shows the switch on but it belongs to an older build's signature.
    func resetEntry() {
        let service: String
        switch self {
        case .accessibility: service = "Accessibility"
        case .inputMonitoring: service = "ListenEvent"
        case .microphone: service = "Microphone"
        case .screenRecording: service = "ScreenCapture"
        case .systemAudio: service = "AudioCapture"
        default: return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "dev.voicedictation.DictationIsland"]
        try? process.run()
        process.waitUntilExit()
    }

    /// Once: clears permission entries that don't work for this build.
    /// 0.5.1 and earlier were signed with a local certificate, 0.5.2 with a Developer ID, and
    /// macOS keeps the old entries (the switches still look on) but rejects them. A rejected
    /// Input Monitoring entry makes macOS keep switching the key listener off, which cut every
    /// hold short. Neither is cleared while it works; Input Monitoring isn't needed (Accessibility
    /// covers the key listener), so a cleared one only means macOS may ask again.
    static func clearEntriesFromOldSignature() {
        let key = "clearedEntriesFromOldSignature2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !CGPreflightListenEventAccess() { Permission.inputMonitoring.resetEntry() }
        if !AXIsProcessTrusted() { Permission.accessibility.resetEntry() }
        // Optional ones too: their switches look on in System Settings while the app says no.
        if !CGPreflightScreenCaptureAccess() { Permission.screenRecording.resetEntry() }
        if SystemAudioPermission.status != .authorized { Permission.systemAudio.resetEntry() }
    }

    func openSettings() {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .systemAudio: anchor = "Privacy_AudioCapture"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
