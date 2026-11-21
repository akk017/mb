import AppKit
import MiniBrainCore
import SwiftUI
#if canImport(KeyboardShortcuts)
import KeyboardShortcuts
#endif

/// Long-lived services for the running app.
public struct AppEnvironment: Sendable {
    public let paths: AppPaths
    public let database: AppDatabase
    public let blobs: BlobStore
    public let repository: ItemRepository
    public let capture: CaptureService
    public let search: any SearchProviding
    public let worker: EnrichmentWorker
    public let customTypes: CustomTypeRepository

    /// Real on-disk environment under Application Support/MiniBrain.
    public static func live(baseDirectory: URL? = nil) throws -> AppEnvironment {
        let paths = try AppPaths(baseDirectory: baseDirectory).ensureDirectories()
        let database = try AppDatabase.open(at: paths.databaseURL)
        let clock = SystemClock()
        let blobs = BlobStore(directory: paths.blobsDirectory)
        let repository = ItemRepository(database: database, clock: clock)
        let services = LocalAIServices.make()
        let ocrEnabled: @Sendable () -> Bool = { AppPreferences.isOCREnabled() }
        let worker = EnrichmentWorker(
            database: database, blobs: blobs, clock: clock,
            processors: EnrichmentPipeline.processors(
                services: services, ocrEnabled: ocrEnabled,
                linkPreviewsEnabled: { AppPreferences.areLinkPreviewsEnabled() },
                autoTagEnabled: { AppPreferences.isAutoTagEnabled() },
                optimizeImages: { AppPreferences.isImageOptimizationEnabled() }))
        let capture = CaptureService(
            database: database, blobs: blobs, clock: clock, notifier: worker,
            isKindEnabled: { kind in
                switch kind {
                case .ocr: ocrEnabled()
                case .aiTags, .imageTags: AppPreferences.isAutoTagEnabled()
                case .optimizeImage: AppPreferences.isImageOptimizationEnabled()
                default: true
                }
            })
        // Links saved before link previews existed get one fetch attempt.
        let now = clock.now
        _ = try? database.writer.write { db in
            try EnrichmentQueue.backfill(.linkPreview, forType: .link, now: now, in: db)
            // Convert images already in the library to WebP (once per item).
            if AppPreferences.isImageOptimizationEnabled() {
                try EnrichmentQueue.backfill(.optimizeImage, forType: .image, now: now, in: db)
                try EnrichmentQueue.backfill(.optimizeImage, forType: .link, now: now, in: db)
            }
        }
        let customTypes = CustomTypeRepository(database: database, clock: clock)
        let parser = QueryParser(customTypeExists: { customTypes.exists(named: $0) })
        let search = SmartSearch(
            database: database, embedder: services.embedder, translator: services.translator, parser: parser)
        return AppEnvironment(
            paths: paths, database: database, blobs: blobs, repository: repository,
            capture: capture, search: search, worker: worker, customTypes: customTypes)
    }
}

