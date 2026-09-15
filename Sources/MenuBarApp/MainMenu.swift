import AppKit

// The menu bar is drawn by macOS, so it is the one piece of system chrome the app cannot
// replace with something of its own. It is built by hand here rather than coming from a
// SwiftUI scene: the app's window is an AppKit one, and a scene declared only to earn a
// menu has nothing to show, which leaves it free to turn up on screen as a blank window.
@MainActor
enum MainMenu {
    static func install() {
        let bar = NSMenu()
        bar.addItem(entry(appName, appMenu()))
        bar.addItem(entry("Edit", editMenu()))
        bar.addItem(entry("View", viewMenu()))

        let windows = windowMenu()
        bar.addItem(entry("Window", windows))

        NSApp.mainMenu = bar
        NSApp.windowsMenu = windows
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("About \(appName)",
                          #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())

        let services = NSMenu()
        menu.addItem(entry("Services", services))
        NSApp.servicesMenu = services

        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), key: "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)),
                          key: "h", modifiers: [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), key: "q"))
        return menu
    }

    // The composer, the diff views and the terminal are all text, so they need the
    // standard editing keys the rest of the Mac has.
    private static func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Undo", NSSelectorFromString("undo:"), key: "z"))
        menu.addItem(item("Redo", NSSelectorFromString("redo:"),
                          key: "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)),
                          key: "v", modifiers: [.command, .option, .shift]))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        return menu
    }

    // Text size is in the View menu because that is where Cmd+ and Cmd- live in every
    // other Mac app. The menu is also the only place these keys can be found: bound to a
    // hidden button in the window the way the app's other shortcuts are, nothing on
    // screen would ever say they exist, and this is the one setting whose whole point is
    // helping someone who is struggling to read.
    private static func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Bigger Text", #selector(AppDelegate.biggerText(_:)), key: "+"))
        menu.addItem(item("Smaller Text", #selector(AppDelegate.smallerText(_:)), key: "-"))
        menu.addItem(item("Actual Size", #selector(AppDelegate.actualSizeText(_:)), key: "0"))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)),
                          key: "f", modifiers: [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func entry(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        submenu.title = title
        return item
    }

    // Every item is left without a target so it travels the responder chain, which is what
    // lets whatever holds focus answer Cut and Copy for itself.
    private static func item(_ title: String, _ action: Selector, key: String = "",
                             modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
