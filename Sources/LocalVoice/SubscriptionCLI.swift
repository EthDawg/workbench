import Foundation
import Darwin

// MARK: - Provider surface

/// An optional handoff to an official assistant CLI the person already
/// installed and signed in to themselves. Workbench does not read, store or
/// forward provider credentials, never calls a provider API directly, and has
/// no fallback from one route to the other. This is a bounded adapter for two
/// documented command-line programs, not an agent or plugin framework.
enum SubscriptionProvider: String, Codable, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }
}

/// What discovery found for one provider. `version` is the CLI's own reported
/// version and `detail` is a short sentence for the host's status row. No
/// account identifier, plan holder, organisation or token material is carried
/// here, persisted or logged.
struct SubscriptionConnection: Identifiable {
    let provider: SubscriptionProvider
    let executable: URL?
    let version: String
    let ready: Bool
    let detail: String

    var id: String { provider.rawValue }

    static func unavailable(_ provider: SubscriptionProvider, _ detail: String, executable: URL? = nil, version: String = "") -> SubscriptionConnection {
        SubscriptionConnection(provider: provider, executable: executable, version: version, ready: false, detail: detail)
    }
}

/// The only result a run returns to the host: the provider's own session or
/// thread identifier for the local receipt, and the reply text. The CLI run is
/// ephemeral; this does not promise a resumable consumer chat.
struct SubscriptionCLIResult {
    let providerSessionID: String?
    let text: String
}

enum SubscriptionCLIError: LocalizedError {
    /// The route cannot be used at all: missing CLI, missing sign-in, missing
    /// `sandbox-exec`, or a job already running. Never a retry hint.
    case unavailable(String)
    /// The CLI tried something the boundary forbids, or Workbench cannot prove
    /// the boundary held. The run is stopped rather than relaxed.
    case boundary(String)
    /// The CLI ran and reported a failure.
    case failed(String)
    /// The CLI exited without a complete, usable result.
    case incomplete(String)
    /// This input is not supported on this route by a verified path.
    case imagesUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let text), .boundary(let text), .failed(let text), .incomplete(let text), .imagesUnsupported(let text):
            return text
        }
    }
}

enum SubscriptionCLILimits {
    static let runTimeout: TimeInterval = 1800
    static let inactivityTimeout: TimeInterval = 300
    static let probeTimeout: TimeInterval = 10
    /// stdout for one run. A stream-json transcript is far smaller; this only
    /// stops a runaway producer from filling memory.
    static let maximumOutputBytes = 8 * 1024 * 1024
    static let maximumProbeBytes = 64 * 1024
    static let maximumLineBytes = 2 * 1024 * 1024
    static let maximumErrorBytes = 64 * 1024
    static let maximumPromptCharacters = 100_000
    static let maximumImages = 64
    static let maximumTotalImageBytes = 128 * 1024 * 1024
    static let maximumImageBytes = 10 * 1024 * 1024
    static let maximumFailureCharacters = 400
}

// MARK: - Environment

/// The child receives an explicit allowlist. Inherited provider keys and
/// configuration overrides are dropped, so no API key, alternative base URL or
/// relocated credential directory can reach the CLI through Workbench: the
/// unmodified CLI keeps using the person's own sign-in.
enum SubscriptionEnvironment {
    static let allowedNames: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TERM", "__CF_USER_TEXT_ENCODING",
    ]
    static let allowedPrefixes = ["XPC_"]

    /// Belt and braces over the allowlist: a name that looks like a credential
    /// or a provider override never survives, whatever else changes above.
    static func isProviderOverride(_ name: String) -> Bool {
        let upper = name.uppercased()
        for marker in ["KEY", "TOKEN", "SECRET", "PASSWORD", "AUTH", "CREDENTIAL", "ANTHROPIC", "OPENAI", "CLAUDE", "CODEX", "CHATGPT", "PROXY", "BASE_URL", "OTEL", "NODE_OPTIONS"] where upper.contains(marker) {
            return true
        }
        return false
    }

    /// `scratch` is an app-owned directory inside the job root. It is set by
    /// Workbench rather than inherited, so the CLI's temporary files stay in the
    /// one place the sandbox profile allows writing.
    static func sanitized(_ source: [String: String], scratch: URL? = nil,
                          provider: SubscriptionProvider? = nil) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in source {
            guard allowedNames.contains(name) || allowedPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            guard !isProviderOverride(name) else { continue }
            result[name] = value
        }
        if let scratch {
            result["TMPDIR"] = scratch.path
            // Claude uses /tmp on macOS unless this documented internal temp
            // override is set. It appends claude-{uid} inside the chosen base.
            // This value is app-owned; inherited provider overrides stay denied.
            if provider == .claude { result["CLAUDE_CODE_TMPDIR"] = scratch.path }
        }
        return result
    }
}

// MARK: - Candidate executables

/// Where an officially installed CLI actually lives on this Mac. Candidates are
/// tried in order; a candidate that cannot report a supported version is
/// skipped, so a stale wrapper pointing at a removed path does not hide a
/// working installation behind it.
enum SubscriptionCLICandidates {
    static func urls(for provider: SubscriptionProvider, home: URL) -> [URL] {
        let paths: [String]
        switch provider {
        case .codex:
            let bundles = ["/Applications/ChatGPT.app", home.appendingPathComponent("Applications/ChatGPT.app").path,
                           "/Applications/Codex.app", home.appendingPathComponent("Applications/Codex.app").path]
            // The app bundles ship the CLI; newer builds nest it under
            // codex-cli/bin while older ones placed it directly in Resources.
            var result = bundles.flatMap { ["\($0)/Contents/Resources/codex-cli/bin/codex", "\($0)/Contents/Resources/codex"] }
            result += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home.appendingPathComponent(".local/bin/codex").path]
            paths = result
        case .claude:
            paths = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                     home.appendingPathComponent(".claude/local/claude").path,
                     home.appendingPathComponent(".local/bin/claude").path]
        }
        var seen = Set<String>()
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
    }
}

/// Minimum versions are the versions whose documented non-interactive flags
/// this adapter relies on. An older CLI is reported as needing an update rather
/// than run with flags it may not understand.
enum SubscriptionVersionCheck {
    static func minimum(for provider: SubscriptionProvider) -> [Int] {
        switch provider {
        case .codex: return [0, 158, 0]
        case .claude: return [2, 1, 236]
        }
    }