/// Owns windows and wires hotkeys/state. Acts as the app delegate.
@MainActor
public final class AppController: NSObject, NSApplicationDelegate, WindowPresenting, NSWindowDelegate {
    public let state = AppState()
    public let preferences = AppPreferences()
    private var settingsWindow: NSWindow?
    private let settingsNavigation = SettingsNavigation()
    private var shortcutSettings: ShortcutSettings?
    public private(set) var environment: AppEnvironment?
    public private(set) var startupError: String?
    private var registrar: (any HotkeyRegistering)?
    private var dropBoxPanel: DropBoxPanel?
    private var libraryWindow: NSWindow?
    private var libraryModel: LibraryViewModel?
    private var dropBoxModel: DropBoxViewModel?
    private var dragMonitor: SystemDragMonitor?
    private var autoShow: DropBoxAutoShow?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(preferences.dockMode == .always ? .regular : .accessory)
        if Bundle.main.bundleURL.pathExtension != "app",
           let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? Self.devIconURL {
            NSApp.applicationIconImage = NSImage(contentsOf: url)
        }
        do {
            // MINIBRAIN_DATA_DIR env > Settings location > Application Support.
            let env = try AppEnvironment.live(baseDirectory: AppPreferences.libraryBaseDirectory())
            environment = env
            _ = try? env.repository.purgeTrash(blobs: env.blobs)
            Task { try? await env.worker.start() }
        } catch {
            startupError = error.localizedDescription
        }
        state.presenter = self
        let registrar = HotkeyRegistrarFactory.make()
        state.bindHotkeys(registrar) { [preferences] in preferences.shortcut(for: $0) }
        self.registrar = registrar
        shortcutSettings = ShortcutSettings(preferences: preferences, registrar: registrar)
        startDragAutoShow()
        if ProcessInfo.processInfo.environment["MINIBRAIN_OPEN_SETTINGS"] != nil { showSettings() } // dev aid
    }

    /// Pops the drop box up whenever a drag starts anywhere on the system.
    private func startDragAutoShow() {
        let autoShow = DropBoxAutoShow(
            appState: state,
            isEnabled: { [preferences] in preferences.autoShowOnDrag },
            dropState: { [weak self] in self?.dropBoxModel?.state })
        let monitor = SystemDragMonitor()
        monitor.watcher.onDragStart = { [weak autoShow] in autoShow?.dragStarted() }
        monitor.watcher.onDragEnd = { [weak autoShow] in autoShow?.dragEnded() }
        monitor.start()
        self.autoShow = autoShow
        self.dragMonitor = monitor
    }

    /// Clicking the Dock icon opens the Library.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { state.setLibraryVisible(true) }
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        registrar?.unregisterAll()
        dragMonitor?.stop()
        if let worker = environment?.worker { Task { await worker.stop() } }
    }

    // MARK: WindowPresenting

    public func setDropBoxVisible(_ visible: Bool) {
        if visible {
            dropBoxModelRefreshed()
            makeDropBoxIfNeeded()?.show(at: preferences.dropBoxPosition, takeFocus: true)
        } else {
            dropBoxPanel?.orderOut(nil)
        }
    }

    public func showDropBoxForDrag() {
        let panel = makeDropBoxIfNeeded()
        dropBoxModelRefreshed()
        panel?.show(at: preferences.dropBoxPosition, takeFocus: false)
    }

    private func dropBoxModelRefreshed() {
        _ = makeDropBoxIfNeeded()
        dropBoxModel?.refreshTypes()
        dropBoxModel?.autoTag = preferences.autoTag
    }

    private func makeDropBoxIfNeeded() -> DropBoxPanel? {
        guard let env = environment else { return nil }
        if dropBoxPanel == nil {
            let model = DropBoxViewModel(capturer: env.capture, customTypes: env.customTypes)
            model.autoTag = preferences.autoTag
            model.onAutoTagChange = { [weak self] on in self?.preferences.autoTag = on }
            model.onSaved = { [weak self] _ in Task { await self?.libraryModel?.refresh() } }
            model.onOpenSettings = { [weak self] in self?.showSettings(tab: .types) }
            dropBoxModel = model
            let panel = DropBoxPanel(content: DropBoxView(model: model))
            panel.anchor = preferences.dropBoxPosition
            panel.onPaste = { [weak model] in
                guard let model else { return }
                Task { await model.paste(NSPasteboard.general, chooseType: ShiftKey.isDown) }
            }
            panel.onOpenSettings = { [weak self] in self?.showSettings() }
            panel.onArrowKey = { [weak model] key in
                guard let model, !model.isAwaitingInput else { return false }
                switch key {
                case .left: model.setAutoTag(false)
                case .right: model.setAutoTag(true)
                case .enter: model.setAutoTag(!model.autoTag)
                }
                return true
            }
            panel.onEscape = { [weak self, weak model] in
                if model?.isAwaitingInput == true { model?.cancelChoice() } else { self?.state.setDropBoxVisible(false) }
            }
            dropBoxPanel = panel
        }
        return dropBoxPanel
    }

    public func setLibraryVisible(_ visible: Bool) {
        guard let env = environment else { return }
        if visible {
            if libraryWindow == nil {
                let model = LibraryViewModel(search: env.search, repository: env.repository, customTypes: env.customTypes)
                model.showsRecognizedText = preferences.showRecognizedText
                libraryModel = model
                let actions = ItemActions(
                    workspace: NSWorkspace.shared, pasteboard: NSPasteboard.general,
                    blobs: env.blobs, repository: env.repository)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                    backing: .buffered, defer: false)
                window.title = "MiniBrain"
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = false
                window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: LibraryView(
                    model: model, actions: actions, openSettings: { [weak self] in self?.showSettings() }))
                window.center()
                window.setFrameAutosaveName("MiniBrainLibrary")
                window.delegate = self
                libraryWindow = window
            }
            libraryWindow?.makeKeyAndOrderFront(nil)
            updateDockPresence()
            NSApp.activate()
            Task { await libraryModel?.refresh() }
        } else {
            libraryWindow?.orderOut(nil)
            updateDockPresence(closing: libraryWindow)
        }
    }

    /// The shortcut to display in the menu-bar menu for a hotkey (nil if cleared).
    public func menuShortcut(for hotkey: Hotkey) -> KeyboardShortcut? {
        #if canImport(KeyboardShortcuts)
        if let shortcut = KeyboardShortcuts.getShortcut(for: hotkey.shortcutName) {
            return KeyCombo(keyCode: UInt32(shortcut.carbonKeyCode), modifiers: shortcut.modifiers).swiftUIShortcut
        }
        return nil
        #else
        return preferences.shortcut(for: hotkey)?.swiftUIShortcut
        #endif
    }

    // MARK: Settings

    public func showSettings(tab: SettingsNavigation.Tab? = nil) {
        if let tab { settingsNavigation.tab = tab }
        if settingsWindow == nil, let shortcutSettings {
            let types = environment.map { env in
                let model = TypesSettings(repository: env.customTypes)
                model.onChange = { [weak self] in
                    self?.dropBoxModel?.refreshTypes()
                    Task { await self?.libraryModel?.refresh() }
                }
                return model
            }
            let storage = environment.map { env in
                StorageSettings(
                    paths: env.paths, database: env.database, repository: env.repository,
                    preferences: preferences,
                    hooks: .init(
                        chooseFolder: Self.chooseFolder, confirm: Self.confirm,
                        relaunch: { [weak self] in self?.relaunch() },
                        reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) }))
            }
            let view = SettingsView(
                preferences: preferences, navigation: settingsNavigation, shortcuts: shortcutSettings,
                types: types, storage: storage,
                onDockModeChange: { [weak self] in self?.updateDockPresence() },
                onRecognizedTextVisibilityChange: { [weak self] in
                    guard let self else { return }
                    self.libraryModel?.showsRecognizedText = self.preferences.showRecognizedText
                },
                clearRecognizedText: { [weak self] in
                    guard let env = self?.environment else { return 0 }
                    let count = try env.repository.clearRecognizedText()
                    Task { await self?.libraryModel?.refresh() }
                    return count
                },
                onPositionChange: { [weak self] in
                    guard let self, let panel = self.dropBoxPanel, panel.isVisible else { return }
                    panel.reposition(self.preferences.dropBoxPosition)
                })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "MiniBrain Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: view)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        updateDockPresence()
        NSApp.activate()
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for your MiniBrain library"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func confirm(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Change Library Location"
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Restarts the app (used after moving the library).
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } else if let executable = Bundle.main.executableURL {
            let process = Process()
            process.executableURL = executable
            try? process.run()
            NSApp.terminate(nil)
        }
    }

    /// Repo icon when running the bare binary during development.
    static var devIconURL: URL? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.icns")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Dock icon per Settings › General › Show in Dock.
    public func updateDockPresence(closing: NSWindow? = nil) {
        let open = [libraryWindow, settingsWindow].contains { w in
            guard let w, w !== closing else { return false }
            return w.isVisible
        }
        let policy: NSApplication.ActivationPolicy = preferences.dockMode.showsInDock(windowOpen: open) ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if open { NSApp.activate() }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        let window = notification.object as? NSWindow
        DispatchQueue.main.async { [weak self] in self?.updateDockPresence(closing: window) }
        if (notification.object as? NSWindow) === libraryWindow { state.setLibraryVisible(false) }
    }
}

/// Menu bar dropdown.
public struct MenuBarContent: View {
    let controller: AppController

    public init(controller: AppController) { self.controller = controller }

    public var body: some View {
        // Shortcuts shown here follow Settings › Shortcuts.
        Button("Drop Box") { controller.state.handle(.toggleDropBox) }
            .keyboardShortcut(controller.menuShortcut(for: .toggleDropBox))
        Button("Library") { controller.state.setLibraryVisible(true) }
            .keyboardShortcut(controller.menuShortcut(for: .toggleLibrary))
        Toggle("Auto-tag Every Drop", isOn: Binding(
            get: { controller.preferences.autoTag },
            set: { controller.preferences.autoTag = $0 }))
        Divider()
        Button("Settings…") { controller.showSettings() }
            .keyboardShortcut(",")
        if let error = controller.startupError {
            Divider()
            Text("Error: \(error)")
        }
        Divider()
        Button("Quit MiniBrain") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
