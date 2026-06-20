import Foundation
import ServiceManagement

/// "Run at login" via SMAppService (macOS 13+). This is the TCC-stable always-on path:
/// the GUI menubar app — the process that actually holds the Screen Recording grant —
/// is relaunched at login, and it auto-resumes capture. No separate launchd daemon that
/// can't get a Screen Recording prompt in the background.
enum LoginItem {
    /// Whether capture should auto-start when the app launches (a flag file the menubar toggles).
    static let autoCaptureFlag = (NSHomeDirectory() as NSString).appendingPathComponent(".screenmemory.autocapture")
    static var autoCaptureEnabled: Bool { FileManager.default.fileExists(atPath: autoCaptureFlag) }
    static func setAutoCapture(_ on: Bool) {
        if on { FileManager.default.createFile(atPath: autoCaptureFlag, contents: nil) }
        else { try? FileManager.default.removeItem(atPath: autoCaptureFlag) }
    }

    /// First-run marker so we can default capture ON for new users without re-enabling it
    /// every launch after they've explicitly stopped (which removes the auto-capture flag).
    private static let initMarker = (NSHomeDirectory() as NSString).appendingPathComponent(".screenmemory.initialized")
    static var isFirstRun: Bool { !FileManager.default.fileExists(atPath: initMarker) }
    static func markInitialized() { FileManager.default.createFile(atPath: initMarker, contents: nil) }

    static var isRegistered: Bool { SMAppService.mainApp.status == .enabled }

    /// Register/unregister the app as a login item. Only meaningful when running from a real
    /// .app bundle (dev CLI runs throw — caught and reported).
    @discardableResult
    static func setEnabled(_ on: Bool) -> String {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return on ? "lancement au démarrage activé" : "lancement au démarrage désactivé"
        } catch {
            return "login item indisponible (\(error.localizedDescription)) — lance depuis l'app packagée"
        }
    }

    static func statusDescription() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval (Réglages → Général → Ouverture)"
        case .notFound: return "not found (run from the packaged .app)"
        @unknown default: return "unknown"
        }
    }
}
