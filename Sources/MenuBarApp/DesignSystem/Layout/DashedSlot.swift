import SwiftUI

// An empty place that something can be put into, such as the seat a picked project
// lands in or the last row of a list that adds one more. A dashed edge in the given
// colour, over a faint wash of it when `filled`.
extension View {
    func dashedSlot(_ colour: Color, cornerRadius: CGFloat = Radius.control,
                    filled: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(colour.opacity(filled ? 0.07 : 0)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(colour, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
