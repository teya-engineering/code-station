# Design system

This is how Code Station looks and behaves, and the parts it is built from. Use it when you build or change anything a person can see.

The code lives in `Sources/MenuBarApp/DesignSystem`. This page says what is there and when to use it. The code is the source of truth for exact values.

## The three rules

1. **Pick a step, not a number.** Sizes, gaps, corners, colours and timings come from the named steps below. A raw number in a feature view is a sign that something is off.
2. **Use the shared part.** If a button, row, card or dialog already exists, use it. Do not draw a look-alike by hand.
3. **Grow the system, not the screen.** If you need something that is missing, add it to `DesignSystem` and to this page, then use it. A one-off inside a feature is how screens drift apart.

## What it should feel like

- **Calm and warm.** Soft paper surfaces, dark ink, one deep green. Nothing shouts.
- **Dense but tidy.** This is a tool for people who work in it all day. Fit a lot in, and keep it lined up.
- **Flat.** Surfaces part by a shade of colour and a thin line. Shadows are rare.
- **Colour has a meaning.** A colour is never there just to look nice. If it is on screen, it says something.
- **It answers.** Every click and hover gets a short, quiet reply.
- **It is our own.** No system-drawn controls. Everything is drawn with the same palette and type.

## Foundations

### Colour

All colours come from `Theme` (`Theme.swift`). Each one works in light and dark mode. Never write a raw `Color(red:...)`, `Color.black` or `Color.white` in a feature.

**Surfaces**, from back to front:

| Step | Use |
| --- | --- |
| `Theme.sidebar` | The sidebar. One shade under the canvas. |
| `Theme.background` | The canvas a pane sits on. |
| `Theme.card` | A card, a header band, a sheet footer. One shade over the canvas. |
| `Theme.field` | A text field or a quiet control. |
| `Theme.sunken` | A row inside a card, where `field` would look like a control. |
| `Theme.statusBand` | The thin line of state under a header. |
| `Theme.terminal` | Command output. Dark in both modes. |

**Text** has three levels: the default, `.foregroundStyle(.secondary)` and `.foregroundStyle(.tertiary)`. Use the default for what people read, secondary for what explains it, and tertiary for what they can ignore.

**Lines**: `Theme.border` goes around a surface. `Theme.hairline` is a rule between two things. `Theme.settingsBorder` and `Theme.settingsHairline` are a stronger pair for places where the normal lines are too faint to see.

**Meaning**. Each of these says one thing, everywhere:

| Colour | Says |
| --- | --- |
| `accent`, `accentFill`, `dotOn` | Ours, chosen, running fine. `accentFill` is for filled buttons. |
| `onFill` | Words and marks on any filled control or filled dot. |
| `attention`, `attentionText`, `secret` | Stopped and waiting for a look. |
| `warningText` on `warningBackground` | Something went wrong. |
| `addition`, `deletion` | Lines added and removed. `deletion` is also the colour of a delete action. Each has an `...NSColor` twin for AppKit text, and a line's band is the same colour, faint. |
| `additionEmphasis`, `deletionEmphasis` | The words that changed within an added or removed line: the same colour as the line's band, a step stronger. Each has an `...NSColor` twin. |
| `plan` | Read only. Nothing will be changed. |
| `brand`, `listen...` | The app itself. Lime on screen means the microphone is open. |
| `showcase`, `snooze...` | A Design session going all out, and a snoozed item. |
| `projectTint(for:)` | A project's own colour. The same one wherever the project shows up. |
| `chartSeries` | Chart lines, in a fixed order. |

Where a colour has a `...Text` twin, use the twin for words and the plain one for dots and fills. The twins are tuned to be readable, and `WarningContrastTests` checks them.

### Type

Roles come from `Typography` (`Tokens.swift`). A role fixes the size and the face.

| Role | Looks like | Use |
| --- | --- | --- |
| `display` | Serif 22 | The name of a whole screen. |
| `title` | Serif 17 | The name of a pane, sheet, card or empty state. |
| `body` | 13 | Text that is read: a sentence, a row's name, a field's value. |
| `detail` | 12 | The sentence under a name. |
| `label` | 12 semibold | The words on a control. |
| `caption` | 11 | A fact beside the main text: a time, a count, a hint. |
| `micro` | 10 semibold | A badge or a count. |
| `code` | Mono 12 | Code and command lines. |
| `data` | Mono 11 | A value the machine made: a path, a branch, an id. |
| `caps` | Mono 10 capitals | The name of a state or a kind. Set it with `.capsText()`. |

