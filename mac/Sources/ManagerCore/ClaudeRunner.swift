import Foundation

public struct ClaudeUsage: Sendable { public var input = 0, output = 0, cacheRead = 0, cacheWrite = 0 }

public struct ClaudeResult: @unchecked Sendable {
    public var structured: [String: Any]
    public var sessionId: String
    public var usage: ClaudeUsage
    public var costUsd: Double
    public var durationMs: Int
}

public struct ClaudeError: Error, CustomStringConvertible {
    public var message: String
    public var sessionNotFound = false
    public var description: String { message }
}

public struct ClaudeRequest: Sendable {
    public var cwd: String
    public var prompt: String
    public var schema: String
    public var model: String
    public var effort: String?
    public var systemPrompt: String?
    public var resume: String?
    public var persist = true
    public var timeout: TimeInterval = 600
}

/// Runs one headless `claude -p` call with structured output.
public struct ClaudeRunner: Sendable {
    public var binary: String

    public init(binary: String? = nil) { self.binary = binary ?? ClaudeRunner.findBinary() }

    public static func findBinary() -> String {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_BIN"], !env.isEmpty { return env }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for p in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "claude"
    }

    public func run(_ r: ClaudeRequest) async throws -> ClaudeResult {
        do { return try await once(r) } catch let e as ClaudeError where e.message.hasPrefix("unparseable") { return try await once(r) }
    }

    private func once(_ r: ClaudeRequest) async throws -> ClaudeResult {
        var args = ["-p", "--output-format", "json", "--model", r.model, "--json-schema", r.schema,
                    "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "project"]
        if let s = r.systemPrompt { args += ["--append-system-prompt", s] }
        if let e = r.effort { args += ["--effort", e] }
        if let s = r.resume { args += ["--resume", s] }
        if !r.persist { args.append("--no-session-persistence") }

        let (out, err, _) = try await ClaudeRunner.exec(binary, args, cwd: r.cwd, stdin: r.prompt, timeout: r.timeout)
        let notFound = (err + out).range(of: "no conversation found|session.*not found", options: [.regularExpression, .caseInsensitive]) != nil
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(out.utf8)) else {
            throw ClaudeError(message: notFound ? "session not found" : "unparseable output: \(String((err.isEmpty ? out : err).prefix(300)))", sessionNotFound: notFound)
        }
        let result: [String: Any]? = (parsed as? [[String: Any]])?.last { $0["type"] as? String == "result" } ?? parsed as? [String: Any]
        guard let res = result else { throw ClaudeError(message: "no result event") }
        if (res["is_error"] as? Bool) == true || (res["subtype"] as? String) != "success" {
            throw ClaudeError(message: "claude error: \(res["subtype"] ?? "") \(String(String(describing: res["result"] ?? "").prefix(300)))", sessionNotFound: notFound)
        }
        var structured = res["structured_output"] as? [String: Any]
        if structured == nil, let s = res["result"] as? String { structured = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] }
        guard let structured else { throw ClaudeError(message: "missing structured_output") }
        let u = res["usage"] as? [String: Any] ?? [:]
        let i = { (k: String) in (u[k] as? NSNumber)?.intValue ?? 0 }
        return ClaudeResult(
            structured: structured, sessionId: res["session_id"] as? String ?? "",
            usage: ClaudeUsage(input: i("input_tokens"), output: i("output_tokens"), cacheRead: i("cache_read_input_tokens"), cacheWrite: i("cache_creation_input_tokens")),
            costUsd: (res["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0, durationMs: (res["duration_ms"] as? NSNumber)?.intValue ?? 0)
    }

    /// Runs a process, writes stdin, and reads stdout/stderr concurrently so large output cannot block the pipe.
    static func exec(_ bin: String, _ args: [String], cwd: String, stdin: String, timeout: TimeInterval) async throws -> (String, String, Int32) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            if bin.contains("/") { p.executableURL = URL(fileURLWithPath: bin); p.arguments = args }
            else { p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = [bin] + args }
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
            p.environment = env
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
            let outBuf = LockedData(), errBuf = LockedData()
            outPipe.fileHandleForReading.readabilityHandler = { h in outBuf.append(h.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { if p.isRunning { p.terminate() } }
            p.terminationHandler = { proc in
                timer.cancel()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outBuf.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errBuf.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: (outBuf.string, errBuf.string, proc.terminationStatus))
            }
            do { try p.run() } catch { cont.resume(throwing: ClaudeError(message: "spawn failed: \(error)")); return }
            timer.resume()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
    }
}

final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
