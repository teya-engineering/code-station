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
| `addition`, `deletion` | Lines added and removed. `deletion` is also the colour of a delete action. |
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

`FormMetrics` supplies the width, guidance editor height and stacking breakpoint for compact dialog forms. `FormPair` places two fields side by side and stacks them when the dialog is narrow.

`FormRow` places a label in a 68-point column beside flexible content. Below 360 points it stacks the label above the content. Give it one child for content that shares the same inset without a label.

Controls that share a row share a step. Pass the step to `ActionButton(height:)` and `GlyphButton(side:)`, and give a hand-drawn control the same step with `.frame(height:)`.

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
| `Motion.ring` | A ring spreading out from a mark that has just landed. |

- Animate with `.motion(_:value:)`, so it turns off under Reduce Motion. Every transition takes `reduceMotion` and falls back to a plain fade.
- Buttons and pills use `.hoverLift`. Rows use `.hoverFill`. Track the pointer with `.onPointerHover`.
- Both also tell `PointerOverControl` when the pointer is on them. A surface that reacts to a press anywhere on itself checks it, so a press meant for a button inside goes only to that button.
- Transitions: `.headerPage` for a tab page, `.popover` for a panel from a button, `.drawer(from:)` for a panel from an edge, `.fadeIn` for plain new content, `.fold` for content that closes.
- A mark carried from one place to another, such as a tile dropped into a group, is a `FlightView` drawn in an overlay above both places (`Motion/Flight.swift`). The flying view must be plain SwiftUI, since it is scaled on the way. Where it lands, `.landingRings(_:colour:cornerRadius:)` sends out two rings in its colour. Under Reduce Motion neither is drawn: the flight lands at once.
- A loop that runs while something works is played by `LayerLoop`, not by a SwiftUI clock.
- Motion confirms what the person did. It never makes them wait and never plays for something they did not cause.

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
| Pick how much, from narrow to wide | `ScopeTrack` (`Controls/ScopeTrack.swift`): stops in order, a knob that slides to the one picked, arrow keys to move along it |
| Turn on any number of a few, all visible | `ToggleChip`: a tick and a tint when on. `ToggleChip(fixed:)` for something always included, shown with a lock. Pass `warns: true` for a choice with a cost. |
| Pick one, each with a sentence | `OptionRow` |
| On or off | `.toggleStyle(.appSwitch)`, `.toggleStyle(.appCheckbox)`, `SettingsToggleRow`. Use `.appSwitch(warns: true)` or `SettingsToggleRow(warns: true)` for a switch with a cost, which turns the attention colour when on. |
| A number in a range | `AppSlider` |
| Text | `.appTextField()`, `AppTextEditor` |
| A date | `DayField` |
| A file or folder | `FilePicker` |
| A label over a field | `LabeledField` |
| A key beside its value | `LabeledRow` |
| A reviewer's model or effort menu | `SeatPill` (`Controls/SeatPill.swift`), with `.appMenu`. Pass `form: true` to fill the available width and wrap long labels, keeping a minimum `ControlHeight.sm` height. The default stays compact. |
| A keyboard shortcut the person sets by pressing it | `KeyRecorder` |
| Sort a sidebar by dragging its rows, or drop one row into another | `.sidebarDrag(_:reorders:drags:drag:onMove:)` (`App/Navigation/SidebarReorder.swift`), with one `SidebarDrag` state per list. It draws the line where the row will land. Set `reorders` to false on rows the dragged one may not sit beside. |
| Sort a stacked list where the order itself means something | `.liveReorder(_:in:spacing:enabled:cornerRadius:state:onDrop:)` (`Controls/LiveReorder.swift`), with one `LiveReorder` state per list. The row follows the pointer after 5 points, so a click still reaches it, and the rows it passes make room at once on `Motion.control`. Read `state.preview(_:)` to show the order before the drop, such as the name on a button. Turn it off while the list is filtered, and give every drag a keyboard and menu twin (Move up, Move down). |
| Mark the first place of an ordered list that has a job of its own | `LeadSlot`: a dashed accent frame with a caption, drawn as a top-aligned background of the list. Leave `LeadSlot.topRoom` above the first row and `LeadSlot.inset` on each side. |
| Say whether a shortcut is a command or a prompt | `KindTile`: the terminal fill for a command, the leaf `userMessage` fill for a prompt. Pair it with the verb (Run or Insert), so the kind never rests on colour alone. |

**Structure**

| Need | Use |
| --- | --- |
| The name of a sheet, dialog or screen | `SheetTitle`: a `TitleMark`, the name and a `CountBadge`, with room for actions on the right |
| A count beside a name | `CountBadge`. Lands with `Motion.pop` and fades out at zero. |
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
| Changed files as bars, to compare their size | `FileBarRow`, one per file, sharing one `scale`. A file left out keeps grey bars; one brought in draws its colour. |
| State in a status band | `StatusCaps`, `StatusValue`, `StatusDot`, `StatusRule` |
| How full something is | `Meter` |
| Run effort and permissions | `EffortMeter`, `EffortPill`, `ShieldPill` and `TrustTone` in `Controls/RunSettingsPills.swift`. Pass `form: true` to the pills for a full-width, 36-point form control; their default stays compact for composer bars. |
| A project's mark | `ProjectDot`, `ProjectTileView` |
| Something running | `RunningDot` |
| A keyboard key | `Keycap` |
| A key the person may have changed | `KeyCombo.label`, `.compactLabel` or `.parts`, read from `keyBindings` |
| Code or JSON | `CodeTextView`, `RawJSONView` |

**Over the window**

| Need | Use |
| --- | --- |
| Tell or ask the person something | `Dialog.notice`, `Dialog.confirm`, shown through `DialogPresenter` |
| Confirm a deletion | `Dialog.impact`: a row for each thing that goes, a row for each thing that stays, and a warning for anything that cannot be restored |
| Say what an action already did, with a way back | `Dialog.receipt` (`Controls/ReceiptDialog.swift`): the impact card with a deck on top showing the group and the new member landing in it, a plus row for what came in, tick rows for what stays, an optional choice, and Undo in the footer. Return, Escape and a click outside all close it, since the action is already done. Use it for a cheap action that is fully undone, instead of asking first. |
| A right-click menu | `.appContextMenu` |
| A hint on hover | `.appTooltip` |
| A click that did its work outside the window | `HeaderNote` |
| Mark what a floating card is about | `.subjectRail(_:)`: a line drawn down the leading edge of the thing while the card is open |

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