- **Three faces, three jobs.** Serif names things. Sans is for reading and for controls. Mono is for anything the machine wrote.
- **Two weights.** Regular for reading, `.weight(.semibold)` for a name or a label. Medium is kept for warnings. Do not use bold.
- **Whole sizes only.** No 11.5 or 12.5.
- **Icons follow their text.** An SF Symbol beside a label takes the label's size and weight. A glyph that stands alone, such as a small chevron or a large empty-state mark, may set its own size.
- **Reading text scales.** The transcript, tool output, diffs and the terminal follow the size the person picked. Use `.scaledText`, `.scaledMono` and `.scaledSerif` there, with a size from `Typography.Size`. The chrome around them stays fixed.
- `Font.logo` is only for the wordmark.
- `BrandWordmark` draws the Code Station name in Sora with green, teal and gold flowing inside the letters. It keeps the text's size and accessibility label, uses `Theme.wordmarkColours` for both appearances and follows the reading scale. Use it for the sidebar brand name.

### Space

Gaps and padding come from `Space` (`Tokens.swift`).

| Step | Points | Typical use |
| --- | --- | --- |
| `xxs` | 2 | A name and the line under it. |
| `xs` | 4 | An icon and its label inside a chip. |
| `sm` | 6 | Parts inside one control. |
| `md` | 8 | Controls side by side. The default gap. |
| `lg` | 12 | Rows in a group. Inside a card. |
| `xl` | 16 | Groups in a section. |
| `xxl` | 20 | The edge of a pane. |
| `xxxl` | 24 | Sections on a page. |

Two steps have a name of their own, because whole screens line up on them:

- `Space.pane` (20): from the edge of a pane, a band or a sheet to what it holds. The header, the content and the footer all start on this line.
- `Space.card` (12): from the edge of a card to what it holds.

Things that belong together sit closer than things that do not. If two gaps look almost the same, make them the same.

### Shape

Corners come from `Radius` (`Tokens.swift`), picked by what the thing is.

| Step | Points | Use |
| --- | --- | --- |
| `tag` | 4 | A chip, a badge, a keycap. |
| `inset` | 6 | A control or row inside another surface, such as a line in a menu. |
| `control` | 8 | A button, a field, a row in a list. |
| `card` | 10 | A card. |
| `floating` | 12 | A menu, a popover, a dialog. |

A shape inside another takes a smaller step than the one around it. A pill or a meter is a `Capsule`.

Draw a surface with the helpers in `Theme.swift`, which pair the fill with its line: `.cardSurface()`, `.fieldSurface()`, or `.surface(_:cornerRadius:)` for another fill.

### Control height

How tall a button, a field or a dropdown stands comes from `ControlHeight` (`Tokens.swift`).

| Step | Points | Use |
| --- | --- | --- |
| `xs` | 20 | A glyph button in a line of text or a dense row. |
| `sm` | 24 | A control inside a row, a chip line or a card's own header. |
| `md` | 28 | A control in a header band or beside a field. `GlyphButton` and the header rail use this. |
| `lg` | 32 | The standard: a sheet footer, a form, a text field, a button on its own. `ActionButton` uses this. |
| `xl` | 36 | The one action an empty pane or a whole form is there to offer. |

`FormMetrics` supplies `dialogWidth` for compact forms, `sheetWidth` for project sheets, the guidance editor height and stacking breakpoint. `FormPair` places two fields side by side and stacks them when the dialog is narrow. Pass `minimumWidth` when pairing larger sections, such as a form and its preview. `ReviewMetrics` supplies the ask, preview, receipt and findings dimensions.

`FormRow` places a label in a 68-point column beside flexible content. Below 360 points it stacks the label above the content. Give it one child for content that shares the same inset without a label.

Controls that share a row share a step. Pass the step to `ActionButton(height:)` and `GlyphButton(side:)`, and give a hand-drawn control the same step with `.frame(height:)`.

`SettingsRuleMetrics` aligns the age and auto-delete columns in a settings card. Below its stacking width, put the description above both controls and repeat their labels.

### Scroll cap

A block that scrolls inside a taller page, such as tool output, log lines or a trace in the transcript, grows with its content up to a cap from `ScrollCap` (`Tokens.swift`) and then scrolls.

