import Testing
@testable import MiniBrainCore

@Suite struct SmokeTests {
    @Test func smokeTestRuns() {
        #expect(MiniBrain.appName == "MiniBrain")
    }
}