    /// Accepts the first dotted numeric token, so `2.1.236 (Claude Code)` and
    /// `codex-cli 0.158.0-alpha.2.1` both resolve.
    static func parse(_ output: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "(),;:[]"))
        for rawToken in output.components(separatedBy: separators) {
            var token = rawToken
            if token.hasPrefix("v"), token.dropFirst().first?.isNumber == true { token.removeFirst() }
            guard let first = token.first, first.isNumber, token.contains(".") else { continue }
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            guard !trimmed.isEmpty, components(trimmed).count >= 2 else { continue }
            return trimmed
        }
        return nil
    }

    /// A dotted number from an unrelated program is not an official CLI.
    static func parse(_ output: String, provider: SubscriptionProvider) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line = lines.first(where: {
            provider == .codex ? $0.hasPrefix("codex-cli ") : $0.hasSuffix("(Claude Code)")
        }) else { return nil }
        return parse(line)
    }

    static func components(_ version: String) -> [Int] {
        let numeric = version.prefix { $0.isNumber || $0 == "." }
        return numeric.split(separator: ".").compactMap { Int($0) }
    }

    static func isSupported(_ version: String, provider: SubscriptionProvider) -> Bool {
        let found = components(version)
        guard !found.isEmpty else { return false }
        let required = minimum(for: provider)
        for index in 0..<max(found.count, required.count) {
            let left = index < found.count ? found[index] : 0
            let right = index < required.count ? required[index] : 0
            if left != right { return left > right }
        }
        return true
    }
}

// MARK: - Authentication status

/// Discovery only asks the CLI who the person is already signed in as. It never
/// starts a paid request, never opens a browser and never keeps the raw answer:
/// the parsed outcome below is all that leaves this type.
enum SubscriptionAuth {
    enum Status {
        /// `summary` is a plan or method word for the status row, never an
        /// account identifier.
        case ready(String)
        case needsSignIn(String)
        case unreadable(String)
    }

    static let claudeSubscriptions: Set<String> = ["pro", "max", "team", "enterprise"]

    static func claude(_ json: String) -> Status {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable("Workbench could not read the Claude Code sign-in status. Run “claude auth status” yourself to check it.")
        }
        func string(_ names: [String]) -> String? {
            for name in names {
                if let value = object[name] as? String { return value }
            }
            return nil
        }
        let loggedIn = (object["loggedIn"] as? Bool) ?? (object["logged_in"] as? Bool) ?? false
        guard loggedIn else {
            return .needsSignIn("Sign in to Claude Code with your Claude subscription, then check again.")
        }
        let method = (string(["authMethod", "auth_method"]) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard method == "claude.ai" else {
            return .needsSignIn("Claude Code is not using a Claude subscription sign-in. Sign in with your Claude account, then check again.")
        }
        let plan = (string(["subscriptionType", "subscription_type"]) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard claudeSubscriptions.contains(plan) else {
            return .needsSignIn("This Claude Code sign-in has no Pro, Max, Team or Enterprise subscription for Workbench to hand work to.")
        }
        return .ready(plan)
    }

    /// The official CLI prints exactly this line for a subscription sign-in.
    static let codexReadyLine = "Logged in using ChatGPT"

    static func codex(_ output: String) -> Status {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(codexReadyLine) { return .ready("ChatGPT") }
        guard lines.contains(where: { !$0.isEmpty }) else {
            return .unreadable("Workbench could not read the Codex sign-in status. Run “codex login status” yourself to check it.")
        }
        return .needsSignIn("Sign in to Codex with your ChatGPT account in the ChatGPT app, then check again.")
    }
}

// MARK: - Short, redacted failures

/// Failure text comes from another program's output, so it is reduced to a few
/// trailing lines with credential-looking lines removed before it can reach the
/// UI or a log. Dropping a useful line is preferred to repeating a secret.
enum SubscriptionRedaction {
    static let markers = ["sk-", "sk_", "bearer", "authorization", "api key", "api-key", "apikey", "token",
                          "secret", "password", "eyj", "auth.json", ".claude.json", "keychain", "cookie", "credential"]

    static func short(_ text: String, limit: Int = SubscriptionCLILimits.maximumFailureCharacters) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let lower = line.lowercased()
                return !markers.contains(where: { lower.contains($0) })
            }
        let joined = lines.suffix(4).joined(separator: " ")
        let collapsed = joined.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}

// MARK: - Job paths

/// Foundation normalizes /private/tmp to /tmp, but macOS sandbox rules match
/// the physical path. Resolve existing ancestors with realpath, including when
/// a new status-probe directory has not been created yet.
enum SubscriptionPaths {
    static func resolved(_ url: URL) -> URL {
        var ancestor = url
        var missing: [String] = []
        while true {
            if let path = realpath(ancestor.path, nil) {
                defer { free(path) }
                var result = URL(fileURLWithPath: String(cString: path))
                for component in missing.reversed() { result.appendPathComponent(component) }
                return result
            }
            guard ancestor.path != "/", !ancestor.lastPathComponent.isEmpty else { return url }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }
}

/// App-owned working paths for one job. The snapshot the person selected stays
/// at `root`; everything this adapter creates lives in one hidden subdirectory
/// so it cannot be confused with the selected material.
struct SubscriptionJobPaths {
    let root: URL
    let support: URL
    let profile: URL
    let logs: URL
    let state: URL
    let scratch: URL

    init(root: URL) {
        let root = SubscriptionPaths.resolved(root)
        self.root = root
        let support = root.appendingPathComponent(".workbench-handoff", isDirectory: true)
        self.support = support
        self.profile = support.appendingPathComponent("sandbox.sb")
        self.logs = support.appendingPathComponent("logs", isDirectory: true)
        self.state = support.appendingPathComponent("state", isDirectory: true)
        self.scratch = support.appendingPathComponent("tmp", isDirectory: true)
    }

