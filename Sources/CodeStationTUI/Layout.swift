import TerminalKit

// Where each region of the TUI sits on the terminal, as in the GUI's window: the sidebar
// column on the left with a border, the top bar over the main pane, and the main pane.
// Overlays (help, forms, prompts) are drawn over the whole frame and are not regions.
//
// Each region is drawn by its own view at the region's size, and `compose` joins what
// they drew into the frame's rows, so a view never needs to know where it sits.
struct Layout {
    struct Region: Equatable {
        var row: Int
        var col: Int
        var rows: Int
        var cols: Int

        var size: TerminalSize { TerminalSize(cols: cols, rows: rows) }
    }

    // The regions that take the keys, moved between with the focus key.
    enum Focus { case sidebar, main }

    let size: TerminalSize
    // Nil when the sidebar is not drawn: the terminal is too narrow for it beside a
    // usable main pane.
    let sidebar: Region?
    let topBar: Region
    let main: Region

    // One row, empty, while the top bar has nothing to say. Over a session it is taller
    // (see `TopBarView.rows`), and it grows again as rows are added to it.
    static let topBarRows = 1
    // The narrowest the main pane gets beside the sidebar.
    static let minimumMainCols = 20

    // The sidebar is about two fifths of the terminal, between 22 and 34 columns, like the
    // GUI's fixed 318 points next to a window of usual width.
    static func sidebarCols(for cols: Int) -> Int {
        min(34, max(22, cols * 2 / 5))
    }

    // Whether the terminal is too narrow for the sidebar beside a usable main pane, so the
    // sidebar folds away and opens over the main pane instead.
    static func isNarrow(_ cols: Int) -> Bool {
        cols - sidebarCols(for: cols) - 1 < minimumMainCols
    }

    // `showsSidebar` docks the sidebar beside the main pane, where there is room for both.
    // `overlaysSidebar` opens it over the main pane where it is not docked: as wide as it
    // would be docked, with what is left of the main pane beside it, or the whole width
    // when there is no room for that.
    // `topBarRows` is how tall the top bar is: one row, or more over a session.
    init(size: TerminalSize, showsSidebar: Bool = true, overlaysSidebar: Bool = false,
         topBarRows: Int = Layout.topBarRows) {
        self.size = size
        let width = Self.sidebarCols(for: size.cols)
        let rows = max(size.rows, 1)
        if showsSidebar, !Self.isNarrow(size.cols) {
            sidebar = Region(row: 0, col: 0, rows: rows, cols: width)
        } else if overlaysSidebar {
            sidebar = Region(row: 0, col: 0, rows: rows, cols: size.cols - width - 1 >= 1 ? width : max(size.cols, 1))
        } else {
            sidebar = nil
        }
        let left = sidebar.map { $0.cols + 1 } ?? 0
        let topRows = min(topBarRows, rows - 1)
        topBar = Region(row: 0, col: left, rows: max(topRows, 0), cols: max(size.cols - left, 1))
        main = Region(row: topBar.rows, col: left, rows: max(rows - topBar.rows, 1),
                      cols: max(size.cols - left, 1))
    }

    // The frame's rows from what each region drew. The sidebar's rows are its full width
    // already, so the border lines up; the rest are cleared to the end of the row by the
    // screen.
    func compose(sidebar sidebarLines: [String], topBar topLines: [String], main mainLines: [String]) -> [String] {
        (0..<max(size.rows, 0)).map { row in
            var line = ""
            if let sidebar {
                line += (row < sidebarLines.count ? sidebarLines[row] : "") + Style.reset
                // A sidebar over the whole width has nothing beside it.
                guard sidebar.cols < size.cols else { return line }
                line += Style.dim + "│" + Style.reset
            }
            if row < topBar.rows {
                line += row < topLines.count ? topLines[row] : ""
            } else {
                let index = row - main.row
                line += index < mainLines.count ? mainLines[index] : ""
            }
            return line
        }
    }

    // A cursor the main pane placed, moved to where the main pane sits.
    func cursor(inMain cursor: Screen.Cursor?) -> Screen.Cursor? {
        cursor.map { Screen.Cursor(row: $0.row + main.row, col: $0.col + main.col) }
    }
}