| Step | Points | Use |
| --- | --- | --- |
| `short` | 220 | A few readings or the tail of a command's output. |
| `medium` | 320 | Log lines, or a document to read before answering. |
| `tall` | 460 | A whole trace waterfall. |

Set it with `.scrollCap(_:)` on the `ScrollView` (`Layout/ScrollCap.swift`), never with `.frame(maxHeight:)`. The modifier scales the cap with the text, and it keeps the block at its own height when the page offers less. A block that gives way makes the page measure shorter than it draws, and the end of the page can no longer be scrolled into view.

A list inside a card that already scrolls, such as the files in the second opinion receipt, uses `MenuContentScrollView` with a `maxHeight` instead, since it stops at its own edge rather than the page's. Pass `fade:` with the surface behind it and the bottom edge fades while more of the list is below. The receipt's height is `ReviewMetrics.receiptListHeight`: nine and a half rows, so the half row also says there is more.

### Depth

The app is flat. There are two shadows, both in `Elevation` (`Tokens.swift`):

- `.elevation(.raised)`: a small part that slides over its track, such as a switch thumb or the chosen tab.
- `.elevation(.floating)`: a surface over the window. `.floatingCard()` already includes it.

A part that is only lifted in one of its states switches between a step and `.none`.

Hover and selection are shown with colour, not with a shadow.

### Motion

Timings come from `Motion` (`Motion/Motion.swift`). Never write your own duration or spring.

| Curve | Use |
| --- | --- |
| `Motion.hover` | A colour settling under the pointer. |
| `Motion.control` | A control taking a new state. |
| `Motion.reveal` | Something arriving, or one pane swapping for another. |
| `Motion.arrive` | A large surface arriving, such as a dialog. |
| `Motion.pop` | A small mark landing, such as a badge. |
| `Motion.draw` | A line drawing itself. |
| `Motion.leave` | Anything put away. Leaving is always faster than arriving. |
| `Motion.flightAcross`, `Motion.flightDown` | A small mark carried across the window. Across eases out and down eases in, which bends the path into a curve. Going home uses `Motion.flightHomeDuration`, which is shorter. |
| `Motion.stagger` | The step between rows that arrive together, such as the files of a folder opening. Add it as a delay per row, and stop counting after a few rows so a long list does not keep the last one waiting. |
| `Motion.ring` | A ring spreading out from a mark that has just landed. |
| `Motion.washDuration`, `Motion.drawCurve` | A wash fading off words just put into a field. `drawCurve` is `Motion.draw`'s curve for Core Animation. |
| `Motion.wordmarkPeriod` | The slow colour flow inside the app's wordmark. Core Animation plays it through `LayerLoop`; it pauses when the window is hidden and stays still under Reduce Motion. |

- Animate with `.motion(_:value:)`, so it turns off under Reduce Motion. Every transition takes `reduceMotion` and falls back to a plain fade.
- Buttons and pills use `.hoverLift`. Rows use `.hoverFill`. Track the pointer with `.onPointerHover`.
- Both also tell `PointerOverControl` when the pointer is on them. A surface that reacts to a press anywhere on itself checks it, so a press meant for a button inside goes only to that button.
- Transitions: `.headerPage` for a tab page, `.popover` for a panel from a button, `.drawer(from:)` for a panel from an edge, `.fadeIn` for plain new content, `.fold` for content that closes.
- A mark carried from one place to another, such as a tile dropped into a group, is a `FlightView` drawn in an overlay above both places (`Motion/Flight.swift`). The flying view must be plain SwiftUI, since it is scaled on the way. Where it lands, `.landingRings(_:colour:cornerRadius:)` sends out two rings in its colour. Under Reduce Motion neither is drawn: the flight lands at once.
- Words put into a text field by a pick, such as a slash command chosen from the menu, are marked where they land with `TextWash.play(over:in:colour:)` (`Motion/TextWash.swift`): a short wash of the colour that fades on `Motion.washDuration`. Core Animation plays it, so the text is not drawn again, and an edit clears it. Leave it out under Reduce Motion.
- A bar chart over time answers a change with `ChartMotion` (`Motion/ChartMotion.swift`). A change of stretch is a zoom: the time axis moves from the old stretch to the new one with `ChartMotion.zoom`, the old bars squeeze into their place on the new axis as they fade (`zoomLeave`), and the new bars grow up from `zoomGrowth` of their height (`zoomArrive`). Place bars with `ChartMotion.place(_:in:width:)` so both sets share one axis. A change of what the bars measure, or of whose share they show, is a re-stack: the bars keep their places and each takes its new height on `ChartMotion.restack(bar:of:)`, left to right. Home's glance plays `RibbonEntrance` first, when Home opens on a full day. Under Reduce Motion there is no entrance, no zoom and no re-stack.
- A loop that runs while something works is played by `LayerLoop`, not by a SwiftUI clock.
- Motion confirms what the person did and never makes them wait. The brand wordmark's quiet colour flow is the only decorative loop; other motion answers an action or shows work in progress.

