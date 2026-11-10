import Cocoa
import ApplicationServices
import CoreGraphics

/// Single place to check and request macOS privacy permissions.
enum PermissionCenter {
    enum Status { case granted, denied, unknown }

    static func status(_ permission: ModulePermission) -> Status {
        switch permission {
        case .accessibility: return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording: return CGPreflightScreenCaptureAccess() ? .granted : .denied
        // Automation and audio capture have no reliable preflight API; the system prompts on first use.
        case .automation, .audioCapture: return .unknown
        }
    }

    static func request(_ permission: ModulePermission) {
        switch permission {
        case .accessibility: requestAccessibility()
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        case .automation, .audioCapture: openSettings(permission)
        }
    }

    static func missing(for module: NexoModule) -> [ModulePermission] {
        module.permissions.filter { status($0) == .denied }
    }

    static func openSettings(_ permission: ModulePermission) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor(permission))") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func anchor(_ permission: ModulePermission) -> String {
        switch permission {
        case .accessibility: return "Privacy_Accessibility"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .automation: return "Privacy_Automation"
        case .audioCapture: return "Privacy_AudioCapture"
        }
    }
}