    func prepare(_ profileText: String) throws {
        let manager = FileManager.default
        for directory in [support, logs, state, scratch] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
        try Data(profileText.utf8).write(to: profile, options: .atomic)
    }
}

/// The directory handed to a CLI must be one app-managed job snapshot. A home
/// folder, a standard user folder or a volume root is refused outright: this
/// adapter never supplies a library root, whatever a caller passes.
enum SubscriptionJobDirectory {
    static func validate(_ url: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws -> URL {
        let resolved = SubscriptionPaths.resolved(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SubscriptionCLIError.unavailable("The prepared job folder is missing, so there is nothing to hand off.")
        }
        let home = SubscriptionPaths.resolved(home)
        var refused = ["/", "/Users", "/Volumes", "/Network", "/tmp", "/private/tmp", "/private/var/folders", "/private", home.path]
        for name in ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library", "Public", "Applications"] {
            refused.append(home.appendingPathComponent(name).path)
        }
        guard !refused.contains(resolved.path) else {
            throw SubscriptionCLIError.boundary("Workbench hands off only a prepared job folder, not \(resolved.lastPathComponent).")
        }
        // An ancestor of the home folder would expose everything below it.
        guard !(home.path + "/").hasPrefix(resolved.path + "/") else {
            throw SubscriptionCLIError.boundary("Workbench hands off only a prepared job folder, not a folder containing your home folder.")
        }
        // A TOML string carries two of the Codex paths; refuse anything that
        // could not be quoted safely rather than escaping it.
        guard !resolved.path.contains("\""), !resolved.path.contains("\\"), !resolved.path.contains("\n") else {
            throw SubscriptionCLIError.unavailable("The prepared job folder's name cannot be passed to the CLI safely.")
        }
        return resolved
    }
}

// MARK: - OS sandbox

/// Every child runs under `sandbox-exec`. The profile denies reading the
/// person's files and limits work data to the selected job folder. The only
/// exceptions are the unmodified CLI's installation, its own installation ID,
/// and read-only native sign-in files; Workbench never reads credential bytes.
/// Saved session contents remain denied even when the CLI checks their metadata.
enum SubscriptionSandbox {
    static let executable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    enum Purpose {
        /// A prompt run, which must not see provider configuration.
        case inference
        /// The CLI needs its config for status; explicit credential-store
        /// arguments keep status and inference on the same native auth store.
        case status
    }

    static func profile(for provider: SubscriptionProvider, purpose: Purpose,
                        directory: URL? = nil, installation: URL? = nil) -> String {
        var lines = [
            "(version 1)",
            ";; Workbench optional CLI handoff. Later rules win in this language.",
            "(allow default)",
            "(deny file-write*)",
            "(deny file-read*",
            "    (subpath \"/Users\")",
            "    (subpath \"/private/tmp\")",
            "    (subpath \"/private/var/folders\")",
            "    (subpath \"/Volumes\")",
            "    (subpath \"/Network\"))",
            ";; The CLI's own installation, so it can load its runtime.",
            "(allow file-read* (subpath (param \"INSTALL_ROOT\")))",
            ";; The one job folder: the selected snapshot plus this run's logs.",
            "(allow file-read* file-write* (subpath (param \"WRITE_ROOT\")))",
            "(allow file-read* (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/random\") (literal \"/dev/urandom\"))",
            "(allow file-write-data (literal \"/dev/null\"))",
            "(deny appleevent-send)",
            "(deny network-inbound)",
            ";; Metadata permits traversal, never directory listings or file contents.",
            "(allow file-read-metadata (literal \"/Users\") (literal (param \"USER_ROOT\")))",
        ]
        // getcwd and native CLI config loading inspect ancestors. Grant only
        // metadata for these exact directories, never their siblings' data.
        var ancestors = Set<String>()
        for root in [directory, installation].compactMap({ $0 }) {
            var path = SubscriptionPaths.resolved(root).deletingLastPathComponent()
            while path.path != "/" && !path.path.isEmpty {
                ancestors.insert(path.path)
                path = path.deletingLastPathComponent()
            }
        }
        for path in ancestors.sorted() {
            let literal = path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            lines.append("(allow file-read-metadata (literal \"\(literal)\"))")
        }
        switch provider {
        case .claude:
            lines.append(";; The person's own Claude Code sign-in, owned by the CLI.")
            lines.append("(allow file-read-metadata (literal (string-append (param \"USER_ROOT\") \"/Library\")) (literal (string-append (param \"USER_ROOT\") \"/Library/Keychains\")))")
            lines.append("(allow file-read* (literal (string-append (param \"USER_ROOT\") \"/.claude.json\")))")
            lines.append("(allow file-read* (literal (string-append (param \"USER_ROOT\") \"/Library/Keychains/login.keychain-db\")))")
        case .codex:
            lines.append(";; The person's own Codex sign-in, owned by the CLI.")
            lines.append("(allow file-read-metadata (literal (string-append (param \"USER_ROOT\") \"/.codex\")))")
            for path in ["/.codex/tmp", "/.codex/tmp/arg0", "/.codex/sessions", "/.codex/archived_sessions"] {
                lines.append("(allow file-read-metadata (literal (string-append (param \"USER_ROOT\") \"\(path)\")))")
            }
            lines.append("(allow file-read* (literal (string-append (param \"USER_ROOT\") \"/.codex/installation_id\")))")
            lines.append("(allow file-read* (literal (string-append (param \"USER_ROOT\") \"/.codex/auth.json\")))")
            // The native CLI opens its own installation identifier read/write
            // while initializing. Credential files remain read-only here.
            lines.append("(allow file-write* (literal (string-append (param \"USER_ROOT\") \"/.codex/installation_id\")))")
            if purpose == .status {
                lines.append("(allow file-read* (literal (string-append (param \"USER_ROOT\") \"/.codex/config.toml\")))")
            }

        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `installRoot` is the directory above the executable's own folder, which
    /// covers a bundled `codex-cli/bin/codex` and a Homebrew `bin/claude`.
    static func installRoot(for executable: URL) -> URL {
        let parent = SubscriptionPaths.resolved(executable).deletingLastPathComponent()
        let above = parent.deletingLastPathComponent()
        return above.path.isEmpty || above.path == "/" ? parent : above
    }

    static func arguments(profile: URL, writeRoot: URL, userRoot: URL, installRoot: URL, executable: URL, arguments: [String]) -> [String] {
        ["-D", "WRITE_ROOT=" + writeRoot.path,
         "-D", "USER_ROOT=" + userRoot.path,
         "-D", "INSTALL_ROOT=" + installRoot.path,
         "-f", profile.path,
         executable.path] + arguments
    }
}

// MARK: - Argument construction

/// Argument arrays only. No text is ever handed to a shell, so a prompt,
/// filename or transcript cannot become a command.
enum SubscriptionCLIPlanner {
    /// `--safe-mode` turns off hooks, plugins and customisations while leaving
    /// sign-in and any managed policy in force. `--bare` is deliberately absent:
    /// it would disable the person's own subscription sign-in.
    static let claudeBase = [
        "--safe-mode",
        "--tools", "",
        "--permission-mode", "dontAsk",
        "--no-chrome",
        "--strict-mcp-config",
        "--mcp-config", "{\"mcpServers\":{}}",
        "--no-session-persistence",
        "--disable-slash-commands",
        "--output-format", "stream-json",
        "--verbose",
    ]

    /// Like Codex, Claude reads the selected prompt from standard input so it
    /// never appears in another process's argument listing.
    static func claude() -> [String] {
        claudeBase + ["-p"]
    }

    /// Features that would let the turn reach the shell, the network, the
    /// browser, other apps, stored memories or another agent.
    static let codexDisabledFeatures = [
        "shell_tool", "unified_exec", "apps", "plugins", "memories", "chronicle", "hooks",
        "browser_use", "browser_use_external", "browser_use_full_cdp_access", "in_app_browser",
        "computer_use", "image_generation", "multi_agent", "multi_agent_v2",
        "workspace_dependencies", "skill_search", "code_mode", "code_mode_host",
        "sleep_tool", "goals", "in_app_local_automation",
    ]

    static func tomlString(_ value: String) throws -> String {
        guard !value.contains("\""), !value.contains("\\"), !value.contains("\n") else {
            throw SubscriptionCLIError.unavailable("A prepared path cannot be passed to the Codex CLI safely.")
        }
        return "\"" + value + "\""
    }

    /// The prompt arrives on stdin through the trailing `-`, so no transcript
    /// text appears in the process arguments.
    /// The same explicit native store is used by login status and exec.
    /// Managed auth requirements still take precedence; no login setting or
    /// credential is changed. A keyring-only sign-in may therefore be unavailable.
    static let codexCredentialArguments = ["-c", "cli_auth_credentials_store=\"file\""]

    static func codex(images: [URL], job: SubscriptionJobPaths) throws -> [String] {
        let logs = try tomlString(job.logs.path)
        let state = try tomlString(job.state.path)
        var result = [
            "exec",
            "--ignore-user-config",
            "--ignore-rules",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "-c", "approval_policy=\"never\"",
            "-c", "web_search=\"disabled\"",
            "-c", "project_doc_max_bytes=0",
            "-c", "log_dir=" + logs,
            "-c", "sqlite_home=" + state,
        ]
        result += codexCredentialArguments
        for feature in codexDisabledFeatures {
            result += ["-c", "features.\(feature)=false"]
        }
        result += ["-c", "features.skip_host_skill_discovery=true"]
        for image in images {
            result += ["-i", image.path]
        }
        result += ["--json", "-"]
        return result
    }
}

// MARK: - Result stream

/// One parsed line of a provider's JSON event stream.
enum SubscriptionStreamEvent: Equatable {
    case session(String)
    /// Reply text to append.
    case text(String)
    /// The turn ended. `failure` is set when the provider reported an error.
    case result(text: String?, session: String?, failure: String?)
    /// A tool or capability the boundary forbids appeared in the stream.
    case forbidden(String)
    case ignored
}

enum SubscriptionStreamParser {
    /// Codex item or event types that must never appear in a handoff turn.
    static let forbiddenCodexTypes: Set<String> = [
        "command_execution", "mcp_tool_call", "web_search", "file_change", "collab_agent_tool_call",
    ]

    static func event(provider: SubscriptionProvider, line: String) -> SubscriptionStreamEvent {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Progress notes and warnings are not events; only a missing
            // terminal event makes a run incomplete.
            return .ignored
        }
        switch provider {
        case .claude: return claude(object)
        case .codex: return codex(object)
        }
    }

    private static func claude(_ object: [String: Any]) -> SubscriptionStreamEvent {
        let type = (object["type"] as? String) ?? ""
        if type == "result" {
            let failed = (object["is_error"] as? Bool) ?? false
            let subtype = (object["subtype"] as? String) ?? ""
            let text = object["result"] as? String
            var failure: String?
            if failed || (subtype != "success" && !subtype.isEmpty) {
                failure = (object["error"] as? String) ?? text ?? subtype
            }
            return .result(text: failed ? nil : text, session: object["session_id"] as? String, failure: failure)
        }
        if let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] {
            for block in content {
                let kind = (block["type"] as? String) ?? ""
                if kind == "tool_use" || kind == "server_tool_use" {
                    return .forbidden("The Claude Code CLI attempted the \((block["name"] as? String) ?? "unnamed") tool, which this handoff does not allow.")
                }
                if kind == "tool_result" {
                    return .forbidden("The Claude Code CLI returned a tool result, which this handoff does not allow.")
                }
            }
        }
        if type == "system", let session = object["session_id"] as? String { return .session(session) }
        if let session = object["session_id"] as? String, type == "assistant" { return .session(session) }
        return .ignored
    }

