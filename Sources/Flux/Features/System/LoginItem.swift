import Observation
import ServiceManagement

/// Open at Login, through the system's Login Items (macOS asks nothing; the user can
/// switch it off in System Settings › General › Login Items, which Flux then reflects).
@MainActor @Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var error: String?

    /// Needs a real app bundle.
    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    var isEnabled: Bool { status == .enabled }
    /// Turned on, but switched off in System Settings.
    var needsApproval: Bool { status == .requiresApproval }

    init() { refresh() }

    func refresh() {
        guard isAvailable else { return }
        status = SMAppService.mainApp.status
    }

    func set(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
