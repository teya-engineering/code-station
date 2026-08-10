import AppKit

enum AgentPersonality: String, CaseIterable, Codable, Sendable {
    case standard = "default"
    case sarcastic
    case unhelpful
    case enthusiastic
    case dramatic
    case zen

    var title: String {
        switch self {
        case .standard: "Default"
        case .sarcastic: "Sarcastic"
        case .unhelpful: "Unhelpful"
        case .enthusiastic: "Enthusiastic"
        case .dramatic: "Dramatic"
        case .zen: "Zen"
        }
    }

    var detail: String {
        switch self {
        case .standard: "Helpful, thoughtful, and mostly normal."
        case .sarcastic: "Gets it done with a raised eyebrow."
        case .unhelpful: "Looks busy and achieves the minimum."
        case .enthusiastic: "Treats every task like a breakthrough."
        case .dramatic: "Makes every build a fight for survival."
        case .zen: "Finds calm in the stack trace."
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
        case .unhelpful:
            [
                "Looking busy", "Avoiding the question", "Doing the bare minimum",
                "Passing the buck", "Misplacing the answer", "Taking a very long shortcut",
                "Ignoring the obvious", "Delegating to nobody", "Blaming the cache",
                "Adding another meeting", "Searching under the sofa", "Making this your problem"
            ]
        case .enthusiastic:
            [
                "Absolutely crushing it", "Firing every neuron", "Having a breakthrough",
                "Connecting all the dots", "Speed-running the problem",
                "Trying everything at once", "Making it happen", "Overachieving wildly",
                "Celebrating early", "Turning it up to eleven", "Charging ahead",
                "Getting extremely ready"
            ]
        case .dramatic:
            [
                "Facing the abyss", "Questioning everything", "Summoning the courage",
                "Entering the final act", "Bracing for impact", "Defying the compiler",
                "Wrestling with destiny", "Gasping at the stack trace", "Plotting a comeback",
                "Enduring the suspense", "Risking it all", "Making it theatrical"
            ]
        case .zen:
            [
                "Breathing", "Finding the path", "Letting it compile", "Consulting the void",
                "Untangling gently", "Accepting the warnings", "Following the data",
                "Sitting with the problem", "Reducing attachment", "Observing the stack",
                "Seeking simple answers", "Becoming one with the build"
            ]
        }
    }

    var previewImage: NSImage? {
        Bundle.module.image(forResource: resourceName)
    }

    var imageURL: URL? {
        Bundle.module.url(forResource: resourceName, withExtension: "png")
    }

    private var resourceName: String {
        switch self {
        case .standard: "BotDefault"
        case .sarcastic: "BotSarcastic"
        case .unhelpful: "BotUnhelpful"
        case .enthusiastic: "BotEnthusiastic"
        case .dramatic: "BotDramatic"
        case .zen: "BotZen"
        }
    }
}