    private static func codex(_ object: [String: Any]) -> SubscriptionStreamEvent {
        let type = (object["type"] as? String) ?? ""
        if forbiddenCodexTypes.contains(type) {
            return .forbidden("The Codex CLI attempted \(type), which this handoff does not allow.")
        }
        if let item = object["item"] as? [String: Any] {
            let itemType = (item["type"] as? String) ?? (item["item_type"] as? String) ?? ""
            if forbiddenCodexTypes.contains(itemType) {
                return .forbidden("The Codex CLI attempted \(itemType), which this handoff does not allow.")
            }
            if type == "item.completed", itemType == "agent_message", let text = item["text"] as? String {
                return .text(text)
            }
            return .ignored
        }
        switch type {
        case "thread.started":
            if let id = object["thread_id"] as? String { return .session(id) }
            return .ignored
        case "turn.completed":
            return .result(text: nil, session: nil, failure: nil)
        case "turn.failed", "error":
            let message = ((object["error"] as? [String: Any])?["message"] as? String)
                ?? (object["error"] as? String)
                ?? (object["message"] as? String)
                ?? "The Codex CLI reported a failure."
            return .result(text: nil, session: nil, failure: message)
        default:
            return .ignored
        }
    }
}

/// The folded state of one run's event stream.
struct SubscriptionStreamState {
    var session: String?
    var texts: [String] = []
    var resultText: String?
    var failure: String?
    var completed = false
    var violation: String?

    mutating func apply(_ event: SubscriptionStreamEvent) {
        switch event {
        case .session(let id):
            if session == nil { session = id }
        case .text(let text):
            texts.append(text)
        case .result(let text, let id, let failure):
            completed = true
            if let text, !text.isEmpty { resultText = text }
            if let id, session == nil { session = id }
            if let failure, self.failure == nil { self.failure = failure }
        case .forbidden(let message):
            if violation == nil { violation = message }
        case .ignored:
            break
        }
    }

