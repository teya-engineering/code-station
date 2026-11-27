import SwiftUI

// The end of a long text the machine made, read only. The last lines sit at the bottom
// and the ones above fade out, so it reads as the tail of something longer rather than
// as the whole of it.
struct TailBlock: View {
    let lines: [String]
    // What a screen reader says in place of the lines, which are only a sample.
    let label: String
    // Lines that name who is speaking are drawn stronger than what was said.
    var isHeading: (String) -> Bool = { _ in false }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let heading = isHeading(line)
                // An empty line still takes its row, so the gaps between blocks survive.
                Text(verbatim: line.isEmpty ? " " : line)
                    .font(Typography.data.weight(heading ? .semibold : .regular))
                    .foregroundStyle(heading ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                     .init(color: .black, location: 0.46)],
                             startPoint: .top, endPoint: .bottom))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