The full motion rules are in `CLAUDE.md`.

## Layout

### A screen

From top to bottom:

1. **Header band**: `.headerBand()`. Always 60 points tall, with the screen's name in `display` or `title`, and its actions on the right. Draw the name with `SheetTitle` (see Titles below).
2. **Status band** (optional): `.statusBand(padding:)`. 30 points tall. Says what state the thing is in, using the `Status...` parts.
3. **Sub header** (optional): `.headerBand(height: Theme.subHeaderHeight)`. 48 points tall.
4. **Content**: on `Theme.background`, inset by `Space.pane`. Sections are led by a `SectionRule`.
5. **Footer strip** (optional): `FooterStrip`.

### A sheet

A header band with a `SheetTitle`, an optional status band, then the content, then a `SheetFooter`. The closing action is always at the bottom right, and Escape does the same thing. Sides are inset by `Space.pane`.

When the main action is off and the reason is not plain from the form, say what is missing at the left end of the footer, through the `leading` slot. Give the `SheetAction` the same sentence as its `blockedReason`, so the dead button shows it as a hint, and use `onBlockedClick` to play the sentence in again, so a click on the dead button still gets an answer. The New workspace sheet is the example.

### Titles

A title names the thing. Everything else is shown, not written.

- **A name is a name.** No number and no sentence in it, so it never changes while the sheet is open.
- **One count, in a badge.** `CountBadge` sits beside the name and takes the colour of the state. A count that says nothing is wrong stays grey.
- **Facts are readings.** Thresholds and what is at stake go on the status band, and change in place as the list changes.
- **The why is one click away.** An explanation that is read once goes behind a `WhyButton`, not under the name.

A dialog shows the mark and the name, with no badge. Its mark takes the colour of what will happen.

### A card

A `.cardSurface()` padded by `Space.card`. Rows inside one card are split by a hairline, not drawn as cards of their own. A card does not sit inside another card. Use `Theme.sunken` for a block inside a card.

## Parts

Use these before drawing anything by hand. All paths are under `Sources/MenuBarApp/DesignSystem`.

**Actions** (`Controls/Buttons.swift`)

| Need | Use |
| --- | --- |
| A button with words | `ActionButton`. The tone says how much it matters: `.green` or `.dark` for the main action, `.outlined` beside it, `.danger` to delete. One main action per screen or card. |
| A button that is only an icon | `GlyphButton`, with an `.appTooltip` that names it. Use `circular: true` for an opaque round button that overlaps a surface's edge. |
| A small link in a line of text or a header | `InlineLink`, `GlyphLink` |
| Copy to the clipboard | `CopyButton` |
| Add a new item to a list | `NewItemButton` |

**Choices and input**

