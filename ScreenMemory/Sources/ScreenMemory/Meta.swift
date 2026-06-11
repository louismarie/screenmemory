import AppKit

/// Per-frame context metadata — app name + window title. The research consensus:
/// this is the single highest-value retrieval signal (Rewind's `segment`,
/// Recall's `WindowCapture`, screenpipe's accessibility columns).
enum Meta {
    /// Frontmost app + its frontmost window title.
    /// Window titles come from CGWindowList (needs Screen Recording — which we have).
    static func frontmost() -> (app: String, title: String) {
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.localizedName ?? ""
        var title = ""
        if let pid = front?.processIdentifier,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                      (w[kCGWindowLayer as String] as? Int) == 0,
                      let name = w[kCGWindowName as String] as? String, !name.isEmpty
                else { continue }
                title = name
                break   // CGWindowList is front-to-back: first hit = frontmost window
            }
        }
        return (app, title)
    }
}
