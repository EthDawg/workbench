import Foundation

/// A description of the existing local CLI route, never an instruction to run it.
/// The review uses this from its in-memory inputs; dispatch rechecks the frozen files.
struct HandoffRunReadiness: Equatable {
    enum State { case off, checking, missing, unsupported, signIn, unverified, restricted, inputLimit, incompatible, busy, ready }
    let state: State
    let detail: String
    var canStart: Bool { state == .ready }

    static func evaluate(provider: SubscriptionProvider, enabled: Bool, checking: Bool,
                         connection: SubscriptionConnection?, busy: Bool, compatible: Bool,
                         inputProblem: String?) -> Self {
        let manual = " Copy instructions remains available."
        if !compatible { return .init(state: .incompatible, detail: "This skill needs files or workspace tools. Copy instructions and give your assistant the complete selected work folder.") }
        if let inputProblem { return .init(state: .inputLimit, detail: inputProblem) }
        if busy { return .init(state: .busy, detail: "Another handoff is running. Wait for it to finish or stop it in History." + manual) }
        if !enabled { return .init(state: .off, detail: provider.title + " is off. Enable it in Connections if you want Workbench to run the task." + manual) }
        if checking { return .init(state: .checking, detail: "Checking " + provider.title + " on this Mac. Nothing will start automatically." + manual) }
        guard let connection else { return .init(state: .unverified, detail: provider.title + " has not been checked. Use Check again or Connections." + manual) }
        guard connection.ready else {
            let state: State
            switch connection.problem {
            case .missing: state = .missing
            case .unsupported: state = .unsupported
            case .signIn: state = .signIn
            case .restricted: state = .restricted
            case .unverified, nil: state = .unverified
            }
            return .init(state: state, detail: connection.detail + manual)
        }
        return .init(state: .ready, detail: provider.title + " is ready. Start task sends only this reviewed selection and request; the result returns to History. Nothing starts until you choose Start task.")
    }

    static func inputProblem(provider: SubscriptionProvider, prompt: String, imageBytes: [Int]) -> String? {
        let manual = " Choose fewer items or use Copy instructions."
        if prompt.count > SubscriptionCLILimits.maximumPromptCharacters {
            return "The full request exceeds the connected limit of 100,000 characters." + manual
        }
        if imageBytes.count > SubscriptionCLILimits.maximumImages(for: provider) {
            return provider.title + " accepts up to \(SubscriptionCLILimits.maximumImages(for: provider)) images per task." + manual
        }
        let each = SubscriptionCLILimits.maximumImageBytes(for: provider)
        if imageBytes.contains(where: { $0 < 0 || $0 > each }) {
            return provider.title + " accepts each image up to " + (provider == .claude ? "3.75" : "10") + " MiB." + manual
        }
        if imageBytes.reduce(0, +) > SubscriptionCLILimits.maximumTotalImageBytes(for: provider) {
            return provider.title + " accepts images totaling up to " + (provider == .claude ? "16" : "128") + " MiB." + manual
        }
        if provider == .claude, !imageBytes.isEmpty {
            guard let bytes = try? SubscriptionClaudeInput.projectedBytes(prompt: prompt, imageBytes: imageBytes) else {
                return "The Claude Code request size could not be verified." + manual
            }
            if bytes > SubscriptionCLILimits.claudeMaximumRequestBytes {
                return "The encoded images and request exceed Claude Code’s 24 MiB request limit." + manual
            }
        }
        return nil
    }
}