| Need | Use |
| --- | --- |
| Pick one from a list | `.appMenu`, or `OptionMenu` for the ready-made dropdown |
| Pick one of a few, all visible | `ChoicePill`s in an `HStack` |
| Pick one of a few as a segmented track, such as the subject of a review | `ChoicePill`s with `icon:` and a shared `thumb:` namespace, in an `HStack` on a `Theme.field` track. The fill slides to the pick on `Motion.control`. |
| A choice in that row that carries a value of its own, such as which branch to compare with | `MenuChoicePill` (`Controls/MenuChoicePill.swift`), beside the `ChoicePill`s. The words pick the choice; the chevron opens an `.appMenu` of values, and so do the words once the choice is picked. Pass `monospaced: true` for a value the machine made, such as a branch. |
| Pick how much, from narrow to wide | `ScopeTrack` (`Controls/ScopeTrack.swift`): stops in order, a knob that slides to the one picked, arrow keys to move along it |
| Turn on any number of a few, all visible | `ToggleChip`: a tick and a tint when on. `ToggleChip(fixed:)` for something always included, shown with a lock. Pass `warns: true` for a choice with a cost. |
| Pick one, each with a sentence | `OptionRow` |
| On or off | `.toggleStyle(.appSwitch)`, `.toggleStyle(.appCheckbox)`, `SettingsToggleRow`. Use `.appSwitch(warns: true)` or `SettingsToggleRow(warns: true)` for a switch with a cost, which turns the attention colour when on. |
| Tick off a changed file as read | `ViewedToggle` (`Controls/ViewedToggle.swift`): an outlined pill with a `CheckboxMark` and "Viewed". `ControlHeight.md` in a pane's header, `.sm` in a card's own header. Pass `edited: true` for a file changed since it was ticked, which gives the pill an amber edge. Kept apart from a row's commit checkbox so the two never read as one. |
| A number in a range | `AppSlider` |
| Text | `.appTextField()`, `AppTextEditor` |
| A count of days | `DayField`. Use `validatesEntry: true` to keep invalid text visible with a correction; Return or leaving the field saves a valid whole number, and Escape restores the saved value. |
| A file or folder | `FilePicker` |
| A label over a field | `LabeledField` |
| A key beside its value | `LabeledRow` |
| A reviewer's model or effort menu | `SeatPill` (`Controls/SeatPill.swift`), with `.appMenu`. Pass `form: true` to fill the available width and wrap long labels, keeping a minimum `ControlHeight.sm` height. The default stays compact. |
| A keyboard shortcut the person sets by pressing it | `KeyRecorder` |
| Sort a sidebar by dragging its rows, or drop one row into another | `.sidebarDrag(_:reorders:drags:drag:onMove:)` (`App/Navigation/SidebarReorder.swift`), with one `SidebarDrag` state per list. It draws the line where the row will land. Set `reorders` to false on rows the dragged one may not sit beside. |
| Sort a stacked list where the order itself means something | `.liveReorder(_:in:spacing:enabled:cornerRadius:state:onDrop:)` (`Controls/LiveReorder.swift`), with one `LiveReorder` state per list. The row follows the pointer after 5 points, so a click still reaches it, and the rows it passes make room at once on `Motion.control`. Read `state.preview(_:)` to show the order before the drop, such as the name on a button. Turn it off while the list is filtered, and give every drag a keyboard and menu twin (Move up, Move down). |
| Mark the first place of an ordered list that has a job of its own | `LeadSlot`: a dashed accent frame with a caption, drawn as a top-aligned background of the list. Leave `LeadSlot.topRoom` above the first row and `LeadSlot.inset` on each side. |
| Say whether a shortcut is a command or a prompt | `KindTile`: the terminal fill for a command, the leaf `userMessage` fill for a prompt. Pair it with the verb (Run or Ask), so the kind never rests on colour alone. |

**Structure**

| Need | Use |
| --- | --- |
| The name of a sheet, dialog or screen | `SheetTitle`: a `TitleMark`, the name and a `CountBadge`, with room for actions on the right |
| A count beside a name | `CountBadge`. Lands with `Motion.pop` and fades out at zero. |
| When a transcript entry happened | `TimeStamp(date:step:)` (`Layout/TimeStamp.swift`): a tertiary mono caption in the format picked in Settings → Appearance, with the full day and second on hover. It reads `\.transcriptTimestamps` and draws nothing when stamps are off, when the date is unknown, or, for a step, when the person chose messages only. A row that puts something next to the stamp, such as a `·`, checks `stamps.shows(date, step:)` first, so the two never disagree. The day the stamps count from comes from `CalendarDay`, so "today" turns into "yesterday" at midnight. |
| An explanation kept out of the way | `WhyButton`: a question mark `GlyphButton` that opens the words in a `.popover` panel |
| A section heading | `SectionRule`. In a form, `SectionLabel`. |
| A group of settings | `ChoiceBlock` holding a `SettingsCard`, with `SettingsRowDivider` between rows |
| A row that opens and closes | `DisclosureHeader` |
| Tabs in a header | `HeaderTabDeck`, `HeaderTabToggle` |
| Buttons in a header | `HeaderRailButton`, `HeaderRailMenuButton`, `HeaderSplitButton` |
| The bottom of a sheet | `SheetFooter` |

