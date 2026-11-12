import Foundation

/// Holds `caffeinate -i -w <pid>` while at least one Claude call runs, so an idle sleep does not cut a job in half.
/// Closing the lid still sleeps the Mac. `-w` ends caffeinate if the app exits.
public final class KeepAwake: @unchecked Sendable {
    public static let shared = KeepAwake()
    private let lock = NSLock()
    private var count = 0
    private var process: Process?

    public var isHolding: Bool { lock.withLock { process?.isRunning ?? false } }

    public func begin() {
        lock.withLock {
            count += 1
            guard count == 1, ProcessInfo.processInfo.environment["MOS_NO_CAFFEINATE"] != "1" else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            p.arguments = ["-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]
            if (try? p.run()) != nil { process = p }
        }
    }

    public func end() {
        lock.withLock {
            count = max(0, count - 1)
            guard count == 0 else { return }
            process?.terminate(); process = nil
        }
    }
}
