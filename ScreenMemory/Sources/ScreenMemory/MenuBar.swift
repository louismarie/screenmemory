import AppKit
import CoreGraphics

/// Menubar control panel + always-on host. This binary's `menubar` subcommand.
/// It holds the Screen Recording grant, auto-resumes capture, serves the dashboard in-process,
/// registers as a login item, and runs the proactive scheduler. Dashboard actions open a native
/// macOS window backed by the in-process dashboard server — no browser tab, no raw files dumped
/// into a text editor.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let dbPath: String
    private var engine: CaptureEngine?
    private let scheduler: ProactiveScheduler
    private let server: DashboardServer
    private let dashboardWindow: DashboardWindowController
    private var statusNote = ""
    private var language: AppLanguage { AppLanguage.preferred }

    init(dbPath: String) {
        self.dbPath = dbPath
        self.scheduler = ProactiveScheduler(dbPath: dbPath)
        self.server = DashboardServer(dbPath: dbPath)
        self.dashboardWindow = DashboardWindowController(baseURL: URL(string: "http://127.0.0.1:8790")!)
        super.init()
        statusItem.button?.title = "🧠"
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    /// Called once at launch — make the app actually always-on.
    func bootstrap() {
        server.start()                                  // dashboard live while the app runs
        _ = LoginItem.setEnabled(true)                  // run at login (best-effort)
        scheduler.onProduced = { [weak self] in self?.rebuildMenu() }
        scheduler.start()
        if LoginItem.isFirstRun { LoginItem.setAutoCapture(true); LoginItem.markInitialized() }

        if CGPreflightScreenCaptureAccess() {
            if LoginItem.autoCaptureEnabled { startCapture() }
        } else {
            // Trigger the system prompt + add the app to the Screen Recording list.
            CGRequestScreenCaptureAccess()
            statusNote = "⚠️ \(language.t("menuScreenPermissionRelaunch", "Allow Screen Recording, then relaunch"))"
            rebuildMenu()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }
    private func memoryCount() -> Int { (try? Store(path: dbPath).count()) ?? 0 }
    private var capturing: Bool { engine?.isRunning == true }

    @objc private func rebuildMenu() {
        menu.removeAllItems()
        let granted = CGPreflightScreenCaptureAccess()
        let dot = capturing ? "🟢" : (granted ? "⚪️" : "🔴")
        menu.addItem(withTitle: "\(dot) \(memoryCount()) \(language.t("menuMemories", "memories"))", action: nil, keyEquivalent: "")
        if let head = Proactive.currentHeadline() {
            let it = NSMenuItem(title: "💡 " + String(head.prefix(64)), action: #selector(openDashboard), keyEquivalent: "")
            it.target = self; it.toolTip = head; menu.addItem(it)
        }
        if !statusNote.isEmpty { menu.addItem(withTitle: statusNote, action: nil, keyEquivalent: "") }
        menu.addItem(.separator())

        if !granted {
            add(menu, "⚠️ \(language.t("menuAllowScreenRecording", "Allow Screen Recording"))", #selector(requestPermission))
            menu.addItem(.separator())
        }
        add(menu,
            Privacy.isPaused
                ? "▶︎ \(language.t("menuResumeIndexing", "Resume indexing"))"
                : "⏸ \(language.t("menuPauseIndexing", "Pause indexing"))",
            #selector(togglePause))
        add(menu,
            capturing
                ? "⏹ \(language.t("menuStopCapture", "Stop capture"))"
                : "● \(language.t("menuStartCapture", "Start capture"))",
            #selector(toggleCapture))

        menu.addItem(.separator())
        add(menu, "📊 \(language.t("menuDashboard", "Dashboard"))", #selector(openDashboard))
        add(menu, "🔎 \(language.t("menuAsk", "Ask"))", #selector(openAsk))
        add(menu, "🗞 \(language.t("menuTodayJournal", "Today's journal"))", #selector(openJournal))
        add(menu, "🎯 \(language.t("coach", "Coach"))", #selector(openCoach))
        add(menu, "📅 \(language.t("menuWeekly", "Weekly synthesis"))", #selector(openWeekly))
        add(menu, "📈 \(language.t("menuTrends", "Trends"))", #selector(openEvolution))

        menu.addItem(.separator())
        let login = NSMenuItem(title: language.t("menuLaunchAtLogin", "Launch at login"),
                               action: #selector(toggleLogin),
                               keyEquivalent: "")
        login.target = self; login.state = LoginItem.isRegistered ? .on : .off
        menu.addItem(login)
        add(menu, language.t("menuOpenLog", "Open log"), #selector(openLog))
        add(menu, language.t("menuQuit", "Quit"), #selector(quit), key: "q")
    }

    // MARK: - Capture

    private func startCapture() {
        guard engine?.isRunning != true else { return }
        statusNote = "⏳ \(language.t("menuStarting", "starting..."))"; rebuildMenu()
        Task { @MainActor in
            do {
                let store = try Store(path: dbPath)
                let embedder = try Embedder()
                let e = CaptureEngine(store: store, embedder: embedder)
                try await e.start(fps: 1)
                engine = e; LoginItem.setAutoCapture(true); statusNote = ""
            } catch {
                statusNote = CGPreflightScreenCaptureAccess()
                    ? "⚠️ \(error.localizedDescription.prefix(38))"
                    : "⚠️ \(language.t("menuAllowScreenRecording", "Allow Screen Recording"))"
            }
            rebuildMenu()
        }
    }

    @objc private func toggleCapture() {
        if let e = engine, e.isRunning {
            e.stop(); engine = nil; LoginItem.setAutoCapture(false); statusNote = "⏹ \(language.t("menuStopped", "stopped"))"; rebuildMenu(); return
        }
        startCapture()
    }

    @objc private func requestPermission() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        statusNote = "↻ \(language.t("menuGrantThenRelaunch", "grant permission, then relaunch the app"))"; rebuildMenu()
    }

    // MARK: - Dashboard window

    private func openDash(_ tab: String) { dashboardWindow.show(tab: tab) }
    @objc private func openDashboard() { openDash("resume") }
    @objc private func openAsk() { openDash("ask") }
    @objc private func openJournal() { openDash("journal") }
    @objc private func openCoach() { openDash("coach") }
    @objc private func openWeekly() { openDash("week") }
    @objc private func openEvolution() { openDash("trends") }

    // MARK: - Toggles

    @objc private func togglePause() {
        if Privacy.isPaused { try? FileManager.default.removeItem(atPath: Privacy.pauseFlag) }
        else { FileManager.default.createFile(atPath: Privacy.pauseFlag, contents: nil) }
        rebuildMenu()
    }
    @objc private func toggleLogin() { statusNote = LoginItem.setEnabled(!LoginItem.isRegistered); rebuildMenu() }
    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: Agent.logPath)) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self; menu.addItem(item)
    }
}

/// Entry point for the `menubar` subcommand — runs as a menubar-only (accessory) app.
@MainActor
func runMenuBar(dbPath: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = MenuBarController(dbPath: dbPath)
    menuBarControllerRef = controller
    controller.bootstrap()
    app.run()
}

@MainActor private var menuBarControllerRef: MenuBarController?