    var text: String {
        (resultText ?? texts.joined(separator: "\n\n")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A zero exit status alone is not success: a usable run needs the
    /// provider's own terminal event and non-empty text.
    func resolve(provider: SubscriptionProvider, status: Int32, standardError: String) throws -> SubscriptionCLIResult {
        if let violation { throw SubscriptionCLIError.boundary(violation) }
        if let failure {
            throw SubscriptionCLIError.failed("\(provider.title) reported: \(SubscriptionRedaction.short(failure))")
        }
        let trailing = SubscriptionRedaction.short(standardError)
        guard completed else {
            let reason = trailing.isEmpty ? "exit code \(status)" : trailing
            throw SubscriptionCLIError.incomplete("\(provider.title) stopped before finishing the reply (\(reason)).")
        }
        guard status == 0 else {
            let reason = trailing.isEmpty ? "exit code \(status)" : trailing
            throw SubscriptionCLIError.failed("\(provider.title) finished with a failure (\(reason)).")
        }
        let text = self.text
        guard !text.isEmpty else {
            throw SubscriptionCLIError.incomplete("\(provider.title) finished without any reply text.")
        }
        return SubscriptionCLIResult(providerSessionID: session, text: text)
    }
}

/// Collects stream events while the child runs. The pipe's reader queue and the
/// calling task both touch it, so one lock owns every field and the session
/// callback fires exactly once.
final class SubscriptionStreamSink: @unchecked Sendable {
    private let lock = NSLock()
    private let provider: SubscriptionProvider
    private let onSession: @Sendable (String) -> Void
    private var state = SubscriptionStreamState()
    private var announced = false

    init(provider: SubscriptionProvider, onSession: @escaping @Sendable (String) -> Void) {
        self.provider = provider
        self.onSession = onSession
    }

    /// Returns a message when the run must be stopped immediately.
    func accept(_ line: String) -> String? {
        let event = SubscriptionStreamParser.event(provider: provider, line: line)
        lock.lock()
        state.apply(event)
        let violation = state.violation
        var session: String?
        if !announced, let found = state.session { announced = true; session = found }
        lock.unlock()
        if let session { onSession(session) }
        return violation
    }

    func snapshot() -> SubscriptionStreamState {
        lock.lock(); defer { lock.unlock() }
        return state
    }
}

// MARK: - Bounded child process

/// A dedicated process group and one worker queue own the child and its pipes.
/// Only the stop reason crosses queues. Nonblocking I/O keeps cancellation and
/// timeouts effective even when a descendant retains a pipe after its parent
/// exits. The leader stays unreaped until group cleanup, so its group identifier
/// cannot be reused by an unrelated process before we signal it.
final class SubscriptionProcess: @unchecked Sendable {
    enum Stop {
        case none, cancelled, timedOut, inactive, overflowed
        case violation(String)

        var isPending: Bool { if case .none = self { return true } else { return false } }
    }

    struct Completion {
        let status: Int32
        let stop: Stop
        let standardOutput: String
        let standardError: String
    }

    private let lock = NSLock()
    private var stop = Stop.none
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let directory: URL
    private let inputData: Data
    private let limit: Int
    private let timeout: TimeInterval
    private let inactivityTimeout: TimeInterval?
    private let onLine: (@Sendable (String) -> String?)?
    private let collectOutput: Bool

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL,
         input: Data, limit: Int, timeout: TimeInterval, inactivityTimeout: TimeInterval? = nil,
         collectOutput: Bool = false, onLine: (@Sendable (String) -> String?)? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.inputData = input
        self.limit = limit
        self.timeout = timeout
        self.inactivityTimeout = inactivityTimeout
        self.collectOutput = collectOutput
        self.onLine = onLine
    }

    func run() async throws -> Completion {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try self.execute()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            self.requestStop(.cancelled)
        }
    }

    private func requestStop(_ reason: Stop) {
        lock.lock(); defer { lock.unlock() }
        if stop.isPending { stop = reason }
    }

    private var stopReason: Stop {
        lock.lock(); defer { lock.unlock() }
        return stop
    }

