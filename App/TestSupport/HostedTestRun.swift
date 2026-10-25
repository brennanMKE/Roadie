import Foundation

/// The app is the host of a unit-test bundle (`RoadieTests`, #0193). XCTest sets `XCTestConfigurationFilePath` in the host
/// app's environment before it launches, and never outside a test run, so `AppDelegate` uses this to skip its launch work.
enum HostedTestRun {
    static let isActive = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
