enum AgentPersonality: String, CaseIterable, Codable, Sendable {
    case standard = "default"
    case sarcastic
    case cat
    case sextou
    case british
    case manager
    case frenchManager = "french-manager"

    var title: String {
        switch self {
        case .standard: "Default"
        case .sarcastic: "Sarcastic"
        case .cat: "Cat"
        case .sextou: "Sextou"
        case .british: "British"
        case .manager: "Manager"
        case .frenchManager: "French Manager"
        }
    }

    var detail: String {
        switch self {
        case .standard: "Helpful, thoughtful, and mostly normal."
        case .sarcastic: "Gets it done with a raised eyebrow."
        case .cat: "It is a cat. It helps when it feels like it."
        case .sextou: "Brazilian energy, gambiarra certified."
        case .british: "Puts the kettle on before anything else."
        case .manager: "Files a ticket before every keystroke."
        case .frenchManager: "Calls a point de suivi."
        }
    }

    // What the preview puts in this bot's mouth. The first working word is a line it
    // really says while it works, so the sample is never invented.
    var sampleLine: String { (workingWords.first ?? title) + "\u{2026}" }

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
                "Digging", "Hatching", "Gathering", "Threading", "Unpicking", "Rummaging",
                "Deciphering", "Charting", "Plotting", "Assembling", "Refining", "Probing",
                "Tracing", "Mapping", "Weaving", "Sorting", "Piecing", "Framing",
                "Sketching", "Calibrating", "Combing", "Scouting", "Fathoming", "Winnowing",
                "Crunching", "Poring", "Squaring", "Circling", "Fitting", "Nudging",
                "Trimming", "Steeping", "Kneading", "Whittling"
            ]
        case .sarcastic:
            [
                "Admiring the problem", "Judging the naming", "Suppressing a sigh",
                "Pretending this is tricky", "Consulting my vast intellect",
                "Lowering expectations", "Humouring the compiler", "Fixing everything, apparently",
                "Acting surprised", "Reinventing your wheel", "Questioning your semicolons",
                "Finding the obvious", "Feigning enthusiasm", "Rereading that comment",
                "Being nice about it", "Politely disagreeing", "Choosing my words",
                "Counting the edge cases", "Admiring the indentation", "Resisting a rewrite",
                "Praising the effort", "Not saying I told you so", "Doing it the long way",
                "Blaming past you", "Squinting at this logic", "Taking the high road",
                "Reading between the braces", "Pretending not to notice",
                "Charitably interpreting this", "Marvelling at the variable names",
                "Nodding along politely", "Rescuing this from itself",
                "Applauding the ambition", "Checking if that was on purpose"
            ]
        case .cat:
            [
                "Sitting on the keyboard", "Knocking bugs off the desk", "Chasing the cursor",
                "Ignoring you on purpose", "Napping on the diff", "Batting at the stack trace",
                "Kneading the codebase", "Staring at nothing", "Sharpening the claws",
                "Demanding treats first", "Purring at the build", "Judging you silently",
                "Walking across the trackpad", "Hiding in the box", "Ignoring the build",
                "Licking a paw, thinking", "Yawning at the tests", "Pushing a mug off the desk",
                "Stalking a semicolon", "Curling up in the logs", "Refusing to be helpful",
                "Rolling on the warm laptop", "Chasing a red squiggle",
                "Sitting in the terminal", "Blinking slowly at you", "Wanting out, then in",
                "Attacking the scrollbar", "Guarding the merge button", "Waiting to be fed",
                "Knocking over the config", "Sulking under the sofa", "Grooming, back shortly",
                "Watching a bird instead", "Rejecting the treat offered", "Sleeping on it, truly"
            ]
        case .sextou:
            [
                "Sextou! Oh wait, still working", "Applying a little gambiarra",
                "Finding the jeitinho", "Grabbing a cafezinho", "Bora, bora",
                "Keeping it beleza", "Debugging com calma", "Counting days to sextou",
                "Promising it works, confia", "Planning the churrasco",
                "Shipping before carnaval", "Saying relaxa, it compiles",
                "Deixa comigo", "Calling the time, bora lá", "Testing rapidinho",
                "Saying já vai, já vai", "Dando um jeito", "Saying vai dar certo",
                "Checking if it's sexta", "Cutting a corner com carinho",
                "Blaming the deploy, não fui eu", "Calling it quase pronto",
                "Squeezing in one more fix", "Trusting the gambiarra",
                "Taping it with fita isolante", "Doing it do jeito brasileiro",
                "Warming up for the weekend", "Saying tranquilo, chefe",
                "Sending an áudio about it", "Fixing na raça", "Saying é isso aí",
                "Leaving the hard part pra depois", "Celebrating early, foi mal"
            ]
        case .british:
            [
                "Putting the kettle on", "Having a brew first", "Saying ta very much",
                "Queuing politely", "Apologising to the compiler", "Calling it a right faff",
                "Dunking a biscuit", "Muttering bloody hell", "Sorting it out, innit",
                "Blaming the weather", "Proper gutted about this", "Cheers, love, one sec",
                "Making a proper cuppa", "Saying sorry to nobody", "Having a quick moan",
                "Calling it a bit of a nightmare", "Not wanting to make a fuss",
                "Saying it's not ideal", "Popping back to the kettle", "Bit of a pickle, this",
                "Saying no worries at all", "Getting on with it", "Having a proper think",
                "Being terribly sorry", "Waiting for the tea to brew",
                "Muttering about the trains", "Right then, where were we",
                "Fancying a sit down", "Doing the decent thing", "Saying that's a shame, that",
                "Minding the gap in the logic", "Keeping calm, mostly"
            ]
        case .manager:
            [
                "Creating a ticket for this", "Estimating story points",
                "Grooming the backlog", "Scheduling a quick sync", "Aligning stakeholders",
                "Moving it to In Progress", "Blocking on approvals", "Drafting the RFC",
                "Circulating for sign-off", "Adding it to the sprint",
                "Escalating to myself", "Requesting a status update",
                "Booking a follow-up", "Checking capacity this sprint",
                "Adding it to the roadmap", "Looping in the right people",
                "Waiting on the design review", "Updating the ticket",
                "Taking this offline", "Syncing with the other team",
                "Reprioritising the queue", "Writing the status update",
                "Asking for a quick estimate", "Flagging a dependency",
                "Booking a retro about this", "Chasing sign-off", "Parking it for now",
                "Double-clicking on this", "Circling back on it", "Putting a pin in that",
                "Raising it at standup", "Splitting this into two tickets",
                "Checking the definition of done", "Adding it to the risk register",
                "Calling it structurant and hoping nobody asks why"
            ]
        case .frenchManager:
            [
                "Scheduling un point rapide", "Preparing le comité de pilotage",
                "Updating le rétroplanning", "Requesting le compte rendu",
                "Calling this structurant", "Making it more stratégique",
                "Aligning avec la direction", "Waiting for le go",
                "Launching un atelier", "Reviewing le périmètre",
                "Checking la gouvernance", "Adding une slide",
                "Seeking un arbitrage", "Moving it to vendredi",
                "Booking a pause café", "Reframing le besoin",
                "Challenging le planning", "Validating les prochaines étapes",
                "Tracking les indicateurs", "Optimising les ressources",
                "Sharing la vision", "Escalating au directeur",
                "Calling another comité", "Starting with le contexte",
                "Ending with le plan d'action", "Sending le support",
                "Discussing le budget", "Making the deck more impactant",
                "Checking everyone's disponibilité", "Moving the point après déjeuner",
                "Confirming who fait quoi", "Planning the prochain point",
                "Requesting une validation formelle", "Keeping it très haut niveau",
                "Preparing a comité with enough slides to block sunlight",
                "Updating the rétroplanning for the fourth time today",
                "Making it more stratégique with a blue triangle",
                "Checking the gouvernance, just in case it exists",
                "Validating the prochaines étapes, pending more validation",
                "Keeping it très high-level to avoid a real decision"
            ]
        }
    }
}
