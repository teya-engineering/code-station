import Foundation

// Something the agent asked back before it can carry on. Claude Code writes these to its
// stdout as control requests and parks the turn until an answer comes back on its stdin.
// Two things arrive this way: a tool waiting for permission, and AskUserQuestion, which
// is the agent asking a real question with options to choose from.
struct PermissionRequest: Identifiable, Equatable, Sendable {
    let id: String
    let toolName: String
    let title: String
    // What the call will actually do, taken from its input: the command a Bash call is
    // about to run, the file an edit is about to touch. This is what the answer is really
    // about, so it is never the CLI's paraphrase of it.
    let subject: String
    // The CLI's own sentence about the call, kept only when it says more than the subject.
    let detail: String
    // The tool's own input, handed back untouched when allowed. An answered question goes
    // back the same way with the answers folded in, which is where the tool reads them.
    let input: Data
    // What the CLI offers as a "do not ask me again", echoed back exactly as it came.
    let suggestions: Data?
    let alwaysTitle: String?
    let questions: [AgentQuestion]

    var isQuestion: Bool { !questions.isEmpty }
}

struct AgentQuestion: Identifiable, Equatable, Sendable {
    struct Option: Identifiable, Equatable, Sendable {
        let id: Int
        let label: String
        let description: String
    }

    let id: Int
    let header: String
    let text: String
    let multiSelect: Bool
    let options: [Option]
}

enum PermissionAnswer: Equatable, Sendable {
    case allowOnce
    case allowAlways
    case deny
    // Question text to what the person picked or typed.
    case answers([String: String])
}

extension PermissionRequest {
    // Built from the `request` object of a `can_use_tool` control request. Decoded by hand
    // for the same reason as the rest of the stream: fields come and go between CLI
    // versions, and a shape we do not recognise must not park a turn forever.
    static func parse(id: String, request: [String: Any], projectPath: String) -> PermissionRequest? {
        guard let toolName = request["tool_name"] as? String else { return nil }
        let rawInput = request["input"] as? [String: Any] ?? [:]
        guard let input = try? JSONSerialization.data(withJSONObject: rawInput) else { return nil }

        let suggestions = (request["permission_suggestions"] as? [Any])
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }

        let subject = subject(toolName: toolName, input: rawInput, projectPath: projectPath)
        let described = request["description"] as? String ?? ""

        return PermissionRequest(
            id: id,
            toolName: toolName,
            title: request["display_name"] as? String ?? toolName,
            subject: subject,
            detail: described == subject ? "" : described,
            input: input,
            suggestions: suggestions,
            alwaysTitle: alwaysTitle(toolName: toolName, suggestions: request["permission_suggestions"]),
            questions: questions(in: rawInput))
    }

    private static func subject(toolName: String, input: [String: Any], projectPath: String) -> String {
        // A command goes out exactly as written, newlines and all. It is read to decide
        // whether to run it, and folding it onto one line is how a second command hides
        // behind the first.
        if let command = input["command"] as? String { return command }
        // Everything else reads the way the activity spine reads it, so a call looks the
        // same whether it is waiting or already done.
        let json = (try? JSONSerialization.data(withJSONObject: input))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return ToolPresentation(tool: ToolUse(id: "", name: toolName, input: json),
                                projectPath: projectPath).argument
    }

    // What the "do not ask again" button says. The CLI decides what is on offer: a whole
    // mode for edits, a rule for anything else.
    private static func alwaysTitle(toolName: String, suggestions: Any?) -> String? {
        guard let first = (suggestions as? [Any])?.first as? [String: Any] else { return nil }
        switch first["type"] as? String {
        case "setMode":
            let mode = first["mode"] as? String ?? ""
            return mode == "acceptEdits" ? "Accept edits from now on" : "Switch to \(mode)"
        case "addRules":
            return "Always allow \(toolName)"
        default:
            return "Don't ask again"
        }
    }

    private static func questions(in input: [String: Any]) -> [AgentQuestion] {
        guard let raw = input["questions"] as? [Any] else { return [] }
        return raw.enumerated().compactMap { index, item in
            guard let question = item as? [String: Any],
                  let text = question["question"] as? String else { return nil }
            let options = (question["options"] as? [Any] ?? []).enumerated()
                .compactMap { position, item -> AgentQuestion.Option? in
                    guard let option = item as? [String: Any],
                          let label = option["label"] as? String else { return nil }
                    return AgentQuestion.Option(id: position,
                                                label: label,
                                                description: option["description"] as? String ?? "")
                }
            guard !options.isEmpty else { return nil }
            return AgentQuestion(id: index,
                                 header: question["header"] as? String ?? "",
                                 text: text,
                                 multiSelect: question["multiSelect"] as? Bool ?? false,
                                 options: options)
        }
    }

    // The answer as the CLI wants it: one JSON line on the process's stdin, quoting the
    // request it belongs to.
    func responseLine(_ answer: PermissionAnswer) -> Data? {
        var decision: [String: Any]
        switch answer {
        case .deny:
            decision = ["behavior": "deny",
                        "message": "The user did not allow this. Do not try it again without asking."]
        case .allowOnce, .allowAlways, .answers:
            var updated = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
            if case .answers(let given) = answer { updated["answers"] = given }
            decision = ["behavior": "allow", "updatedInput": updated]
            if case .allowAlways = answer, let suggestions,
               let list = try? JSONSerialization.jsonObject(with: suggestions) {
                decision["updatedPermissions"] = list
            }
        }

        let envelope: [String: Any] = [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": id, "response": decision],
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
        line.append(0x0A)
        return line
    }

    // How an answered question reads in the transcript afterwards. The answers themselves
    // go back inside the tool's input, where nothing else would show them.
    static func transcript(of answers: [String: String]) -> String {
        answers.sorted { $0.key < $1.key }
            .map { "\($0.key)\n\($0.value)" }
            .joined(separator: "\n\n")
    }
}
