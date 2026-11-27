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
        static let wordmark: CGFloat = 15
        static let title: CGFloat = 17
        static let display: CGFloat = 22
        static let figure: CGFloat = 34
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
    static let wordmarkKerning: CGFloat = -0.55
}

extension View {
    func capsText() -> some View {
        font(Typography.caps).kerning(Typography.capsKerning)
    }
}

// The brand lockup keeps its artwork and text metrics independent of control sizing.
enum BrandMetrics {
    static let barHeight: CGFloat = 68
    static let drawingSide: CGFloat = 41
    static let layoutSide: CGFloat = 33
    static let ownerSize: CGFloat = 9
    static let nameGap: CGFloat = 1
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

// MARK: - Chart

// The sizes a chart in a reply is built from. A chart is drawn by hand, so its lanes,
// rail and marks take their sizes from here the way a form takes its from `FormMetrics`.
enum ChartMetrics {
    // The first lane holds the series the finding is about, so it stands tallest. Each
    // lane after it is a strip of context.
    static let leadLaneHeight: CGFloat = 172
    static let laneHeight: CGFloat = 76
    static let laneGap: CGFloat = 24
    // The room above the plot where moments are named, two rows of flags deep.
    static let railHeight: CGFloat = 46
    static let flagRows = 2
    static let flagHeight: CGFloat = 18
    static let flagStep: CGFloat = 22
    static let flagGap: CGFloat = 4
    static let flagEdge: CGFloat = 2
    // With no moments to name, the rail only holds the unit over the first lane.
    static let unitRoom: CGFloat = 18
    static let axisHeight: CGFloat = 24
    static let axisWidth: CGFloat = 40
    static let trailingInset: CGFloat = Space.lg
    // One mark of the time axis for about this much width.
    static let tickSpacing: CGFloat = 88

    static let lineWidth: CGFloat = 2
    static let sparkLineWidth: CGFloat = 1.75
    static let endDot: CGFloat = 3.5
    static let hoverDot: CGFloat = 4.5
    static let keyWidth: CGFloat = 14
    static let keyHeight: CGFloat = 3
    // How far a series fades while another one is pointed at in the strip.
    static let dimmed: Double = 0.16
    // The longest a series name may run in the strip before it is cut in the middle.
    static let nameWidth: CGFloat = 220

    static let barHeight: CGFloat = 14
    static let barNameShare: CGFloat = 0.46
    // The room kept at the end of a bar's track for its number.
    static let barValueRoom: CGFloat = 64
    static let statMinHeight: CGFloat = 104
    static let sparkHeight: CGFloat = 44
    static let meterHeight: CGFloat = 8
    static let cometHeight: CGFloat = 56

    // The strip of log volume above the lines.
    static let rhythmHeight: CGFloat = 50
    static let rhythmBars = 60
    static let rhythmGap: CGFloat = 2
}

// MARK: - Scroll cap

// How tall a block that scrolls inside a page may grow before it scrolls instead, such as
// tool output in a transcript. Set with `.scrollCap(_:)`, which scales it with the text.
enum ScrollCap {
    // A few readings or the tail of a command's output.
    static let short: CGFloat = 220
    // Log lines or a document to read before answering.
    static let medium: CGFloat = 320
    // A whole trace waterfall.
    static let tall: CGFloat = 460
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

// Shared dimensions for dialog and sheet forms.
enum FormMetrics {
    static let dialogWidth: CGFloat = 460
    static let sheetWidth: CGFloat = 680
    static let guidanceHeight: CGFloat = 96
    static let pairedFieldsWidth: CGFloat = 340
    static let rowLabelWidth: CGFloat = 68
    static let inlineRowWidth: CGFloat = 360
}

enum NumberFieldMetrics {
    static let compactWidth: CGFloat = 36
    static let wideWidth: CGFloat = 60
}

// Aligned age and action columns in a settings rule table.
enum SettingsRuleMetrics {
    static let stackedWidth: CGFloat = 520
    static let ageWidth: CGFloat = 120
    static let actionWidth: CGFloat = 150
}

// The sizes Dispatch's sheet holds to, so the request list, the address and the answer
// line up the same way whatever is in them.
enum DispatchMetrics {
    static let sheet = CGSize(width: 1020, height: 720)
    static let libraryWidth: CGFloat = 236
    static let titleRowHeight: CGFloat = 50
    static let addressLineHeight: CGFloat = 46
    static let goesToHeight: CGFloat = 30
    static let wireHeight: CGFloat = 2
    // A parameter or header row, and the columns its kind and name keep.
    static let rowHeight: CGFloat = 34
    static let kindWidth: CGFloat = 40
    static let nameWidth: CGFloat = 168
    static let responseHeaderHeight: CGFloat = 44
    // Room for the longest wait the counter shows, so its ticking moves nothing beside it.
    static let elapsedWidth: CGFloat = 56
    static let dot: CGFloat = 6
    static let spinner: CGFloat = 16
}

enum ReviewMetrics {
    static let askWidth: CGFloat = 640
    static let askHeight: CGFloat = 760
    static let columnsWidth: CGFloat = 680
    static let rangeHeight: CGFloat = 44
    static let rangeStripHeight: CGFloat = 30
    static let fileNameWidth: CGFloat = 260
    // The change receipt in the ask stops at nine and a half rows and scrolls inside, so
    // a big review keeps the card one size and the half row says there is more.
    static let receiptListHeight: CGFloat = ControlHeight.md * 9.5
    static let receiptBarWidth: CGFloat = 84
    // Room for a row's file count and its "+n −n", so the bars line up down the list.
    static let receiptCountWidth: CGFloat = 52
    static let receiptFiguresWidth: CGFloat = 88
    static let findingsWidth: CGFloat = 1000
    static let findingsListWidth: CGFloat = 280
}

enum SkillsMetrics {
    // One column per agent, narrow enough that four leave the package names room.
    static let hostColumnWidth: CGFloat = 160
}
