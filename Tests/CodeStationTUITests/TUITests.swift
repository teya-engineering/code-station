import Testing

// Every headless TUI test, one at a time. Quitting the TUI runs the station's quit sweep,
// which ends every process the test process started, so a quit in one test would stop
// the fake agents and git commands of another running beside it.
@Suite(.serialized)
enum TUITests {}
