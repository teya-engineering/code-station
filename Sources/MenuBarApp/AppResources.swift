import Foundation

// SwiftPM's own `Bundle.module` looks for the resource bundle beside the executable and
// then at the path it was built at. Neither is where an app bundle keeps it: `build-app.sh`
// puts it in `Contents/Resources`, so an installed app silently reads the resources of
// whichever build directory happens to still be on the machine, and a machine without one
// crashes on the fatalError inside `Bundle.module`.
enum AppResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(bundleName),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    private static let bundleName = "MenuBarApp_MenuBarApp.bundle"
}
