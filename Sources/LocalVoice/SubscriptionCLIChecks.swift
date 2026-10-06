import Foundation
import Darwin
import CryptoKit

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
        let claudeImageArguments = SubscriptionCLIPlanner.claude(hasImages: true)
        try check(value(after: "--input-format", in: claudeImageArguments) == "stream-json", "Claude images use the native streaming input format")
        try check(Array(claudeImageArguments.prefix(SubscriptionCLIPlanner.claudeBase.count)) == SubscriptionCLIPlanner.claudeBase, "images preserve every tool and customization restriction")
        try check(!claudeArguments.contains("--input-format"), "text-only handoffs preserve the established input route")
        try check(SubscriptionCLILimits.maximumImages(for: .codex) == 64 && SubscriptionCLILimits.maximumImageBytes(for: .codex) == 10 * 1024 * 1024 && SubscriptionCLILimits.maximumTotalImageBytes(for: .codex) == 128 * 1024 * 1024, "Codex image limits are unchanged")
        try check(SubscriptionCLILimits.maximumImages(for: .claude) == 20 && SubscriptionCLILimits.maximumImageBytes(for: .claude) == 3_932_160, "Claude image limits fit the narrower native input path")
        try check(4 * ((SubscriptionCLILimits.claudeMaximumImageBytes + 2) / 3) == 5 * 1024 * 1024, "the per-image cap includes base64 expansion")
        try check(SubscriptionCLILimits.maximumTotalImageBytes(for: .claude) == 16 * 1024 * 1024 && SubscriptionCLILimits.maximumRequestBytes(for: .claude) == 24 * 1024 * 1024, "Claude raw and serialized request limits are explicit")

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
        try check(value(after: "--output-last-message", in: codexArguments) == job.finalMessage.path, "Codex writes its final message into this job")
        try check(job.finalMessage != SubscriptionJobPaths(root: job.root).finalMessage, "each attempt gets a different final-message path")
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

        // Frozen direct-image input. These synthetic byte fixtures exercise
        // the wire format; native image decoding is checked by the separate
        // rendered-PNG acceptance run.
        let bytesOne = Data("selected-image-one /\n".utf8)
        let bytesTwo = Data("selected-image-two \"content\"".utf8)
        try bytesOne.write(to: first)
        try bytesTwo.write(to: second)
        let excluded = job.root.appendingPathComponent("inputs/unselected.png")
        let excludedBytes = Data("unselected-image-marker".utf8)
        try excludedBytes.write(to: excluded)
        let imagePrompt = "Compare the selected pictures.\nKeep \"quoted\" text intact."
        let imageInput = try SubscriptionClaudeInput.encode(prompt: imagePrompt, images: [second, first], directory: job.root)
        let decodedInput = try JSONSerialization.jsonObject(with: imageInput) as? [String: Any]
        let userMessage = decodedInput?["message"] as? [String: Any]
        let blocks = userMessage?["content"] as? [[String: Any]] ?? []
        let imageBlocks = blocks.filter { $0["type"] as? String == "image" }
        let sources = imageBlocks.compactMap { $0["source"] as? [String: Any] }
        let decodedImages = sources.compactMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } }
        try check(decodedInput?["type"] as? String == "user" && userMessage?["role"] as? String == "user", "one native user message carries the request")
        try check(blocks.count == 3 && imageBlocks.count == 2 && blocks.last?["text"] as? String == imagePrompt, "only selected images and the exact prompt are encoded")
        try check(sources.allSatisfy { $0["type"] as? String == "base64" && $0["media_type"] as? String == "image/png" }, "images use direct base64 content blocks")
        try check(decodedImages == [bytesTwo, bytesOne], "selected bytes and caller order survive serialization exactly")
        try check(decodedImages.map { SHA256.hash(data: $0) } == [bytesTwo, bytesOne].map { SHA256.hash(data: $0) }, "input image hashes match the frozen sources in order")
        try check(imageInput.last == 0x0A && imageInput.filter { $0 == 0x0A }.count == 1, "the request is one newline-delimited JSON message")
        let imageInputText = String(decoding: imageInput, as: UTF8.self)
        try check(!imageInputText.contains(excludedBytes.base64EncodedString()) && !imageInputText.contains(job.root.path), "unselected content and local paths are absent from the request")
        try check(imageInput.count > bytesOne.count + bytesTwo.count + imagePrompt.utf8.count && imageInput.count <= SubscriptionCLILimits.claudeMaximumRequestBytes, "the serialized byte count includes base64 and JSON overhead")
        try Data("later source replacement".utf8).write(to: first)
        try check(decodedImages[1] == bytesOne, "later file edits cannot change the prepared input bytes")
        try bytesOne.write(to: first)
        try check(try SubscriptionClaudeInput.encode(prompt: imagePrompt, images: [], directory: job.root) == Data(imagePrompt.utf8), "text-only stdin stays byte-for-byte unchanged")
        for (extensionName, mediaType) in [("jpg", "image/jpeg"), ("jpeg", "image/jpeg"), ("gif", "image/gif"), ("webp", "image/webp")] {
            let image = job.root.appendingPathComponent("inputs/format." + extensionName)
            try bytesOne.write(to: image)
            let payload = try SubscriptionClaudeInput.encode(prompt: "Synthetic input", images: [image], directory: job.root)
            try check(String(decoding: payload, as: UTF8.self).contains(mediaType), "\(extensionName) maps to its native image media type")
        }
        try rejects("too many Claude images are refused before serialization") {
            _ = try SubscriptionClaudeInput.encode(prompt: imagePrompt, images: Array(repeating: first, count: 21), directory: job.root)
        }
        let oversizedImage = job.root.appendingPathComponent("inputs/oversized.png")
        let oversizedDescriptor = open(oversizedImage.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard oversizedDescriptor >= 0 else { throw VoiceError.message("Could not create image limit fixture") }
        guard ftruncate(oversizedDescriptor, off_t(SubscriptionCLILimits.claudeMaximumImageBytes + 1)) == 0 else { close(oversizedDescriptor); throw VoiceError.message("Could not size image limit fixture") }
        close(oversizedDescriptor)
        try rejects("a per-image overflow is refused before reading its bytes") {
            _ = try SubscriptionClaudeInput.encode(prompt: imagePrompt, images: [oversizedImage], directory: job.root)
        }
        var aggregateImages: [URL] = []
        for index in 0..<5 {
            let image = job.root.appendingPathComponent("inputs/aggregate-\(index).png")
            let descriptor = open(image.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw VoiceError.message("Could not create aggregate fixture") }
            let size = index == 4 ? 1024 * 1024 + 1 : SubscriptionCLILimits.claudeMaximumImageBytes
            guard ftruncate(descriptor, off_t(size)) == 0 else { close(descriptor); throw VoiceError.message("Could not size aggregate fixture") }
            close(descriptor)
            aggregateImages.append(image)
        }
        try rejects("aggregate image overflow is refused before encoding") {
            _ = try SubscriptionClaudeInput.encode(prompt: imagePrompt, images: aggregateImages, directory: job.root)
        }
        try rejects("the complete serialized request has its own byte limit") {
            _ = try SubscriptionClaudeInput.encode(prompt: String(repeating: "x", count: SubscriptionCLILimits.claudeMaximumRequestBytes), images: [first], directory: job.root)
        }
        let outsideImage = directory.deletingLastPathComponent().appendingPathComponent("outside-image-" + UUID().uuidString + ".png")
        try excludedBytes.write(to: outsideImage)
        defer { try? FileManager.default.removeItem(at: outsideImage) }
        try rejects("an out-of-job Claude image is never encoded") {
            _ = try SubscriptionClaudeInput.encode(prompt: imagePrompt, images: [outsideImage], directory: job.root)
        }
        let linkedImage = job.root.appendingPathComponent("inputs/linked.png")
        try FileManager.default.createSymbolicLink(at: linkedImage, withDestinationURL: outsideImage)
        try rejects("an image symlink cannot expose unselected bytes") {
            _ = try SubscriptionClaudeInput.encode(prompt: imagePrompt, images: [linkedImage], directory: job.root)
        }
        let hardLinkedImage = job.root.appendingPathComponent("inputs/hard-linked.png")
        try FileManager.default.linkItem(at: outsideImage, to: hardLinkedImage)
        try rejects("an image hard link cannot expose unselected bytes") {
            _ = try SubscriptionClaudeInput.encode(prompt: imagePrompt, images: [hardLinkedImage], directory: job.root)
        }

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
        try check(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Prepared draft.\"}}") == .ignored, "stream agent messages are not a final-reply source")
        try check(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"item.completed\",\"item\":{\"item_type\":\"agent_message\",\"text\":\"Second form.\"}}") == .ignored, "the alternative agent-message key is also ignored")
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
                     "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"I am checking the selected images.\"}}",
                     "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Final reply is in the output file.\"}}",
                     "{\"type\":\"turn.completed\"}"] {
            complete.apply(SubscriptionStreamParser.event(provider: .codex, line: line))
        }
        let finalJSON = "{\"title\":\"Synthetic final\",\"tags\":[\"fixture\"]}"
        let resolved = try complete.resolve(provider: .codex, status: 0, standardError: "", codexFinalMessage: { finalJSON })
        try check(resolved.providerSessionID == "thread-fixture" && resolved.text == finalJSON, "commentary and stream messages never contaminate the final reply")
        let metadata = try JSONSerialization.jsonObject(with: Data(resolved.text.utf8)) as? [String: Any]
        try check(metadata?["title"] as? String == "Synthetic final", "the returned metadata remains strict JSON")
        try rejects("a complete stream without its final-message file is incomplete") {
            _ = try complete.resolve(provider: .codex, status: 0, standardError: "")
        }
        try rejects("a whitespace-only final-message file is incomplete") {
            _ = try complete.resolve(provider: .codex, status: 0, standardError: "", codexFinalMessage: { "  \n" })
        }

        var partial = SubscriptionStreamState()
        partial.apply(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"thread.started\",\"thread_id\":\"thread-fixture\"}"))
        partial.apply(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Half an answer\"}}"))
        try rejects("a final file without the terminal event is never returned") {
            _ = try partial.resolve(provider: .codex, status: 0, standardError: "", codexFinalMessage: { finalJSON })
        }

        var successThenFailure = SubscriptionStreamState()
        successThenFailure.apply(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Text\"}}"))
        successThenFailure.apply(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"turn.completed\"}"))
        try rejects("a non-zero exit fails even with a complete turn and final file") {
            _ = try successThenFailure.resolve(provider: .codex, status: 3, standardError: "codex: broken pipe", codexFinalMessage: { finalJSON })
        }
        successThenFailure.apply(SubscriptionStreamParser.event(provider: .codex, line: "{\"type\":\"turn.failed\",\"error\":{\"message\":\"synthetic failure\"}}"))
        try rejects("a failure event invalidates a final file even with status zero") {
            _ = try successThenFailure.resolve(provider: .codex, status: 0, standardError: "", codexFinalMessage: { finalJSON })
        }
        var forbiddenWithFinal = complete
        forbiddenWithFinal.apply(.forbidden("Synthetic forbidden tool"))
        try rejects("a forbidden tool invalidates a successful final file") {
            _ = try forbiddenWithFinal.resolve(provider: .codex, status: 0, standardError: "", codexFinalMessage: { finalJSON })
        }

        // Actual final-message files: stale output, unsafe types, encoding and
        // size cannot turn a completed event stream into a usable reply.
        func withFinalFile(_ exercise: (SubscriptionJobPaths, SubscriptionFinalMessageFile) throws -> Void) throws {
            let attempt = SubscriptionJobPaths(root: job.root)
            let file = try SubscriptionFinalMessageFile(job: attempt)
            try exercise(attempt, file)
        }
        try withFinalFile { attempt, file in
            try check(try file.read() == nil, "a missing final file is reported as missing")
            try Data(finalJSON.utf8).write(to: attempt.finalMessage)
            let receipt = try complete.resolve(provider: .codex, status: 0, standardError: "", codexFinalMessage: { try file.read() })
            try check(receipt.text == finalJSON, "a complete turn returns the actual final file only")
            try rejects("an existing final path cannot be reused") { _ = try SubscriptionFinalMessageFile(job: attempt) }
        }
        let staleAttempt = SubscriptionJobPaths(root: job.root)
        try Data("Stale reply from a previous attempt".utf8).write(to: staleAttempt.finalMessage)
        try withFinalFile { _, file in
            try rejects("a stale file cannot satisfy a later completed run without its own final") {
                _ = try complete.resolve(provider: .codex, status: 0, standardError: "", codexFinalMessage: { try file.read() })
            }
        }
        let unselected = directory.deletingLastPathComponent().appendingPathComponent("unselected-reply-" + UUID().uuidString)
        try Data("Unselected synthetic text".utf8).write(to: unselected)
        defer { try? FileManager.default.removeItem(at: unselected) }
        try withFinalFile { attempt, file in
            try FileManager.default.createSymbolicLink(at: attempt.finalMessage, withDestinationURL: unselected)
            try rejects("a final-message symlink cannot read outside the job") { _ = try file.read() }
        }
        try withFinalFile { attempt, file in
            try FileManager.default.linkItem(at: unselected, to: attempt.finalMessage)
            try rejects("a hard-linked final reply is refused") { _ = try file.read() }
        }
        try withFinalFile { attempt, file in
            guard mkfifo(attempt.finalMessage.path, 0o600) == 0 else { throw VoiceError.message("Could not create synthetic FIFO") }
            try rejects("a FIFO reply is refused without waiting for a writer") { _ = try file.read() }
        }
        try withFinalFile { attempt, file in
            try FileManager.default.createDirectory(at: attempt.finalMessage, withIntermediateDirectories: false)
            try rejects("a directory is not a reply") { _ = try file.read() }
        }
        try withFinalFile { attempt, file in
            try Data([0xFF, 0xFE]).write(to: attempt.finalMessage)
            try rejects("a final reply must be valid UTF-8") { _ = try file.read() }
        }
        try withFinalFile { attempt, file in
            let descriptor = open(attempt.finalMessage.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw VoiceError.message("Could not create synthetic oversized reply") }
            defer { close(descriptor) }
            guard ftruncate(descriptor, off_t(SubscriptionCLILimits.maximumReplyBytes + 1)) == 0 else {
                throw VoiceError.message("Could not size synthetic reply")
            }
            try rejects("an oversized final file is refused before loading it") { _ = try file.read() }
        }
        let escaped = SubscriptionJobPaths(root: directory.appendingPathComponent("escape-check"))
        let outsideSupport = directory.appendingPathComponent("unselected-support")
        try FileManager.default.createDirectory(at: escaped.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideSupport, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: escaped.support, withDestinationURL: outsideSupport)
        try rejects("preparation refuses a redirected support folder") { try escaped.prepare(codexProfile) }
        try rejects("final-message setup refuses a redirected support folder") { _ = try SubscriptionFinalMessageFile(job: escaped) }
        try check(!FileManager.default.fileExists(atPath: outsideSupport.appendingPathComponent("sandbox.sb").path), "preparation writes nothing through the support symlink")

        let replaced = SubscriptionJobPaths(root: directory.appendingPathComponent("replacement-check"))
        try FileManager.default.createDirectory(at: replaced.root, withIntermediateDirectories: true)
        try replaced.prepare(codexProfile)
        let pinnedFile = try SubscriptionFinalMessageFile(job: replaced)
        try FileManager.default.moveItem(at: replaced.support, to: replaced.root.appendingPathComponent("original-support"))
        try Data("Unselected replacement reply".utf8).write(to: outsideSupport.appendingPathComponent(replaced.finalMessage.lastPathComponent))
        try FileManager.default.createSymbolicLink(at: replaced.support, withDestinationURL: outsideSupport)
        try check(try pinnedFile.read() == nil, "a support-directory replacement cannot redirect the pinned reply read")

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

        let absent = await SubscriptionCLI.discover(.claude, candidates: [], probe: { _, _ in nil })
        try check(!absent.ready && absent.executable == nil && absent.detail.contains("No installed"), "nothing installed is reported as nothing installed")

        try check(absent.problem == .missing && stale.problem == .unsupported && needsSignIn.problem == .signIn
                  && blocked.problem == .unverified, "known discovery states remain distinct")
        for failedProbe in [nil, SubscriptionCLI.Probe(status: 1, standardOutput: "", standardError: "denied"),
                            SubscriptionCLI.Probe(status: 0, standardOutput: "unexpected version output", standardError: "")] {
            let unverified = await SubscriptionCLI.discover(.claude, candidates: [claudePath], probe: { _, _ in failedProbe })
            try check(!unverified.ready && unverified.executable == claudePath && unverified.problem == .unverified
                      && !unverified.detail.contains("No installed"), "a found but failed version probe stays unverified, not missing")
        }

        // Input refusals. None of these reach a process launch.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubscriptionCLIAdapter-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("inputs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingCandidate = directory.appendingPathComponent("absent-cli")
        try check(!SubscriptionCLI.candidateMayExist(missingCandidate), "a definitely absent CLI path can be called missing")
        let brokenCandidate = directory.appendingPathComponent("broken-cli")
        try FileManager.default.createSymbolicLink(at: brokenCandidate, withDestinationURL: missingCandidate)
        try check(SubscriptionCLI.candidateMayExist(brokenCandidate), "a dangling installed wrapper stays unverified")
        let deniedDirectory = directory.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: deniedDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: deniedDirectory.path)
        let unknownBehindDenial = SubscriptionCLI.candidateMayExist(deniedDirectory.appendingPathComponent("candidate"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedDirectory.path)
        try check(unknownBehindDenial, "a denied candidate location is not evidence of absence")
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
        try await refuses("more images than the Claude Code limit", {
            try await SubscriptionCLI.run(claudeConnection, prompt: "Describe this", images: Array(repeating: image, count: 21), directory: directory, onSession: { _ in })
        }, { if case .unavailable = $0 { return true } else { return false } })

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
        // Use zsh's built-in timer: starting a separate sleep process for
        // every 50 ms update made this depend on CI process-launch latency.
        // A one-second fixture window gives scheduling headroom while the
        // two-second stream must still survive beyond that window.
        let inactivityWindow: TimeInterval = 1
        let active = SubscriptionProcess(executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f", "-c", "zmodload zsh/zselect; repeat 20 { print -r -- progress; zselect -t 10; }; exit 0"],
            environment: ["PATH": "/usr/bin:/bin"], directory: root, input: Data(),
            limit: 65536, timeout: 10, inactivityTimeout: inactivityWindow, collectOutput: true)
        let activeAt = ProcessInfo.processInfo.systemUptime
        let progressing = try await active.run()
        let activeElapsed = ProcessInfo.processInfo.systemUptime - activeAt
        let updates = progressing.standardOutput.split(separator: "\n")
        try check(progressing.status == 0 && progressing.stop.isPending && updates.count == 20,
                  "reported progress extends the inactivity window (status \(progressing.status), stop \(progressing.stop), \(updates.count) updates, \(String(format: "%.3f", activeElapsed))s)")
        try check(activeElapsed > inactivityWindow * 1.5, "a progressing run actually lasts beyond its inactivity window")
        // Fill more than one bounded pipe drain, then delay the eighth line's
        // consumer while later lines are already queued. Checking inactivity
        // before the next drain incorrectly rejects this successful child.
        let bufferedOutput = (0..<12).map {
            String(format: "%02d", $0) + String(repeating: "x", count: 16 * 1024 - 3) + "\n"
        }.joined()
        let buffered = SubscriptionProcess(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", bufferedOutput], environment: ["PATH": "/usr/bin:/bin"], directory: root,
            input: Data(), limit: 1024 * 1024, timeout: 10, inactivityTimeout: inactivityWindow, collectOutput: true,
            onLine: { line in
                if line.hasPrefix("07") { Thread.sleep(forTimeInterval: 1.25) }
                return nil
            })
        let bufferedResult = try await buffered.run()
        try check(bufferedResult.status == 0 && bufferedResult.stop.isPending && bufferedResult.standardOutput == bufferedOutput,
                  "queued progress survives a delayed output consumer without false inactivity")
        let quiet = SubscriptionProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["8"],
            environment: ["PATH": "/usr/bin:/bin"], directory: root, input: Data(),
            limit: 65536, timeout: 10, inactivityTimeout: inactivityWindow)
        let quietAt = ProcessInfo.processInfo.systemUptime
        let inactive = try await quiet.run()
        guard case .inactive = inactive.stop else { throw VoiceError.message("SUBSCRIPTION PROCESS CHECK FAILED: inactivity not reported") }
        try check(ProcessInfo.processInfo.systemUptime - quietAt < 5, "a silent producer remains bounded by inactivity")
        let paused = SubscriptionProcess(executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f", "-c", "zmodload zsh/zselect; repeat 12 { print -r -- progress; zselect -t 10; }; zselect -t 800"],
            environment: ["PATH": "/usr/bin:/bin"], directory: root, input: Data(),
            limit: 65536, timeout: 10, inactivityTimeout: inactivityWindow, collectOutput: true)
        let pausedAt = ProcessInfo.processInfo.systemUptime
        let stalled = try await paused.run()
        let pausedElapsed = ProcessInfo.processInfo.systemUptime - pausedAt
        guard case .inactive = stalled.stop else { throw VoiceError.message("SUBSCRIPTION PROCESS CHECK FAILED: paused progress did not become inactive") }
        try check(stalled.standardOutput.split(separator: "\n").count == 12 && pausedElapsed > inactivityWindow * 1.5,
                  "progress is allowed before the producer becomes silent")
        try check(pausedElapsed < 6, "earlier progress cannot keep a paused producer alive indefinitely")
        let continuouslyActive = SubscriptionProcess(executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f", "-c", "zmodload zsh/zselect; repeat 100 { print -r -- progress; zselect -t 10; }"],
            environment: ["PATH": "/usr/bin:/bin"], directory: root, input: Data(),
            limit: 65536, timeout: 1.5, inactivityTimeout: inactivityWindow, collectOutput: true)
        let deadlineAt = ProcessInfo.processInfo.systemUptime
        let deadlineStopped = try await continuouslyActive.run()
        guard case .timedOut = deadlineStopped.stop else { throw VoiceError.message("SUBSCRIPTION PROCESS CHECK FAILED: progress bypassed the overall deadline") }
        try check(deadlineStopped.standardOutput.split(separator: "\n").count > 5 && ProcessInfo.processInfo.systemUptime - deadlineAt < 5,
                  "continuous progress still obeys the independent overall deadline")
        print("SUBSCRIPTION_PROCESS_CHECKS_OK: \(count) checks passed; inherited-pipe timeout \(String(format: "%.3f", elapsed))s; progressing \(String(format: "%.3f", activeElapsed))s; paused \(String(format: "%.3f", pausedElapsed))s")
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
        func installFixture(authLine: String, status: Int32 = 0, resultMode: String = "complete") throws {
            let script = """
            #!/bin/sh
            if [ "$1" = login ]; then
                printf '%s\\n' '\(authLine)' >&2
                exit \(status)
            fi
            if [ "$1" = exec ]; then
                printf started > inference-started
                cat >/dev/null
                output=
                while [ "$#" -gt 0 ]; do
                    if [ "$1" = --output-last-message ]; then shift; output="$1"; fi
                    shift
                done
                [ -n "$output" ] || exit 20
                if [ '\(resultMode)' != missing-final ]; then
                    printf '%s' '{"title":"Synthetic final","tags":["fixture"]}' > "$output"
                fi
                printf '%s\\n' '{"type":"thread.started","thread_id":"synthetic-dispatch"}' '{"type":"item.completed","item":{"type":"agent_message","text":"I am checking the selected images."}}' '{"type":"item.completed","item":{"type":"agent_message","text":"Final reply is in the output file."}}'
                if [ '\(resultMode)' = forbidden ]; then
                    printf '%s\\n' '{"type":"item.started","item":{"type":"command_execution"}}'
                fi
                if [ '\(resultMode)' = failure ]; then
                    printf '%s\\n' '{"type":"turn.failed","error":{"message":"Synthetic failure"}}'
                elif [ '\(resultMode)' != missing-terminal ]; then
                    printf '%s\\n' '{"type":"turn.completed"}'
                fi
                if [ '\(resultMode)' = nonzero ]; then exit 3; fi
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
        try check(receipt.providerSessionID == "synthetic-dispatch" && receipt.text == "{\"title\":\"Synthetic final\",\"tags\":[\"fixture\"]}", "actual synthetic dispatch returns final JSON without progress commentary")
        try check(FileManager.default.fileExists(atPath: marker.path), "successful receipt follows the actual inference branch")
        try Data("Stale final from an earlier attempt".utf8).write(to: job.finalMessage)
        for mode in ["missing-final", "missing-terminal", "failure", "nonzero", "forbidden"] {
            try installFixture(authLine: "Logged in using ChatGPT", resultMode: mode)
            do {
                _ = try await SubscriptionCLI.run(cachedReady, prompt: "Synthetic input", images: [], directory: job.root, onSession: { _ in })
                throw VoiceError.message("SUBSCRIPTION SANDBOX CHECK FAILED: \(mode) returned a result")
            } catch let error as SubscriptionCLIError {
                let expected: Bool
                switch (mode, error) {
                case ("missing-final", .incomplete), ("missing-terminal", .incomplete),
                     ("failure", .failed), ("nonzero", .failed), ("forbidden", .boundary): expected = true
                default: expected = false
                }
                try check(expected, "\(mode) refuses a receipt even with stale or newly written final text")
            }
        }
        let claude = runtime.appendingPathComponent("claude")
        let claudeScript = """
        #!/bin/sh
        if [ "$2" = auth ]; then
            printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"pro"}'
            exit 0
        fi
        cat > captured-claude-input.json
        printf '%s\\n' '{"type":"system","session_id":"synthetic-claude-images"}' '{"type":"result","subtype":"success","is_error":false,"result":"Synthetic image receipt.","session_id":"synthetic-claude-images"}'
        """
        try Data(claudeScript.utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude.path)
        let imageOne = job.root.appendingPathComponent("one.png")
        let imageTwo = job.root.appendingPathComponent("two.png")
        let bytesOne = Data("synthetic first image".utf8)
        let bytesTwo = Data("synthetic second image".utf8)
        try bytesOne.write(to: imageOne)
        try bytesTwo.write(to: imageTwo)
        let claudeReady = SubscriptionConnection(provider: .claude, executable: claude, version: "2.1.236", ready: true, detail: "Synthetic subscription.")
        let imageReceipt = try await SubscriptionCLI.run(claudeReady, prompt: "Synthetic selected images", images: [imageTwo, imageOne], directory: job.root, onSession: { _ in })
        try check(imageReceipt.text == "Synthetic image receipt." && imageReceipt.providerSessionID == "synthetic-claude-images", "a native-shaped Claude image turn completes through actual stdin dispatch")
        let captured = try Data(contentsOf: job.root.appendingPathComponent("captured-claude-input.json"))
        let object = try JSONSerialization.jsonObject(with: captured) as? [String: Any]
        let message = object?["message"] as? [String: Any]
        let blocks = message?["content"] as? [[String: Any]] ?? []
        let receivedImages = blocks.compactMap { ($0["source"] as? [String: Any])?["data"] as? String }.compactMap { Data(base64Encoded: $0) }
        try check(receivedImages == [bytesTwo, bytesOne], "actual stdin delivers only selected image bytes in caller order")
        try check(receivedImages.map { SHA256.hash(data: $0) } == [bytesTwo, bytesOne].map { SHA256.hash(data: $0) }, "actual dispatched image hashes match the selected files")
        try check(blocks.count == 3 && blocks.last?["text"] as? String == "Synthetic selected images", "actual stdin excludes neighboring files and adds only the prompt")
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
