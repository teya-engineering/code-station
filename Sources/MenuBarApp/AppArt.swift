import AppKit

// The app mark, shared by the sidebar and the Dock icon generator. Loaded once because
// the same image is drawn on every sidebar update.
enum AppArt {
    static let logo = Bundle.module.image(forResource: "AppIcon")
}