    private func execute() throws -> Completion {
        guard stopReason.isPending else { throw CancellationError() }
        let input = Pipe(), output = Pipe(), error = Pipe()
        let handles = [input.fileHandleForReading, input.fileHandleForWriting,
                       output.fileHandleForReading, output.fileHandleForWriting,
                       error.fileHandleForReading, error.fileHandleForWriting]
        defer { handles.forEach { try? $0.close() } }
        let inputFD = input.fileHandleForWriting.fileDescriptor
        let outputFD = output.fileHandleForReading.fileDescriptor
        let errorFD = error.fileHandleForReading.fileDescriptor
        for fd in [inputFD, outputFD, errorFD] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
                throw SubscriptionCLIError.unavailable("Workbench could not prepare the CLI pipes.")
            }
        }
        // A CLI may stop reading a long prompt at any time. Do not change the
        // app-wide SIGPIPE handler or let that closed pipe terminate Workbench.
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0 else {
            throw SubscriptionCLIError.unavailable("Workbench could not prepare the CLI input pipe.")
        }
        let pid = try spawn(input: input.fileHandleForReading.fileDescriptor,
                            output: output.fileHandleForWriting.fileDescriptor,
                            error: error.fileHandleForWriting.fileDescriptor)
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        var reaped = false
        defer {
            if !reaped {
                _ = kill(-pid, SIGKILL)
                _ = kill(pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }

        var outputOpen = true, errorOpen = true, inputOpen = true
        var inputOffset = 0, byteCount = 0
        var collected = Data(), errorTail = Data(), lineBuffer = Data()
        var leaderExited = false
        var stoppingAt: TimeInterval?
        var lastActivity = ProcessInfo.processInfo.systemUptime
        let deadline = lastActivity + timeout

        func deliverLines(finishing: Bool = false) {
            while let end = lineBuffer.firstIndex(of: 0x0A) {
                let line = lineBuffer.prefix(upTo: end)
                if line.count > SubscriptionCLILimits.maximumLineBytes { requestStop(.overflowed); return }
                if let onLine, let violation = onLine(String(decoding: line, as: UTF8.self)) {
                    requestStop(.violation(violation))
                }
                lineBuffer.removeSubrange(...end)
            }
            if lineBuffer.count > SubscriptionCLILimits.maximumLineBytes { requestStop(.overflowed) }
            if finishing, !lineBuffer.isEmpty, stopReason.isPending {
                if let onLine, let violation = onLine(String(decoding: lineBuffer, as: UTF8.self)) {
                    requestStop(.violation(violation))
                }
                lineBuffer.removeAll()
            }
        }

        func readAvailable(_ fd: Int32, isError: Bool) -> Bool {
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            // Limit each drain so a producer cannot starve the stop/deadline
            // check by continuously filling one pipe.
            for _ in 0..<8 {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count == 0 { return false }
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno == EAGAIN || errno == EWOULDBLOCK
                }
                lastActivity = ProcessInfo.processInfo.systemUptime
                byteCount += count
                guard byteCount <= limit else { requestStop(.overflowed); return true }
                let chunk = Data(bytes.prefix(count))
                if isError {
                    errorTail.append(chunk)
                    if errorTail.count > SubscriptionCLILimits.maximumErrorBytes {
                        errorTail.removeFirst(errorTail.count - SubscriptionCLILimits.maximumErrorBytes)
                    }
                } else {
                    if collectOutput { collected.append(chunk) }
                    lineBuffer.append(chunk)
                    deliverLines()
                }
                if !stopReason.isPending { break }
            }
            return true
        }

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= deadline { requestStop(.timedOut) }
            if let inactivityTimeout, now - lastActivity >= inactivityTimeout { requestStop(.inactive) }
            if !stopReason.isPending, stoppingAt == nil {
                stoppingAt = now
                // POSIX_SPAWN_SETPGROUP makes this only our child and its
                // descendants, even if the direct child has already exited.
                _ = kill(-pid, SIGTERM)
                _ = kill(pid, SIGTERM)
            }
            if let stoppingAt, now - stoppingAt >= 0.25 {
                _ = kill(-pid, SIGKILL)
                _ = kill(pid, SIGKILL)
                break
            }
            if inputOpen {
                if !stopReason.isPending || inputOffset == inputData.count {
                    try? input.fileHandleForWriting.close()
                    inputOpen = false
                } else {
                    let count = inputData.withUnsafeBytes { data in
                        Darwin.write(inputFD, data.baseAddress!.advanced(by: inputOffset), min(16 * 1024, data.count - inputOffset))
                    }
                    if count > 0 { inputOffset += count }
                    else if count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                        try? input.fileHandleForWriting.close()
                        inputOpen = false
                    }
                }
            }
            if outputOpen { outputOpen = readAvailable(outputFD, isError: false) }
            if errorOpen { errorOpen = readAvailable(errorFD, isError: true) }
            if !leaderExited {
                var info = siginfo_t()
                // WNOWAIT retains the exited leader until all group signals
                // are done. No Foundation termination handler can reap it early.
                if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                    leaderExited = info.si_pid == pid
                }
            }
            if leaderExited && !outputOpen && !errorOpen { break }
            var descriptors: [pollfd] = []
            if outputOpen { descriptors.append(pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0)) }
            if errorOpen { descriptors.append(pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0)) }
            if inputOpen { descriptors.append(pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0)) }
            _ = poll(&descriptors, nfds_t(descriptors.count), 20)
        }
        // Close pipes before reaping: descendants cannot keep the result wait
        // alive. Kill any remaining members even after an ordinary leader exit.
        _ = kill(-pid, SIGKILL)
        if !leaderExited { _ = kill(pid, SIGKILL) }
        try? output.fileHandleForReading.close()
        try? error.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
        var rawStatus: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &rawStatus, 0) } while waited < 0 && errno == EINTR
        reaped = waited == pid
        deliverLines(finishing: true)
        let status: Int32 = waited == pid ? (rawStatus & 0x7F == 0 ? (rawStatus >> 8) & 0xFF : 128 + (rawStatus & 0x7F)) : -1
        return Completion(status: status, stop: stopReason,
                          standardOutput: String(decoding: collected, as: UTF8.self),
                          standardError: String(decoding: errorTail, as: UTF8.self))
    }

    private func spawn(input: Int32, output: Int32, error: Int32) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw SubscriptionCLIError.unavailable("Workbench could not prepare the CLI process.")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw SubscriptionCLIError.unavailable("Workbench could not prepare the CLI process.")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let directoryAction: Int32
        if #available(macOS 26, *) {
            directoryAction = posix_spawn_file_actions_addchdir(&actions, directory.path)
        } else {
            directoryAction = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        }
        guard directoryAction == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, error, STDERR_FILENO) == 0 else {
            throw SubscriptionCLIError.unavailable("Workbench could not isolate the CLI process.")
        }
        var argv = ([executable.path] + arguments).map { $0.withCString { strdup($0) } } + [nil]
        var envp = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)".withCString { strdup($0) } } + [nil]
        defer { argv.compactMap { $0 }.forEach { free($0) }; envp.compactMap { $0 }.forEach { free($0) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            throw SubscriptionCLIError.unavailable("Workbench could not allocate the CLI process arguments.")
        }
        // Cancellation can arrive while constructing the launch. Check again
        // before spawning; later cancellation is handled by the worker loop.
        guard stopReason.isPending else { throw CancellationError() }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp) == 0, pid > 0 else {
            throw SubscriptionCLIError.unavailable("Workbench could not start \(executable.lastPathComponent).")
        }
        return pid
    }
}

// MARK: - One job at a time

/// The host owns one handoff job. A second concurrent run is refused rather
/// than queued, so no run starts work the person did not ask for.
private actor SubscriptionCLIGate {
    static let shared = SubscriptionCLIGate()
    private var busy = false

    func acquire() -> Bool {
        guard !busy else { return false }
        busy = true
        return true
    }

    func release() { busy = false }
}

// MARK: - Adapter

enum SubscriptionCLI {
    /// One short command result. `nil` from a probe means the candidate could
    /// not be launched at all, so discovery moves to the next one.
    struct Probe: Sendable {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Injection seam for the checks: logical command in, bounded result out.
    typealias ProbeRunner = @Sendable (URL, [String]) async -> Probe?

    static let claudeImagesVerified = false

    static func versionArguments() -> [String] { ["--version"] }

    static func authArguments(for provider: SubscriptionProvider) -> [String] {
        switch provider {
        case .claude: return ["--safe-mode", "auth", "status", "--json"]
        case .codex: return ["login", "status"] + SubscriptionCLIPlanner.codexCredentialArguments
        }
    }

    // MARK: Discovery

    /// Looks for an installed, supported, already signed-in CLI. It runs only
    /// `--version` and the provider's own status command, so it starts no paid
    /// inference, opens no browser and begins no sign-in. Nothing here launches
    /// the CLI app; the host offers that separately.
    static func discover(_ provider: SubscriptionProvider) async -> SubscriptionConnection {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return await discover(provider,
                              candidates: SubscriptionCLICandidates.urls(for: provider, home: home),
                              probe: liveProbe(for: provider, home: home))
    }

