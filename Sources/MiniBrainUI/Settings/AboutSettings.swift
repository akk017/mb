import AppKit
import MiniBrainCore
import SwiftUI

/// What Settings › About shows: version, build, and where things live.
public struct AboutInfo: Sendable, Equatable {
    public var version: String
    public var buildDate: Date?
    public var commit: String?
    public var appURL: URL
    public var dataDirectory: URL?
    public var logsDirectory: URL
    public var osVersion: String

    /// `MBBuildTime` / `MBGitCommit` are stamped into Info.plist by
    /// scripts/make-app.sh; dev runs fall back to the executable's date.
    public init(infoDictionary: [String: Any], appURL: URL, executableDate: Date?,
                dataDirectory: URL?, logsDirectory: URL, osVersion: String) {
        version = infoDictionary["CFBundleShortVersionString"] as? String ?? MiniBrain.version
        buildDate = (infoDictionary["MBBuildTime"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? executableDate
        commit = (infoDictionary["MBGitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.appURL = appURL
        self.dataDirectory = dataDirectory
        self.logsDirectory = logsDirectory
        self.osVersion = osVersion
    }

    public static func current(dataDirectory: URL?, bundle: Bundle = .main) -> AboutInfo {
        let executableDate = bundle.executableURL
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        return AboutInfo(
            infoDictionary: bundle.infoDictionary ?? [:], appURL: bundle.bundleURL, executableDate: executableDate,
            dataDirectory: dataDirectory,
            logsDirectory: Log.shared.fileURL?.deletingLastPathComponent() ?? Log.defaultDirectory,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    public var isPackagedApp: Bool { appURL.pathExtension == "app" }

    /// Plain text for bug reports (Copy Info).
    public var diagnosticsText: String {
        var lines = ["\(MiniBrain.appName) \(version)"]
        if let buildDate { lines.append("Built: \(ISO8601DateFormatter().string(from: buildDate))") }
        if let commit { lines.append("Commit: \(commit)") }
        lines.append("macOS: \(osVersion)")
        lines.append("App: \(appURL.path)")
        if let dataDirectory { lines.append("Data: \(dataDirectory.path)") }
        lines.append("Logs: \(logsDirectory.path)")
        return lines.joined(separator: "\n")
    }
}

struct AboutSettingsTab: View {
    let info: AboutInfo
    let reveal: (URL) -> Void
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(MiniBrain.appName).font(.title2.weight(.semibold))
                        Text("Version \(info.version)").foregroundStyle(.secondary)
                        if let date = info.buildDate {
                            Text("Built \(date.formatted(date: .long, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let commit = info.commit {
                            Text("Commit \(commit)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(copied ? "Copied" : "Copy Info") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(info.diagnosticsText, forType: .string)
                        copied = true
                    }
                    .help("Copy version, build and locations for a bug report")
                }
                .padding(.vertical, 4)
            }
            Section("Locations") {
                location("Application", info.appURL, note: info.isPackagedApp ? nil : "Development build (not an .app)")
                if let data = info.dataDirectory { location("Data", data, note: "Library: database + files") }
                location("Logs", info.logsDirectory, note: nil)
            }
        }
        .formStyle(.grouped)
    }

    private func location(_ title: String, _ url: URL, note: String?) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(url.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let note { Text(note).font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer()
            Button("Reveal in Finder") { reveal(url) }
        }
    }
}
