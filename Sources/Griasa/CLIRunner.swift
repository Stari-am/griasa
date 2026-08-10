import Foundation

/// Answers AI requests through a locally installed vendor CLI — Claude Code
/// (`claude -p`) or Codex (`codex exec`) — using the CLI's own subscription
/// login instead of an API key. This is the supported headless mode of both
/// tools; no UI scripting of the desktop apps is involved.
enum CLIRunner {
    /// Explicit path override keys (Settings) — checked before the usual dirs.
    static func overrideKey(for provider: LLMProvider) -> String {
        provider == .claudeCLI ? "claudeCLIPath" : "codexCLIPath"
    }

    /// Resolved binary path, or nil when the CLI isn't installed. GUI apps
    /// don't inherit the shell PATH, so we probe the common install dirs.
    static func locate(_ provider: LLMProvider) -> String? {
        let binary = provider == .claudeCLI ? "claude" : "codex"
        let override = (UserDefaults.standard.string(forKey: overrideKey(for: provider)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = override.isEmpty ? [] : [(override as NSString).expandingTildeInPath]
        candidates += [
            "\(home)/.local/bin/\(binary)",
            "/opt/homebrew/bin/\(binary)",
            "/usr/local/bin/\(binary)",
            "\(home)/bin/\(binary)",
            "\(home)/.bun/bin/\(binary)",
            "\(home)/.npm-global/bin/\(binary)",
            "\(home)/.volta/bin/\(binary)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func complete(_ config: LLMConfig, system: String, user: String,
                         model: String, timeout: TimeInterval) async throws -> String {
        guard !config.baseURL.isEmpty else {
            throw NSError(domain: "Griasa", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "\(config.provider.displayName): CLI not found. Install it or set the path in Settings → AI."
            ])
        }
        switch config.provider {
        case .claudeCLI:
            return try await claudeComplete(binary: config.baseURL, system: system,
                                            user: user, model: model, timeout: timeout)
        case .codexCLI:
            return try await codexComplete(binary: config.baseURL, system: system,
                                           user: user, model: model, timeout: timeout)
        default:
            fatalError("CLIRunner called for a non-CLI provider")
        }
    }

    // MARK: - Claude Code

    private static func claudeComplete(binary: String, system: String, user: String,
                                       model: String, timeout: TimeInterval) async throws -> String {
        // --system-prompt replaces the coding-assistant persona; --tools ""
        // and --max-turns 1 make it a pure completion.
        // --exclude-dynamic-system-prompt-sections drops the environment/repo
        // context Claude Code prepends by default — measurably faster and
        // stops that context from steering the answer.
        // The user message rides stdin — transcripts can exceed ARG_MAX.
        var args = ["-p", "--output-format", "text", "--max-turns", "1",
                    "--tools", "", "--exclude-dynamic-system-prompt-sections",
                    "--system-prompt", system]
        if !model.isEmpty { args += ["--model", model] }
        let result = try await run(binary: binary, args: args, stdin: user, timeout: timeout)
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode != 0 || text.isEmpty {
            throw classify(provider: "Claude Code",
                           output: text.isEmpty ? result.stderr : text,
                           loginHint: "Open Terminal, run `claude`, and log in with your subscription.")
        }
        return text
    }

    // MARK: - Codex

    private static func codexComplete(binary: String, system: String, user: String,
                                      model: String, timeout: TimeInterval) async throws -> String {
        // codex exec prints progress to stdout; the reliable channel for the
        // final answer is --output-last-message. No system-prompt flag, so it
        // is prepended to the prompt.
        let lastMessage = FileManager.default.temporaryDirectory
            .appendingPathComponent("griasa-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: lastMessage) }
        var args = ["exec", "--skip-git-repo-check",
                    "--output-last-message", lastMessage.path, "-"]
        if !model.isEmpty { args.insert(contentsOf: ["-m", model], at: 1) }
        let prompt = system + "\n\n" + user
        let result = try await run(binary: binary, args: args, stdin: prompt, timeout: timeout)
        let text = (try? String(contentsOf: lastMessage, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if result.exitCode != 0 || text.isEmpty {
            throw classify(provider: "Codex",
                           output: text.isEmpty ? result.stderr : text,
                           loginHint: "Open Terminal, run `codex login`, and sign in with ChatGPT.")
        }
        return text
    }

    /// Login and usage-limit failures become AIProviderError so the existing
    /// account alert fires — with CLI-appropriate advice, not API-key advice.
    private static func classify(provider: String, output: String, loginHint: String) -> Error {
        let tail = String(output.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = tail.lowercased()
        if lower.contains("not logged in") || lower.contains("login") || lower.contains("unauthorized") {
            return AIProviderError(provider: provider, status: 401, detail: tail,
                                   adviceOverride: loginHint)
        }
        if lower.contains("usage limit") || lower.contains("rate limit") || lower.contains("quota") {
            return AIProviderError(provider: provider, status: 429, detail: tail,
                                   adviceOverride: "Your subscription's usage limit is reached — it resets on its own schedule.")
        }
        return NSError(domain: "Griasa", code: 8, userInfo: [
            NSLocalizedDescriptionKey: "\(provider) CLI failed: \(tail.isEmpty ? "no output" : tail)"
        ])
    }

    // MARK: - Process plumbing

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(binary: String, args: [String], stdin: String,
                            timeout: TimeInterval) async throws -> RunResult {
        try await Task.detached(priority: .userInitiated) {
            try runBlocking(binary: binary, args: args, stdin: stdin, timeout: timeout)
        }.value
    }

    /// Deliberately synchronous — Process pipes and waitUntilExit are blocking
    /// IO, kept off the cooperative pool's async contexts (runs on a detached
    /// task's thread).
    private static func runBlocking(binary: String, args: [String], stdin: String,
                                    timeout: TimeInterval) throws -> RunResult {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            // Neutral cwd so the CLI never picks up some project's context;
            // strip ANTHROPIC_API_KEY — subscription auth is the whole point.
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            let binDir = (binary as NSString).deletingLastPathComponent
            env["PATH"] = "\(binDir):/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
            process.environment = env

            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe

            try process.run()

            // Feed stdin off this thread; the child reads all input before
            // answering, so this can't deadlock against the output reads.
            DispatchQueue.global(qos: .utility).async {
                if let data = stdin.data(using: .utf8) {
                    try? inPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try? inPipe.fileHandleForWriting.close()
            }
            var timedOut = false
            let killer = DispatchWorkItem {
                timedOut = true
                process.terminate()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

            // Drain stderr concurrently so neither pipe buffer can fill up.
            var errData = Data()
            let errDone = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                errDone.signal()
            }
            let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            killer.cancel()
            errDone.wait()

            if timedOut {
                throw NSError(domain: "Griasa", code: 9, userInfo: [
                    NSLocalizedDescriptionKey: "CLI request timed out after \(Int(timeout))s"
                ])
            }
            return RunResult(exitCode: process.terminationStatus,
                             stdout: String(data: outData, encoding: .utf8) ?? "",
                             stderr: String(data: errData, encoding: .utf8) ?? "")
    }
}
