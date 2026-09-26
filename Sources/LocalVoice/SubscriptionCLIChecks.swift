import Foundation
import Darwin

/// Focused checks for the optional CLI handoff adapter. They exercise argument
/// construction, the environment allowlist, the OS sandbox profile, event
/// parsing for complete, partial, failed and forbidden streams, sign-in
/// fixtures, and candidate fallback through an injected probe.
///
/// Nothing here launches an assistant CLI, reads a real credential file or
/// starts any inference: every provider answer is a synthetic fixture string.
enum SubscriptionCLIChecks {

    // MARK: Deterministic checks

    static func run() throws {
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw VoiceError.message("SUBSCRIPTION CLI CHECK FAILED: \(label)") }
            count += 1
        }
        func rejects(_ label: String, _ body: () throws -> Void) throws {
            do { try body() } catch { count += 1; return }
            throw VoiceError.message("SUBSCRIPTION CLI CHECK FAILED: \(label)")
        }
        func value(after flag: String, in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        // Provider surface
        try check(SubscriptionProvider.allCases.map(\.id) == ["codex", "claude"], "both providers are offered")
        try check(SubscriptionProvider.codex.title == "Codex" && SubscriptionProvider.claude.title == "Claude Code", "frozen provider titles")
        let encoded = try JSONEncoder().encode([SubscriptionProvider.claude, .codex])
        try check(try JSONDecoder().decode([SubscriptionProvider].self, from: encoded) == [.claude, .codex], "provider selection survives saving")
        let missing = SubscriptionConnection.unavailable(.codex, "Not installed.")
        try check(missing.id == "codex" && !missing.ready && missing.executable == nil && missing.version.isEmpty, "unavailable connection carries no executable")

        // Candidate search
        let home = URL(fileURLWithPath: "/Users/fixture")
        let codexCandidates = SubscriptionCLICandidates.urls(for: .codex, home: home).map(\.path)
        try check(codexCandidates.first == "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", "official bundled Codex is tried first")
        for expected in ["/Applications/ChatGPT.app/Contents/Resources/codex",
                         "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
                         "/Users/fixture/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                         "/Users/fixture/Applications/Codex.app/Contents/Resources/codex",
                         "/opt/homebrew/bin/codex",
                         "/Users/fixture/.local/bin/codex"] {
            try check(codexCandidates.contains(expected), "Codex candidate \(expected)")
        }
        try check(Set(codexCandidates).count == codexCandidates.count, "no repeated Codex candidate")
        let claudeCandidates = SubscriptionCLICandidates.urls(for: .claude, home: home).map(\.path)
        try check(claudeCandidates.first == "/opt/homebrew/bin/claude", "installed Claude Code is tried first")
        try check(claudeCandidates.contains("/Users/fixture/.claude/local/claude"), "Claude Code local install is a candidate")
        try check(!claudeCandidates.contains(where: { $0.contains("codex") }), "provider candidates stay separate")

        // Reported versions
        try check(SubscriptionVersionCheck.parse("2.1.236 (Claude Code)") == "2.1.236", "Claude Code version text")
        try check(SubscriptionVersionCheck.parse("codex-cli 0.158.0-alpha.2.1") == "0.158.0-alpha.2.1", "Codex prerelease version text")
        try check(SubscriptionVersionCheck.parse("claude version v1.2.3") == "1.2.3", "leading v ignored")
        try check(SubscriptionVersionCheck.parse("command not found") == nil, "a broken wrapper reports no version")
        try check(SubscriptionVersionCheck.parse("") == nil, "empty output reports no version")
        try check(SubscriptionVersionCheck.isSupported("2.1.236", provider: .claude), "installed Claude Code is supported")
        try check(!SubscriptionVersionCheck.isSupported("2.0.999", provider: .claude), "older Claude Code is refused")
        try check(SubscriptionVersionCheck.isSupported("0.158.0-alpha.2.1", provider: .codex), "installed Codex is supported")
        try check(!SubscriptionVersionCheck.isSupported("0.157.9", provider: .codex), "older Codex is refused")
        try check(SubscriptionVersionCheck.isSupported("1.0.0", provider: .codex), "a later Codex major version is supported")

        // Environment allowlist
        let inherited = [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/fixture", "USER": "fixture", "LOGNAME": "fixture",
            "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8", "LC_ALL": "C", "TERM": "xterm-256color",
            "__CF_USER_TEXT_ENCODING": "0x1F5:0:0", "XPC_FLAGS": "0x0", "XPC_SERVICE_NAME": "0",
            "ANTHROPIC_API_KEY": "fixture-secret", "OPENAI_API_KEY": "fixture-secret",
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:1", "ANTHROPIC_AUTH_TOKEN": "fixture-secret",
            "CLAUDE_CODE_OAUTH_TOKEN": "fixture-secret", "CODEX_HOME": "/tmp/fixture-codex",
            "CLAUDE_CODE_TMPDIR": "/tmp/fixture-shared-claude", "CLAUDE_CONFIG_DIR": "/tmp/fixture-claude", "AWS_SECRET_ACCESS_KEY": "fixture-secret",
            "SSH_AUTH_SOCK": "/tmp/fixture.sock", "NODE_OPTIONS": "--inspect", "HTTPS_PROXY": "http://127.0.0.1:2",
            "TMPDIR": "/private/var/folders/fixture/",
        ]
        let sanitized = SubscriptionEnvironment.sanitized(inherited)
        try check(Set(sanitized.keys) == Set(["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TERM", "__CF_USER_TEXT_ENCODING", "XPC_FLAGS", "XPC_SERVICE_NAME"]), "only ordinary variables are forwarded")
        try check(!sanitized.values.contains("fixture-secret"), "no inherited credential value survives")
        try check(sanitized["TMPDIR"] == nil, "an inherited temporary directory is not forwarded")
        for name in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_BASE_URL", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "NODE_OPTIONS", "HTTPS_PROXY"] {
            try check(SubscriptionEnvironment.isProviderOverride(name) && sanitized[name] == nil, "provider override \(name) is excluded")
        }
        let scratch = URL(fileURLWithPath: "/Users/fixture/Jobs/job-1/.workbench-handoff/tmp")
        let scoped = SubscriptionEnvironment.sanitized(inherited, scratch: scratch)
        try check(scoped["TMPDIR"] == scratch.path, "temporary files are kept inside the job folder")
        try check(scoped["HOME"] == "/Users/fixture", "the CLI keeps its own home so it finds its own sign-in")
        try check(sanitized["CLAUDE_CODE_TMPDIR"] == nil, "an inherited Claude temp override is excluded")
        let claudeScoped = SubscriptionEnvironment.sanitized(inherited, scratch: scratch, provider: .claude)
        try check(claudeScoped["CLAUDE_CODE_TMPDIR"] == scratch.path && claudeScoped["TMPDIR"] == scratch.path,
                  "Claude internal and ordinary temporary files use the app-owned job scratch directory")
        let codexScoped = SubscriptionEnvironment.sanitized(inherited, scratch: scratch, provider: .codex)
        try check(codexScoped["CLAUDE_CODE_TMPDIR"] == nil, "the Claude-specific override is not forwarded to Codex")

        // Claude argument construction
        let claudeArguments = SubscriptionCLIPlanner.claude()
        try check(claudeArguments.last == "-p", "Claude takes the prompt from standard input")
        try check(claudeArguments.contains("--safe-mode"), "hooks, plugins and customisations are disabled")
        try check(!claudeArguments.contains("--bare"), "the person's own sign-in is never disabled")
        try check(!claudeArguments.contains("--dangerously-skip-permissions"), "no permission bypass flag")
        try check(value(after: "--tools", in: claudeArguments) == "", "tools are disabled")
        try check(value(after: "--permission-mode", in: claudeArguments) == "dontAsk", "no interactive permission prompt")
        try check(value(after: "--mcp-config", in: claudeArguments) == "{\"mcpServers\":{}}", "no MCP server is configured")
        try check(value(after: "--output-format", in: claudeArguments) == "stream-json", "results arrive as a readable event stream")
        for flag in ["--no-chrome", "--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands", "--verbose", "-p"] {
            try check(claudeArguments.contains(flag), "Claude Code flag \(flag)")
        }

        // Codex argument construction
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubscriptionCLIChecks-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = SubscriptionJobPaths(root: directory)
        let first = job.root.appendingPathComponent("inputs/screen-1.png")
        let second = job.root.appendingPathComponent("inputs/screen-2.png")
        try FileManager.default.createDirectory(at: job.root.appendingPathComponent("inputs"), withIntermediateDirectories: true)
        try Data("synthetic-image-bytes".utf8).write(to: first)
        try Data("synthetic-image-bytes".utf8).write(to: second)
        let codexArguments = try SubscriptionCLIPlanner.codex(images: [first, second], job: job)
        try check(codexArguments.first == "exec", "a non-interactive Codex turn")
        try check(Array(codexArguments.suffix(2)) == ["--json", "-"], "events as JSON and the prompt on standard input")
        try check(!codexArguments.contains(where: { $0.contains("rm -rf") }), "no prompt text reaches the arguments")
        for flag in ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check"] {
            try check(codexArguments.contains(flag), "Codex flag \(flag)")
        }
        try check(value(after: "--sandbox", in: codexArguments) == "read-only", "Codex's own sandbox is read-only")
        let settings = codexArguments.enumerated().filter { $0.element == "-c" }.map { codexArguments[$0.offset + 1] }
        for setting in ["approval_policy=\"never\"", "web_search=\"disabled\"", "cli_auth_credentials_store=\"file\"", "project_doc_max_bytes=0",
                        "log_dir=\"\(job.logs.path)\"", "sqlite_home=\"\(job.state.path)\"",
                        "features.skip_host_skill_discovery=true"] {
            try check(settings.contains(setting), "Codex setting \(setting)")
        }
        for feature in SubscriptionCLIPlanner.codexDisabledFeatures {
            try check(settings.contains("features.\(feature)=false"), "Codex feature \(feature) is disabled")
        }
        for feature in ["shell_tool", "unified_exec", "browser_use", "computer_use", "multi_agent", "multi_agent_v2",
                        "hooks", "plugins", "memories", "in_app_local_automation", "code_mode"] {
            try check(SubscriptionCLIPlanner.codexDisabledFeatures.contains(feature), "\(feature) is in the disabled list")
        }
        try check(settings.allSatisfy { $0.hasPrefix("features.") ? $0.hasSuffix("=false") || $0 == "features.skip_host_skill_discovery=true" : true }, "only the skill-discovery skip is enabled")
        let imageFlags = codexArguments.enumerated().filter { $0.element == "-i" }.map { codexArguments[$0.offset + 1] }
        try check(imageFlags == [first.path, second.path], "each selected image is passed once by path")
        let batch = (0..<45).map { job.root.appendingPathComponent("inputs/screen-\($0).png") }
        for image in batch { try Data("synthetic-image-bytes".utf8).write(to: image) }
        let acceptedBatch = try SubscriptionCLI.validated(batch, in: job.root, provider: .codex)
        let batchArguments = try SubscriptionCLIPlanner.codex(images: acceptedBatch, job: job)
        let batchPaths = batchArguments.enumerated().filter { $0.element == "-i" }.map { batchArguments[$0.offset + 1] }
        try check(batchPaths == batch.map(\.path), "a selected 45-image batch retains every image and its order")
        try rejects("a path that cannot be quoted safely") { _ = try SubscriptionCLIPlanner.tomlString("/tmp/job\"name") }

        // Job folder boundary
        try check(try SubscriptionJobDirectory.validate(job.root, home: home).path == SubscriptionPaths.resolved(job.root).path, "a prepared job folder is accepted")
        let syntheticHome = directory.appendingPathComponent("home/fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: syntheticHome.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        for refused in [syntheticHome, syntheticHome.deletingLastPathComponent(), URL(fileURLWithPath: "/"),
                        URL(fileURLWithPath: "/Users"), syntheticHome.appendingPathComponent("Documents")] {
            try rejects("library or home folder refused: \(refused.lastPathComponent)") {
                _ = try SubscriptionJobDirectory.validate(refused, home: syntheticHome)
            }
        }
        try rejects("a missing job folder") { _ = try SubscriptionJobDirectory.validate(directory.appendingPathComponent("absent"), home: home) }
        try rejects("a file is not a job folder") { _ = try SubscriptionJobDirectory.validate(first, home: home) }

        // Sandbox profile
        let claudeProfile = SubscriptionSandbox.profile(for: .claude, purpose: .inference)
        let codexProfile = SubscriptionSandbox.profile(for: .codex, purpose: .inference)
        let codexStatusProfile = SubscriptionSandbox.profile(for: .codex, purpose: .status)
        for fragment in ["(deny file-write*)", "(subpath \"/Users\")", "(subpath \"/private/tmp\")",
                         "(subpath \"/private/var/folders\")", "(subpath \"/Volumes\")", "(subpath \"/Network\")",
                         "(deny appleevent-send)", "(deny network-inbound)",
                         "(allow file-read* file-write* (subpath (param \"WRITE_ROOT\")))"] {
            try check(claudeProfile.contains(fragment) && codexProfile.contains(fragment), "profile rule \(fragment)")
        }
        try check(claudeProfile.contains("\"/.claude.json\"") && claudeProfile.contains("\"/Library/Keychains/login.keychain-db\""), "Claude Code reads only its own sign-in")
        try check(!claudeProfile.contains(".codex"), "one provider's profile never opens the other's files")
        try check(codexProfile.contains("\"/.codex/auth.json\"") && !codexProfile.contains("config.toml"), "an inference turn never sees Codex configuration")
        try check(codexStatusProfile.contains("config.toml"), "the CLI status command can read its configuration")
        try job.prepare(codexProfile)
        let scratchPermissions = try FileManager.default.attributesOfItem(atPath: job.scratch.path)[.posixPermissions] as? NSNumber
        try check(scratchPermissions?.intValue == 0o700, "the app-owned temp base is private to this user")
        let nativeWrites = codexProfile.split(separator: "\n").filter { $0.contains("allow file-write") }
        try check(nativeWrites.filter { $0.contains("installation_id") }.count == 1, "only the installation identifier receives a native-home write allowance")
        try check(!nativeWrites.contains(where: { $0.contains("auth.json") || $0.contains("keychain") }), "credential files receive no write allowance")
        guard let denyIndex = claudeProfile.range(of: "(deny file-read*")?.lowerBound,
              let allowIndex = claudeProfile.range(of: "(param \"WRITE_ROOT\")")?.lowerBound else {
            throw VoiceError.message("SUBSCRIPTION CLI CHECK FAILED: profile rule order")
        }
        try check(denyIndex < allowIndex, "the job folder allowance follows the denials that it overrides")
        try check(SubscriptionSandbox.installRoot(for: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")).path == "/Applications/ChatGPT.app/Contents/Resources/codex-cli", "bundled install root")
        try check(SubscriptionSandbox.installRoot(for: URL(fileURLWithPath: "/fixture/opt/homebrew/bin/claude")).path == "/fixture/opt/homebrew", "installed Claude Code root")
        let sandboxArguments = SubscriptionSandbox.arguments(profile: job.profile, writeRoot: job.root, userRoot: home,
                                                            installRoot: URL(fileURLWithPath: "/opt/homebrew"),
                                                            executable: URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                                                            arguments: claudeArguments)
        try check(Array(sandboxArguments.prefix(7)) == ["-D", "WRITE_ROOT=" + job.root.path, "-D", "USER_ROOT=" + home.path,
                                                       "-D", "INSTALL_ROOT=/opt/homebrew", "-f"], "sandbox parameters precede the profile")
        try check(sandboxArguments[7] == job.profile.path && sandboxArguments[8] == "/opt/homebrew/bin/claude", "the profile wraps the chosen executable")
        try check(Array(sandboxArguments.dropFirst(9)) == claudeArguments, "the CLI's own arguments are unchanged")

        // Claude event stream
        let claudeInit = "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"session-fixture\"}"
        try check(SubscriptionStreamParser.event(provider: .claude, line: claudeInit) == .session("session-fixture"), "the session identifier is reported early")
        let claudeResult = "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"Prepared draft.\",\"session_id\":\"session-fixture\",\"total_cost_usd\":0.42}"
        try check(SubscriptionStreamParser.event(provider: .claude, line: claudeResult) == .result(text: "Prepared draft.", session: "session-fixture", failure: nil), "a successful result carries text and session")
        let claudeFailure = "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"result\":\"Something went wrong\"}"
        if case .result(let text, _, let failure) = SubscriptionStreamParser.event(provider: .claude, line: claudeFailure) {
            try check(text == nil && failure == "Something went wrong", "a reported error is not treated as a reply")
        } else { throw VoiceError.message("SUBSCRIPTION CLI CHECK FAILED: Claude failure result") }
        let claudeTool = "{\"type\":\"assistant\",\"session_id\":\"session-fixture\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}}]}}"
        if case .forbidden(let message) = SubscriptionStreamParser.event(provider: .claude, line: claudeTool) {
            try check(message.contains("Bash"), "an attempted tool is named in the refusal")
        } else { throw VoiceError.message("SUBSCRIPTION CLI CHECK FAILED: Claude tool use must be forbidden") }
        let claudeToolResult = "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"output\"}]}}"
        try check(isForbidden(SubscriptionStreamParser.event(provider: .claude, line: claudeToolResult)), "a tool result is forbidden")
        try check(SubscriptionStreamParser.event(provider: .claude, line: "Warning: something") == .ignored, "a non-JSON line is not an event")
        try check(SubscriptionStreamParser.event(provider: .claude, line: "{\"type\":\"stream_event\"}") == .ignored, "an unrelated event is ignored")

        // Codex event stream
        try check(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"thread.started\",\"thread_id\":\"thread-fixture\"}") == .session("thread-fixture"), "the Codex thread identifier is reported")
        try check(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Prepared draft.\"}}") == .text("Prepared draft."), "an agent message is reply text")
        try check(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"item.completed\",\"item\":{\"item_type\":\"agent_message\",\"text\":\"Second form.\"}}") == .text("Second form."), "the alternative item key is understood")
        try check(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"turn.completed\"}") == .result(text: nil, session: nil, failure: nil), "a completed turn ends the run")
        if case .result(_, _, let failure) = SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"turn.failed\",\"error\":{\"message\":\"usage limit reached\"}}") {
            try check(failure == "usage limit reached", "a failed turn reports its reason")
        } else { throw VoiceError.message("SUBSCRIPTION CLI CHECK FAILED: Codex turn.failed") }
        if case .result(_, _, let failure) = SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"error\",\"message\":\"stream interrupted\"}") {
            try check(failure == "stream interrupted", "a stream error ends the run")
        } else { throw VoiceError.message("SUBSCRIPTION CLI CHECK FAILED: Codex error event") }
        for forbidden in SubscriptionStreamParser.forbiddenCodexTypes.sorted() {
            let line = "{\"type\":\"item.completed\",\"item\":{\"type\":\"\(forbidden)\"}}"
            try check(isForbidden(SubscriptionStreamParser.event(provider: .codex, line: line)), "\(forbidden) is refused")
            try check(isForbidden(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"\(forbidden)\"}")), "a top-level \(forbidden) event is refused")
        }
        try check(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"item.completed\",\"item\":{\"type\":\"reasoning\"}}") == .ignored, "reasoning items are ignored")

        // Folding a stream into one result
        var complete = SubscriptionStreamState()
        for line in ["{\"type\":\"thread.started\",\"thread_id\":\"thread-fixture\"}",
                     "{\"type\":\"item.completed\",\"item\":{\"type\":\"reasoning\"}}",
                     "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"First part.\"}}",
                     "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Second part.\"}}",
                     "{\"type\":\"turn.completed\"}"] {
            complete.apply(SubscriptionStreamParser.event(provider: .codex, line: line))
        }
        let resolved = try complete.resolve(provider: .codex, status: 0, standardError: "")
        try check(resolved.providerSessionID == "thread-fixture" && resolved.text == "First part.\n\nSecond part.", "a complete Codex turn returns its whole reply")

        var partial = SubscriptionStreamState()
        partial.apply(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"thread.started\",\"thread_id\":\"thread-fixture\"}"))
        partial.apply(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Half an answer\"}}"))
        try rejects("a partial stream is never returned as a result") { _ = try partial.resolve(provider: .codex, status: 0, standardError: "") }

        var successThenFailure = SubscriptionStreamState()
        successThenFailure.apply(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Text\"}}"))
        successThenFailure.apply(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"turn.completed\"}"))
        try rejects("a non-zero exit is a failure even with a complete turn") { _ = try successThenFailure.resolve(provider: .codex, status: 3, standardError: "codex: broken pipe") }

        var claudeState = SubscriptionStreamState()
        claudeState.apply(SubscriptionStreamParser.event(provider: .claude, line: claudeInit))
        claudeState.apply(SubscriptionStreamParser.event(provider: .claude, line: claudeResult))
        let claudeResolved = try claudeState.resolve(provider: .claude, status: 0, standardError: "")
        try check(claudeResolved.text == "Prepared draft." && claudeResolved.providerSessionID == "session-fixture", "a complete Claude Code turn returns its reply")

        var emptyResult = SubscriptionStreamState()
        emptyResult.apply(SubscriptionStreamParser.event(provider: .claude, line: "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"   \"}"))
        try rejects("an empty reply is incomplete, not success") { _ = try emptyResult.resolve(provider: .claude, status: 0, standardError: "") }

        var violation = SubscriptionStreamState()
        violation.apply(SubscriptionStreamParser.event(provider: .claude, line: claudeTool))
        violation.apply(SubscriptionStreamParser.event(provider: .claude, line: claudeResult))
        do {
            _ = try violation.resolve(provider: .claude, status: 0, standardError: "")
            throw VoiceError.message("SUBSCRIPTION CLI CHECK FAILED: a boundary violation must not return text")
        } catch let error as SubscriptionCLIError {
            guard case .boundary = error else { throw VoiceError.message("SUBSCRIPTION CLI CHECK FAILED: violation reported as \(error)") }
            count += 1
        }

        // The live sink: one session callback, immediate stop on a violation
        let sessions = SubscriptionCheckBox()
        let sink = SubscriptionStreamSink(provider: .claude, onSession: { [sessions] id in sessions.append(id) })
        try check(sink.accept(claudeInit) == nil, "an ordinary line does not stop the run")
        _ = sink.accept("{\"type\":\"assistant\",\"session_id\":\"other-session\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Thinking\"}]}}")
        try check(sessions.values == ["session-fixture"], "the session identifier is reported once")
        try check(sink.accept(claudeTool) != nil, "a forbidden tool stops the run immediately")
        try check(sink.snapshot().violation != nil, "the violation is recorded")

        // Sign-in fixtures. Account details in a fixture must not reach the UI.
        let claudeReady = "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"subscriptionType\":\"max\",\"email\":\"person@example.com\",\"organization\":\"Example Ltd\"}"
        try check(summary(SubscriptionAuth.claude(claudeReady)) == "max", "a Claude subscription sign-in is ready")
        try check(isReady(SubscriptionAuth.claude(claudeReady)), "readiness comes from the CLI's own answer")
        try check(!summary(SubscriptionAuth.claude(claudeReady)).contains("person@example.com"), "no account identifier is kept")
        try check(isReady(SubscriptionAuth.claude("{\"logged_in\":true,\"auth_method\":\"claude.ai\",\"subscription_type\":\"pro\"}")), "the alternative key spelling is understood")
        for plan in ["pro", "max", "team", "enterprise"] {
            try check(isReady(SubscriptionAuth.claude("{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"subscriptionType\":\"\(plan)\"}")), "\(plan) subscription accepted")
        }
        for refused in ["{\"loggedIn\":false,\"authMethod\":\"claude.ai\",\"subscriptionType\":\"max\"}",
                        "{\"loggedIn\":true,\"authMethod\":\"apiKey\",\"subscriptionType\":\"max\"}",
                        "{\"loggedIn\":true,\"authMethod\":\"bedrock\",\"subscriptionType\":\"enterprise\"}",
                        "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"subscriptionType\":\"free\"}",
                        "{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}"] {
            try check(!isReady(SubscriptionAuth.claude(refused)), "refused Claude sign-in: \(refused.prefix(48))")
        }
        if case .unreadable = SubscriptionAuth.claude("claude: unknown command") { count += 1 }
        else { throw VoiceError.message("SUBSCRIPTION CLI CHECK FAILED: unreadable Claude status") }
        try check(isReady(SubscriptionAuth.codex("Logged in using ChatGPT")), "a ChatGPT sign-in is ready")
        try check(isReady(SubscriptionAuth.status(for: .codex, status: .init(status: 0, standardOutput: "", standardError: "Logged in using ChatGPT\n"))), "the actual Codex stderr status is accepted")
        try check(!isReady(SubscriptionAuth.status(for: .codex, status: .init(status: 1, standardOutput: "", standardError: "Logged in using ChatGPT\n"))), "a failed Codex status cannot establish readiness")
        try check(!isReady(SubscriptionAuth.status(for: .codex, status: .init(status: 0, standardOutput: "", standardError: "Logged in using an API key\n"))), "stderr API auth is refused")
        try check(SubscriptionVersionCheck.parse("unrelated 0.158.0", provider: .codex) == nil, "an unrelated program cannot establish a supported CLI")
        try check(isReady(SubscriptionAuth.codex("  Logged in using ChatGPT  \nAccount: person@example.com\n")), "surrounding lines do not change the outcome")
        try check(summary(SubscriptionAuth.codex("Logged in using ChatGPT\nperson@example.com")) == "ChatGPT", "no Codex account identifier is kept")
        for refused in ["Not logged in", "Logged in using an API key", "Logged in using ChatGPT account for work",
                        "logged in using chatgpt"] {
            try check(!isReady(SubscriptionAuth.codex(refused)), "refused Codex status: \(refused)")
        }
        if case .unreadable = SubscriptionAuth.codex("   \n") { count += 1 }
        else { throw VoiceError.message("SUBSCRIPTION CLI CHECK FAILED: unreadable Codex status") }
        try check(SubscriptionCLI.authArguments(for: .claude) == ["--safe-mode", "auth", "status", "--json"], "the Claude status probe stays in safe mode")
        try check(SubscriptionCLI.authArguments(for: .codex) == ["login", "status", "-c", "cli_auth_credentials_store=\"file\""], "the Codex status probe matches the inference credential store")

        // Short, redacted failures
        let noisy = "starting\nAuthorization: Bearer sk-fixture-secret\nANTHROPIC_API_KEY=sk-fixture-secret\nError: the model is overloaded"
        let redacted = SubscriptionRedaction.short(noisy)
        try check(redacted.contains("the model is overloaded"), "a useful failure survives")
        try check(!redacted.contains("sk-fixture-secret") && !redacted.lowercased().contains("bearer"), "credential-looking output is dropped")
        try check(SubscriptionRedaction.short(String(repeating: "detail ", count: 400)).count <= SubscriptionCLILimits.maximumFailureCharacters + 1, "failure text is bounded")
        try check(SubscriptionRedaction.short("   \n  ").isEmpty, "empty output produces no failure text")

        print("SUBSCRIPTION_CLI_CHECKS_OK: \(count) checks passed")
    }

    // MARK: Discovery and refusal checks

    /// Exercises candidate fallback, sign-in outcomes and every input refusal
    /// through the injected probe seam. No assistant CLI is launched.
    static func runAdapterChecks() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw VoiceError.message("SUBSCRIPTION CLI ADAPTER CHECK FAILED: \(label)") }
            count += 1
        }

        let bundled = URL(fileURLWithPath: "/fixture/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        let brokenWrapper = URL(fileURLWithPath: "/fixture/.local/bin/codex")
        let outdated = URL(fileURLWithPath: "/fixture/homebrew/bin/codex")

        // A broken wrapper must not hide the working bundled binary behind it.
        let calls = SubscriptionCheckBox()
        let working: SubscriptionCLI.ProbeRunner = { [calls] url, arguments in
            calls.append(url.lastPathComponent + " " + arguments.joined(separator: " "))
            guard url != brokenWrapper else { return nil }
            if arguments == SubscriptionCLI.versionArguments() {
                return SubscriptionCLI.Probe(status: 0, standardOutput: "codex-cli 0.158.0-alpha.2.1\n", standardError: "")
            }
            return SubscriptionCLI.Probe(status: 0, standardOutput: "", standardError: "Logged in using ChatGPT\n")
        }
        let found = await SubscriptionCLI.discover(.codex, candidates: [brokenWrapper, bundled, outdated], probe: working)
        try check(found.ready && found.executable == bundled, "a broken wrapper falls through to the installed CLI")
        try check(found.version == "0.158.0-alpha.2.1" && found.detail.contains("ChatGPT"), "the connection reports the CLI's own version")
        try check(!found.detail.lowercased().contains("token") && !found.detail.contains("$"), "no credential or cost appears in the status")
        try check(calls.values == ["codex --version", "codex --version", "codex login status -c cli_auth_credentials_store=\"file\""], "discovery runs only version and status commands")

        // An installed but older CLI is reported rather than run.
        let old: SubscriptionCLI.ProbeRunner = { url, arguments in
            guard url == outdated, arguments == SubscriptionCLI.versionArguments() else { return nil }
            return SubscriptionCLI.Probe(status: 0, standardOutput: "codex-cli 0.100.0\n", standardError: "")
        }
        let stale = await SubscriptionCLI.discover(.codex, candidates: [bundled, outdated], probe: old)
        try check(!stale.ready && stale.version == "0.100.0" && stale.detail.contains("0.158.0 or newer"), "an unsupported version asks for an update")

        // Signed out: the executable is known, the route is not ready.
        let claudePath = URL(fileURLWithPath: "/fixture/homebrew/bin/claude")
        let signedOut: SubscriptionCLI.ProbeRunner = { _, arguments in
            if arguments == SubscriptionCLI.versionArguments() {
                return SubscriptionCLI.Probe(status: 0, standardOutput: "2.1.236 (Claude Code)\n", standardError: "")
            }
            return SubscriptionCLI.Probe(status: 0, standardOutput: "{\"loggedIn\":false}", standardError: "")
        }
        let needsSignIn = await SubscriptionCLI.discover(.claude, candidates: [claudePath], probe: signedOut)
        try check(!needsSignIn.ready && needsSignIn.executable == claudePath && needsSignIn.version == "2.1.236", "a signed-out CLI is found but not ready")
        try check(needsSignIn.detail.lowercased().contains("sign in"), "the status explains what the person must do")

        let unreadable: SubscriptionCLI.ProbeRunner = { _, arguments in
            arguments == SubscriptionCLI.versionArguments()
                ? SubscriptionCLI.Probe(status: 0, standardOutput: "2.1.236 (Claude Code)", standardError: "")
                : nil
        }
        let blocked = await SubscriptionCLI.discover(.claude, candidates: [claudePath], probe: unreadable)
        try check(!blocked.ready && blocked.detail.contains("could not check"), "an unusable status probe reports honestly")

        let absent = await SubscriptionCLI.discover(.claude, candidates: [claudePath], probe: { _, _ in nil })
        try check(!absent.ready && absent.executable == nil && absent.detail.contains("No installed"), "nothing installed is reported as nothing installed")

        // Input refusals. None of these reach a process launch.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubscriptionCLIAdapter-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("inputs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("inputs/screen.png")
        try Data("synthetic-image-bytes".utf8).write(to: image)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-" + UUID().uuidString + ".png")
        try Data("synthetic-image-bytes".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        func refuses(_ label: String, _ body: () async throws -> SubscriptionCLIResult, _ matches: (SubscriptionCLIError) -> Bool) async throws {
            do {
                _ = try await body()
                throw VoiceError.message("SUBSCRIPTION CLI ADAPTER CHECK FAILED: \(label) was allowed")
            } catch let error as SubscriptionCLIError {
                guard matches(error) else { throw VoiceError.message("SUBSCRIPTION CLI ADAPTER CHECK FAILED: \(label) reported as \(error)") }
                count += 1
            }
        }
        let missingExecutable = URL(fileURLWithPath: directory.appendingPathComponent("absent-cli").path)
        let codexConnection = SubscriptionConnection(provider: .codex, executable: missingExecutable, version: "0.158.0", ready: true, detail: "")
        let claudeConnection = SubscriptionConnection(provider: .claude, executable: missingExecutable, version: "2.1.236", ready: true, detail: "")
        let notConnected = SubscriptionConnection.unavailable(.codex, "Sign in first.")

        try await refuses("an unconnected provider", {
            try await SubscriptionCLI.run(notConnected, prompt: "Prepare a draft", images: [], directory: directory, onSession: { _ in })
        }, { if case .unavailable = $0 { return true } else { return false } })
        try await refuses("an empty prompt", {
            try await SubscriptionCLI.run(codexConnection, prompt: "   \n ", images: [], directory: directory, onSession: { _ in })
        }, { if case .unavailable = $0 { return true } else { return false } })
        try await refuses("an oversized prompt", {
            try await SubscriptionCLI.run(codexConnection, prompt: String(repeating: "word ", count: 40_000), images: [], directory: directory, onSession: { _ in })
        }, { if case .unavailable = $0 { return true } else { return false } })
        try await refuses("a home folder as the job folder", {
            try await SubscriptionCLI.run(codexConnection, prompt: "Prepare a draft", images: [], directory: URL(fileURLWithPath: NSHomeDirectory()), onSession: { _ in })
        }, { if case .boundary = $0 { return true } else { return false } })
        try await refuses("a missing job folder", {
            try await SubscriptionCLI.run(codexConnection, prompt: "Prepare a draft", images: [], directory: directory.appendingPathComponent("absent"), onSession: { _ in })
        }, { if case .unavailable = $0 { return true } else { return false } })
        try await refuses("an image outside the job folder", {
            try await SubscriptionCLI.run(codexConnection, prompt: "Prepare a draft", images: [outside], directory: directory, onSession: { _ in })
        }, { if case .boundary = $0 { return true } else { return false } })
        try await refuses("more images than the limit", {
            try await SubscriptionCLI.run(codexConnection, prompt: "Prepare a draft",
                                          images: Array(repeating: image, count: SubscriptionCLILimits.maximumImages + 1),
                                          directory: directory, onSession: { _ in })
        }, { if case .unavailable = $0 { return true } else { return false } })
        try await refuses("images on the unverified Claude Code path", {
            try await SubscriptionCLI.run(claudeConnection, prompt: "Describe this", images: [image], directory: directory, onSession: { _ in })
        }, { if case .imagesUnsupported = $0 { return true } else { return false } })

        // Cancellation is honoured before anything is launched. The connection
        // points at a path that does not exist, so no CLI can run either way.
        let task = Task { () -> SubscriptionCLIResult in
            try await SubscriptionCLI.run(codexConnection, prompt: "Prepare a draft", images: [], directory: directory, onSession: { _ in })
        }
        task.cancel()
        do {
            _ = try await task.value
            throw VoiceError.message("SUBSCRIPTION CLI ADAPTER CHECK FAILED: a cancelled run returned a result")
        } catch is CancellationError {
            count += 1
        } catch is SubscriptionCLIError {
            // The validation reached the missing executable first; still no run.
            count += 1
        }

        print("SUBSCRIPTION_CLI_ADAPTER_CHECKS_OK: \(count) checks passed")
    }

    // MARK: Real synthetic process lifecycle

    /// Exercises the real runner with local system commands and disposable
    /// synthetic bytes. No provider, user content or network is involved.
    static func runProcessChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SubscriptionProcessChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw VoiceError.message("SUBSCRIPTION PROCESS CHECK FAILED: \(message)") }
            count += 1
        }
        func child(_ executable: String, _ arguments: [String], input: Data = Data(),
                   limit: Int = 1024 * 1024, timeout: TimeInterval = 2,
                   onLine: (@Sendable (String) -> String?)? = nil) -> SubscriptionProcess {
            SubscriptionProcess(executable: URL(fileURLWithPath: executable), arguments: arguments,
                                environment: ["PATH": "/usr/bin:/bin"], directory: root,
                                input: input, limit: limit, timeout: timeout,
                                collectOutput: true, onLine: onLine)
        }
        let lines = SubscriptionCheckBox()
        let finalLine = try await child("/usr/bin/printf", ["%s", "first\nlast"], onLine: { line in lines.append(line); return nil }).run()
        try check(finalLine.status == 0 && finalLine.standardOutput == "first\nlast" && lines.values == ["first", "last"], "an unterminated final line is delivered exactly once")

        let streams = try await child("/bin/sh", ["-c", "printf stdout; printf stderr >&2"]).run()
        try check(streams.standardOutput == "stdout" && streams.standardError == "stderr", "stdout and stderr stay distinct")
        let prompt = Data(String(repeating: "synthetic line\n", count: 40_000).utf8)
        let echo = try await child("/bin/cat", [], input: prompt).run()
        try check(echo.status == 0 && echo.standardOutput == String(decoding: prompt, as: UTF8.self), "a prompt larger than pipe capacity is transferred without blocking")
        let closedInput = try await child("/bin/sh", ["-c", "exit 0"], input: prompt).run()
        try check(closedInput.status == 0, "early stdin closure does not raise SIGPIPE in Workbench")

        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["8"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }
        let started = ProcessInfo.processInfo.systemUptime
        let orphan = try await child("/bin/sh", ["-c", "/bin/sleep 8 & printf '%s\\n' \"$!\"; exit 0"], timeout: 0.1).run()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        guard case .timedOut = orphan.stop else { throw VoiceError.message("SUBSCRIPTION PROCESS CHECK FAILED: inherited-pipe timeout not reported") }
        try check(elapsed < 1.5, "timeout stays bounded after the direct child exits")
        guard let descendant = Int32(orphan.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw VoiceError.message("SUBSCRIPTION PROCESS CHECK FAILED: synthetic descendant PID missing")
        }
        // launchd may briefly hold an orphan zombie after the group signal.
        for _ in 0..<25 where kill(descendant, 0) == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(kill(descendant, 0) == -1 && errno == ESRCH, "the timed-out descendant was stopped")
        try check(unrelated.isRunning, "stopping one group preserves an unrelated process")

        let cancelledChild = child("/bin/sh", ["-c", "trap '' TERM; /bin/sleep 8 & wait"], timeout: 5)
        let cancelled = Task { try await cancelledChild.run() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        cancelled.cancel()
        let stopped = try await cancelled.value
        guard case .cancelled = stopped.stop else { throw VoiceError.message("SUBSCRIPTION PROCESS CHECK FAILED: cancellation not reported") }
        try check(ProcessInfo.processInfo.systemUptime - cancelledAt < 1.5, "cancellation escalates when SIGTERM is ignored")

        let flood = try await child("/usr/bin/yes", ["synthetic"], limit: 1024).run()
        guard case .overflowed = flood.stop else { throw VoiceError.message("SUBSCRIPTION PROCESS CHECK FAILED: output limit not reported") }
        try check(flood.standardOutput.utf8.count <= 1024, "stdout is bounded before accumulation")
        let errorFlood = try await child("/bin/sh", ["-c", "exec /usr/bin/yes synthetic >&2"], limit: 1024).run()
        guard case .overflowed = errorFlood.stop else { throw VoiceError.message("SUBSCRIPTION PROCESS CHECK FAILED: stderr limit not reported") }
        try check(errorFlood.standardError.utf8.count <= 1024, "stderr shares the bounded output budget")
        let forbidden = try await child("/bin/sh", ["-c", "printf 'forbidden\\n'; /bin/sleep 8"], onLine: { _ in "synthetic boundary refusal" }).run()
        guard case .violation = forbidden.stop else { throw VoiceError.message("SUBSCRIPTION PROCESS CHECK FAILED: forbidden event did not stop child") }
        try check(forbidden.status != 0, "a forbidden stream event stops the actual process")
        let active = SubscriptionProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "for i in 1 2 3 4 5 6; do printf 'progress\\n'; /bin/sleep 0.05; done"],
            environment: ["PATH": "/usr/bin:/bin"], directory: root, input: Data(),
            limit: 65536, timeout: 2, inactivityTimeout: 0.15, collectOutput: true)
        let progressing = try await active.run()
        try check(progressing.status == 0 && progressing.stop.isPending, "reported progress extends the inactivity window")
        let quiet = SubscriptionProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["8"],
            environment: ["PATH": "/usr/bin:/bin"], directory: root, input: Data(),
            limit: 65536, timeout: 2, inactivityTimeout: 0.1)
        let inactive = try await quiet.run()
        guard case .inactive = inactive.stop else { throw VoiceError.message("SUBSCRIPTION PROCESS CHECK FAILED: inactivity not reported") }
        count += 1
        print("SUBSCRIPTION_PROCESS_CHECKS_OK: \(count) checks passed; inherited-pipe timeout \(String(format: "%.3f", elapsed))s")
    }

    // MARK: Real synthetic OS boundary and dispatch

    /// These checks use sandbox-exec and a synthetic CLI script. They verify
    /// actual file denial and dispatch-time auth switching without contacting a
    /// provider or reading a native credential file.
    static func runSandboxChecks() async throws {
        let root = SubscriptionPaths.resolved(FileManager.default.temporaryDirectory
            .appendingPathComponent("SubscriptionSandboxChecks-" + UUID().uuidString))
        let job = SubscriptionJobPaths(root: root.appendingPathComponent("selected-job"))
        try FileManager.default.createDirectory(at: job.root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw VoiceError.message("SUBSCRIPTION SANDBOX CHECK FAILED: \(message)") }
            count += 1
        }
        let outside = root.appendingPathComponent("unselected.txt")
        try Data("unselected synthetic content".utf8).write(to: outside)
        let selected = job.root.appendingPathComponent("selected.txt")
        try Data("selected synthetic content".utf8).write(to: selected)
        let fixtureHome = root.appendingPathComponent("synthetic-home")
        let native = fixtureHome.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let syntheticAuth = native.appendingPathComponent("auth.json")
        let syntheticID = native.appendingPathComponent("installation_id")
        try Data("synthetic auth fixture".utf8).write(to: syntheticAuth)
        try Data("synthetic installation".utf8).write(to: syntheticID)
        let shell = URL(fileURLWithPath: "/bin/sh")
        let installation = SubscriptionSandbox.installRoot(for: shell)
        try job.prepare(SubscriptionSandbox.profile(for: .codex, purpose: .inference, directory: job.root, installation: installation))
        let script = "cat selected.txt; cat \"$2\" >/dev/null || exit 14; if cat \"$1\" 2>/dev/null; then exit 11; fi; if (printf changed >\"$1\") 2>/dev/null; then exit 12; fi; if (printf changed >\"$2\") 2>/dev/null; then exit 13; fi; printf 'synthetic installation updated' >\"$3\""
        let args = SubscriptionSandbox.arguments(profile: job.profile, writeRoot: job.root,
            userRoot: fixtureHome, installRoot: installation, executable: shell,
            arguments: ["-c", script, "fixture", outside.path, syntheticAuth.path, syntheticID.path])
        let boundary = try await SubscriptionProcess(executable: SubscriptionSandbox.executable, arguments: args,
            environment: ["PATH": "/usr/bin:/bin"], directory: job.root, input: Data(),
            limit: 65536, timeout: 3, collectOutput: true).run()
        try check(boundary.status == 0 && boundary.standardOutput == "selected synthetic content", "selected file is readable and sibling contents are denied (status \(boundary.status): \(SubscriptionRedaction.short(boundary.standardError)))")
        let retained = try String(contentsOf: outside, encoding: .utf8)
        try check(retained == "unselected synthetic content", "the sibling write was denied")
        let retainedAuth = try String(contentsOf: syntheticAuth, encoding: .utf8)
        let updatedID = try String(contentsOf: syntheticID, encoding: .utf8)
        try check(retainedAuth == "synthetic auth fixture", "native credential writes remain denied")
        try check(updatedID == "synthetic installation updated", "only native installation ID maintenance is permitted")

        let runtime = root.appendingPathComponent("runtime/bin")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let cli = runtime.appendingPathComponent("codex")
        let marker = job.root.appendingPathComponent("inference-started")
        func installFixture(authLine: String, status: Int32 = 0) throws {
            let script = """
            #!/bin/sh
            if [ "$1" = login ]; then
                printf '%s\\n' '\(authLine)' >&2
                exit \(status)
            fi
            if [ "$1" = exec ]; then
                printf started > inference-started
                cat >/dev/null
                printf '%s\\n' '{"type":"thread.started","thread_id":"synthetic-dispatch"}' '{"type":"item.completed","item":{"type":"agent_message","text":"Synthetic dispatch completed."}}' '{"type":"turn.completed"}'
                exit 0
            fi
            exit 19
            """
            try Data(script.utf8).write(to: cli)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }
        let cachedReady = SubscriptionConnection(provider: .codex, executable: cli, version: "0.158.0", ready: true, detail: "Synthetic cached connection.")
        for (authLine, status) in [("Logged in using an API key", Int32(0)), ("synthetic config failure", Int32(2))] {
            try installFixture(authLine: authLine, status: status)
            do {
                _ = try await SubscriptionCLI.run(cachedReady, prompt: "Synthetic input", images: [], directory: job.root, onSession: { _ in })
                throw VoiceError.message("SUBSCRIPTION SANDBOX CHECK FAILED: stale cached sign-in dispatched")
            } catch is SubscriptionCLIError {
                try check(!FileManager.default.fileExists(atPath: marker.path), "stale or unreadable auth blocks inference at actual dispatch")
            }
        }
        try installFixture(authLine: "Logged in using ChatGPT")
        let receipt = try await SubscriptionCLI.run(cachedReady, prompt: "Synthetic input", images: [], directory: job.root, onSession: { _ in })
        try check(receipt.providerSessionID == "synthetic-dispatch" && receipt.text == "Synthetic dispatch completed.", "a current subscription sign-in allows a complete synthetic dispatch")
        try check(FileManager.default.fileExists(atPath: marker.path), "successful receipt follows the actual inference branch")
        print("SUBSCRIPTION_SANDBOX_CHECKS_OK: \(count) checks passed")
    }

    // MARK: Helpers

    private static func isForbidden(_ event: SubscriptionStreamEvent) -> Bool {
        if case .forbidden = event { return true }
        return false
    }

    private static func isReady(_ status: SubscriptionAuth.Status) -> Bool {
        if case .ready = status { return true }
        return false
    }

    private static func summary(_ status: SubscriptionAuth.Status) -> String {
        switch status {
        case .ready(let text), .needsSignIn(let text), .unreadable(let text): return text
        }
    }
}

/// Collects callback values from whichever queue delivers them.
private final class SubscriptionCheckBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock(); storage.append(value); lock.unlock()
    }

    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
