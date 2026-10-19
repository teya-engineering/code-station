// The engine shared by every front end. It must build without AppKit or SwiftUI, so the
// terminal UI (and later a daemon) can use it. Files move in here from the GUI target in
// batches; until then this is the only thing in it.
public enum CodeStationCoreLibrary {
    public static let name = "CodeStationCore"
}