    static func discover(_ provider: SubscriptionProvider, candidates: [URL], probe: ProbeRunner) async -> SubscriptionConnection {
        var outdated: (URL, String)?
        for candidate in candidates {
            if Task.isCancelled {
                return .unavailable(provider, "Checking for \(provider.title) was cancelled.")
            }
            guard let result = await probe(candidate, versionArguments()), result.status == 0,
                  let version = SubscriptionVersionCheck.parse(result.standardOutput, provider: provider) else { continue }
            guard SubscriptionVersionCheck.isSupported(version, provider: provider) else {
                // A newer copy may still be ahead in the candidate list.
                if outdated == nil { outdated = (candidate, version) }
                continue
            }
            guard let status = await probe(candidate, authArguments(for: provider)) else {
                return .unavailable(provider, "Workbench could not check the \(provider.title) sign-in.", executable: candidate, version: version)
            }
            switch SubscriptionAuth.status(for: provider, status: status) {
            case .ready(let summary):
                let detail = provider == .claude
                    ? "\(provider.title) \(version) is signed in with a \(summary) subscription."
                    : "\(provider.title) \(version) is signed in with \(summary)."
                return SubscriptionConnection(provider: provider, executable: candidate, version: version, ready: true, detail: detail)
            case .needsSignIn(let message), .unreadable(let message):
                return .unavailable(provider, message, executable: candidate, version: version)
            }
        }
        if let outdated {
            let required = SubscriptionVersionCheck.minimum(for: provider).map(String.init).joined(separator: ".")
            return .unavailable(provider,
                                "\(provider.title) \(outdated.1) is installed, but this handoff needs \(required) or newer.",
                                executable: outdated.0, version: outdated.1)
        }
        return .unavailable(provider, "No installed \(provider.title) command line was found. Install and sign in to it yourself, then check again.")
    }

    /// Discovery uses the same OS boundary as a run, with a disposable write
    /// root. Raw status output is parsed and dropped; it is never logged.
    private static func liveProbe(for provider: SubscriptionProvider, home: URL) -> ProbeRunner {
        { executable, arguments in
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
            return await sandboxedProbe(provider, executable: executable, arguments: arguments, home: home)
        }
    }

    /// The sign-in probe runs under the same OS boundary as a real turn, using a
    /// disposable write root that is removed afterwards.
    private static func sandboxedProbe(_ provider: SubscriptionProvider, executable: URL, arguments: [String], home: URL) async -> Probe? {
        guard FileManager.default.isExecutableFile(atPath: SubscriptionSandbox.executable.path) else { return nil }
        let job = SubscriptionJobPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("Workbench-CLI-Status-" + UUID().uuidString, isDirectory: true))
        do {
            try FileManager.default.createDirectory(at: job.root, withIntermediateDirectories: true)
            try job.prepare(SubscriptionSandbox.profile(for: provider, purpose: .status, directory: job.root,
                                                        installation: SubscriptionSandbox.installRoot(for: executable)))
        } catch {
            try? FileManager.default.removeItem(at: job.root)
            return nil
        }
        defer { try? FileManager.default.removeItem(at: job.root) }
        let passed = SubscriptionSandbox.arguments(profile: job.profile, writeRoot: job.root, userRoot: home,
                                                  installRoot: SubscriptionSandbox.installRoot(for: executable),
                                                  executable: executable, arguments: arguments)
        let environment = SubscriptionEnvironment.sanitized(ProcessInfo.processInfo.environment, scratch: job.scratch, provider: provider)
        return await launchProbe(SubscriptionSandbox.executable, passed, environment, job.root)
    }

    private static func launchProbe(_ command: URL, _ arguments: [String], _ environment: [String: String], _ directory: URL) async -> Probe? {
        let process = SubscriptionProcess(executable: command, arguments: arguments, environment: environment,
                                          directory: directory, input: Data(),
                                          limit: SubscriptionCLILimits.maximumProbeBytes,
                                          timeout: SubscriptionCLILimits.probeTimeout, collectOutput: true)
        do {
            let completion = try await process.run()
            guard completion.stop.isPending else { return nil }
            return Probe(status: completion.status, standardOutput: completion.standardOutput, standardError: completion.standardError)
        } catch {
            return nil
        }
    }

    // MARK: One run

    /// Hands the prepared prompt to the connected CLI and returns its reply.
    ///
    /// `directory` must be the immutable, app-managed snapshot for this job: it
    /// holds only material the person selected. Outside it, only the CLI's
    /// runtime, installation ID and read-only native sign-in are allowed. Tools are off, so
    /// the CLI cannot run commands,
    /// browse, write files elsewhere or start another agent. Nothing is
    /// retried, no provider is substituted and no usage is purchased.
    static func run(_ connection: SubscriptionConnection, prompt: String, images: [URL], directory: URL,
                    onSession: @escaping @Sendable (String) -> Void) async throws -> SubscriptionCLIResult {
        try Task.checkCancellation()
        guard connection.ready, let executable = connection.executable else {
            throw SubscriptionCLIError.unavailable("\(connection.provider.title) is not connected. \(connection.detail)")
        }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw SubscriptionCLIError.unavailable("There is nothing to hand off yet.")
        }
        guard prompt.count <= SubscriptionCLILimits.maximumPromptCharacters else {
            throw SubscriptionCLIError.unavailable("This request is too long for the \(connection.provider.title) handoff. Select less material and try again.")
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let root = try SubscriptionJobDirectory.validate(directory, home: home)
        let images = try validated(images, in: root, provider: connection.provider)
        let job = SubscriptionJobPaths(root: root)

        // The OS boundary is not optional. Without it this route reports
        // unavailable instead of running with weaker isolation.
        guard FileManager.default.isExecutableFile(atPath: SubscriptionSandbox.executable.path) else {
            throw SubscriptionCLIError.unavailable("This Mac has no sandbox-exec, so Workbench cannot run the \(connection.provider.title) handoff safely.")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SubscriptionCLIError.unavailable("The \(connection.provider.title) command line is no longer installed at its checked location. Check the connection again.")
        }

        let inner: [String]
        let input: Data
        switch connection.provider {
        case .claude:
            inner = SubscriptionCLIPlanner.claude()
            input = Data(prompt.utf8)
        case .codex:
            inner = try SubscriptionCLIPlanner.codex(images: images, job: job)
            input = Data(prompt.utf8)
        }

        do {
            try job.prepare(SubscriptionSandbox.profile(for: connection.provider, purpose: .inference, directory: job.root,
                                                        installation: SubscriptionSandbox.installRoot(for: executable)))
        } catch {
            throw SubscriptionCLIError.unavailable("Workbench could not prepare the sandbox for this job folder, so it did not start \(connection.provider.title).")
        }
        let arguments = SubscriptionSandbox.arguments(profile: job.profile, writeRoot: job.root, userRoot: home,
                                                     installRoot: SubscriptionSandbox.installRoot(for: executable),
                                                     executable: executable, arguments: inner)
        let environment = SubscriptionEnvironment.sanitized(ProcessInfo.processInfo.environment, scratch: job.scratch, provider: connection.provider)

        guard await SubscriptionCLIGate.shared.acquire() else {
            throw SubscriptionCLIError.unavailable("Another handoff is already running. Wait for it to finish or stop it first.")
        }
        do {
            // Cached readiness is only a UI hint. The CLI may have changed
            // accounts since discovery. Check its current auth mode under the
            // same configuration as inference, without editing native login.
            let checkedStatus = await sandboxedProbe(connection.provider, executable: executable,
                                                       arguments: authArguments(for: connection.provider), home: home)
            try Task.checkCancellation()
            guard let status = checkedStatus else {
                throw SubscriptionCLIError.unavailable("Workbench could not verify the current subscription sign-in. Check the connection and try again.")
            }
            switch SubscriptionAuth.status(for: connection.provider, status: status) {
            case .ready: break
            case .needsSignIn(let message), .unreadable(let message):
                throw SubscriptionCLIError.unavailable(message)
            }
            try Task.checkCancellation()
            let result = try await dispatch(connection, arguments: arguments,
                                            environment: environment, job: job, input: input, onSession: onSession)
            await SubscriptionCLIGate.shared.release()
            return result
        } catch {
            await SubscriptionCLIGate.shared.release()
            throw error
        }
    }

