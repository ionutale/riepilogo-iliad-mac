import Foundation

/// Whether this process is an XCTest run.
///
/// The test bundle is app-hosted (`TEST_HOST` points at the app binary), so
/// `RiepilogoIliadApp.init()` runs during `make test`. Without this predicate the
/// whole suite booted the real app: it created/opened the developer's production
/// `iliad.db`, ran the 180-day retention prune against their history, put an icon
/// in the menu bar, asked for notification permission, and — once accounts are
/// configured — performed real authenticated logins against iliad.it and drove
/// Safari through `osascript`. Tests must never touch the user's data or
/// credentials.
enum AppBootstrap {
    static var isRunningTests: Bool {
        // XCTest exports this in the environment of the host process it injects
        // itself into, which is why it is visible from `App.init()`.
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
