import AppKit
import SwiftUI

// How a pull request's state is drawn, in GitHub's colours, wherever it shows: the light
// on the session chip, the mark and the badge in its card. The two read from here, so a
// state can never be one colour on the chip and another in the card. One not read from
// GitHub yet is Linked, an empty grey ring, until it is.
struct PullRequestTone: Hashable {
    let readiness: PullRequestStatus.Readiness?

    init(_ status: PullRequestStatus?) {
        readiness = status?.readiness
    }

    var word: String { readiness?.label ?? "Linked" }

    // How much the pull request needs the person, most first. The chip names the one
    // that needs them most.
    var urgency: Int {
        switch readiness {
        case .changesRequested?: 0
        case .inReview?: 1
        case .approved?: 2
        case .draft?: 3
        case .merged?: 4
        case .closed?: 5
        case nil: 6
        }
    }

    // The light on the chip.
    var dot: Color {
        switch readiness {
        case .draft?: Theme.dotOff
        case .inReview?: Theme.attention
        case .approved?: Theme.dotOn
        case .changesRequested?, .closed?: Theme.deletion
        case .merged?: Theme.merged
        case nil: Color(nsColor: .tertiaryLabelColor)
        }
    }

    // Not read yet, so the light is an empty ring.
    var dotIsRing: Bool { readiness == nil }

    // The words and the card's mark.
    var ink: Color {
        switch readiness {
        case .draft?, nil: Theme.secondaryText
        case .inReview?: Theme.attentionText
        case .approved?: Theme.dotOnText
        case .changesRequested?, .closed?: Theme.deletionText
        case .merged?: Theme.mergedText
        }
    }

    // The badge behind the word in the card.
    var wash: Color {
        switch readiness {
        case .draft?, nil: Theme.field
        case .inReview?: Theme.inReviewWash
        case .approved?: Theme.approvedWash
        case .changesRequested?: Theme.changesRequestedWash
        case .merged?: Theme.mergedWash
        case .closed?: Theme.closedWash
        }
    }

    // Merged and closed have marks of their own, so the state is never told by colour
    // alone.
    var symbol: PullRequestMark.Symbol {
        switch readiness {
        case .draft?: .draft
        case .merged?: .merge
        case .closed?: .closed
        case .inReview?, .approved?, .changesRequested?, nil: .pull
        }
    }
}
