import SwiftUI

// The environment a server is tagged with, offered wherever one is picked. The empty tag
// is a real choice rather than a missing answer: a filesystem or docs server is not tied
// to a deployment, and a diagnosis in any environment should still be able to use it.
struct ServerEnvironmentChoice: Identifiable, Equatable {
    let tag: String
    let title: String

    var id: String { tag }

    static let any = ServerEnvironmentChoice(tag: "", title: "Any")

    // A tag the site file has stopped naming is kept on the end of the list, so a server
    // carrying one still shows what it says instead of reading as if it had none.
    static func all(including tag: String = "",
                    in defaults: SiteDefaults = .current) -> [ServerEnvironmentChoice] {
        var choices = [any] + defaults.deployEnvironments.map {
            ServerEnvironmentChoice(tag: $0.name, title: $0.label)
        }
        if !tag.isEmpty, !choices.contains(where: { $0.tag == tag }) {
            choices.append(ServerEnvironmentChoice(tag: tag, title: tag))
        }
        return choices
    }

    static func title(for tag: String, in defaults: SiteDefaults = .current) -> String {
        all(including: tag, in: defaults).first { $0.tag == tag }?.title ?? any.title
    }

    var subtitle: String {
        tag.isEmpty
            ? "Offered in every environment."
            : "Offered only in \(title) diagnoses."
    }
}

// A row of pills for picking the environment a server belongs to.
struct ServerEnvironmentPills: View {
    @Binding var tag: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ServerEnvironmentChoice.all(including: tag)) { choice in
                ChoicePill(title: choice.title, selected: tag == choice.tag) {
                    tag = choice.tag
                }
            }
        }
    }
}

// The same choices as a menu, for the places a row of pills would not fit.
extension ServerEnvironmentChoice {
    static func menu(selected: String,
                     choose: @escaping (String) -> Void) -> [MenuEntry] {
        all(including: selected).map { choice in
            .item(choice.title,
                  checked: choice.tag == selected,
                  subtitle: choice.subtitle,
                  action: { choose(choice.tag) })
        }
    }
}