**Showing data**

| Need | Use |
| --- | --- |
| A small tag or value | `MonoChip` |
| Lines added and removed | `DiffPair` |
| Changed files as bars, to compare their size | `FileBarRow`, one per file, sharing one `scale`. A file left out keeps grey bars; one brought in draws its colour. Pass `nameWidth` for compact previews. |
| Lines added and removed as bars in a list whose names need the room | `DiffBar`: two short bars on a fixed length (`ReviewMetrics.receiptBarWidth`), on a `scale` the rows share. |
| The shape of a whole change at a glance | `ChangeMap` (`Layout/ChangeMap.swift`): one slice per file, as wide as its lines changed, green over red, with a wider gap between groups and a group's name under it when it is wide enough. Hovering a slice names it and clicking opens it. Pass a `focus` to light one group or file and dim the rest, and use `hover` to light the matching row in the list beside it. It draws in left to right with `Motion.draw` through a mask. It is one image to assistive tech and not a tab stop, so the list beside it must carry the same facts. |
| The range a review covers | `ComparisonRange`: the base, HEAD and working tree, or the previous review snapshot. It draws the included range without inventing commit counts. Pass `compact: true` for a 30-point strip with no card, at the head of a card that already names the range. |
| State in a status band | `StatusCaps`, `StatusValue`, `StatusDot`, `StatusRule` |
| How full something is | `Meter` |
| How far through a short list the person is | `ProgressRing` (`Layout/ProgressRing.swift`): a 14-point ring beside a count such as "3 of 7 viewed". The arc draws round with `Motion.draw`. The words carry the count, so the ring stays out of the accessibility tree. |
| A few readings on one slim line, each with a closer look | A row of cells, each a dot, a name, the reading and a `ChangeFigure`. Resting on a cell opens a `ReadingPeek` (`Layout/StatParts.swift`) above it, as the content of a hanging `Tooltip` with `side: .above`: the name, the reading, how it moved in words ("18% less than yesterday"), and a `Sparkline` that draws itself out from the left. The figures roll with `.numericText` when the reading moves. |
| A run of readings, as a line | `Sparkline`. Pass a long run through `Sparkline.thinned` first, so it keeps its shape at a small size. |
| A small fact in a grid of them | `StatFact`: label, reading, and an optional line saying what it means; pass `icon:` to lead with an `IconBadge` |
| One thing's share of a whole, beside others | `ShareBarRow`, one per thing, sharing one `scale`. The bar draws out with `Motion.draw` when the row arrives. |
| A count by weekday and hour | `HeatGrid`: hovering a cell says what it holds on the line under the grid, with a less-to-more key beside it |
| What a number measures, as a mark | `IconBadge`: a symbol on a soft square (or `round: true` circle) of the reading's own colour |
| How a number moved, beside the number | `ChangeFigure`: a small coloured figure with an arrow, green when the move is the good way and amber when not (`lowerIsBetter` for waits and costs). `ChangeFigure.words` says the move as "18% more" or "18% less". |
| A record worth celebrating | `RecordBadge`: an `IconBadge` on a round, the caps label, the reading, and a line under it, on a faint wash of its colour |
| A whole split into a few parts along one line | `ShareStrip`: one segmented bar with a key under it; pass the rest as an "Other" part in `Theme.dotOff` |
| A whole split into a few parts, as a ring | `ShareDonut`: the parts round a ring with the leading share in the middle and a key beside it |
| A note set apart inside a card, such as a tip | `.washSurface(tint:)`: a faint wash of the note's colour with an edge in the same colour |
| Work the person is waiting on, with how far it has got | `ProgressCard`: a `LoopSpinner`, a title, a sentence and a `Meter` with "120 of 412 sessions". On its own in an empty pane for a first load; `compact: true` for a tinted strip over content already on screen while more arrives. |
| Run effort and permissions | `EffortMeter`, `EffortPill`, `ShieldPill` and `TrustTone` in `Controls/RunSettingsPills.swift`. Pass `form: true` to the pills for a full-width, 36-point form control; their default stays compact for composer bars. |
| A project's mark | `ProjectDot`, `ProjectTileView` |
| Something running | `RunningDot` |
| A keyboard key | `Keycap` |
| A key the person may have changed | `KeyCombo.label`, `.compactLabel` or `.parts`, read from `keyBindings` |
| JSON | `RawJSONView` |
| A text view that holds code | Call `turnOffProseHelpers()` and paint it with `paintCode`, both in `CodeTextView.swift` |

