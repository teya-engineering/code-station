import SwiftUI

// The fixed steps the interface is built from: type, space, corners and depth. Colour
// lives in `Theme` and timing in `Motion`. A view picks a step by what the thing is, not
// by a number, so two screens built apart still land on the same sizes.
// docs/design-system.md says which step is for what.

// MARK: - Type

// One role per kind of text. A role fixes the size and the face. Weight is the one thing
// a caller may change, with `.weight(.semibold)` for a name or a label.
enum Typography {
    // Whole points only. Half a point is too small a step to read as a choice, so it
    // only ever reads as two labels that do not quite match.
    enum Size {
        static let micro: CGFloat = 10
        static let caption: CGFloat = 11
        static let detail: CGFloat = 12
        static let body: CGFloat = 13
        static let title: CGFloat = 17
        static let display: CGFloat = 22
    }

    // The name of a whole screen.
    static let display = Font.serif(Size.display)
    // The name of a pane, a sheet, a card or an empty state.
    static let title = Font.serif(Size.title)

    // Text that is read: a sentence, a row's name, a field's value.
    static let body = Font.system(size: Size.body)
    // The sentence under a name, and anything else that explains.
    static let detail = Font.system(size: Size.detail)
    // The words on a control.
    static let label = Font.system(size: Size.detail, weight: .semibold)
    // A fact beside the main text: a time, a count, a hint.
    static let caption = Font.system(size: Size.caption)
    // A badge or a count on a mark.
    static let micro = Font.system(size: Size.micro, weight: .semibold)

    // Code and command lines.
    static let code = Font.mono(Size.detail)
    // A value the machine made: a path, a branch, an id.
    static let data = Font.mono(Size.caption)
    // Mono capitals that name a state or a kind. Set with `capsText()`, which also
    // spaces the letters.
    static let caps = Font.mono(Size.micro, .semibold)
    static let capsKerning: CGFloat = 0.6
}

extension View {
    func capsText() -> some View {
        font(Typography.caps).kerning(Typography.capsKerning)
    }
}

// MARK: - Space

// Gaps and padding. The steps are far enough apart to be told from each other, which is
// what stops a screen from collecting 7s, 9s and 11s that all mean "about 8".
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let xxxl: CGFloat = 24

    // From the edge of a pane, a band or a sheet to what it holds. Shared, so a header,
    // the content under it and the footer that closes it all start on one line.
    static let pane = xxl
    // From the edge of a card to what it holds.
    static let card = lg
}

// MARK: - Shape

// Corners, by what the thing is. A shape inside another takes a smaller step than the
// one around it, so the two curves stay parallel.
enum Radius {
    // A chip, a badge, a keycap.
    static let tag: CGFloat = 4
    // A control or a row drawn inside another surface, such as a line in a menu.
    static let inset: CGFloat = 6
    // A button, a field, a row in a list.
    static let control: CGFloat = 8
    // A card.
    static let card: CGFloat = 10
    // Anything that floats over the window: a menu, a popover, a dialog.
    static let floating: CGFloat = 12
}

// MARK: - Control height

// How tall a button, a field or a dropdown stands. Controls that share a row share a
// step, so their edges line up without anyone measuring.
enum ControlHeight {
    // A glyph button tucked into a line of text or a dense row.
    static let xs: CGFloat = 20
    // A control inside a row, a chip line or a card's own header.
    static let sm: CGFloat = 24
    // A control in a header band or beside a field.
    static let md: CGFloat = 28
    // The standard: a sheet footer, a form, a button standing on its own.
    static let lg: CGFloat = 32
    // The one action an empty pane or a whole form is there to offer.
    static let xl: CGFloat = 36
}

// MARK: - Depth

// The app is flat. Surfaces part by colour and a hairline, and a shadow is kept for the
// two cases where something really is above the page.
struct Elevation {
    let opacity: Double
    let radius: CGFloat
    let y: CGFloat

    // Flat, for a part that only lifts in one of its states.
    static let none = Elevation(opacity: 0, radius: 0, y: 0)
    // A small part that slides over its own track: a switch thumb, a slider knob, the
    // chosen tab.
    static let raised = Elevation(opacity: 0.12, radius: 1.5, y: 1)
    // A surface over the window: a menu, a tooltip, a dialog.
    static let floating = Elevation(opacity: 0.16, radius: 18, y: 6)
}

extension View {
    func elevation(_ elevation: Elevation) -> some View {
        shadow(color: .black.opacity(elevation.opacity), radius: elevation.radius, y: elevation.y)
    }
}
