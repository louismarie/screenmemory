import AppKit
import WebKit

@MainActor
final class DashboardWindowController: NSWindowController, WKNavigationDelegate {
    private let baseURL: URL
    private let webView: WKWebView
    private var hasCenteredWindow = false

    init(baseURL: URL) {
        self.baseURL = baseURL

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "ScreenMemory"
        window.subtitle = "Dashboard local"
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.setFrameAutosaveName("ScreenMemoryDashboard")
        window.contentView = webView

        super.init(window: window)
        webView.navigationDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(tab: String) {
        if !hasCenteredWindow {
            window?.center()
            hasCenteredWindow = true
        }

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        load(tab: tab)
    }

    func reload() {
        if webView.url == nil {
            load(tab: "reprendre")
        } else {
            webView.reload()
        }
    }

    private func load(tab: String) {
        let safeTab = tab.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        if isShowingDashboard {
            webView.evaluateJavaScript("show('\(safeTab)')") { [weak self] _, error in
                if error != nil {
                    self?.loadURL(tab: safeTab)
                }
            }
        } else {
            loadURL(tab: safeTab)
        }
    }

    private var isShowingDashboard: Bool {
        guard let url = webView.url else { return false }
        return url.scheme == baseURL.scheme && url.host == baseURL.host && url.port == baseURL.port
    }

    private func loadURL(tab: String) {
        guard let url = URL(string: "\(baseURL.absoluteString)/#\(tab)") else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        webView.load(request)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showConnectionError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showConnectionError(error)
    }

    private func showConnectionError(_ error: Error) {
        let html = """
        <!doctype html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>ScreenMemory</title>
        <style>
        html,body{height:100%;margin:0;background:#111114;color:#ededf0;font:14px -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
        body{display:grid;place-items:center}
        main{width:min(560px,calc(100vw - 48px));padding:28px;border:1px solid rgba(255,255,255,.12);border-radius:16px;background:#18181d;box-shadow:0 20px 80px rgba(0,0,0,.35)}
        h1{font-size:20px;margin:0 0 10px}
        p{color:#a1a1aa;line-height:1.55;margin:0 0 14px}
        code{color:#c8cbff}
        .err{margin-top:18px;padding:12px;border-radius:10px;background:#241817;color:#ffb4ad;border:1px solid rgba(255,69,58,.35);word-break:break-word}
        </style>
        </head>
        <body>
        <main>
        <h1>Dashboard interne indisponible</h1>
        <p>La fenêtre macOS est ouverte, mais le serveur local embarqué ne répond pas encore sur <code>\(baseURL.absoluteString)</code>.</p>
        <p>Quitte puis relance ScreenMemory depuis l'icône de menu. Si le problème persiste, le port 8790 est peut-être déjà occupé.</p>
        <div class="err">\(Self.escape(error.localizedDescription))</div>
        </main>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
