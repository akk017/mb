import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An app during which the drop box doesn't pop up on drag.
public struct ExcludedApp: Codable, Hashable, Identifiable, Sendable {
    public var bundleID: String
    public var name: String
    public var id: String { bundleID.lowercased() }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    /// Reads an .app bundle (nil when it has no bundle identifier).
    public init?(appURL: URL) {
        guard let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let info = bundle.localizedInfoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] ?? info["CFBundleName"]
            ?? bundle.infoDictionary?["CFBundleDisplayName"] ?? bundle.infoDictionary?["CFBundleName"]) as? String
        self.init(bundleID: id, name: name ?? appURL.deletingPathExtension().lastPathComponent)
    }

    init?(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return nil }
        self.init(bundleID: id, name: app.localizedName ?? id)
    }
}

/// When an excluded app pauses the drag pop-up.
public enum ExclusionRule: String, CaseIterable, Sendable {
    /// The app you're dragging in / looking at is excluded.
    case frontmost
    /// An excluded app is open at all.
    case running

    var title: String {
        switch self {
        case .frontmost: "In front"
        case .running: "Open"
        }
    }
}

/// The decision, kept pure for tests.
public struct DropExclusions: Sendable {
    public var apps: [ExcludedApp]
    public var rule: ExclusionRule

    public init(apps: [ExcludedApp], rule: ExclusionRule) {
        self.apps = apps
        self.rule = rule
    }

    /// The excluded app currently pausing the pop-up, if any.
    public func blockingApp(frontmost: String?, running: Set<String>) -> ExcludedApp? {
        guard !apps.isEmpty else { return nil }
        switch rule {
        case .frontmost:
            guard let front = frontmost?.lowercased() else { return nil }
            return apps.first { $0.id == front }
        case .running:
            let open = Set(running.map { $0.lowercased() })
            return apps.first { open.contains($0.id) }
        }
    }

    /// Live check against NSWorkspace.
    @MainActor
    public func currentBlockingApp(workspace: NSWorkspace = .shared) -> ExcludedApp? {
        guard !apps.isEmpty else { return nil }
        let front = workspace.frontmostApplication?.bundleIdentifier
        let running = rule == .running ? Set(workspace.runningApplications.compactMap(\.bundleIdentifier)) : []
        return blockingApp(frontmost: front, running: running)
    }
}

/// Settings › General › Excluded Apps.
struct ExcludedAppsSection: View {
    @Bindable var preferences: AppPreferences
    /// Apps to offer under "Add Running App" (regular apps, not MiniBrain).
    var runningApps: @MainActor () -> [ExcludedApp] = { ExcludedAppsSection.regularRunningApps() }

    var body: some View {
        Section {
            Picker("Pause pop-up while an excluded app is", selection: $preferences.exclusionRule) {
                ForEach(ExclusionRule.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if preferences.excludedApps.isEmpty {
                Text("No excluded apps").foregroundStyle(.secondary)
            } else {
                ForEach(preferences.excludedApps) { app in
                    HStack(spacing: 8) {
                        AppIcon(bundleID: app.bundleID)
                        Text(app.name)
                        Text(app.bundleID).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                        Button {
                            preferences.removeExcludedApp(app.bundleID)
                        } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove \(app.name)")
                    }
                }
            }
            HStack {
                Menu("Add Running App") {
                    let taken = Set(preferences.excludedApps.map(\.id))
                    let apps = runningApps().filter { !taken.contains($0.id) }
                    if apps.isEmpty { Text("No other apps open") }
                    ForEach(apps) { app in
                        Button(app.name) { preferences.addExcludedApp(app) }
                    }
                }
                .fixedSize()
                Button("Choose App…", action: chooseApp)
                Spacer()
            }
        } header: {
            Text("Excluded Apps")
        } footer: {
            Text("Dragging won’t pop up the drop box while one of these apps is \(preferences.exclusionRule == .frontmost ? "in front" : "open"). ⌘⇧Space still opens it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps that shouldn’t pop up the drop box"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let app = ExcludedApp(appURL: url) { preferences.addExcludedApp(app) }
        }
    }

    @MainActor
    static func regularRunningApps() -> [ExcludedApp] {
        let me = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != me }
            .compactMap(ExcludedApp.init)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "app.dashed").frame(width: 18, height: 18).foregroundStyle(.secondary)
        }
    }
}
