import Foundation
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@Suite struct AboutInfoTests {
    let app = URL(fileURLWithPath: "/Applications/MiniBrain.app")
    let data = URL(fileURLWithPath: "/Users/me/MiniBrain")
    let logs = URL(fileURLWithPath: "/Users/me/Library/Application Support/MiniBrain/Logs")

    @Test func readsVersionBuildTimeAndCommitFromInfoPlist() {
        let info = AboutInfo(
            infoDictionary: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "0.1.0",
                             "MBBuildTime": "2026-11-22T06:10:00Z", "MBGitCommit": "fcdda89-dirty"],
            appURL: app, executableDate: nil, dataDirectory: data, logsDirectory: logs, osVersion: "Version 26.1")
        #expect(info.version == "0.1.0")
        #expect(info.buildDate == ISO8601DateFormatter().date(from: "2026-11-22T06:10:00Z"))
        #expect(info.commit == "fcdda89-dirty")
        #expect(info.isPackagedApp)
    }

    @Test func devRunFallsBackToExecutableDate() {
        let built = Date(timeIntervalSince1970: 1_800_000_000)
        let info = AboutInfo(infoDictionary: [:], appURL: URL(fileURLWithPath: "/repo/.build/release"),
                             executableDate: built, dataDirectory: data, logsDirectory: logs, osVersion: "26")
        #expect(info.version == MiniBrain.version)
        #expect(info.buildDate == built)
        #expect(info.commit == nil)
        #expect(!info.isPackagedApp)
    }

    @Test func diagnosticsTextListsEverythingForBugReports() {
        let info = AboutInfo(
            infoDictionary: ["CFBundleShortVersionString": "0.1.0", "MBBuildTime": "2026-11-22T06:10:00Z", "MBGitCommit": "abc1234"],
            appURL: app, executableDate: nil, dataDirectory: data, logsDirectory: logs, osVersion: "Version 26.1")
        let text = info.diagnosticsText
        for expected in ["MiniBrain 0.1.0", "Built: 2026-11-22T06:10:00Z", "Commit: abc1234", "macOS: Version 26.1",
                         "App: /Applications/MiniBrain.app", "Data: /Users/me/MiniBrain",
                         "Logs: /Users/me/Library/Application Support/MiniBrain/Logs"] {
            #expect(text.contains(expected), "\(expected)")
        }
    }
}
