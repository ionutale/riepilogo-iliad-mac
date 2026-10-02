import Foundation

/// Runs an AppleScript and returns its stdout.
typealias ScriptRunner = @Sendable (_ script: String, _ args: [String]) async throws -> String

/// Fetches the consumi page through Safari (same-origin XHR), for networks
/// that block direct access. Requires Safari's "Allow JavaScript from Apple
/// Events" setting.
struct SafariFetcher: HTMLFetcher {
    let runner: ScriptRunner

    init(runner: @escaping ScriptRunner = SafariFetcher.defaultRunner) {
        self.runner = runner
    }

    func fetchHTML(for account: FetchedAccount) async throws -> String {
        let js = Self.javaScript(username: account.username, password: account.password)
        let out: String
        do {
            out = try await runner(Self.appleScript, [js])
        } catch let error as IliadError {
            if case .network(let message) = error,
               message.contains("Allow JavaScript from Apple Events") ||
               message.contains("JavaScript dagli eventi Apple") {
                throw IliadError.safariJSSetting(
                    "abilita in Safari: Impostazioni > Avanzate > \"Mostra funzioni per sviluppatori web\", poi menu Sviluppo > \"Consenti JavaScript dagli eventi Apple\"")
            }
            throw error
        } catch {
            throw IliadError.network("safari: \(error.localizedDescription)")
        }
        if out.contains("name=\"login-ident\"") {
            throw IliadError.auth("login Safari non riuscito per questo account")
        }
        return out
    }

    // MARK: - Scripts

    static let appleScript = #"""
    on run argv
        set js to item 1 of argv
        tell application "Safari"
            set targetTab to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (URL of t) starts with "https://www.iliad.it" then
                            set targetTab to t
                            exit repeat
                        end if
                    end try
                end repeat
                if targetTab is not missing value then exit repeat
            end repeat
            if targetTab is missing value then
                set newWin to make new document with properties {URL:"https://www.iliad.it/account/login"}
                delay 4
                set targetTab to current tab of newWin
            end if
            return do JavaScript js in targetTab
        end tell
    end run
    """#

    static func javaScript(username: String, password: String) -> String {
        func literal(_ value: String) -> String {
            let data = try! JSONEncoder().encode(value)
            return String(data: data, encoding: .utf8)!
        }
        return """
        (function () {
          function xhr(method, url, body) {
            var x = new XMLHttpRequest();
            x.open(method, url, false);
            if (body) { x.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded'); }
            x.send(body || null);
            return x;
          }
          xhr('GET', '/account/?logout=user');
          xhr('POST', '/account/login', 'login-ident=' + encodeURIComponent(\(literal(username))) + '&login-pwd=' + encodeURIComponent(\(literal(password))));
          return xhr('GET', '/account/consumi-e-credito').responseText;
        })()
        """
    }

    /// Hard cap on a single osascript run.
    private static let runnerTimeout: TimeInterval = 60

    /// Runs osascript with the script and the JS as an argument.
    ///
    /// The run is bounded so a wedged osascript — a Safari modal dialog, an
    /// automation prompt, a blocked `delay` — cannot stall a refresh forever:
    /// the child is terminated after `Self.runnerTimeout` seconds, and
    /// immediately when the calling task is cancelled. Cancellation before the
    /// process even starts fails fast without spawning one.
    static let defaultRunner: ScriptRunner = { script, args in
        let limit = Self.runnerTimeout
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                DispatchQueue.global().async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", script, "--"] + args
                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: IliadError.network("osascript: \(error.localizedDescription)"))
                        return
                    }
                    // Adopting the process also covers cancellation that landed
                    // between the check above and `run()`. `Task.isCancelled` is
                    // deliberately not re-read here: inside a GCD block there is
                    // no current task, so it would always report false.
                    box.store(process)

                    let deadline = DispatchWorkItem { box.expire() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: deadline)

                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    deadline.cancel()
                    if process.terminationStatus != 0 {
                        if box.didTimeOut {
                            continuation.resume(throwing: IliadError.network("osascript: timeout \(Int(limit)) s"))
                            return
                        }
                        let message = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
                        continuation.resume(throwing: IliadError.network(message))
                        return
                    }
                    continuation.resume(returning: String(data: outData, encoding: .utf8) ?? "")
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

/// Holds the running `osascript` so the timeout and the cancellation handler
/// can terminate it. `Process` is not `Sendable`, so every access goes through
/// the lock.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    /// Adopts a freshly started process. If cancellation was already requested
    /// while it was being built, it is terminated straight away.
    func store(_ process: Process) {
        lock.lock()
        let stopNow = cancelled
        if !stopNow { self.process = process }
        lock.unlock()
        if stopNow { process.terminate() }
    }

    /// Records the cancellation request and kills the process if it is still
    /// running. Idempotent, so it is safe from the cancellation handler and
    /// from the start race at the same time.
    func terminate() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    /// Called by the deadline: records that the run went over the limit and
    /// kills the process, so the reads unblock and the non-zero exit is
    /// reported as a timeout.
    func expire() {
        lock.lock()
        timedOut = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }; return timedOut
    }
}