**Over the window**

| Need | Use |
| --- | --- |
| Tell or ask the person something | `Dialog.notice`, `Dialog.confirm`, shown through `DialogPresenter` |
| Confirm a deletion | `Dialog.impact`: a row for each thing that goes, a row for each thing that stays, and a warning for anything that cannot be restored |
| Say what an action already did, with a way back | `Dialog.receipt` (`Controls/ReceiptDialog.swift`): the impact card with a deck on top showing the group and the new member landing in it, a plus row for what came in, tick rows for what stays, an optional choice, and Undo in the footer. Return, Escape and a click outside all close it, since the action is already done. Use it for a cheap action that is fully undone, instead of asking first. |
| A right-click menu | `.appContextMenu` |
| A hint on hover | `.appTooltip` |
| A click that did its work outside the window | `HeaderNote`, shown for a moment by a `TransientNote`. The view holds one in `@State`, calls `show(_:icon:)` on the click and draws it with `.headerNote(_:alignment:top:trailing:)`. A second note takes the place of the first. Pass a `duration` only when the note must stay shorter or longer than usual. |
| Mark what a floating card is about | `.subjectRail(_:)`: a line drawn down the leading edge of the thing while the card is open |
| Keep keyboard focus inside a floating surface | `.focusBoundary(active:)`: contains Tab and Shift-Tab in the surface and restores focus on dismissal. Pause it while a child menu or dialog is open. |

The system file chooser (`NSOpenPanel`, `NSSavePanel`) is the only native surface allowed. Never use `NSAlert`, `.alert`, `.confirmationDialog`, `.contextMenu`, `Menu`, `Picker`, the built-in button and toggle styles, or `.textFieldStyle(.roundedBorder)`.

## Keys

Every key the app answers is listed once in `AppCommand` (`Features/Settings/KeyBindings.swift`), with what it does, the key it starts with, and where it works. The Keyboard page in Settings is built from that list, and the person can move any key marked `canChange`.

- Bind a key the person can change with `.appShortcut(.command)` on a hidden button, `.keyMonitor(_:follows:)` on a `WindowKeyMonitor`, or `handler.pressed(.command, event)` inside a `WindowKeyHandler`. Never write that key itself in a view.
- Write a key in a hint or a tooltip from `keyBindings`: `keys(for:)` for the key, `tooltip(_:for:)` for "Name (⌘K)". A key can be taken away, so the hint must hide when there is none.
- Give a key the scope it really has. `.window` keys are live everywhere. A `.pane` key is live in one area, and `firstClaim` says it is caught by a monitor or a handler, so it is asked before the window's own keys and may share one. A key bound to a SwiftUI button has no first claim. The Keyboard page uses the scope to refuse a key that would clash.
- Keys that follow a convention stay fixed: Escape, Return, Tab, the arrows, single letters that only work while nothing is typed, and the standard editing keys. They are still listed, and are still written where they are bound.
- A new key goes into `AppCommand` first, or nothing on screen will say it exists.

## States

Every view should have an answer for each of these.

| State | How it shows |
| --- | --- |
| Empty | `PaneMessage`: an icon, a title, a line that says why, and the way out if there is one. |
| Working | A `LayerLoop` spinner or a `RunningDot`. Keep what was there on screen while new data loads. |
| Failed | `.warningCard()` for one card, `WarningStrip` for the whole screen. Say what went wrong and offer the fix. |
| Hover | `.hoverLift` or `.hoverFill`. |
| Selected | The accent colour: a tint, a line or a tick. |
| Disabled | `.disabled(true)`. The shared controls dim themselves. |
| Keyboard focus | `FocusRingStroke`. |

## Before you call it done

- No raw sizes, heights, colours, corners or timings in the view.
- Every part that has a shared version uses it.
- It lines up with the screen around it: same inset, same header height, same type roles.
- It has all its states: empty, working, failed, hover, disabled.
- It moves when it arrives, leaves and is clicked, and stands still under Reduce Motion.
- It reads well in light and dark mode.
- You looked at it in the running app.

## Older code

Some screens were built before these steps had names, and still hold raw numbers. When you touch such a view, move what you touch onto the steps. A value that falls between two steps goes to the nearer one.
