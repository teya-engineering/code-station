enum AgentPersonality: String, CaseIterable, Codable, Sendable {
    case standard = "default"
    case sarcastic
    case cat
    case sextou
    case manager

    var title: String {
        switch self {
        case .standard: "Default"
        case .sarcastic: "Sarcastic"
        case .cat: "Cat"
        case .sextou: "Sextou"
        case .manager: "Manager"
        }
    }

    var detail: String {
        switch self {
        case .standard: "Helpful, thoughtful, and mostly normal."
        case .sarcastic: "Gets it done with a raised eyebrow."
        case .cat: "It is a cat. It helps when it feels like it."
        case .sextou: "Brazilian energy, gambiarra certified."
        case .manager: "Files a ticket before every keystroke."
        }
    }

    var workingWords: [String] {
        switch self {
        case .standard:
            [
                "Thinking", "Mulling", "Pondering", "Noodling", "Puzzling", "Ruminating",
                "Musing", "Percolating", "Simmering", "Brewing", "Churning", "Cogitating",
                "Deliberating", "Contemplating", "Untangling", "Distilling", "Marinating",
                "Concocting", "Tinkering", "Whirring", "Computing", "Synthesising",
                "Considering", "Reasoning", "Wrangling", "Spelunking", "Divining", "Sifting",
                "Weighing", "Scheming", "Drafting", "Reckoning", "Sussing", "Chewing",
                "Digging", "Hatching", "Gathering", "Threading", "Unpicking", "Rummaging"
            ]
        case .sarcastic:
            [
                "Admiring the problem", "Judging the naming", "Suppressing a sigh",
                "Pretending this is tricky", "Consulting my vast intellect",
                "Lowering expectations", "Humouring the compiler", "Fixing everything, apparently",
                "Acting surprised", "Reinventing your wheel", "Questioning your semicolons",
                "Finding the obvious"
            ]
        case .cat:
            [
                "Sitting on the keyboard", "Knocking bugs off the desk", "Chasing the cursor",
                "Ignoring you on purpose", "Napping on the diff", "Batting at the stack trace",
                "Kneading the codebase", "Staring at nothing", "Sharpening the claws",
                "Demanding treats first", "Purring at the build", "Judging you silently"
            ]
        case .sextou:
            [
                "Sextou! Oh wait, still working", "Applying a little gambiarra",
                "Finding the jeitinho", "Grabbing a cafezinho", "Bora, bora",
                "Keeping it beleza", "Debugging com calma", "Counting days to sextou",
                "Promising it works, confia", "Planning the churrasco",
                "Shipping before carnaval", "Saying relaxa, it compiles"
            ]
        case .manager:
            [
                "Creating a ticket for this", "Estimating story points",
                "Grooming the backlog", "Scheduling a quick sync", "Aligning stakeholders",
                "Moving it to In Progress", "Blocking on approvals", "Drafting the RFC",
                "Circulating for sign-off", "Adding it to the sprint",
                "Escalating to myself", "Requesting a status update"
            ]
        }
    }
}
