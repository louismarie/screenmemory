import AppKit

/// Menubar control panel (AppKit NSStatusItem). Same binary, `menubar` subcommand.
/// Shows memory count, toggles pause, and starts/stops the always-on capture daemon.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let dbPath: String
    private var engine: CaptureEngine?      // in-process capture (this app is the TCC-responsible process)
    private var statusNote = ""

    init(dbPath: String) {
        self.dbPath = dbPath
        super.init()
        statusItem.button?.title = "🧠"
        menu.delegate = self                // refresh the counter every time the menu opens
        statusItem.menu = menu
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func memoryCount() -> Int { (try? Store(path: dbPath).count()) ?? 0 }
    private var capturing: Bool { engine?.isRunning == true }

    @objc private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(withTitle: "🧠 \(memoryCount()) souvenirs", action: nil, keyEquivalent: "")
        if !statusNote.isEmpty { menu.addItem(withTitle: statusNote, action: nil, keyEquivalent: "") }
        menu.addItem(.separator())

        let paused = Privacy.isPaused
        add(menu, paused ? "▶︎ Reprendre l’indexation" : "⏸ Mettre en pause", #selector(togglePause))

        add(menu, capturing ? "⏹ Arrêter la capture" : "● Démarrer la capture",
            #selector(toggleCapture))

        menu.addItem(.separator())
        add(menu, "🗞 Recap d'hier", #selector(openRecap))
        add(menu, "Ouvrir le log", #selector(openLog))
        add(menu, "Quitter", #selector(quit), key: "q")
    }

    @objc private func openRecap() {
        statusNote = "⏳ recap en cours…"; rebuildMenu()
        Task { @MainActor in
            let cal = Calendar.current
            let day = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".screenmemory.recaps")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = (dir as NSString).appendingPathComponent("\(f.string(from: day)).md")
            if !FileManager.default.fileExists(atPath: path), let store = try? Store(path: dbPath) {
                let r = await Recap.generate(day: day, store: store)
                try? Recap.markdown(r).write(toFile: path, atomically: true, encoding: .utf8)
            }
            statusNote = ""
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            rebuildMenu()
        }
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func togglePause() {
        if Privacy.isPaused { try? FileManager.default.removeItem(atPath: Privacy.pauseFlag) }
        else { FileManager.default.createFile(atPath: Privacy.pauseFlag, contents: nil) }
        rebuildMenu()
    }

    @objc private func toggleCapture() {
        if let e = engine, e.isRunning {
            e.stop(); engine = nil; statusNote = "⏹ arrêté"; rebuildMenu(); return
        }
        statusNote = "⏳ démarrage…"; rebuildMenu()
        Task { @MainActor in
            do {
                let store = try Store(path: dbPath)
                let embedder = try Embedder()
                let e = CaptureEngine(store: store, embedder: embedder)
                try await e.start(fps: 1)   // triggers the Screen Recording prompt for THIS signed app
                engine = e
                statusNote = "● capture en cours"
            } catch {
                statusNote = "⚠️ \(error.localizedDescription.prefix(40))"
            }
            rebuildMenu()
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Agent.logPath))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// Entry point for the `menubar` subcommand — runs as a menubar-only (accessory) app.
@MainActor
func runMenuBar(dbPath: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = MenuBarController(dbPath: dbPath)
    menuBarControllerRef = controller     // retain
    app.run()
}

@MainActor private var menuBarControllerRef: MenuBarController?