    private static func dispatch(_ connection: SubscriptionConnection, arguments: [String],
                                 environment: [String: String], job: SubscriptionJobPaths, input: Data,
                                 onSession: @escaping @Sendable (String) -> Void) async throws -> SubscriptionCLIResult {
        let sink = SubscriptionStreamSink(provider: connection.provider, onSession: onSession)
        let child = SubscriptionProcess(executable: SubscriptionSandbox.executable, arguments: arguments,
                                        environment: environment, directory: job.root, input: input,
                                        limit: SubscriptionCLILimits.maximumOutputBytes,
                                        timeout: SubscriptionCLILimits.runTimeout,
                                        inactivityTimeout: SubscriptionCLILimits.inactivityTimeout,
                                        onLine: { [sink] line in sink.accept(line) })
        let completion = try await child.run()
        try Task.checkCancellation()
        switch completion.stop {
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw SubscriptionCLIError.failed("\(connection.provider.title) did not finish within 30 minutes and was stopped.")
        case .inactive:
            throw SubscriptionCLIError.failed("\(connection.provider.title) reported no progress for five minutes and was stopped.")
        case .overflowed:
            throw SubscriptionCLIError.failed("\(connection.provider.title) produced more output than Workbench accepts and was stopped.")
        case .violation(let message):
            throw SubscriptionCLIError.boundary(message)
        case .none:
            break
        }
        return try sink.snapshot().resolve(provider: connection.provider, status: completion.status,
                                           standardError: completion.standardError)
    }

    static let supportedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// Attachments must already live inside the selected snapshot, so a run can
    /// never reference a picture the person did not choose.
    static func validated(_ images: [URL], in root: URL, provider: SubscriptionProvider) throws -> [URL] {
        guard !images.isEmpty else { return [] }
        if provider == .claude, !claudeImagesVerified {
            // The scoped-read path for Claude Code attachments is not verified
            // here, and claiming the model saw a picture it never received
            // would be worse than saying so.
            throw SubscriptionCLIError.imagesUnsupported("Images cannot be included in a Claude Code handoff yet. Hand off the text only, or use Codex for the pictures.")
        }
        guard images.count <= SubscriptionCLILimits.maximumImages else {
            throw SubscriptionCLIError.unavailable("A handoff accepts at most \(SubscriptionCLILimits.maximumImages) images. Select fewer and try again.")
        }
        let prefix = root.path + "/"
        var result: [URL] = []
        var totalBytes = 0
        for image in images {
            let resolved = SubscriptionPaths.resolved(image)
            guard resolved.path.hasPrefix(prefix) else {
                throw SubscriptionCLIError.boundary("An attachment is outside this job's folder, so Workbench did not hand it off.")
            }
            guard supportedImageExtensions.contains(resolved.pathExtension.lowercased()) else {
                throw SubscriptionCLIError.unavailable("\(resolved.lastPathComponent) is not a supported image for this handoff.")
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes?[.size] as? NSNumber, size.intValue > 0 else {
                throw SubscriptionCLIError.unavailable("\(resolved.lastPathComponent) could not be read, so Workbench did not hand it off.")
            }
            guard size.intValue <= SubscriptionCLILimits.maximumImageBytes else {
                throw SubscriptionCLIError.unavailable("\(resolved.lastPathComponent) is too large for this handoff.")
            }
            totalBytes += size.intValue
            guard totalBytes <= SubscriptionCLILimits.maximumTotalImageBytes else {
                throw SubscriptionCLIError.unavailable("The selected images exceed this handoff's total size limit. Select fewer images and try again.")
            }
            result.append(resolved)
        }
        return result
    }
}

extension SubscriptionAuth {
    /// Parses one status probe. Only the outcome below is kept; the raw output,
    /// which may name the account, is discarded with the probe.
    static func status(for provider: SubscriptionProvider, status probe: SubscriptionCLI.Probe) -> Status {
        switch provider {
        case .claude:
            guard probe.status == 0 else {
                return .needsSignIn("Sign in to Claude Code with your Claude subscription, then check again.")
            }
            return claude(probe.standardOutput)
        case .codex:
            guard probe.status == 0 else {
                if (probe.standardOutput + "\n" + probe.standardError).split(whereSeparator: \.isNewline)
                    .contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Not logged in" }) {
                    return .needsSignIn("Sign in to Codex with your ChatGPT account in the ChatGPT app, then check again.")
                }
                return .unreadable("Workbench could not verify the Codex subscription sign-in under this Mac's handoff restrictions. Check the CLI setup and try again.")
            }
            // The official CLI currently writes this status to stderr; older
            // versions and fixtures may use stdout. Neither raw stream leaves
            // this parser.
            return codex(probe.standardOutput + "\n" + probe.standardError)
        }
    }
}
